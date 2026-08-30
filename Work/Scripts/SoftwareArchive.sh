#!/bin/bash
# SoftwareArchive 主脚本（macOS 版）
# 用法：bash SoftwareArchive.sh [-Action Menu|Init|RebuildIndex|Verify]

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SELF_DIR/SoftwareArchiveCore.sh"

sa_init_locale
detect_system_proxy

ACTION='Menu'
if [ "${1:-}" = '-Action' ] && [ -n "${2:-}" ]; then
    ACTION=$2
elif [ -n "${1:-}" ]; then
    ACTION=$1
fi
case $ACTION in
    Menu|Init|RebuildIndex|Verify|List) : ;;
    *) ACTION='Menu' ;;
esac

sa_paths_init "$SELF_DIR"
mkdir -p "$CONFIG_DIR"
[ -f "$CONFIG_FILE" ] || write_file "$CONFIG_FILE" "$(sa_default_config_text)"
sa_read_config
LIBRARY_DIR=$(resolve_path "$CONFIG_DIR" "$LIBRARY_PATH_CFG")
if [ "$LIBRARY_DIR" = '/' ] || [ "$LIBRARY_DIR" = "$ROOT_DIR" ]; then
    printf '%s\n' 'config.yml 中的 library_path 范围过大，请指向一个专用 Library 目录。'
    exit 1
fi
INDEX_FILE="$LIBRARY_DIR/资源索引.xlsx"
sa_init_environment

trap 'if [ -n "${SA_ACTIVE_DOWNLOAD_PID:-}" ]; then kill "$SA_ACTIVE_DOWNLOAD_PID" 2>/dev/null; wait "$SA_ACTIVE_DOWNLOAD_PID" 2>/dev/null; SA_ACTIVE_DOWNLOAD_PID=""; fi; printf "\n%s\n" "${GRAY}已中断。${NONE}"; exit 130' INT

# ---------- 颜色与基础 UI ----------

NONE=$'\033[0m'; DARK=$'\033[90m'; CYAN=$'\033[96m'; GRAY=$'\033[37m'
WHITE=$'\033[97m'; YELLOW=$'\033[93m'; GREEN=$'\033[32m'; RED=$'\033[31m'

sa_clear() { if [ -t 1 ]; then clear; fi; }

show_header() { # title [lines...]
    local title=$1; shift
    sa_clear
    printf '%s\n' "${DARK}============================================================${NONE}"
    printf '%s\n' "${CYAN}  ${title}${NONE}"
    printf '%s\n' "${DARK}============================================================${NONE}"
    if [ $# -gt 0 ]; then
        local l
        for l in "$@"; do
            if [ -n "$l" ]; then printf '%s\n' "${GRAY}${l}${NONE}"; else printf '\n'; fi
        done
        printf '\n'
    fi
}

wait_for_user() {
    local msg=${1:-'按任意键返回……'}
    printf '\n'
    printf '%s\n' "${DARK}${msg}${NONE}"
    if [ -t 0 ]; then local k; IFS= read -rsn1 k; fi
}

read_key() {
    # 有按键助手时（交互终端 + perl 可用）：从管道读已解析的 token，
    # 单独按 Esc 约 40ms 内返回；无助手时回退到 bash 原生读取（Esc 约延迟 1 秒）。
    if [ -n "${SA_KEY_FD:-}" ]; then
        if ! IFS= read -r KEY <&"$SA_KEY_FD"; then
            printf '\n%s\n' '输入已结束，程序退出。'
            exit 130
        fi
        [ -n "$KEY" ] && return 0
        # 助手不会输出空行；防御性忽略后再读
        KEY=''
        return 0
    fi
    local k k2 k3 k4 next code needed i
    # stdin 关闭（EOF）时必须干净退出：否则上层菜单循环会立即重绘并再次
    # 读取，以 100% CPU 无限空转（曾导致失控进程持续发热数小时）。
    if ! IFS= read -rsn1 k; then
        printf '\n%s\n' '输入已结束，程序退出。'
        exit 130
    fi
    KEY=''
    if [ "$k" = $'\033' ]; then
        KEY=ESC
        if IFS= read -rsn1 -t 1 k2 2>/dev/null; then
            KEY=UNKNOWN
            if [ "$k2" = '[' ] || [ "$k2" = 'O' ]; then
                if IFS= read -rsn1 -t 1 k3 2>/dev/null; then
                    case $k3 in
                        A) KEY=UP ;;
                        B) KEY=DOWN ;;
                        C) KEY=RIGHT ;;
                        D) KEY=LEFT ;;
                        H) KEY=HOME ;;
                        F) KEY=END ;;
                        1|7)
                            if IFS= read -rsn1 -t 1 k4 2>/dev/null && [ "$k4" = '~' ]; then KEY=HOME; fi
                            ;;
                        3)
                            if IFS= read -rsn1 -t 1 k4 2>/dev/null && [ "$k4" = '~' ]; then KEY=DELETE; fi
                            ;;
                        4|8)
                            if IFS= read -rsn1 -t 1 k4 2>/dev/null && [ "$k4" = '~' ]; then KEY=END; fi
                            ;;
                    esac
                fi
            fi
        fi
        return 0
    fi
    if [ -z "$k" ]; then KEY=ENTER; return 0; fi
    if [ "$k" = ' ' ]; then KEY=SPACE; return 0; fi
    if [ "$k" = $'\177' ] || [ "$k" = $'\010' ]; then KEY=BACKSPACE; return 0; fi
    if [ "$k" = $'\001' ]; then KEY=HOME; return 0; fi
    if [ "$k" = $'\005' ]; then KEY=END; return 0; fi
    if [ "$k" = $'\004' ]; then KEY=DELETE; return 0; fi
    if [ "$k" = $'\025' ]; then KEY=CLEAR; return 0; fi

    # macOS 自带 Bash 3.2 的 read -n1 按字节读取。先收齐一个 UTF-8
    # 字符再交给输入框，避免中文在输入和回显时变成问号。
    LC_CTYPE=C printf -v code '%d' "'$k" 2>/dev/null || code=0
    [ "$code" -lt 0 ] && code=$((code + 256))
    needed=1
    if [ "$code" -ge 194 ] && [ "$code" -le 223 ]; then
        needed=2
    elif [ "$code" -ge 224 ] && [ "$code" -le 239 ]; then
        needed=3
    elif [ "$code" -ge 240 ] && [ "$code" -le 244 ]; then
        needed=4
    fi
    for ((i = 2; i <= needed; i++)); do
        if IFS= read -rsn1 -t 1 next 2>/dev/null; then k=$k$next; else break; fi
    done
    KEY="CHAR:$k"
}

select_one() {
    # SELECT_TITLE SELECT_OPTIONS[] SELECT_DEFAULT_INDEX SELECT_HELP[] SELECT_ALLOW_CANCEL → SELECT_RESULT
    # 选项超过终端高度时启用视口滚动：只渲染可见范围，选中项始终保持在屏幕内。
    local n=${#SELECT_OPTIONS[@]}
    [ "$n" -eq 0 ] && { SELECT_RESULT=-1; return 0; }
    local pos=$SELECT_DEFAULT_INDEX
    [ "$pos" -lt 0 ] && pos=0
    [ "$pos" -ge "$n" ] && pos=$((n - 1))
    local i marker color footer
    # 屏幕高度（tput 不可用或非终端时按 24 行处理）
    local term_h
    term_h=$(tput lines 2>/dev/null)
    case $term_h in ''|*[!0-9]*) term_h=24 ;; esac
    [ "$term_h" -lt 10 ] && term_h=10
    # 帮助文本拆成实际显示行（元素可能内嵌换行），超长时截断，保证下方仍有选项空间
    local -a help_lines=()
    local h el
    for el in ${SELECT_HELP[@]+"${SELECT_HELP[@]}"}; do
        while IFS= read -r h; do help_lines+=("$h"); done < <(printf '%s\n' "$el")
    done
    local maxhelp=$((term_h - 9))
    [ "$maxhelp" -lt 2 ] && maxhelp=2
    local help_omitted=0
    if [ ${#help_lines[@]} -gt "$maxhelp" ]; then
        help_omitted=$(( ${#help_lines[@]} - maxhelp ))
        help_lines=("${help_lines[@]:0:maxhelp}")
    fi
    # 视口预算：标题 3 行 + 页脚前空行 1 + 页脚 1 + 上下指示各预留，共 8 行
    local viewport=$((term_h - 8 - ${#help_lines[@]}))
    [ "$viewport" -lt 3 ] && viewport=3
    [ "$viewport" -gt "$n" ] && viewport=$n
    local top=0 end above below
    if [ "$pos" -ge "$viewport" ]; then top=$((pos - viewport + 1)); fi
    while :; do
        # 平移视口，保证选中项可见
        if [ "$pos" -lt "$top" ]; then top=$pos; fi
        if [ "$pos" -ge $((top + viewport)) ]; then top=$((pos - viewport + 1)); fi
        end=$((top + viewport))
        [ "$end" -gt "$n" ] && end=$n
        sa_clear
        printf '%s\n' "${DARK}============================================================${NONE}"
        printf '%s\n' "${CYAN}  ${SELECT_TITLE}${NONE}"
        printf '%s\n' "${DARK}============================================================${NONE}"
        for h in "${help_lines[@]}"; do
            if [ -n "$h" ]; then printf '%s\n' "${GRAY}${h}${NONE}"; else printf '\n'; fi
        done
        [ "$help_omitted" -gt 0 ] && printf '%s\n' "${DARK}…… 其余 $help_omitted 行帮助文本省略${NONE}"
        printf '\n'
        above=$top
        below=$((n - end))
        [ "$above" -gt 0 ] && printf '%s\n' "${DARK}  ↑ 向上还有 $above 项${NONE}"
        for ((i = top; i < end; i++)); do
            if [ "$i" = "$pos" ]; then marker='>'; color=$YELLOW; else marker=' '; color=$GRAY; fi
            printf '%s\n' "${color} ${marker} ${SELECT_OPTIONS[$i]}${NONE}"
        done
        [ "$below" -gt 0 ] && printf '%s\n' "${DARK}  ↓ 向下还有 $below 项${NONE}"
        printf '\n'
        footer='↑↓ 移动  Enter 确认'
        [ -n "$SELECT_ALLOW_CANCEL" ] && footer="$footer  Esc 返回"
        [ $((above + below)) -gt 0 ] && footer="$footer  （列表可滚动）"
        printf '%s\n' "${DARK}${footer}${NONE}"
        read_key
        case $KEY in
            UP) if [ "$pos" -le 0 ]; then pos=$((n - 1)); else pos=$((pos - 1)); fi ;;
            DOWN) if [ "$pos" -ge $((n - 1)) ]; then pos=0; else pos=$((pos + 1)); fi ;;
            HOME) pos=0 ;;
            END) pos=$((n - 1)) ;;
            ENTER) SELECT_RESULT=$pos; return 0 ;;
            ESC) if [ -n "$SELECT_ALLOW_CANCEL" ]; then SELECT_RESULT=-1; return 0; fi ;;
        esac
    done
}

select_many() {
    # SIM_TITLE SIM_OPTIONS[] SIM_DEFAULT[] SIM_REQUIRE_ONE SIM_HELP[] → SIM_INDEXES[] SIM_CANCELLED
    local n=${#SIM_OPTIONS[@]}
    [ "$n" -eq 0 ] && { SIM_INDEXES=(); SIM_CANCELLED=1; return 0; }
    local -a flags=()
    local i idx
    for ((i = 0; i < n; i++)); do flags+=(''); done
    for idx in ${SIM_DEFAULT[@]+"${SIM_DEFAULT[@]}"}; do
        if [ "$idx" -ge 0 ] && [ "$idx" -lt "$n" ]; then flags[$idx]=1; fi
    done
    local pos=0 msg='' cursor box color
    while :; do
        local -a lines=()
        if [ ${#SIM_HELP[@]} -gt 0 ]; then
            for l in "${SIM_HELP[@]}"; do lines+=("$l"); done
        fi
        [ -n "$msg" ] && lines+=("$msg")
        if [ ${#lines[@]} -gt 0 ]; then
            show_header "$SIM_TITLE" "${lines[@]}"
        else
            show_header "$SIM_TITLE"
        fi
        for ((i = 0; i < n; i++)); do
            if [ "$i" = "$pos" ]; then cursor='>'; else cursor=' '; fi
            if [ -n "${flags[$i]}" ]; then box='[x]'; else box='[ ]'; fi
            if [ "$i" = "$pos" ]; then color=$YELLOW; else color=$GRAY; fi
            printf '%s\n' "${color} ${cursor} ${box} ${SIM_OPTIONS[$i]}${NONE}"
        done
        printf '\n'
        printf '%s\n' "${DARK}↑↓ 移动  Space 选择/取消  Enter 确认  Esc 返回${NONE}"
        msg=''
        read_key
        case $KEY in
            UP) if [ "$pos" -le 0 ]; then pos=$((n - 1)); else pos=$((pos - 1)); fi ;;
            DOWN) if [ "$pos" -ge $((n - 1)) ]; then pos=0; else pos=$((pos + 1)); fi ;;
            SPACE) if [ -n "${flags[$pos]}" ]; then flags[$pos]=''; else flags[$pos]=1; fi ;;
            ENTER)
                SIM_INDEXES=()
                for ((i = 0; i < n; i++)); do
                    [ -n "${flags[$i]}" ] && SIM_INDEXES+=("$i")
                done
                if [ -n "$SIM_REQUIRE_ONE" ] && [ ${#SIM_INDEXES[@]} -eq 0 ]; then
                    msg='请至少选择一项。'
                else
                    SIM_CANCELLED=''
                    return 0
                fi
                ;;
            ESC) SIM_INDEXES=(); SIM_CANCELLED=1; return 0 ;;
        esac
    done
}

draw_console_text() { # prompt buffer cursor
    local prompt=$1 buf=$2 cursor=$3
    local left=${buf:0:$cursor} right=${buf:$cursor}
    # 反色高亮插入点处的字符，模拟可见光标
    # （macOS 终端默认硬件光标不闪烁，中文之间几乎不可见）
    local first=' ' rest=''
    if [ -n "$right" ]; then
        first=${right:0:1}
        if [ ${#right} -gt 1 ]; then rest=${right:1}; fi
    fi
    # 输入行显式着色：不依赖终端默认文字色（黑底+黑字配置下默认色不可见）。
    # 灰色 (37) 在浅色与深色背景下均可读；反色光标块不改变前景色，
    # 光标右侧文字自动继承灰色，最后统一 NONE 复位。
    printf '\r\033[2K%s：%s' "${GRAY}${prompt}" "$left"
    # 保存光标后再输出右半段，恢复时无需自行计算中文字符的显示宽度。
    printf '\033[s\033[7m%s\033[27m%s\033[K\033[u%s' "$first" "$rest" "${NONE}"
}

read_console_text() { # prompt [initial] → RCT_VALUE RCT_CANCELLED
    local prompt=$1 buf=${2:-} ch left right
    local cursor=${#buf} length
    draw_console_text "$prompt" "$buf" "$cursor"
    while :; do
        read_key
        case $KEY in
            ESC) printf '\r\033[2K%s：%s\n' "${GRAY}${prompt}" "${buf}${NONE}"; RCT_CANCELLED=1; RCT_VALUE=''; return 0 ;;
            ENTER) printf '\r\033[2K%s：%s\n' "${GRAY}${prompt}" "${buf}${NONE}"; RCT_CANCELLED=''; RCT_VALUE=$buf; return 0 ;;
            LEFT)
                if [ "$cursor" -gt 0 ]; then cursor=$((cursor - 1)); draw_console_text "$prompt" "$buf" "$cursor"; fi
                ;;
            RIGHT)
                length=${#buf}
                if [ "$cursor" -lt "$length" ]; then cursor=$((cursor + 1)); draw_console_text "$prompt" "$buf" "$cursor"; fi
                ;;
            HOME) cursor=0; draw_console_text "$prompt" "$buf" "$cursor" ;;
            END) cursor=${#buf}; draw_console_text "$prompt" "$buf" "$cursor" ;;
            BACKSPACE)
                if [ "$cursor" -gt 0 ]; then
                    left=${buf:0:$((cursor - 1))}
                    right=${buf:$cursor}
                    buf=$left$right
                    cursor=$((cursor - 1))
                    draw_console_text "$prompt" "$buf" "$cursor"
                fi
                ;;
            DELETE)
                length=${#buf}
                if [ "$cursor" -lt "$length" ]; then
                    left=${buf:0:$cursor}
                    right=${buf:$((cursor + 1))}
                    buf=$left$right
                    draw_console_text "$prompt" "$buf" "$cursor"
                fi
                ;;
            CLEAR)
                buf=''; cursor=0; draw_console_text "$prompt" "$buf" "$cursor"
                ;;
            CHAR:*)
                ch=${KEY#CHAR:}
                left=${buf:0:$cursor}
                right=${buf:$cursor}
                buf=$left$ch$right
                cursor=$((cursor + ${#ch}))
                draw_console_text "$prompt" "$buf" "$cursor"
                ;;
        esac
    done
}

read_value() {
    # RV_TITLE RV_PROMPT RV_EXAMPLE RV_DEFAULT RV_ALLOW_EMPTY RV_VALIDATOR RV_HELP[] → RV_VALUE RV_CANCELLED
    local err=''
    local -a lines=()
    local l v
    while :; do
        lines=('←→ 移动光标，Esc 返回上一步，Enter 确认输入；Ctrl+U 清空。')
        for l in ${RV_HELP[@]+"${RV_HELP[@]}"}; do lines+=("$l"); done
        [ -n "$RV_EXAMPLE" ] && lines+=("示例：$RV_EXAMPLE")
        [ -n "$RV_DEFAULT" ] && lines+=('已载入现有内容，可直接编辑或回车确认。')
        [ -n "$err" ] && lines+=("提示：$err")
        show_header "$RV_TITLE" "${lines[@]}"
        read_console_text "$RV_PROMPT" "$RV_DEFAULT"
        if [ -n "$RCT_CANCELLED" ]; then RV_CANCELLED=1; return 0; fi
        RV_CANCELLED=''
        v=$(trim "$RCT_VALUE")
        if [ -z "$v" ] && [ -n "$RV_DEFAULT" ]; then v=$RV_DEFAULT; fi
        if [ -z "$v" ] && [ -z "$RV_ALLOW_EMPTY" ]; then
            err='该项不能为空，请重新输入。'
            continue
        fi
        if [ -n "$RV_VALIDATOR" ]; then
            err=$("$RV_VALIDATOR" "$v")
            if [ -n "$err" ]; then continue; fi
        fi
        RV_VALUE=$v
        return 0
    done
}

confirm_action() { # CA_TITLE CA_DETAILS[] CA_DEFAULT_NO → CA_RESULT
    local -a opts=()
    if [ -n "$CA_DEFAULT_NO" ]; then opts+=('取消' '确认继续'); else opts+=('确认继续' '取消'); fi
    SELECT_TITLE=$CA_TITLE
    SELECT_OPTIONS=("${opts[@]}")
    SELECT_DEFAULT_INDEX=0
    SELECT_HELP=(${CA_DETAILS[@]+"${CA_DETAILS[@]}"})
    SELECT_ALLOW_CANCEL=1
    select_one
    [ "$SELECT_RESULT" -lt 0 ] && { CA_RESULT=''; return 0; }
    if [ -n "$CA_DEFAULT_NO" ]; then
        [ "$SELECT_RESULT" = '1' ] && CA_RESULT=1 || CA_RESULT=''
    else
        [ "$SELECT_RESULT" = '0' ] && CA_RESULT=1 || CA_RESULT=''
    fi
}

# ---------- 输入校验器 ----------

validate_new_name() {
    local err
    err=$(test_software_name "$1")
    if [ -n "$err" ]; then printf '%s\n' "$err"; return 0; fi
    if [ -e "$LIBRARY_DIR/$1" ]; then printf '%s\n' '资源库中已经存在同名目录。'; fi
}

validate_url() { test_web_url "$1"; }

validate_optional_url() { # Record 的官网地址允许留空
    [ -z "$1" ] && return 0
    test_web_url "$1"
}

validate_file_exists() {
    [ -n "$1" ] || return 0
    [ -f "$1" ] || printf '%s\n' '文件不存在，请检查路径。'
}

validate_exact_name() {
    [ "$1" = "$EXPECTED_NAME" ] || printf '%s\n' '名称不一致，请核对后重新输入。'
}

# ---------- 向导组件 ----------

join_str() { local IFS=$1; shift; printf '%s' "$*"; }

select_platforms() { # defaults... → SP_RESULT[] SP_CANCELLED
    local -a defaults=("$@") sel=()
    local i
    for ((i = 0; i < ${#DEFAULT_PLATFORMS[@]}; i++)); do
        for d in ${defaults[@]+"${defaults[@]}"}; do
            [ "$d" = "${DEFAULT_PLATFORMS[$i]}" ] && sel+=("$i")
        done
    done
    SIM_TITLE='选择支持平台'
    SIM_OPTIONS=("${DEFAULT_PLATFORMS[@]}")
    SIM_DEFAULT=(${sel[@]+"${sel[@]}"})
    SIM_REQUIRE_ONE=1
    SIM_HELP=('可多选，使用 Space 切换。')
    select_many
    if [ -n "$SIM_CANCELLED" ]; then SP_CANCELLED=1; return 0; fi
    SP_CANCELLED=''
    SP_RESULT=()
    for i in "${SIM_INDEXES[@]}"; do SP_RESULT+=("${DEFAULT_PLATFORMS[$i]}"); done
}

read_tags() { # → RT_TAGS[] RT_CANCELLED
    local -a tags=()
    local current helpmsg
    while :; do
        if [ ${#tags[@]} -gt 0 ]; then
            current=$(join_str ' / ' ${tags[@]+"${tags[@]}"})
            helpmsg="已录入：$current [空回车结束]"
            RV_HELP=("$helpmsg")
        else
            RV_HELP=()
        fi
        RV_TITLE='填写标签（可选）'
        RV_PROMPT='输入一个标签，直接回车结束'
        RV_EXAMPLE='文件管理'
        RV_DEFAULT=''
        RV_ALLOW_EMPTY=1
        RV_VALIDATOR=''
        read_value
        if [ -n "$RV_CANCELLED" ]; then RT_CANCELLED=1; return 0; fi
        RT_CANCELLED=''
        if [ -z "$RV_VALUE" ]; then RT_TAGS=(${tags[@]+"${tags[@]}"}); return 0; fi
        if [ ${#RV_VALUE} -gt 40 ]; then
            show_header '标签过长' '单个标签请控制在 40 个字符以内。' \
                "已录入：$(if [ ${#tags[@]} -gt 0 ]; then join_str ' / ' ${tags[@]+"${tags[@]}"}; else printf '无'; fi)"
            wait_for_user
            continue
        fi
        local dup=0 t
        for t in ${tags[@]+"${tags[@]}"}; do [ "$t" = "$RV_VALUE" ] && dup=1; done
        [ "$dup" = '0' ] && tags+=("$RV_VALUE")
    done
}

get_optional_metadata() { # → OM_VERSION OM_TAGS[] OM_LICENSE OM_NOTES OM_CANCELLED
    local step=0 version='' license='' notes=''
    local -a tags=()
    OM_CANCELLED=''
    while :; do
        case $step in
            0)
                SELECT_TITLE='可选信息'
                SELECT_OPTIONS=('暂不填写可选信息' '现在填写版本、标签、许可证和备注')
                SELECT_DEFAULT_INDEX=0
                SELECT_HELP=()
                SELECT_ALLOW_CANCEL=1
                select_one
                if [ "$SELECT_RESULT" -lt 0 ]; then OM_CANCELLED=1; return 0; fi
                if [ "$SELECT_RESULT" = '0' ]; then
                    OM_VERSION=''; OM_TAGS=(); OM_LICENSE=''; OM_NOTES=''
                    return 0
                fi
                step=1
                ;;
            1)
                RV_TITLE='当前版本（可选）'; RV_PROMPT='版本号'; RV_EXAMPLE='v2.5.0'
                RV_DEFAULT=$version; RV_ALLOW_EMPTY=1; RV_VALIDATOR=''; RV_HELP=()
                read_value
                [ -n "$RV_CANCELLED" ] && { step=0; continue; }
                version=$RV_VALUE; step=2
                ;;
            2)
                read_tags
                [ -n "$RT_CANCELLED" ] && { step=1; continue; }
                tags=(${RT_TAGS[@]+"${RT_TAGS[@]}"})
                step=3
                ;;
            3)
                RV_TITLE='许可证（可选）'; RV_PROMPT='许可证'; RV_EXAMPLE='MIT'
                RV_DEFAULT=$license; RV_ALLOW_EMPTY=1; RV_VALIDATOR=''; RV_HELP=()
                read_value
                [ -n "$RV_CANCELLED" ] && { step=2; continue; }
                license=$RV_VALUE; step=4
                ;;
            4)
                RV_TITLE='备注（可选）'; RV_PROMPT='备注'; RV_EXAMPLE='仅保留稳定版'
                RV_DEFAULT=$notes; RV_ALLOW_EMPTY=1; RV_VALIDATOR=''; RV_HELP=()
                read_value
                [ -n "$RV_CANCELLED" ] && { step=3; continue; }
                notes=$RV_VALUE
                OM_VERSION=$version; OM_TAGS=(${tags[@]+"${tags[@]}"}); OM_LICENSE=$license; OM_NOTES=$notes
                return 0
                ;;
        esac
    done
}

select_local_files() { # title → FILES[] FILES_CANCELLED
    FILES=(); FILES_CANCELLED=''
    local out line
    if command -v osascript >/dev/null 2>&1; then
        out=$(osascript \
            -e 'set fs to choose file with multiple selections allowed with prompt "选择安装包" without invisibles' \
            -e 'set out to ""' \
            -e 'repeat with f in fs' \
            -e 'set out to out & (POSIX path of f) & linefeed' \
            -e 'end repeat' \
            -e 'return out' 2>/dev/null)
        if [ $? -ne 0 ] || [ -z "$out" ]; then
            FILES_CANCELLED=1
            return 0
        fi
        while IFS= read -r line; do
            [ -n "$line" ] && FILES+=("$line")
        done <<< "$out"
        [ ${#FILES[@]} -gt 0 ] && return 0
        FILES_CANCELLED=1
        return 0
    fi
    while :; do
        RV_TITLE=$1
        RV_PROMPT='文件完整路径（直接回车结束）'
        RV_EXAMPLE='/Users/me/Downloads/setup.dmg'
        RV_DEFAULT=''
        RV_ALLOW_EMPTY=1
        RV_VALIDATOR='validate_file_exists'
        RV_HELP=()
        read_value
        if [ -n "$RV_CANCELLED" ]; then FILES_CANCELLED=1; return 0; fi
        if [ -z "$RV_VALUE" ]; then break; fi
        local full=$(cd "$(dirname "$RV_VALUE")" 2>/dev/null && pwd)/$(basename "$RV_VALUE")
        local dup=0 f
        for f in ${FILES[@]+"${FILES[@]}"}; do [ "$f" = "$full" ] && dup=1; done
        [ "$dup" = '0' ] && FILES+=("$full")
    done
    FILES_CANCELLED=''
}

select_file_platform() { # filename preferred... → SFP_RESULT SFP_CANCELLED
    local fname=$1; shift
    local -a preferred=("$@") all=()
    local p found
    for p in ${preferred[@]+"${preferred[@]}"} "${DEFAULT_PLATFORMS[@]}"; do
        [ -z "$p" ] && continue
        found=0
        for a in ${all[@]+"${all[@]}"}; do [ "$a" = "$p" ] && found=1; done
        [ "$found" = '0' ] && all+=("$p")
    done
    local guess=$(get_platform_guess "$fname")
    local default=0 i
    for ((i = 0; i < ${#all[@]}; i++)); do
        [ "${all[$i]}" = "$guess" ] && default=$i
    done
    SELECT_TITLE='确认安装包平台'
    SELECT_OPTIONS=(${all[@]+"${all[@]}"})
    SELECT_DEFAULT_INDEX=$default
    SELECT_HELP=("文件：$fname")
    SELECT_ALLOW_CANCEL=1
    select_one
    if [ "$SELECT_RESULT" -lt 0 ]; then SFP_CANCELLED=1; return 0; fi
    SFP_CANCELLED=''
    SFP_RESULT=${all[$SELECT_RESULT]}
}

add_local_packages() { # stage version preferred... → MAP_*（累计）AP_CANCELLED
    local stage=$1 version=$2; shift 2
    local -a preferred=("$@")
    local f plat vfolder tdir
    AP_CANCELLED=''
    for f in ${FILES[@]+"${FILES[@]}"}; do
        select_file_platform "$(basename "$f")" ${preferred[@]+"${preferred[@]}"}
        if [ -n "$SFP_CANCELLED" ]; then AP_CANCELLED=1; return 0; fi
        plat=$SFP_RESULT
        MAP_NAMES+=("$(basename "$f")")
        MAP_PLATFORMS+=("$plat")
        MAP_URLS+=("$f")
        MAP_SIZES+=(0)
        vfolder=$(safe_path_segment "$version" 'Unknown')
        tdir="$stage/Packages/$vfolder/$plat"
        mkdir -p "$tdir"
        cp -f "$f" "$tdir/$(basename "$f")" || { sa_set_error "复制安装包失败：$f"; return 1; }
    done
    return 0
}

size_text_of() { # bytes
    local b=$1
    if [ "$b" -ge 1048576 ]; then
        printf '%s MB' "$(awk -v b="$b" 'BEGIN{printf "%.1f", b/1048576}')"
    elif [ "$b" -gt 0 ]; then
        printf '%s KB' "$(( (b + 1023) / 1024 ))"
    else
        printf ''
    fi
}

select_release_asset_mappings() { # 使用 ASSET_* 与 preferred... → MAP_* SAM_CANCELLED
    local -a preferred=("$@")
    local n=${#ASSET_NAMES[@]}
    if [ "$n" -eq 0 ]; then SAM_CANCELLED=''; return 0; fi
    local -a platforms=()
    local p found a i
    for p in ${preferred[@]+"${preferred[@]}"} "${DEFAULT_PLATFORMS[@]}"; do
        [ -z "$p" ] && continue
        found=0
        for a in ${platforms[@]+"${platforms[@]}"}; do [ "$a" = "$p" ] && found=1; done
        [ "$found" = '0' ] && platforms+=("$p")
    done
    local -a decided=() assigned=()
    for ((i = 0; i < n; i++)); do decided+=(''); assigned+=(''); done
    local choice status size labels
    while :; do
        local -a labels=()
        for ((i = 0; i < n; i++)); do
            status='未处理'
            if [ -n "${decided[$i]}" ]; then
                if [ "${assigned[$i]}" = '__SKIP__' ]; then status='不归档'; else status=${assigned[$i]}; fi
            fi
            size=$(size_text_of "${ASSET_SIZES[$i]}")
            labels+=("[$status] ${ASSET_NAMES[$i]}${size:+  [$size]}")
        done
        labels+=('完成安装包选择并继续')
        SELECT_TITLE='逐个选择 Release 安装包'
        SELECT_OPTIONS=("${labels[@]}")
        SELECT_DEFAULT_INDEX=0
        SELECT_HELP=('选择一个文件后，为它指定平台；随后会回到本列表。'
                     '可重复处理文件，最后选择“完成安装包选择并继续”。'
                     'Esc 返回 Release 决策页面。')
        SELECT_ALLOW_CANCEL=1
        select_one
        choice=$SELECT_RESULT
        if [ "$choice" -lt 0 ]; then SAM_CANCELLED=1; return 0; fi
        if [ "$choice" = "$n" ]; then
            local selected=0 undecided=0
            for ((i = 0; i < n; i++)); do
                if [ -z "${decided[$i]}" ]; then undecided=$((undecided + 1))
                elif [ "${assigned[$i]}" != '__SKIP__' ]; then selected=$((selected + 1)); fi
            done
            SELECT_TITLE='确认安装包选择'
            SELECT_OPTIONS=('完成并继续' '返回继续处理文件')
            SELECT_DEFAULT_INDEX=0
            SELECT_HELP=("已选择归档：$selected 个" "尚未处理：$undecided 个（将视为不归档）")
            SELECT_ALLOW_CANCEL=1
            select_one
            [ "$SELECT_RESULT" = '0' ] || continue
            MAP_PLATFORMS=(); MAP_NAMES=(); MAP_URLS=(); MAP_SIZES=()
            for ((i = 0; i < n; i++)); do
                if [ -n "${decided[$i]}" ] && [ "${assigned[$i]}" != '__SKIP__' ]; then
                    MAP_PLATFORMS+=("${assigned[$i]}")
                    MAP_NAMES+=("${ASSET_NAMES[$i]}")
                    MAP_URLS+=("${ASSET_URLS[$i]}")
                    MAP_SIZES+=("${ASSET_SIZES[$i]}")
                fi
            done
            SAM_CANCELLED=''
            return 0
        fi
        local -a platopts=(${platforms[@]+"${platforms[@]}"} '不归档此文件')
        local guess=$(get_platform_guess "${ASSET_NAMES[$choice]}")
        local pdefault=0
        for ((i = 0; i < ${#platforms[@]}; i++)); do
            [ "${platforms[$i]}" = "$guess" ] && pdefault=$i
        done
        SELECT_TITLE='指定安装包对应平台'
        SELECT_OPTIONS=("${platopts[@]}")
        SELECT_DEFAULT_INDEX=$pdefault
        SELECT_HELP=("文件：${ASSET_NAMES[$choice]}" '确认后会回到安装包列表，可继续处理下一个文件。')
        SELECT_ALLOW_CANCEL=1
        select_one
        [ "$SELECT_RESULT" -lt 0 ] && continue
        decided[$choice]=1
        if [ "$SELECT_RESULT" = "${#platforms[@]}" ]; then
            assigned[$choice]='__SKIP__'
        else
            assigned[$choice]=${platforms[$SELECT_RESULT]}
        fi
    done
}

add_release_packages() { # stagepath（使用 RELEASE_* 与 MAP_*）
    local stage=$1 i dest vfolder aname existing_size
    for ((i = 0; i < ${#MAP_NAMES[@]}; i++)); do
        vfolder=$(safe_path_segment "$RELEASE_TAG" 'Unknown')
        aname=$(safe_path_segment "${MAP_NAMES[$i]}" "asset_$i")
        dest="$stage/Packages/$vfolder/${MAP_PLATFORMS[$i]}"
        mkdir -p "$dest"
        dest="$dest/$aname"
        if [ -f "$dest" ]; then
            existing_size=$(file_size "$dest")
            if [ "${MAP_SIZES[$i]}" -gt 0 ] && [ "$existing_size" = "${MAP_SIZES[$i]}" ]; then
                continue
            fi
        fi
        show_header '下载安装包' "正在下载：${MAP_NAMES[$i]}" "保存到：$dest"
        invoke_sa_file_download "${MAP_URLS[$i]}" "$dest" "${MAP_SIZES[$i]}" || return 1
    done
    return 0
}

move_old_packages() { # stage newversion → 0 继续 / 1 返回
    local pkgs="$1/Packages" newver=$2
    [ -d "$pkgs" ] || return 0
    local -a olds=()
    local d
    for d in "$pkgs"/*/; do
        [ -d "$d" ] || continue
        [ "$(basename "$d")" = "$newver" ] && continue
        olds+=("$(basename "$d")")
    done
    [ ${#olds[@]} -eq 0 ] && return 0
    SELECT_TITLE='处理旧版本安装包'
    SELECT_OPTIONS=('保留在 Packages' '移动到 Archive/Packages' '从正式结果中删除旧版本' '返回')
    SELECT_DEFAULT_INDEX=0
    SELECT_HELP=("旧版本：$(join_str ' / ' ${olds[@]+"${olds[@]}"})")
    SELECT_ALLOW_CANCEL=1
    select_one
    [ "$SELECT_RESULT" -lt 0 ] || [ "$SELECT_RESULT" = '3' ] && return 1
    if [ "$SELECT_RESULT" = '0' ]; then return 0; fi
    if [ "$SELECT_RESULT" = '1' ]; then
        local archive="$1/Archive/Packages"
        mkdir -p "$archive"
        local target
        for d in "${olds[@]}"; do
            target="$archive/$d"
            if [ -e "$target" ]; then target="${target}_$(date '+%Y%m%d_%H%M%S')"; fi
            mv "$pkgs/$d" "$target" || return 1
        done
        return 0
    fi
    if [ "$SELECT_RESULT" = '2' ]; then
        CA_TITLE='确认删除暂存副本中的旧版本'
        CA_DETAILS=('本次提交后旧版本不会保留。' '原资源库在提交前保持不变。')
        CA_DEFAULT_NO=1
        confirm_action
        [ -z "$CA_RESULT" ] && return 1
        for d in "${olds[@]}"; do rm -rf "$pkgs/$d" || return 1; done
        return 0
    fi
}

show_info_summary() { # 使用 INFO_*（或向导变量） → 单行数组
    local ver url tags lic notes
    ver=$INFO_VERSION
    if [ -z "$ver" ]; then
        case $INFO_POLICY in
            Record) ver='留空（仅记录，不跟踪版本）' ;;
            *) ver='留空（Packages 使用 Unknown）' ;;
        esac
    fi
    url=$INFO_SOURCE_URL; [ -n "$url" ] || url='未填写'
    if [ ${#INFO_TAGS[@]} -gt 0 ]; then tags=$(join_str ' / ' ${INFO_TAGS[@]+"${INFO_TAGS[@]}"}); else tags='无'; fi
    lic=$INFO_LICENSE; [ -n "$lic" ] || lic='未填写'
    notes=$INFO_NOTES; [ -n "$notes" ] || notes='未填写'
    SUMMARY_LINES=(
        "名称：$INFO_NAME"
        "平台：$(join_str ' / ' ${INFO_PLATFORMS[@]+"${INFO_PLATFORMS[@]}"})"
        "策略：$INFO_POLICY"
        "版本：$ver"
        "来源：$url"
        "标签：$tags"
        "许可证：$lic"
        "备注：$notes"
    )
}

complete_manual_step() { # task_existing(1/0) → 0 提交成功 / 1 暂存退出 / 2 失败
    local existing=$1
    local manual="$TASK_STAGEPATH/使用手册.md"
    local -a opts=('打开 使用手册.md' '我已完成使用手册')
    [ "$existing" = '1' ] && opts+=('本次检查后无需修改')
    opts+=('暂存任务并退出')
    local ready choice
    while :; do
        SELECT_TITLE='使用手册确认'
        SELECT_OPTIONS=("${opts[@]}")
        SELECT_DEFAULT_INDEX=0
        SELECT_HELP=("软件：$TASK_SOFTWARENAME" '该环节需要人工处理，确认后才会写入正式资源库。')
        SELECT_ALLOW_CANCEL=1
        select_one
        choice=$SELECT_RESULT
        if [ "$choice" -lt 0 ] || [ "$choice" = "$(( ${#opts[@]} - 1 ))" ]; then
            TASK_STATUS='WaitingManual'
            TASK_STEP='ManualPending'
            save_sa_task
            show_header '任务已暂存' '下次启动脚本时可以继续。' "任务目录：$TASK_TASKPATH"
            wait_for_user
            return 1
        fi
        if [ "$choice" = '0' ]; then
            if ! open_local_path "$manual"; then
                show_header '无法自动打开文件' "$SA_ERROR_MSG" "请手动打开：$manual"
                wait_for_user
            fi
            continue
        fi
        ready=0
        [ "$choice" = '1' ] && ready=1
        [ "$existing" = '1' ] && [ "$choice" = '2' ] && ready=1
        if [ "$ready" = '1' ]; then
            TASK_STATUS='ReadyToCommit'
            TASK_STEP='ManualConfirmed'
            save_sa_task
            show_header '提交到正式资源库' '正在生成校验文件并重建索引，请稍候。'
            local target
            if ! target=$(commit_sa_task); then
                show_header '提交失败' "$SA_ERROR_MSG" "任务已保留：$TASK_TASKPATH"
                wait_for_user
                return 2
            fi
            show_completion "$TASK_SOFTWARENAME" "$target"
            remove_sa_task "$TASK_TASKPATH" "$TASK_ID"
            return 0
        fi
    done
}

show_completion() { # name path
    show_header '操作完成' \
        "软件：$1" \
        "正式目录：$2" \
        '' \
        '请备份到阿里云盘：' \
        "1. Library/$1/" \
        '2. Library/资源索引.xlsx' \
        '' \
        '云端操作：删除旧软件目录，上传新的完整软件目录，再上传新的资源索引。'
    wait_for_user
}

show_task_failure() { # task保留
    TASK_MESSAGE=$SA_ERROR_MSG
    TASK_STATUS='InProgress'
    save_sa_task
    local -a lines=("$SA_ERROR_MSG" '正式资源库没有写入半成品。' "任务已保留：$TASK_TASKPATH")
    case $TASK_STEP in
        ReleaseDownloadPending|GitArchivePending)
            lines+=('回到主菜单后选择“处理未完成任务”即可重试当前步骤。') ;;
    esac
    show_header '任务未完成' "${lines[@]}"
    wait_for_user
}

# ---------- 新软件入库 ----------

start_new_software() {
    local wizard_step=0 policy='Fixed' policy_index=0
    local name_value='' source_url=''
    local -a platforms=()
    local om_version='' om_license='' om_notes=''
    local -a om_tags=()
    local wname wplat wconfirm

    while :; do
        case $wizard_step in
            0)
                SELECT_TITLE='收录新软件'
                SELECT_OPTIONS=('Fixed：保存确定版本的安装包' 'Maintain：持续跟踪 Release 与 Git 源码' 'Record：仅记录，不保存安装包和源码')
                SELECT_DEFAULT_INDEX=$policy_index
                SELECT_HELP=('Fixed：手动收录安装包，不查询更新。'
                             'Maintain：自动查询 Release，并归档 Git 源码。'
                             'Record：只记一条备忘（如商业软件），恢复环境时提醒自己重新下载。')
                SELECT_ALLOW_CANCEL=1
                select_one
                [ "$SELECT_RESULT" -lt 0 ] && return 0
                policy_index=$SELECT_RESULT
                case $policy_index in
                    0) policy='Fixed' ;;
                    1) policy='Maintain' ;;
                    2) policy='Record' ;;
                esac
                wizard_step=1
                ;;
            1)
                RV_TITLE='软件名称'; RV_PROMPT='名称'; RV_EXAMPLE='SoftwareA'
                RV_DEFAULT=$name_value; RV_ALLOW_EMPTY=''; RV_VALIDATOR='validate_new_name'; RV_HELP=()
                read_value
                [ -n "$RV_CANCELLED" ] && { wizard_step=0; continue; }
                name_value=$RV_VALUE
                wizard_step=2
                ;;
            2)
                select_platforms ${platforms[@]+"${platforms[@]}"}
                [ -n "$SP_CANCELLED" ] && { wizard_step=1; continue; }
                platforms=(${SP_RESULT[@]+"${SP_RESULT[@]}"})
                if [ "$policy" = 'Fixed' ]; then wizard_step=4; else wizard_step=3; fi
                ;;
            3)
                if [ "$policy" = 'Record' ]; then
                    RV_TITLE='官网 / 下载页地址（可选）'; RV_PROMPT='source_url'; RV_EXAMPLE='https://www.example.com/product'
                    RV_DEFAULT=$source_url; RV_ALLOW_EMPTY=1; RV_VALIDATOR='validate_optional_url'
                    RV_HELP=('Record 建议填写官网或下载页，恢复环境时方便快速定位；没有可留空。')
                else
                    RV_TITLE='源码仓库地址'; RV_PROMPT='source_url'; RV_EXAMPLE='https://github.com/owner/project'
                    RV_DEFAULT=$source_url; RV_ALLOW_EMPTY=''; RV_VALIDATOR='validate_url'; RV_HELP=()
                fi
                read_value
                [ -n "$RV_CANCELLED" ] && { wizard_step=2; continue; }
                source_url=$RV_VALUE
                wizard_step=4
                ;;
            4)
                get_optional_metadata
                if [ -n "$OM_CANCELLED" ]; then
                    if [ "$policy" = 'Fixed' ]; then wizard_step=2; else wizard_step=3; fi
                    continue
                fi
                om_version=$OM_VERSION; om_tags=(${OM_TAGS[@]+"${OM_TAGS[@]}"})
                om_license=$OM_LICENSE; om_notes=$OM_NOTES
                wizard_step=5
                ;;
            5)
                INFO_NAME=$name_value
                INFO_PLATFORMS=(${platforms[@]+"${platforms[@]}"})
                INFO_POLICY=$policy
                INFO_VERSION=$om_version
                INFO_SOURCE_URL=$source_url
                INFO_SOURCE_TYPE=$(get_source_type "$source_url")
                INFO_TAGS=(${om_tags[@]+"${om_tags[@]}"})
                INFO_LICENSE=$om_license
                INFO_LASTCHECKED=$(today_str)
                INFO_NOTES=$om_notes
                show_info_summary
                local confirm_title='确认创建入库任务' confirm_label='确认并继续'
                if [ "$policy" = 'Record' ]; then
                    confirm_title='确认收录（Record，仅记录）'
                    confirm_label='确认并写入档案库'
                fi
                SELECT_TITLE="$confirm_title"
                SELECT_OPTIONS=("$confirm_label" '返回修改可选信息' '取消本次入库')
                SELECT_DEFAULT_INDEX=0
                SELECT_HELP=("${SUMMARY_LINES[@]}")
                SELECT_ALLOW_CANCEL=1
                select_one
                wconfirm=$SELECT_RESULT
                if [ "$wconfirm" = '0' ]; then break; fi
                if [ "$wconfirm" = '2' ]; then return 0; fi
                wizard_step=4
                ;;
        esac
    done

    if [ "$policy" = 'Record' ]; then
        # Record 不走暂存任务：条目只有 info.yml，直接写入正式库并重建索引。
        # 重建索引会重新扫描全部条目并覆盖 INFO_* 全局变量，
        # 因此软件名和目录必须先捕获到局部变量再重建。
        local rname=$INFO_NAME
        local rdir="$LIBRARY_DIR/$rname"
        if ! mkdir -p "$rdir" 2>/dev/null; then
            show_header '收录失败' "无法创建目录：$rdir"
            wait_for_user
            return 0
        fi
        if ! write_info_yaml "$rdir/info.yml"; then
            show_header '收录失败' "无法写入：$rdir/info.yml"
            wait_for_user
            return 0
        fi
        rebuild_index_tsv >/dev/null 2>&1
        new_sa_index_workbook >/dev/null 2>&1
        show_header '收录完成' \
            "软件：${rname}（Record，仅记录）" \
            "目录：$rdir" \
            '' \
            '该条目只保存 info.yml，不占用安装包和源码空间。' \
            '如需记录下载入口、账号要求或许可证信息，可手动在该目录补充 使用手册.md。' \
            '云端备份：上传新的 资源索引.xlsx，并同步该软件目录（只有 info.yml）。'
        wait_for_user
        return 0
    fi
    new_sa_task "New$policy" "$INFO_NAME"
    if ! new_software_body "$policy" "$source_url" "$INFO_NAME"; then
        [ -n "$SA_ERROR_MSG" ] && show_task_failure
        return 0
    fi
    return 0
}

new_software_body() { # policy source_url name → 0 完成 / 1 取消或失败（SA_ERROR_MSG 有值时失败）
    local policy=$1 source_url=$2 name=$3
    local lookup_state='Pending' rc
    if [ "$policy" = 'Maintain' ]; then
        initialize_software_directory "$TASK_STAGEPATH" maintain
    else
        initialize_software_directory "$TASK_STAGEPATH"
    fi

    if [ "$policy" = 'Fixed' ]; then
        select_local_files '选择 Fixed 安装包'
        if [ -n "$FILES_CANCELLED" ] || [ ${#FILES[@]} -eq 0 ]; then
            remove_sa_task "$TASK_TASKPATH" "$TASK_ID"
            return 1
        fi
        MAP_PLATFORMS=(); MAP_NAMES=(); MAP_URLS=(); MAP_SIZES=()
        if ! add_local_packages "$TASK_STAGEPATH" "$INFO_VERSION" ${INFO_PLATFORMS[@]+"${INFO_PLATFORMS[@]}"}; then
            [ -n "$AP_CANCELLED" ] && { remove_sa_task "$TASK_TASKPATH" "$TASK_ID"; SA_ERROR_MSG=''; return 1; }
            return 1
        fi
        [ -n "$AP_CANCELLED" ] && { remove_sa_task "$TASK_TASKPATH" "$TASK_ID"; SA_ERROR_MSG=''; return 1; }
    else
        while [ "$lookup_state" = 'Pending' ]; do
            show_header '查询最新 Release' "正在查询：$source_url"
            get_latest_release "$source_url"
            rc=$?
            if [ $rc -eq 0 ]; then
                lookup_state='Found'
            elif [ $rc -eq 1 ]; then
                lookup_state='None'
            else
                SELECT_TITLE='Release 查询失败'
                SELECT_OPTIONS=('重试查询' '继续，仅归档源码' '继续，手动选择安装包' '取消入库')
                SELECT_DEFAULT_INDEX=0
                SELECT_HELP=("$SA_ERROR_MSG" '查询失败不会再显示成“未发现正式 Release”。')
                SELECT_ALLOW_CANCEL=1
                select_one
                case $SELECT_RESULT in
                    0) lookup_state='Pending' ;;
                    1) lookup_state='SourceOnly' ;;
                    2) lookup_state='ManualPackages' ;;
                    *) lookup_state='Cancelled' ;;
                esac
            fi
        done
        if [ "$lookup_state" = 'Cancelled' ]; then
            remove_sa_task "$TASK_TASKPATH" "$TASK_ID"
            SA_ERROR_MSG=''
            return 1
        fi
        if [ "$lookup_state" = 'Found' ]; then
            local release_decided=0 rchoice
            while [ "$release_decided" = '0' ]; do
                SELECT_TITLE='发现正式 Release'
                SELECT_OPTIONS=("采用 $RELEASE_TAG 并选择安装包" '跳过本次 Release，仅归档源码' '取消本次入库')
                SELECT_DEFAULT_INDEX=0
                SELECT_HELP=("版本：$RELEASE_TAG" "发布时间：$(format_release_time "$RELEASE_PUBLISHED")")
                SELECT_ALLOW_CANCEL=1
                select_one
                rchoice=$SELECT_RESULT
                if [ "$rchoice" = '2' ]; then
                    remove_sa_task "$TASK_TASKPATH" "$TASK_ID"; SA_ERROR_MSG=''; return 1
                fi
                if [ "$rchoice" = '1' ]; then break; fi
                if [ "$rchoice" -lt 0 ]; then continue; fi
                select_release_asset_mappings ${INFO_PLATFORMS[@]+"${INFO_PLATFORMS[@]}"}
                if [ -n "$SAM_CANCELLED" ]; then continue; fi
                INFO_VERSION=$RELEASE_TAG
                if [ ${#MAP_NAMES[@]} -gt 0 ]; then
                    TASK_STATUS='InProgress'
                    TASK_STEP='ReleaseDownloadPending'
                    ctx_write_info "$TASK_TASKPATH"
                    ctx_write_release "$TASK_TASKPATH"
                    ctx_write_mappings "$TASK_TASKPATH"
                    save_sa_task
                    if ! add_release_packages "$TASK_STAGEPATH"; then return 1; fi
                fi
                break
            done
        elif [ "$lookup_state" = 'None' ]; then
            SELECT_TITLE='未发现正式 Release'
            SELECT_OPTIONS=('仅归档源码' '手动选择安装包' '取消入库')
            SELECT_DEFAULT_INDEX=0
            SELECT_HELP=()
            SELECT_ALLOW_CANCEL=1
            select_one
            if [ "$SELECT_RESULT" -lt 0 ] || [ "$SELECT_RESULT" = '2' ]; then
                remove_sa_task "$TASK_TASKPATH" "$TASK_ID"; SA_ERROR_MSG=''; return 1
            fi
            if [ "$SELECT_RESULT" = '1' ]; then
                select_local_files '选择安装包'
                if [ -n "$FILES_CANCELLED" ]; then
                    remove_sa_task "$TASK_TASKPATH" "$TASK_ID"; SA_ERROR_MSG=''; return 1
                fi
                if [ ${#FILES[@]} -gt 0 ]; then
                    MAP_PLATFORMS=(); MAP_NAMES=(); MAP_URLS=(); MAP_SIZES=()
                    if ! add_local_packages "$TASK_STAGEPATH" "$INFO_VERSION" ${INFO_PLATFORMS[@]+"${INFO_PLATFORMS[@]}"}; then
                        [ -n "$AP_CANCELLED" ] && { remove_sa_task "$TASK_TASKPATH" "$TASK_ID"; SA_ERROR_MSG=''; return 1; }
                        return 1
                    fi
                    [ -n "$AP_CANCELLED" ] && { remove_sa_task "$TASK_TASKPATH" "$TASK_ID"; SA_ERROR_MSG=''; return 1; }
                fi
            fi
        elif [ "$lookup_state" = 'ManualPackages' ]; then
            select_local_files '选择安装包'
            if [ -n "$FILES_CANCELLED" ]; then
                remove_sa_task "$TASK_TASKPATH" "$TASK_ID"; SA_ERROR_MSG=''; return 1
            fi
            if [ ${#FILES[@]} -gt 0 ]; then
                MAP_PLATFORMS=(); MAP_NAMES=(); MAP_URLS=(); MAP_SIZES=()
                if ! add_local_packages "$TASK_STAGEPATH" "$INFO_VERSION" ${INFO_PLATFORMS[@]+"${INFO_PLATFORMS[@]}"}; then
                    [ -n "$AP_CANCELLED" ] && { remove_sa_task "$TASK_TASKPATH" "$TASK_ID"; SA_ERROR_MSG=''; return 1; }
                    return 1
                fi
                [ -n "$AP_CANCELLED" ] && { remove_sa_task "$TASK_TASKPATH" "$TASK_ID"; SA_ERROR_MSG=''; return 1; }
            fi
        fi
        TASK_STATUS='InProgress'
        TASK_STEP='GitArchivePending'
        ctx_write_info "$TASK_TASKPATH"
        save_sa_task
        show_header '归档 Git 源码' '正在建立或更新 mirror，并生成完整 bundle。'
        local mirror
        if ! mirror=$(update_git_mirror "$name" "$source_url"); then return 1; fi
        mkdir -p "$TASK_STAGEPATH/Source"
        new_git_bundle "$mirror" "$TASK_STAGEPATH/Source/$name.bundle" || return 1
    fi

    write_info_yaml "$TASK_STAGEPATH/info.yml"
    new_user_manual "$TASK_STAGEPATH/使用手册.md" "$name" "$INFO_VERSION" ${INFO_PLATFORMS[@]+"${INFO_PLATFORMS[@]}"}
    new_sa_checksums "$TASK_STAGEPATH" >/dev/null
    TASK_MESSAGE=''; TASK_STATUS='WaitingManual'; TASK_STEP='ManualPending'
    save_sa_task
    complete_manual_step 0
    return 0
}

# ---------- 记录选择与更新 ----------

select_software_record() { # title [policy] → SR_INDEX / SR_CANCELLED
    local title=$1 policy=${2:-}
    get_software_records
    local -a labels=() idxs=()
    local i version label
    for ((i = 0; i < ${#REC_NAMES[@]}; i++)); do
        if [ -n "$policy" ]; then
            if [ "${REC_VALID[$i]}" != '1' ]; then continue; fi
            read_info_yaml "${REC_DIRS[$i]}/info.yml" >/dev/null 2>&1
            [ "$INFO_POLICY" != "$policy" ] && continue
        fi
        if [ "${REC_VALID[$i]}" = '1' ]; then
            read_info_yaml "${REC_DIRS[$i]}/info.yml" >/dev/null 2>&1
            version=$INFO_VERSION; [ -n "$version" ] || version='未记录版本'
            label="${REC_NAMES[$i]}  [$INFO_POLICY / $version]"
        else
            label="${REC_NAMES[$i]}  [Invalid / 无法读取]"
        fi
        labels+=("$label")
        idxs+=("$i")
    done
    if [ ${#labels[@]} -eq 0 ]; then
        show_header "$title" '没有符合条件的软件。'
        wait_for_user
        SR_CANCELLED=1
        return 0
    fi
    SELECT_TITLE=$title
    SELECT_OPTIONS=("${labels[@]}")
    SELECT_DEFAULT_INDEX=0
    SELECT_HELP=()
    SELECT_ALLOW_CANCEL=1
    select_one
    if [ "$SELECT_RESULT" -lt 0 ]; then SR_CANCELLED=1; return 0; fi
    SR_CANCELLED=''
    SR_INDEX=${idxs[$SELECT_RESULT]}
}

start_fixed_update() { # record_index
    local ri=$1
    read_info_yaml "${REC_DIRS[$ri]}/info.yml" >/dev/null 2>&1
    RV_TITLE='新版本'; RV_PROMPT='版本号'; RV_EXAMPLE='v3.0.0'
    RV_DEFAULT=''; RV_ALLOW_EMPTY=1; RV_VALIDATOR=''; RV_HELP=()
    read_value
    [ -n "$RV_CANCELLED" ] && return 0
    local newver=$RV_VALUE
    select_local_files '选择新版本安装包'
    if [ -n "$FILES_CANCELLED" ] || [ ${#FILES[@]} -eq 0 ]; then return 0; fi
    new_sa_task 'UpdateFixed' "$INFO_NAME"
    if ! fixed_update_body "$newver" "$ri"; then
        [ -n "$SA_ERROR_MSG" ] && show_task_failure
        return 0
    fi
}

fixed_update_body() { # new_version record_index
    local newver=$1 ri=$2
    copy_software_to_task "${REC_DIRS[$ri]}" || return 1
    read_info_yaml "$TASK_STAGEPATH/info.yml" >/dev/null 2>&1 || return 1
    local -a preferred=(${INFO_PLATFORMS[@]+"${INFO_PLATFORMS[@]}"})
    local newfolder=$(safe_path_segment "$newver" 'Unknown')
    if ! move_old_packages "$TASK_STAGEPATH" "$newfolder"; then
        remove_sa_task "$TASK_TASKPATH" "$TASK_ID"; SA_ERROR_MSG=''
        return 1
    fi
    MAP_PLATFORMS=(); MAP_NAMES=(); MAP_URLS=(); MAP_SIZES=()
    if ! add_local_packages "$TASK_STAGEPATH" "$newver" ${preferred[@]+"${preferred[@]}"}; then
        [ -n "$AP_CANCELLED" ] && { remove_sa_task "$TASK_TASKPATH" "$TASK_ID"; SA_ERROR_MSG=''; return 1; }
        return 1
    fi
    [ -n "$AP_CANCELLED" ] && { remove_sa_task "$TASK_TASKPATH" "$TASK_ID"; SA_ERROR_MSG=''; return 1; }
    read_info_yaml "$TASK_STAGEPATH/info.yml" >/dev/null 2>&1
    INFO_VERSION=$newver
    INFO_LASTCHECKED=$(today_str)
    local p found allp
    local -a newplats=(${INFO_PLATFORMS[@]+"${INFO_PLATFORMS[@]}"})
    for p in ${MAP_PLATFORMS[@]+"${MAP_PLATFORMS[@]}"}; do
        found=0
        for allp in ${newplats[@]+"${newplats[@]}"}; do [ "$allp" = "$p" ] && found=1; done
        [ "$found" = '0' ] && newplats+=("$p")
    done
    INFO_PLATFORMS=(${newplats[@]+"${newplats[@]}"})
    write_info_yaml "$TASK_STAGEPATH/info.yml"
    new_sa_checksums "$TASK_STAGEPATH" >/dev/null
    TASK_MESSAGE=''; TASK_STATUS='WaitingManual'; TASK_STEP='ManualPending'
    save_sa_task
    complete_manual_step 1
    return 0
}

start_maintain_update() { # record_index
    local ri=$1
    read_info_yaml "${REC_DIRS[$ri]}/info.yml" >/dev/null 2>&1
    local name=$INFO_NAME url=$INFO_SOURCE_URL
    local lookup_state='Pending' rc
    while [ "$lookup_state" = 'Pending' ]; do
        show_header '查询 Maintain 更新' "正在查询：$url"
        get_latest_release "$url"
        rc=$?
        if [ $rc -eq 0 ]; then lookup_state='Found'
        elif [ $rc -eq 1 ]; then lookup_state='None'
        else
            SELECT_TITLE='Release 查询失败'
            SELECT_OPTIONS=('重试查询' '跳过 Release，只更新源码 bundle' '取消更新')
            SELECT_DEFAULT_INDEX=0
            SELECT_HELP=("$SA_ERROR_MSG" '查询失败不会再显示成“没有可用的正式 Release”。')
            SELECT_ALLOW_CANCEL=1
            select_one
            case $SELECT_RESULT in
                0) lookup_state='Pending' ;;
                1) lookup_state='SourceOnly' ;;
                *) lookup_state='Cancelled' ;;
            esac
        fi
    done
    [ "$lookup_state" = 'Cancelled' ] && return 0
    local -a details=("当前保存版本：$(if [ -n "$INFO_VERSION" ]; then printf '%s' "$INFO_VERSION"; else printf '未记录'; fi)")
    MAP_PLATFORMS=(); MAP_NAMES=(); MAP_URLS=(); MAP_SIZES=()
    local update_release=0
    if [ "$lookup_state" = 'Found' ]; then
        details+=("最新正式 Release：$RELEASE_TAG" "发布时间：$(format_release_time "$RELEASE_PUBLISHED")")
        local decided=0
        while [ "$decided" = '0' ]; do
            SELECT_TITLE='选择 Maintain 更新内容'
            SELECT_OPTIONS=('更新 Release 安装包与源码' '只更新源码 bundle' '取消')
            SELECT_DEFAULT_INDEX=0
            SELECT_HELP=(${details[@]+"${details[@]}"})
            SELECT_ALLOW_CANCEL=1
            select_one
            [ "$SELECT_RESULT" = '2' ] && return 0
            [ "$SELECT_RESULT" -lt 0 ] && return 0
            [ "$SELECT_RESULT" = '1' ] && { decided=1; continue; }
            select_release_asset_mappings ${INFO_PLATFORMS[@]+"${INFO_PLATFORMS[@]}"}
            [ -n "$SAM_CANCELLED" ] && continue
            update_release=1
            decided=1
        done
    elif [ "$lookup_state" = 'None' ]; then
        details+=('GitHub/GitLab 查询成功，当前没有可用的正式 Release。')
        SELECT_TITLE='选择 Maintain 更新内容'
        SELECT_OPTIONS=('只更新源码 bundle' '取消')
        SELECT_DEFAULT_INDEX=0
        SELECT_HELP=(${details[@]+"${details[@]}"})
        SELECT_ALLOW_CANCEL=1
        select_one
        [ "$SELECT_RESULT" -lt 0 ] || [ "$SELECT_RESULT" = '1' ] && return 0
    else
        details+=('Release 查询失败，已选择只更新源码 bundle。')
    fi

    new_sa_task 'UpdateMaintain' "$name"
    if ! maintain_update_body "$ri" "$update_release" "$url"; then
        [ -n "$SA_ERROR_MSG" ] && show_task_failure
        return 0
    fi
}

maintain_update_body() { # record_index update_release url
    local ri=$1 update_release=$2 url=$3
    copy_software_to_task "${REC_DIRS[$ri]}" || return 1
    read_info_yaml "$TASK_STAGEPATH/info.yml" >/dev/null 2>&1 || return 1
    if [ "$update_release" = '1' ] && [ ${#MAP_NAMES[@]} -gt 0 ]; then
        local release_folder=$(safe_path_segment "$RELEASE_TAG" 'Unknown')
        if ! move_old_packages "$TASK_STAGEPATH" "$release_folder"; then
            remove_sa_task "$TASK_TASKPATH" "$TASK_ID"; SA_ERROR_MSG=''
            return 1
        fi
        INFO_VERSION=$RELEASE_TAG
        TASK_STATUS='InProgress'
        TASK_STEP='ReleaseDownloadPending'
        ctx_write_info "$TASK_TASKPATH"
        ctx_write_release "$TASK_TASKPATH"
        ctx_write_mappings "$TASK_TASKPATH"
        save_sa_task
        if ! add_release_packages "$TASK_STAGEPATH"; then return 1; fi
    fi
    TASK_STATUS='InProgress'
    TASK_STEP='GitArchivePending'
    ctx_write_info "$TASK_TASKPATH"
    save_sa_task
    show_header '更新 Git 源码归档' '正在更新 mirror 并生成新的完整 bundle。'
    local mirror
    if ! mirror=$(update_git_mirror "$INFO_NAME" "$url"); then return 1; fi
    mkdir -p "$TASK_STAGEPATH/Source"
    new_git_bundle "$mirror" "$TASK_STAGEPATH/Source/$INFO_NAME.bundle" || return 1
    INFO_LASTCHECKED=$(today_str)
    INFO_SOURCE_TYPE=$(get_source_type "$INFO_SOURCE_URL")
    write_info_yaml "$TASK_STAGEPATH/info.yml"
    new_sa_checksums "$TASK_STAGEPATH" >/dev/null
    TASK_MESSAGE=''; TASK_STATUS='WaitingManual'; TASK_STEP='ManualPending'
    save_sa_task
    complete_manual_step 1
    return 0
}

start_update_software() {
    select_software_record '选择需要更新的软件'
    [ -n "$SR_CANCELLED" ] && return 0
    read_info_yaml "${REC_DIRS[$SR_INDEX]}/info.yml" >/dev/null 2>&1
    case $INFO_POLICY in
        Fixed) start_fixed_update "$SR_INDEX" ;;
        Maintain) start_maintain_update "$SR_INDEX" ;;
        Record)
            show_header 'Record 条目无需更新' \
                '记录型软件不保存安装包与源码，没有可更新的资源。' \
                '修改名称、平台、备注等信息：直接编辑该软件的 info.yml，然后在主菜单重建资源索引。' \
                '开始保存资源：使用「修改更新策略」转为 Fixed 或 Maintain。'
            wait_for_user ;;
        *) show_header '无法更新' 'info.yml 中的 update_policy 无效。'; wait_for_user ;;
    esac
}

# ---------- 策略转换 ----------

start_change_policy() {
    select_software_record '选择需要修改更新策略的软件'
    [ -n "$SR_CANCELLED" ] && return 0
    local ri=$SR_INDEX
    if ! read_info_yaml "${REC_DIRS[$ri]}/info.yml" >/dev/null 2>&1; then
        show_header '无法修改' 'info.yml 读取失败，请先修复。'; wait_for_user; return 0
    fi
    case $INFO_POLICY in
        Fixed|Maintain|Record) : ;;
        *) show_header '无法修改' '当前 update_policy 无效，请先修复 info.yml。'; wait_for_user; return 0 ;;
    esac
    local target
    local -a topts=() thelp=()
    case $INFO_POLICY in
        Fixed)
            topts=('Maintain：持续跟踪 Release 与 Git 源码')
            thelp=('将为该软件建立 Git mirror 并生成源码 bundle；现有安装包全部保留。')
            ;;
        Maintain)
            topts=('Fixed：保存确定版本的安装包')
            thelp=('停止 Release 自动查询；现有 Source/*.bundle 与来源信息全部保留。')
            ;;
        Record)
            topts=('Fixed：开始保存确定版本的安装包' 'Maintain：开始跟踪 Release 与 Git 源码')
            thelp=("当前：${INFO_NAME}（Record，仅记录）"
                   '转换后按目标策略补齐安装包或源码，现有信息全部保留。')
            ;;
    esac
    SELECT_TITLE='选择目标更新策略'
    SELECT_OPTIONS=("${topts[@]}")
    SELECT_DEFAULT_INDEX=0
    SELECT_HELP=(${thelp[@]+"${thelp[@]}"})
    SELECT_ALLOW_CANCEL=1
    select_one
    [ "$SELECT_RESULT" -lt 0 ] && return 0
    if [ "$INFO_POLICY" = 'Fixed' ]; then target='Maintain'
    elif [ "$INFO_POLICY" = 'Maintain' ]; then target='Fixed'
    elif [ "$SELECT_RESULT" = '0' ]; then target='Fixed'
    else target='Maintain'
    fi
    CA_TITLE='确认修改更新策略'
    CA_DETAILS=("$INFO_NAME：$INFO_POLICY → $target")
    CA_DEFAULT_NO=''
    confirm_action
    [ -z "$CA_RESULT" ] && return 0
    new_sa_task 'ChangePolicy' "$INFO_NAME"
    if ! change_policy_body "$ri" "$target"; then
        [ -n "$SA_ERROR_MSG" ] && show_task_failure
        return 0
    fi
}

# Record → Maintain：查询最新 Release 并可选下载对应平台的安装包，
# 使转换后的条目与直接收录的 Maintain 保持一致（都有安装包 + 源码归档）。
# 选择并映射了文件时走 ReleaseDownloadPending 检查点，下载中断可断点恢复。
sa_change_release_step() { # → 0 继续（无论是否下载）/ 1 取消转换或下载失败
    local lookup='Pending' rc
    while [ "$lookup" = 'Pending' ]; do
        show_header '查询最新 Release' "正在查询：$INFO_SOURCE_URL"
        get_latest_release "$INFO_SOURCE_URL"
        rc=$?
        if [ $rc -eq 0 ]; then lookup='Found'
        elif [ $rc -eq 1 ]; then lookup='None'
        else
            SELECT_TITLE='Release 查询失败'
            SELECT_OPTIONS=('重试查询' '跳过安装包，仅归档源码' '取消转换')
            SELECT_DEFAULT_INDEX=0
            SELECT_HELP=("$SA_ERROR_MSG")
            SELECT_ALLOW_CANCEL=1
            select_one
            case $SELECT_RESULT in
                0) : ;;
                1) lookup='Skip'; SA_ERROR_MSG='' ;;
                *) remove_sa_task "$TASK_TASKPATH" "$TASK_ID"; SA_ERROR_MSG=''; return 1 ;;
            esac
        fi
    done
    if [ "$lookup" = 'None' ]; then
        show_header '未发现正式 Release' \
            '该仓库当前没有正式 Release，转换后将只包含源码归档。' \
            '以后可在「更新已有软件」中补下载安装包。'
        wait_for_user
        return 0
    fi
    [ "$lookup" = 'Skip' ] && return 0
    local decided=0 choice
    while [ "$decided" = '0' ]; do
        SELECT_TITLE='选择 Release 安装包'
        SELECT_OPTIONS=("下载 $RELEASE_TAG 的安装包" '跳过，仅归档源码')
        SELECT_DEFAULT_INDEX=0
        SELECT_HELP=("版本：$RELEASE_TAG" "发布时间：$(format_release_time "$RELEASE_PUBLISHED")" '转换时一并下载安装包，与直接收录的 Maintain 软件保持一致。')
        SELECT_ALLOW_CANCEL=1
        select_one
        choice=$SELECT_RESULT
        if [ "$choice" = '1' ]; then return 0; fi
        [ "$choice" -lt 0 ] && continue
        MAP_PLATFORMS=(); MAP_NAMES=(); MAP_URLS=(); MAP_SIZES=()
        select_release_asset_mappings ${INFO_PLATFORMS[@]+"${INFO_PLATFORMS[@]}"}
        [ -n "$SAM_CANCELLED" ] && continue
        decided=1
    done
    [ ${#MAP_NAMES[@]} -eq 0 ] && return 0
    INFO_VERSION=$RELEASE_TAG
    TASK_STATUS='InProgress'
    TASK_STEP='ReleaseDownloadPending'
    ctx_write_info "$TASK_TASKPATH"
    ctx_write_release "$TASK_TASKPATH"
    ctx_write_mappings "$TASK_TASKPATH"
    save_sa_task
    add_release_packages "$TASK_STAGEPATH" || return 1
    return 0
}

change_policy_body() { # record_index target
    local ri=$1 target=$2 from_policy
    copy_software_to_task "${REC_DIRS[$ri]}" || return 1
    read_info_yaml "$TASK_STAGEPATH/info.yml" >/dev/null 2>&1 || return 1
    from_policy=$INFO_POLICY
    if [ "$target" = 'Maintain' ]; then
        RV_TITLE='设置源码仓库地址'; RV_PROMPT='source_url'; RV_EXAMPLE='https://github.com/owner/project'
        RV_DEFAULT=$INFO_SOURCE_URL; RV_ALLOW_EMPTY=''; RV_VALIDATOR='validate_url'; RV_HELP=()
        read_value
        if [ -n "$RV_CANCELLED" ]; then
            remove_sa_task "$TASK_TASKPATH" "$TASK_ID"; SA_ERROR_MSG=''
            return 1
        fi
        INFO_SOURCE_URL=$RV_VALUE
        INFO_SOURCE_TYPE=$(get_source_type "$INFO_SOURCE_URL")
        INFO_POLICY='Maintain'
        if [ "$from_policy" = 'Record' ] && ! sa_change_release_step; then return 1; fi
        mkdir -p "$TASK_STAGEPATH/Source"
        TASK_STATUS='InProgress'
        TASK_STEP='GitArchivePending'
        ctx_write_info "$TASK_TASKPATH"
        save_sa_task
        show_header '建立源码归档' '正在建立 mirror 并生成完整 bundle。'
        local mirror
        if ! mirror=$(update_git_mirror "$INFO_NAME" "$INFO_SOURCE_URL"); then return 1; fi
        new_git_bundle "$mirror" "$TASK_STAGEPATH/Source/$INFO_NAME.bundle" || return 1
    else
        INFO_POLICY='Fixed'
        if [ "$from_policy" = 'Record' ]; then
            # Record 没有 Packages：转 Fixed 时需要现场选择安装包。
            select_local_files '选择 Fixed 安装包'
            if [ -n "$FILES_CANCELLED" ] || [ ${#FILES[@]} -eq 0 ]; then
                remove_sa_task "$TASK_TASKPATH" "$TASK_ID"; SA_ERROR_MSG=''
                return 1
            fi
            MAP_PLATFORMS=(); MAP_NAMES=(); MAP_URLS=(); MAP_SIZES=()
            if ! add_local_packages "$TASK_STAGEPATH" "$INFO_VERSION" ${INFO_PLATFORMS[@]+"${INFO_PLATFORMS[@]}"}; then
                [ -n "$AP_CANCELLED" ] && { remove_sa_task "$TASK_TASKPATH" "$TASK_ID"; SA_ERROR_MSG=''; return 1; }
                return 1
            fi
            [ -n "$AP_CANCELLED" ] && { remove_sa_task "$TASK_TASKPATH" "$TASK_ID"; SA_ERROR_MSG=''; return 1; }
        fi
    fi
    [ -f "$TASK_STAGEPATH/使用手册.md" ] || \
        new_user_manual "$TASK_STAGEPATH/使用手册.md" "$INFO_NAME" "$INFO_VERSION" ${INFO_PLATFORMS[@]+"${INFO_PLATFORMS[@]}"}
    INFO_LASTCHECKED=$(today_str)
    write_info_yaml "$TASK_STAGEPATH/info.yml"
    new_sa_checksums "$TASK_STAGEPATH" >/dev/null
    TASK_MESSAGE=''; TASK_STATUS='WaitingManual'; TASK_STEP='ManualPending'
    save_sa_task
    complete_manual_step 1
    return 0
}

# ---------- 删除软件 ----------

start_delete_software() {
    select_software_record '选择需要彻底删除的软件'
    [ -n "$SR_CANCELLED" ] && return 0
    # 注意：不能写成 local ri=... name=${REC_NAMES[$ri]} —— 同一行 local 的
    # 多个赋值先整体展开再执行，$ri 当时还是空值，空下标会取到第 0 条。
    local ri=$SR_INDEX
    local name=${REC_NAMES[$ri]} dir=${REC_DIRS[$ri]}
    get_sa_software_footprint "$name" "$dir"
    local -a details=()
    if [ -n "$FP_LIBRARY" ]; then
        details+=("Library 目录：${FP_LIBRARY}（$(get_sa_size_text "$FP_LIBRARY")）")
    else
        details+=('Library 目录：不存在')
    fi
    local m
    if [ ${#FP_MIRRORS[@]} -gt 0 ]; then
        for m in "${FP_MIRRORS[@]}"; do
            details+=("Git mirror：${m}（$(get_sa_size_text "$m")）")
        done
    else
        details+=('Git mirror：不存在')
    fi
    details+=("未完成任务：${#FP_TASKS[@]} 个")
    if [ -z "$FP_LIBRARY" ] && [ ${#FP_MIRRORS[@]} -eq 0 ] && [ ${#FP_TASKS[@]} -eq 0 ]; then
        show_header '没有可删除的内容' '该软件在 Library、Repositories 和 Temp 中都没有本地数据。'
        wait_for_user
        return 0
    fi
    details+=('')
    details+=('以上内容将被彻底删除，不可恢复。输入软件名称以确认。')
    EXPECTED_NAME=$name
    RV_TITLE='确认彻底删除'
    RV_PROMPT="输入软件名称 $name 以确认"
    RV_EXAMPLE=$name
    RV_DEFAULT=''
    RV_ALLOW_EMPTY=''
    RV_VALIDATOR='validate_exact_name'
    RV_HELP=(${details[@]+"${details[@]}"})
    read_value
    [ -n "$RV_CANCELLED" ] && return 0

    show_header '正在彻底删除' "软件：$name" '请稍候……'
    if ! remove_sa_software "$name" "$dir"; then
        show_header '删除未完成' "$SA_ERROR_MSG"
        wait_for_user
        return 0
    fi
    if ! new_sa_index_workbook; then
        show_header '索引重建失败' "$SA_ERROR_MSG"
        wait_for_user
        return 0
    fi
    local -a lines=()
    local p
    for p in ${DEL_REMOVED[@]+"${DEL_REMOVED[@]}"}; do lines+=("已删除：$p"); done
    for p in ${DEL_ERRORS[@]+"${DEL_ERRORS[@]}"}; do lines+=("失败：$p"); done
    lines+=('资源索引已按剩余软件重建。')
    lines+=('')
    lines+=('云端操作：删除阿里云盘上的对应软件目录，并上传新的资源索引.xlsx。')
    show_header '删除完成' "${lines[@]}"
    wait_for_user
}

# ---------- 校验 / 索引 / 清理 ----------

start_verify_resources() {
    get_software_records
    if [ ${#REC_NAMES[@]} -eq 0 ]; then
        show_header '校验资源完整性' '资源库中还没有软件。'
        wait_for_user
        return 0
    fi
    local -a opts=('校验全部软件')
    local i
    for ((i = 0; i < ${#REC_NAMES[@]}; i++)); do
        opts+=("只校验：${REC_NAMES[$i]}")
    done
    SELECT_TITLE='校验资源完整性'
    SELECT_OPTIONS=("${opts[@]}")
    SELECT_DEFAULT_INDEX=0
    SELECT_HELP=()
    SELECT_ALLOW_CANCEL=1
    select_one
    [ "$SELECT_RESULT" -lt 0 ] && return 0
    local -a targets=()
    if [ "$SELECT_RESULT" = '0' ]; then
        for ((i = 0; i < ${#REC_NAMES[@]}; i++)); do targets+=("$i"); done
    else
        targets+=($((SELECT_RESULT - 1)))
    fi
    sa_clear
    printf '%s\n' "${CYAN}资源完整性校验${NONE}"
    printf '\n'
    local allpass=1 r status pathpart expected actual symbol color
    for r in "${targets[@]}"; do
        printf '%s\n' "${WHITE}${REC_NAMES[$r]}${NONE}"
        if sa_skip_checksum_verify "${REC_DIRS[$r]}"; then
            printf '%s\n' "${GRAY}  Record（仅记录）：无校验文件，跳过。${NONE}"
            printf '\n'
            continue
        fi
        test_sa_checksums "${REC_DIRS[$r]}"
        for item in ${CK_RESULTS[@]+"${CK_RESULTS[@]}"}; do
            status=${item%%|*}
            pathpart=${item#*|}
            pathpart=${pathpart%%|*}
            rest=${item#*|*|}
            expected=${rest%%|*}
            actual=${rest#*|}
            if [ "$status" = 'OK' ]; then symbol='✓'; color=$GREEN; else symbol='✗'; color=$RED; fi
            printf '%s\n' "${color}  $symbol [$status] $pathpart${NONE}"
            if [ "$status" = 'Mismatch' ]; then
                printf '%s\n' "${DARK}    预期：$expected${NONE}"
                printf '%s\n' "${DARK}    实际：$actual${NONE}"
            fi
        done
        if [ "$CK_PASSED" = '1' ]; then color=$GREEN; else color=$RED; allpass=0; fi
        printf '%s\n' "${color}  $CK_MESSAGE${NONE}"
        verify_sa_bundles "${REC_DIRS[$r]}"
        if [ "$BV_COUNT" -gt 0 ]; then
            if [ "$BV_OK" = "$BV_COUNT" ]; then color=$GREEN; else color=$RED; allpass=0; fi
            printf '%s\n' "${color}  $BV_MESSAGE${NONE}"
        fi
        printf '\n'
    done
    if [ "$allpass" = '1' ]; then color=$GREEN; msg='全部校验通过。'; else color=$RED; msg='校验发现问题，请检查红色项目。'; fi
    printf '%s\n' "${color}${msg}${NONE}"
    wait_for_user
}

start_rebuild_index() {
    show_header '重建资源索引' '正在扫描 Library/*/info.yml。'
    rebuild_index_tsv
    if new_sa_index_workbook; then
        show_header '资源索引已重建' "TSV：$INDEX_TSV_FILE" "XLSX：$INDEX_FILE"
    else
        show_header '资源索引已重建（XLSX 跳过）' "TSV：$INDEX_TSV_FILE" "$SA_ERROR_MSG"
    fi
    wait_for_user
}

start_clean_temp() {
    clear_expired_temp "$TEMP_RETENTION_DAYS"
    local -a lines=("保留天数：$TEMP_RETENTION_DAYS"
                    "已删除：${#CLEARED_REMOVED[@]}"
                    "因未完成任务而跳过：${#CLEARED_SKIPPED[@]}")
    show_header '临时目录清理完成' "${lines[@]}"
    wait_for_user
}

# ---------- 任务恢复 ----------

resume_sa_task() { # task_index
    local ti=$1
    TASK_ID=${TASKS_IDS[$ti]}
    TASK_OPERATION=${TASKS_OPS[$ti]}
    TASK_SOFTWARENAME=${TASKS_NAMES[$ti]}
    TASK_STATUS=${TASKS_STATUS[$ti]}
    TASK_STEP=${TASKS_STEPS[$ti]}
    TASK_TASKPATH=${TASKS_PATHS[$ti]}
    TASK_STAGEPATH="$TASK_TASKPATH/Staging"
    TASK_CREATEDAT=''
    TASK_UPDATEDAT=${TASKS_UPDATED[$ti]}
    TASK_MESSAGE=''
    local info_file="$TASK_STAGEPATH/info.yml"
    local manual="$TASK_STAGEPATH/使用手册.md"
    if [ "$TASK_STEP" = 'ReleaseDownloadPending' ]; then
        if ! ctx_read_info "$TASK_TASKPATH" || ! ctx_read_release "$TASK_TASKPATH" || ! ctx_read_mappings "$TASK_TASKPATH"; then
            show_header '无法继续安装包下载' '任务缺少 Release 下载上下文，请删除后重新开始。'
            wait_for_user
            return 0
        fi
        # 将 1.0 早期任务的错误字段原地规范化，后续再次恢复也可直接读取。
        ctx_write_info "$TASK_TASKPATH"
        ctx_write_release "$TASK_TASKPATH"
        ctx_write_mappings "$TASK_TASKPATH"
        remove_legacy_empty_release_dirs "$TASK_STAGEPATH"
        if ! add_release_packages "$TASK_STAGEPATH"; then
            TASK_MESSAGE=$SA_ERROR_MSG
            TASK_STATUS='InProgress'
            save_sa_task
            show_header '安装包下载仍未完成' "$SA_ERROR_MSG" '已经下载完成的文件不会重复下载。'
            wait_for_user
            return 0
        fi
        TASK_MESSAGE=''
        TASK_STATUS='InProgress'
        TASK_STEP='GitArchivePending'
        ctx_write_info "$TASK_TASKPATH"
        save_sa_task
        # 不再递归读取 TASKS_STEPS 中的旧检查点；直接在本次调用进入 Git 归档。
    fi
    if [ "$TASK_STEP" = 'GitArchivePending' ]; then
        if ! ctx_read_info "$TASK_TASKPATH"; then
            show_header '无法自动继续 Git 归档' \
                '这个任务缺少恢复所需的上下文。' \
                '请删除该任务并重新开始入库；已下载文件仍可先从任务目录取出。'
            wait_for_user
            return 0
        fi
        if [ -z "$INFO_SOURCE_URL" ]; then
            show_header '无法自动继续 Git 归档' '恢复信息中缺少 source_url。'
            wait_for_user
            return 0
        fi
        show_header '继续 Git 源码归档' '正在重新检查 mirror 并生成完整 bundle。'
        local mirror
        if ! mirror=$(update_git_mirror "$TASK_SOFTWARENAME" "$INFO_SOURCE_URL"); then
            TASK_MESSAGE=$SA_ERROR_MSG
            TASK_STATUS='InProgress'
            save_sa_task
            show_header 'Git 归档仍未完成' "$SA_ERROR_MSG" '任务与恢复上下文已保留，可稍后重试。'
            wait_for_user
            return 0
        fi
        mkdir -p "$TASK_STAGEPATH/Source"
        if ! new_git_bundle "$mirror" "$TASK_STAGEPATH/Source/$TASK_SOFTWARENAME.bundle"; then
            TASK_MESSAGE=$SA_ERROR_MSG
            TASK_STATUS='InProgress'
            save_sa_task
            show_header 'Git 归档仍未完成' "$SA_ERROR_MSG" '任务与恢复上下文已保留，可稍后重试。'
            wait_for_user
            return 0
        fi
        INFO_LASTCHECKED=$(today_str)
        INFO_SOURCE_TYPE=$(get_source_type "$INFO_SOURCE_URL")
        write_info_yaml "$info_file"
        [ -f "$manual" ] || new_user_manual "$manual" "$INFO_NAME" "$INFO_VERSION" ${INFO_PLATFORMS[@]+"${INFO_PLATFORMS[@]}"}
        new_sa_checksums "$TASK_STAGEPATH" >/dev/null
        TASK_MESSAGE=''
        TASK_STATUS='WaitingManual'
        TASK_STEP='ManualPending'
        save_sa_task
        local existing=0
        case $TASK_OPERATION in New*) : ;; *) existing=1 ;; esac
        complete_manual_step "$existing"
        return 0
    fi
    local manual_ok=0
    case $TASK_STEP in ManualPending|ManualConfirmed) manual_ok=1 ;; esac
    case $TASK_STATUS in WaitingManual|ReadyToCommit) manual_ok=1 ;; esac
    if [ "$manual_ok" = '1' ] && [ -f "$info_file" ]; then
        if ! read_info_yaml "$info_file"; then
            show_header '无法继续任务' "$SA_ERROR_MSG" '暂存文件未达到安全检查点。'
            wait_for_user
            return 0
        fi
        [ -f "$manual" ] || new_user_manual "$manual" "$INFO_NAME" "$INFO_VERSION" ${INFO_PLATFORMS[@]+"${INFO_PLATFORMS[@]}"}
        new_sa_checksums "$TASK_STAGEPATH" >/dev/null
        TASK_STATUS='WaitingManual'; TASK_STEP='ManualPending'
        save_sa_task
        local existing=0
        case $TASK_OPERATION in New*) : ;; *) existing=1 ;; esac
        complete_manual_step "$existing"
        return 0
    fi
    show_header '无法继续旧任务' \
        "当前检查点：$TASK_STEP" \
        '该检查点没有足够信息安全恢复。' \
        '请返回后选择“删除任务并重新开始”，或先打开任务目录取出已下载文件。'
    wait_for_user
}

invoke_recovery_prompt() {
    local ti choice resumable action op
    local -a labels actionopts help
    while :; do
        get_sa_tasks
        [ ${#TASKS_IDS[@]} -eq 0 ] && return 0
        labels=()
        for ((ti = 0; ti < ${#TASKS_IDS[@]}; ti++)); do
            labels+=("${TASKS_NAMES[$ti]}  [${TASKS_OPS[$ti]} / ${TASKS_STEPS[$ti]}]")
        done
        labels+=('稍后处理')
        SELECT_TITLE='发现未完成任务'
        SELECT_OPTIONS=("${labels[@]}")
        SELECT_DEFAULT_INDEX=0
        SELECT_HELP=('未完成任务不会改动正式资源库。')
        SELECT_ALLOW_CANCEL=1
        select_one
        [ "$SELECT_RESULT" -lt 0 ] || [ "$SELECT_RESULT" = "$(( ${#labels[@]} - 1 ))" ] && return 0
        ti=$SELECT_RESULT
        local info_file="${TASKS_PATHS[$ti]}/Staging/info.yml"
        resumable=0
        if [ "${TASKS_STEPS[$ti]}" = 'ReleaseDownloadPending' ] \
           && [ -f "${TASKS_PATHS[$ti]}/context-info.properties" ] \
           && [ -f "${TASKS_PATHS[$ti]}/context-release.properties" ] \
           && [ -f "${TASKS_PATHS[$ti]}/context-mappings.tsv" ]; then
            resumable=1
        fi
        if [ "${TASKS_STEPS[$ti]}" = 'GitArchivePending' ] \
           && [ -f "${TASKS_PATHS[$ti]}/context-info.properties" ]; then
            resumable=1
        fi
        local manual_ok=0
        case ${TASKS_STEPS[$ti]} in ManualPending|ManualConfirmed) manual_ok=1 ;; esac
        case ${TASKS_STATUS[$ti]} in WaitingManual|ReadyToCommit) manual_ok=1 ;; esac
        if [ "$manual_ok" = '1' ] && [ -f "$info_file" ]; then resumable=1; fi
        if [ "$resumable" = '1' ]; then
            actionopts=('继续' '打开任务目录' '删除任务并重新开始' '稍后处理')
        else
            actionopts=('删除旧任务并重新开始' '打开任务目录' '仅删除这个旧任务' '稍后处理')
        fi
        help=("软件：${TASKS_NAMES[$ti]}"
              "状态：${TASKS_STATUS[$ti]}"
              "检查点：${TASKS_STEPS[$ti]}"
              "更新时间：$(printf '%s' "${TASKS_UPDATED[$ti]}" | tr 'T' ' ')")
        [ "$resumable" = '0' ] && help+=('该任务缺少安全恢复检查点，不再提供无效的“继续”。')
        SELECT_TITLE='处理未完成任务'
        SELECT_OPTIONS=("${actionopts[@]}")
        SELECT_DEFAULT_INDEX=0
        SELECT_HELP=(${help[@]+"${help[@]}"})
        SELECT_ALLOW_CANCEL=1
        select_one
        action=$SELECT_RESULT
        [ "$action" -lt 0 ] || [ "$action" = '3' ] && return 0
        if [ "$action" = '0' ] && [ "$resumable" = '1' ]; then
            resume_sa_task "$ti"
            continue
        fi
        if [ "$action" = '0' ]; then
            CA_TITLE='删除旧任务并重新开始'
            CA_DETAILS=('旧任务的暂存目录将被删除。' '正式资源库不会受影响。')
            CA_DEFAULT_NO=1
            confirm_action
            if [ -n "$CA_RESULT" ]; then
                op=${TASKS_OPS[$ti]}
                remove_sa_task "${TASKS_PATHS[$ti]}" "${TASKS_IDS[$ti]}"
                case $op in
                    New*) start_new_software ;;
                    Update*) start_update_software ;;
                    ChangePolicy) start_change_policy ;;
                esac
            fi
            continue
        fi
        if [ "$action" = '1' ]; then
            open_local_path "${TASKS_PATHS[$ti]}" || {
                show_header '无法打开目录' "$SA_ERROR_MSG"
                wait_for_user
            }
            continue
        fi
        if [ "$action" = '2' ]; then
            CA_TITLE='确认删除暂存任务'
            CA_DETAILS=('只删除 Work/Temp 中的任务，正式资源库保持不变。')
            CA_DEFAULT_NO=1
            confirm_action
            [ -n "$CA_RESULT" ] && remove_sa_task "${TASKS_PATHS[$ti]}" "${TASKS_IDS[$ti]}"
        fi
    done
}

# ---------- 按键助手（消除 bash 3.2 下单独按 Esc 的 1 秒延迟） ----------

SA_KEY_FD=''
SA_KEY_HELPER_PID=''

sa_key_helper_start() {
    [ -t 0 ] || return 0
    command -v perl >/dev/null 2>&1 || return 0
    [ -f "$SELF_DIR/sa-keys.pl" ] || return 0
    KEY_FIFO="$TEMP_DIR/keys.$$"
    rm -f "$KEY_FIFO"
    mkfifo "$KEY_FIFO" 2>/dev/null || return 0
    # 注意：后台任务的 stdin 会被 shell 自动重定向到 /dev/null，
    # 必须显式 <&0 把终端绑定给助手，否则它立即读到 EOF 退出。
    perl "$SELF_DIR/sa-keys.pl" <&0 > "$KEY_FIFO" 2>/dev/null &
    SA_KEY_HELPER_PID=$!
    # 打开读端（阻塞到助手打开写端为止）；之后删除路径不影响已打开的 fd
    if ! eval "exec 6< \"\$KEY_FIFO\"" 2>/dev/null; then
        kill "$SA_KEY_HELPER_PID" 2>/dev/null
        SA_KEY_HELPER_PID=''
        rm -f "$KEY_FIFO"
        return 0
    fi
    SA_KEY_FD=6
    rm -f "$KEY_FIFO"
    return 0
}

sa_key_helper_stop() {
    if [ -n "$SA_KEY_HELPER_PID" ]; then
        kill "$SA_KEY_HELPER_PID" 2>/dev/null
        wait "$SA_KEY_HELPER_PID" 2>/dev/null
        SA_KEY_HELPER_PID=''
    fi
    if [ -n "$SA_KEY_FD" ]; then
        eval "exec $SA_KEY_FD<&-" 2>/dev/null
        SA_KEY_FD=''
    fi
    return 0
}

# ---------- 主菜单 ----------

guard() { # fn...
    "$@"
    local rc=$?
    if [ $rc -ne 0 ]; then
        show_header '操作未完成' "错误信息：$SA_ERROR_MSG" '正式资源库没有写入半成品，可返回主菜单重试。'
        wait_for_user
    fi
    return 0
}

open_library() {
    open_local_path "$LIBRARY_DIR" || {
        show_header '无法打开目录' "$SA_ERROR_MSG"
        wait_for_user
    }
}

# ---------- 搜索档案 ----------

start_search_archive() {
    get_software_records
    if [ ${#REC_NAMES[@]} -eq 0 ]; then
        show_header '搜索档案' '资源库中还没有软件。'
        wait_for_user
        return 0
    fi
    local -a lines=('输入关键字，将匹配：名称、备注、标签、状态、使用手册全文（不区分大小写）。')
    RV_TITLE='搜索档案'
    RV_PROMPT='关键字'
    RV_EXAMPLE=''
    RV_DEFAULT=''
    RV_ALLOW_EMPTY=''
    RV_VALIDATOR=''
    RV_HELP=("${lines[@]}")
    read_value
    if [ -n "$RV_CANCELLED" ]; then return 0; fi
    local q=$RV_VALUE ri
    local -a hits=() hit_idx=()
    for ((ri = 0; ri < ${#REC_NAMES[@]}; ri++)); do
        if record_matches_query "$q" "${REC_DIRS[$ri]}"; then
            hits+=("${REC_NAMES[$ri]}（${INFO_VERSION:-未记录版本}）— ${INFO_NOTES:-无备注}")
            hit_idx+=("$ri")
        fi
    done
    if [ ${#hits[@]} -eq 0 ]; then
        show_header '搜索档案' "没有匹配“$q”的软件。"
        wait_for_user
        return 0
    fi
    SELECT_TITLE="搜索结果：$q"
    SELECT_OPTIONS=("${hits[@]}")
    SELECT_DEFAULT_INDEX=0
    SELECT_HELP=('选择一项查看详情；Esc 返回。')
    SELECT_ALLOW_CANCEL=1
    select_one
    [ "$SELECT_RESULT" -lt 0 ] && return 0
    local sel=${hit_idx[$SELECT_RESULT]}
    read_info_yaml "${REC_DIRS[$sel]}/info.yml" >/dev/null 2>&1
    local plats tags
    plats=$(IFS='/'; echo "${INFO_PLATFORMS[*]}")
    tags=$(IFS='/'; echo "${INFO_TAGS[*]}")
    show_header "详情：$INFO_NAME" \
        "版本：${INFO_VERSION:-未记录}    平台：${plats:-无}    状态：${INFO_STATUS:-active}" \
        "策略：$INFO_POLICY    标签：${tags:-无}    最近检查：${INFO_LASTCHECKED:-从未}" \
        "来源：${INFO_SOURCE_URL:-无}" \
        "备注：${INFO_NOTES:-无}" \
        "目录：${REC_DIRS[$sel]}" \
        "手册：$([ -f "${REC_DIRS[$sel]}/使用手册.md" ] && printf '已存在' || printf '缺失')"
    wait_for_user
}

# ---------- 批量检查全部更新 ----------

start_check_all_updates() {
    get_software_records
    if [ ${#REC_NAMES[@]} -eq 0 ]; then
        show_header '检查全部更新' '资源库中还没有软件。'
        wait_for_user
        return 0
    fi
    if ! sa_lock_acquire '检查全部更新：'; then
        show_header '无法开始' "$SA_ERROR_MSG"
        wait_for_user
        return 0
    fi
    local -a upd=() same=() fail=() idx_upd=()
    local ri rc cur latest
    for ((ri = 0; ri < ${#REC_NAMES[@]}; ri++)); do
        read_info_yaml "${REC_DIRS[$ri]}/info.yml" >/dev/null 2>&1
        [ "$INFO_POLICY" = 'Maintain' ] || continue
        [ "${INFO_STATUS:-active}" = 'active' ] || continue
        show_header '检查全部更新' "正在查询（$((ri + 1))/${#REC_NAMES[@]}）：$INFO_SOURCE_URL"
        get_latest_release "$INFO_SOURCE_URL"
        rc=$?
        if [ $rc -ne 0 ]; then
            fail+=("${REC_NAMES[$ri]}：查询失败")
            continue
        fi
        cur=${INFO_VERSION:-未记录}
        latest=${RELEASE_TAG:-未知}
        if [ "$latest" = "$cur" ]; then
            same+=("${REC_NAMES[$ri]}：已是最新（${cur}）")
        else
            upd+=("${REC_NAMES[$ri]}：$cur → $latest")
            idx_upd+=("$ri")
        fi
    done
    sa_lock_release
    local -a summary=()
    [ ${#upd[@]}  -gt 0 ] && summary+=("有新版本 ${#upd[@]} 个：")
    [ ${#same[@]} -gt 0 ] && summary+=("已最新 ${#same[@]} 个")
    [ ${#fail[@]} -gt 0 ] && summary+=("查询失败 ${#fail[@]} 个")
    [ ${#summary[@]} -eq 0 ] && summary+=('没有策略为 Maintain 且状态为 active 的软件。')
    SELECT_TITLE='检查全部更新：结果'
    local -a opts=()
    [ ${#upd[@]} -gt 0 ] && opts+=('进入某个软件的更新向导')
    opts+=('仅查看明细' '返回')
    SELECT_OPTIONS=("${opts[@]}")
    SELECT_DEFAULT_INDEX=0
    local detail=''
    local l
    for l in "${upd[@]+"${upd[@]}"}"; do detail+="$l"$'\n'; done
    for l in "${same[@]+"${same[@]}"}"; do detail+="$l"$'\n'; done
    for l in "${fail[@]+"${fail[@]}"}"; do detail+="$l"$'\n'; done
    SELECT_HELP=("${summary[@]}" "$detail")
    SELECT_ALLOW_CANCEL=1
    select_one
    local pick=$SELECT_RESULT
    [ "$pick" -lt 0 ] && return 0
    if [ ${#upd[@]} -gt 0 ] && [ "$pick" = '0' ]; then
        SELECT_TITLE='选择要更新的软件'
        SELECT_OPTIONS=("${upd[@]}")
        SELECT_DEFAULT_INDEX=0
        SELECT_HELP=('选择后进入该软件的更新向导。')
        SELECT_ALLOW_CANCEL=1
        select_one
        [ "$SELECT_RESULT" -lt 0 ] && return 0
        start_maintain_update "${idx_upd[$SELECT_RESULT]}"
    fi
    return 0
}

# ---------- 标记软件状态 ----------

start_mark_status() {
    get_software_records
    if [ ${#REC_NAMES[@]} -eq 0 ]; then
        show_header '标记软件状态' '资源库中还没有软件。'
        wait_for_user
        return 0
    fi
    local -a opts=()
    local ri
    for ((ri = 0; ri < ${#REC_NAMES[@]}; ri++)); do
        read_info_yaml "${REC_DIRS[$ri]}/info.yml" >/dev/null 2>&1
        opts+=("${REC_NAMES[$ri]}（当前：${INFO_STATUS:-active}）")
    done
    SELECT_TITLE='标记软件状态'
    SELECT_OPTIONS=("${opts[@]}")
    SELECT_DEFAULT_INDEX=0
    SELECT_HELP=('适用于 Fixed 软件失效/迁移等情况；active 软件才会参与更新检查。')
    SELECT_ALLOW_CANCEL=1
    select_one
    [ "$SELECT_RESULT" -lt 0 ] && return 0
    local sel=$SELECT_RESULT
    read_info_yaml "${REC_DIRS[$sel]}/info.yml" >/dev/null 2>&1
    SELECT_TITLE="标记状态：$INFO_NAME"
    SELECT_OPTIONS=('active：正常使用' 'deprecated：已失效/停止维护' 'migrated：已迁移到其他软件' '返回')
    SELECT_DEFAULT_INDEX=0
    SELECT_HELP=()
    SELECT_ALLOW_CANCEL=1
    select_one
    [ "$SELECT_RESULT" -lt 0 ] || [ "$SELECT_RESULT" -ge 3 ] && return 0
    local st=('active' 'deprecated' 'migrated')
    INFO_STATUS=${st[$SELECT_RESULT]}
    write_info_yaml "$INFO_PATH"
    rebuild_index_tsv >/dev/null 2>&1
    show_header '标记软件状态' "已将 $INFO_NAME 标记为 $INFO_STATUS。"
    wait_for_user
}

# ---------- Maintain（源码镜像维护） ----------

start_maintain_menu() {
    get_software_records
    if [ ${#REC_NAMES[@]} -eq 0 ]; then
        show_header '维护源码镜像' '资源库中还没有软件。'
        wait_for_user
        return 0
    fi
    local -a opts=() idx=()
    local ri
    for ((ri = 0; ri < ${#REC_NAMES[@]}; ri++)); do
        read_info_yaml "${REC_DIRS[$ri]}/info.yml" >/dev/null 2>&1
        if [ "$INFO_POLICY" = 'Maintain' ]; then
            opts+=("${REC_NAMES[$ri]}（${INFO_VERSION:-未记录}）")
            idx+=("$ri")
        fi
    done
    if [ ${#opts[@]} -eq 0 ]; then
        show_header '维护源码镜像' '没有策略为 Maintain 的软件。'
        wait_for_user
        return 0
    fi
    SELECT_TITLE='维护源码镜像 (Maintain)'
    SELECT_OPTIONS=("${opts[@]}")
    SELECT_DEFAULT_INDEX=0
    SELECT_HELP=('更新该软件的 Git mirror 与 .bundle 源码备份。')
    SELECT_ALLOW_CANCEL=1
    select_one
    [ "$SELECT_RESULT" -lt 0 ] && return 0
    start_maintain_update "${idx[$SELECT_RESULT]}"
}

# ---------- 导出 / 导入软件条目 ----------

start_export_entry() {
    get_software_records
    if [ ${#REC_NAMES[@]} -eq 0 ]; then
        show_header '导出软件条目' '资源库中还没有软件。'
        wait_for_user
        return 0
    fi
    local -a opts=()
    local ri
    for ((ri = 0; ri < ${#REC_NAMES[@]}; ri++)); do
        opts+=("${REC_NAMES[$ri]}（${REC_DIRS[$ri]##*/}）")
    done
    SELECT_TITLE='导出软件条目'
    SELECT_OPTIONS=("${opts[@]}")
    SELECT_DEFAULT_INDEX=0
    SELECT_HELP=('导出为可分享的 zip；对方可通过「导入软件条目」直接入库。')
    SELECT_ALLOW_CANCEL=1
    select_one
    [ "$SELECT_RESULT" -lt 0 ] && return 0
    local sel=$SELECT_RESULT
    local name=${REC_NAMES[$sel]}
    read_info_yaml "${REC_DIRS[$sel]}/info.yml" >/dev/null 2>&1
    SELECT_TITLE='导出内容'
    SELECT_OPTIONS=('完整（安装包 + 手册 + 信息；不含源码镜像）' '仅信息与使用手册' '返回')
    SELECT_DEFAULT_INDEX=0
    SELECT_HELP=()
    SELECT_ALLOW_CANCEL=1
    select_one
    [ "$SELECT_RESULT" -lt 0 ] || [ "$SELECT_RESULT" -ge 2 ] && return 0
    local mode=$SELECT_RESULT
    local dest="$HOME/Desktop/${name}-$(safe_path_segment "${INFO_VERSION:-unknown}").saentry.zip"
    rm -f "$dest"
    if [ "$mode" = '0' ]; then
        (cd "$LIBRARY_DIR" && zip -q -r "$dest" "$name" -x "$name/Source/*") || {
            show_header '导出失败' 'zip 打包出错。' ; wait_for_user; return 0;
        }
    else
        local -a inc=("$name/info.yml")
        [ -f "$LIBRARY_DIR/$name/使用手册.md" ] && inc+=("$name/使用手册.md")
        [ -f "$LIBRARY_DIR/$name/checksums.sha256" ] && inc+=("$name/checksums.sha256")
        (cd "$LIBRARY_DIR" && zip -q -r "$dest" "$name" -i ${inc[@]+"${inc[@]}"}) || {
            show_header '导出失败' 'zip 打包出错。' ; wait_for_user; return 0;
        }
    fi
    show_header '导出完成' "文件：$dest" '可直接发送给他人；对方在主菜单选择「导入软件条目」。'
    wait_for_user
}

start_import_entry() {
    select_local_files '选择要导入的 .saentry.zip'
    if [ -n "$FILES_CANCELLED" ] || [ ${#FILES[@]} -eq 0 ]; then return 0; fi
    local src=${FILES[0]}
    local stage="$TEMP_DIR/import_$(date +%s)"
    rm -rf "$stage"; mkdir -p "$stage"
    if ! unzip -q "$src" -d "$stage" 2>/dev/null; then
        rm -rf "$stage"
        show_header '导入失败' '无法解压该文件，请确认是 .saentry.zip。'
        wait_for_user
        return 0
    fi
    local info=$(find "$stage" -maxdepth 3 -name info.yml -print 2>/dev/null | head -1)
    if [ -z "$info" ]; then
        rm -rf "$stage"
        show_header '导入失败' '压缩包中没有找到 info.yml。'
        wait_for_user
        return 0
    fi
    if ! read_info_yaml "$info"; then
        rm -rf "$stage"
        show_header '导入失败' "$SA_ERROR_MSG"
        wait_for_user
        return 0
    fi
    local name=$INFO_NAME
    local target="$LIBRARY_DIR/$(safe_path_segment "$name")"
    if [ -e "$target" ]; then
        rm -rf "$stage"
        show_header '导入失败' "已存在同名软件：$name" '如需覆盖请先删除原有条目。'
        wait_for_user
        return 0
    fi
    mkdir -p "$LIBRARY_DIR"
    mv "$(dirname "$info")" "$target"
    rm -rf "$stage"
    if [ "$INFO_POLICY" = 'Record' ]; then
        rebuild_index_tsv >/dev/null 2>&1
        new_sa_index_workbook >/dev/null 2>&1
        show_header '导入完成' "$name 已加入档案库（Record，仅记录，无需使用手册）。"
        wait_for_user
        return 0
    fi
    if [ ! -f "$target/使用手册.md" ]; then
        new_user_manual "$target/使用手册.md" "$name" "${INFO_VERSION:-}" ${INFO_PLATFORMS[@]+"${INFO_PLATFORMS[@]}"}
    fi
    rebuild_index_tsv >/dev/null 2>&1
    new_sa_index_workbook >/dev/null 2>&1
    show_header '导入完成' "$name 已加入档案库（版本 ${INFO_VERSION:-未记录}）。" '如使用手册仍是模板，请补写后回到“更新已有软件”确认完成。'
    wait_for_user
}

start_main_menu() {
    if ! sa_lock_acquire; then
        show_header '无法启动' "$SA_ERROR_MSG" '关闭另一个正在运行的实例后重试。'
        wait_for_user
        return 0
    fi
    trap 'sa_lock_release; sa_key_helper_stop' EXIT
    sa_key_helper_start
    invoke_recovery_prompt
    local choice records_count maintain_count record_count pending_count deprecated_count i
    local -a options
    while :; do
        get_software_records
        records_count=${#REC_NAMES[@]}
        pending_count=${#TASKS_IDS[@]}
        maintain_count=0
        record_count=0
        deprecated_count=0
        for ((i = 0; i < records_count; i++)); do
            if [ "${REC_VALID[$i]}" = '1' ]; then
                read_info_yaml "${REC_DIRS[$i]}/info.yml" >/dev/null 2>&1
                [ "$INFO_POLICY" = 'Maintain' ] && maintain_count=$((maintain_count + 1))
                [ "$INFO_POLICY" = 'Record' ] && record_count=$((record_count + 1))
                [ "${INFO_STATUS:-active}" != 'active' ] && deprecated_count=$((deprecated_count + 1))
            fi
        done
        options=('收录新软件'
                 '更新已有软件'
                 '检查全部更新'
                 "处理未完成任务 [$pending_count]"
                 '搜索档案'
                 '修改更新策略'
                 '标记软件状态'
                 '删除已有软件'
                 '维护源码镜像 (Maintain)'
                 '导出软件条目'
                 '导入软件条目'
                 '校验资源完整性'
                 '重建 资源索引'
                 '清理过期临时目录'
                 '打开 Library 目录'
                 '重新初始化工作环境'
                 '退出')
        SELECT_TITLE="SoftwareArchive $SA_VERSION 软件档案管理"
        SELECT_OPTIONS=("${options[@]}")
        SELECT_DEFAULT_INDEX=0
        SELECT_HELP=("已收录：$records_count 个；Maintain：$maintain_count 个；仅记录：$record_count 个；失效/迁移：$deprecated_count 个；未完成任务：$pending_count 个"
                     '方向键选择，重要操作会在提交前再次确认。')
        SELECT_ALLOW_CANCEL=''
        select_one
        choice=$SELECT_RESULT
        case $choice in
            0) guard start_new_software ;;
            1) guard start_update_software ;;
            2) guard start_check_all_updates ;;
            3) guard invoke_recovery_prompt ;;
            4) guard start_search_archive ;;
            5) guard start_change_policy ;;
            6) guard start_mark_status ;;
            7) guard start_delete_software ;;
            8) guard start_maintain_menu ;;
            9) guard start_export_entry ;;
            10) guard start_import_entry ;;
            11) guard start_verify_resources ;;
            12) guard start_rebuild_index ;;
            13) guard start_clean_temp ;;
            14) guard open_library ;;
            15)
                sa_init_environment
                show_header '初始化完成' 'Repositories、Downloads、Temp、Config 和索引已经检查。'
                wait_for_user
                ;;
            16) sa_lock_release; sa_key_helper_stop; trap - EXIT; return 0 ;;
        esac
    done
}

# ---------- 入口 ----------

case $ACTION in
    Init)
        sa_init_environment
        rebuild_index_tsv >/dev/null 2>&1
        printf '%s\n' 'SoftwareArchive 环境初始化完成。'
        if [ -n "${SA_DATA_HOME:-}" ]; then
            printf '%s\n' "代码目录：$ROOT_DIR"
            printf '%s\n' "数据目录：$SA_DATA_HOME"
        else
            printf '%s\n' "根目录：$ROOT_DIR"
        fi
        ;;
    List)
        # 输出 TSV 清单到 stdout（机器可读；供其他工具/脚本消费）
        write_index_tsv
        exit 0
        ;;
    RebuildIndex)
        if ! rebuild_index_tsv; then
            printf '%s\n' "$SA_ERROR_MSG" >&2
            exit 1
        fi
        printf '%s\n' "资源索引已生成：$INDEX_TSV_FILE"
        if new_sa_index_workbook; then
            printf '%s\n' "资源索引已生成：$INDEX_FILE"
        else
            printf '%s\n' "提示：${SA_ERROR_MSG}（TSV 索引不受影响）" >&2
        fi
        ;;
    Verify)
        failed=0
        get_software_records
        for ((i = 0; i < ${#REC_NAMES[@]}; i++)); do
            if sa_skip_checksum_verify "${REC_DIRS[$i]}"; then
                printf '%s\n' "${REC_NAMES[$i]}：Record（仅记录，跳过校验）"
                continue
            fi
            test_sa_checksums "${REC_DIRS[$i]}"
            verify_sa_bundles "${REC_DIRS[$i]}"
            local line="${REC_NAMES[$i]}：${CK_MESSAGE}"
            [ -n "$BV_MESSAGE" ] && line+="（${BV_MESSAGE}）"
            printf '%s\n' "$line"
            [ "$CK_PASSED" = '1' ] || failed=$((failed + 1))
            [ "$BV_COUNT" -gt 0 ] && [ "$BV_OK" != "$BV_COUNT" ] && failed=$((failed + 1))
        done
        if [ "$failed" -gt 0 ]; then exit 2; fi
        exit 0
        ;;
    *)
        start_main_menu
        ;;
esac
