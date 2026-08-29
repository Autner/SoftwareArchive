#!/bin/bash
# SoftwareArchive 核心函数库（macOS 版）
# 由 SoftwareArchive.sh 在启动时 source，请勿单独执行。
# 兼容 macOS 自带的 bash 3.2。

SA_VERSION='1.0.7'

# ---------- 环境 ----------

sa_init_locale() {
    case "${LC_ALL:-}" in
        ''|*[Uu][Tt][Ff]-8*) : ;;
        *) unset LC_ALL ;;
    esac
    case "${LANG:-}" in
        *[Uu][Tt][Ff]-8*) : ;;
        *) export LANG='en_US.UTF-8' ;;
    esac
}

write_file() { # path content
    mkdir -p "$(dirname "$1")"
    printf '%s' "$2" > "$1"
}

trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}

now_iso() { date '+%Y-%m-%dT%H:%M:%S'; }
today_str() { date '+%Y-%m-%d'; }

file_size() { # path → 字节数
    stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null || echo 0
}

file_mtime_epoch() { # path → epoch 秒
    stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

dir_size_kb() { # path → KB 数
    du -sk "$1" 2>/dev/null | awk '{print $1}' | head -1
}

kb_text() { # kb → 人类可读
    awk -v k="$1" 'BEGIN{
        if (k >= 1024) printf "%.1f MB", k/1024;
        else printf "%d KB", k;
    }'
}

bytes_text() { awk -v b="$1" 'BEGIN{ printf "%.1f MB", b/1048576 }'; }

sa_set_error() { SA_ERROR_MSG=$1; printf '%s\n' "$1" >&2; return 0; }

# ---------- 路径与配置 ----------

resolve_path() { # base rel → 规范化绝对路径（不要求存在）
    local base=$1 rel=$2 cur seg
    case $rel in
        /*) printf '%s' "$rel"; return ;;
    esac
    cur=$base
    local oldIFS=$IFS
    IFS='/'
    local -a parts=($rel)
    IFS=$oldIFS
    for seg in "${parts[@]}"; do
        case $seg in
            ''|'.') continue ;;
            '..') cur=$(dirname "$cur") ;;
            *) cur="$cur/$seg" ;;
        esac
    done
    printf '%s' "$cur"
}

sa_default_config_text() {
    printf '%s' 'library_path: ../../Library

temp_retention_days: 30

default_platforms:
  - Windows
  - macOS
  - Linux
  - Android
  - iOS

release_check:
  prerelease: false
  draft: false

checksum:
  algorithm: SHA256

ui:
  language: zh-CN
'
}

sa_read_config() {
    LIBRARY_PATH_CFG='../../Library'
    TEMP_RETENTION_DAYS=30
    DEFAULT_PLATFORMS=(Windows macOS Linux Android iOS)
    INCLUDE_PRERELEASE=0
    INCLUDE_DRAFT=0
    CHECKSUM_ALGORITHM='SHA256'
    SA_LANGUAGE='zh-CN'
    [ -f "$CONFIG_FILE" ] || return 0
    local section='' line key val
    local -a platforms=()
    local re_top='^([A-Za-z_]+):[[:space:]]*(.*)$'
    local re_sub='^[[:space:]]+([A-Za-z_]+):[[:space:]]*(.*)$'
    local re_item='^[[:space:]]*-[[:space:]]*(.+)$'
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        [ -z "$(trim "$line")" ] && continue
        case $line in \#*) continue ;; esac
        if [ -n "$section" ] && [[ $line =~ $re_item ]]; then
            platforms+=("$(yaml_unquote "${BASH_REMATCH[1]}")")
            continue
        fi
        if [[ $line =~ $re_top ]]; then
            key=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
            section=''
            case $key in
                library_path) [ -n "$val" ] && LIBRARY_PATH_CFG=$(yaml_unquote "$val") ;;
                temp_retention_days)
                    val=$(yaml_unquote "$val")
                    case $val in ''|*[!0-9]*) : ;; *) [ "$val" -ge 1 ] && TEMP_RETENTION_DAYS=$val ;; esac
                    ;;
                default_platforms|release_check|checksum|ui)
                    [ -z "$val" ] && section=$key
                    ;;
            esac
            continue
        fi
        if [[ $line =~ $re_sub ]]; then
            key=${BASH_REMATCH[1]}; val=$(yaml_unquote "${BASH_REMATCH[2]}")
            case "$section.$key" in
                release_check.prerelease) [ "$val" = 'true' ] && INCLUDE_PRERELEASE=1 ;;
                release_check.draft) [ "$val" = 'true' ] && INCLUDE_DRAFT=1 ;;
                checksum.algorithm) : ;;
                ui.language) SA_LANGUAGE=$val ;;
            esac
        fi
    done < "$CONFIG_FILE"
    if [ ${#platforms[@]} -gt 0 ]; then DEFAULT_PLATFORMS=("${platforms[@]}"); fi
    return 0
}

sa_paths_init() { # scripts_dir
    SCRIPTS_DIR=$(cd "$1" && pwd)
    WORK_DIR=$(dirname "$SCRIPTS_DIR")
    ROOT_DIR=$(dirname "$WORK_DIR")
    CONFIG_DIR="$WORK_DIR/Config"
    CONFIG_FILE="$CONFIG_DIR/config.yml"
    REPOS_DIR="$WORK_DIR/Repositories"
    DOWNLOADS_DIR="$WORK_DIR/Downloads"
    TEMP_DIR="$WORK_DIR/Temp"
    sa_read_config
    LIBRARY_DIR=$(resolve_path "$CONFIG_DIR" "$LIBRARY_PATH_CFG")
    if [ "$LIBRARY_DIR" = '/' ] || [ "$LIBRARY_DIR" = "$ROOT_DIR" ]; then
        printf '%s\n' 'config.yml 中的 library_path 范围过大，请指向一个专用 Library 目录。' >&2
        exit 1
    fi
    INDEX_FILE="$LIBRARY_DIR/资源索引.xlsx"
}

sa_init_environment() {
    mkdir -p "$LIBRARY_DIR" "$CONFIG_DIR" "$REPOS_DIR" "$DOWNLOADS_DIR" "$TEMP_DIR"
    [ -f "$CONFIG_FILE" ] || write_file "$CONFIG_FILE" "$(sa_default_config_text)"
    [ -f "$INDEX_FILE" ] || new_sa_index_workbook
    return 0
}

# ---------- YAML（info.yml 子集） ----------

yaml_quote() {
    local s=${1:-}
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

yaml_unquote() {
    local s
    s=$(trim "$1")
    case $s in
        \"*\")
            s=${s#\"}; s=${s%\"}
            s=${s//\\\"/\"}
            s=${s//\\\\/\\}
            ;;
        \'\'*)
            s=${s#\`\'} ;;
    esac
    printf '%s' "$s"
}

# info.yml 读取结果存入 INFO_* 全局变量
read_info_yaml() { # path → 0 成功 / 1 失败
    local path=$1
    [ -f "$path" ] || { sa_set_error "找不到 info.yml：$path"; return 1; }
    INFO_NAME=''; INFO_POLICY=''; INFO_VERSION=''; INFO_SOURCE_URL=''
    INFO_SOURCE_TYPE=''; INFO_LICENSE=''; INFO_LASTCHECKED=''; INFO_NOTES=''
    INFO_PLATFORMS=(); INFO_TAGS=()
    INFO_PATH=$path
    INFO_DIR=$(dirname "$path")
    local list_key='' line key val
    local re_main='^([a-z_]+):[[:space:]]*(.*)$'
    local re_item='^[[:space:]]*-[[:space:]]*(.*)$'
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        [ -z "$(trim "$line")" ] && continue
        case $line in \#*) continue ;; esac
        if [ -n "$list_key" ]; then
            if [[ $line =~ $re_item ]]; then
                if [ "$list_key" = 'platforms' ]; then
                    INFO_PLATFORMS+=("$(yaml_unquote "${BASH_REMATCH[1]}")")
                else
                    INFO_TAGS+=("$(yaml_unquote "${BASH_REMATCH[1]}")")
                fi
                continue
            fi
            list_key=''
        fi
        if [[ $line =~ $re_main ]]; then
            key=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
            case $key in
                name) INFO_NAME=$(yaml_unquote "$val") ;;
                update_policy) INFO_POLICY=$(yaml_unquote "$val") ;;
                current_version) INFO_VERSION=$(yaml_unquote "$val") ;;
                source_url) INFO_SOURCE_URL=$(yaml_unquote "$val") ;;
                source_type) INFO_SOURCE_TYPE=$(yaml_unquote "$val") ;;
                license) INFO_LICENSE=$(yaml_unquote "$val") ;;
                last_checked) INFO_LASTCHECKED=$(yaml_unquote "$val") ;;
                notes) INFO_NOTES=$(yaml_unquote "$val") ;;
                platforms)
                    if [ -z "$(trim "$val")" ]; then list_key='platforms'
                    elif [ "$(trim "$val")" = '[]' ]; then INFO_PLATFORMS=()
                    fi ;;
                tags)
                    if [ -z "$(trim "$val")" ]; then list_key='tags'
                    elif [ "$(trim "$val")" = '[]' ]; then INFO_TAGS=()
                    fi ;;
            esac
        fi
    done < "$path"
    [ -n "$INFO_NAME" ] || { sa_set_error "info.yml 缺少 name 字段：$path"; return 1; }
    return 0
}

write_info_yaml() { # path（内容取自 INFO_* 全局变量）
    local path=$1 item text=''
    text+="name: $(yaml_quote "$INFO_NAME")"$'\n'$'\n'
    text+='platforms:'$'\n'
    for item in "${INFO_PLATFORMS[@]}"; do text+="  - $(yaml_quote "$item")"$'\n'; done
    text+=$'\n'
    text+="update_policy: $(yaml_quote "$INFO_POLICY")"$'\n'$'\n'
    text+="current_version: $(yaml_quote "$INFO_VERSION")"$'\n'$'\n'
    text+="source_url: $(yaml_quote "$INFO_SOURCE_URL")"$'\n'
    text+="source_type: $(yaml_quote "$INFO_SOURCE_TYPE")"$'\n'$'\n'
    if [ ${#INFO_TAGS[@]} -eq 0 ]; then
        text+='tags: []'$'\n'
    else
        text+='tags:'$'\n'
        for item in "${INFO_TAGS[@]}"; do text+="  - $(yaml_quote "$item")"$'\n'; done
    fi
    text+=$'\n'
    text+="license: $(yaml_quote "$INFO_LICENSE")"$'\n'$'\n'
    text+="last_checked: $(yaml_quote "$INFO_LASTCHECKED")"$'\n'$'\n'
    text+="notes: $(yaml_quote "$INFO_NOTES")"$'\n'
    write_file "$path" "$text"
}

# 记录列表：REC_NAMES[] / REC_DIRS[] / REC_VALID[]（按名称排序）
get_software_records() {
    REC_NAMES=(); REC_DIRS=(); REC_VALID=()
    [ -d "$LIBRARY_DIR" ] || return 0
    local d line name dir
    local -a pairs=()
    for d in "$LIBRARY_DIR"/*/; do
        [ -d "$d" ] || continue
        [ -f "${d}info.yml" ] || continue
        name=$(basename "$d")
        pairs+=("$name"$'\x1f'"$d")
    done
    if [ ${#pairs[@]} -eq 0 ]; then return 0; fi
    local oldIFS=$IFS
    IFS=$'\n'
    local -a sorted=($(printf '%s\n' "${pairs[@]}" | LC_ALL=C sort -t $'\x1f' -k1,1))
    IFS=$oldIFS
    for line in "${sorted[@]}"; do
        name=${line%%$'\x1f'*}
        dir=${line#*$'\x1f'}
        REC_NAMES+=("$name")
        REC_DIRS+=("$dir")
        if read_info_yaml "${dir}info.yml" 2>/dev/null; then REC_VALID+=('1'); else REC_VALID+=('0'); fi
    done
    return 0
}

# ---------- 名称与 URL 校验 ----------

test_software_name() { # name → 输出错误信息（空为通过）
    local n=$1 upper
    [ -z "$(trim "$n")" ] && { printf '%s\n' '软件名称不能为空。'; return; }
    case $n in
        ' '*|*' ') printf '%s\n' '软件名称首尾不能包含空格。'; return ;;
    esac
    case $n in
        *[\\/:\*\?\"\<\>\|]*) printf '%s\n' '软件名称含有文件名禁用字符。'; return ;;
    esac
    case $n in
        *.|*' ') printf '%s\n' '软件名称不能以点或空格结尾。'; return ;;
    esac
    upper=$(printf '%s' "$n" | tr '[:lower:]' '[:upper:]')
    case $upper in
        CON|PRN|AUX|NUL|COM1|COM2|COM3|COM4|COM5|COM6|COM7|COM8|COM9|LPT1|LPT2|LPT3|LPT4|LPT5|LPT6|LPT7|LPT8|LPT9)
            printf '%s\n' '该名称属于 Windows 保留文件名（为保证跨平台兼容同样禁止）。'; return ;;
    esac
    return 0
}

test_web_url() { # url → 错误信息
    case $1 in
        http://*|https://*) : ;;
        *) printf '%s\n' '地址必须以 https:// 或 http:// 开头。'; return ;;
    esac
    local rest=${1#*://}
    case $rest in
        ''|*' '*) printf '%s\n' '地址格式无效。'; return ;;
    esac
    return 0
}

safe_path_segment() { # value [fallback]
    local v=$(trim "$1") fb=${2:-Unknown}
    [ -z "$v" ] && { printf '%s' "$fb"; return; }
    local out='' ch i
    for ((i=0; i<${#v}; i++)); do
        ch=${v:i:1}
        case $ch in
            [\\/:\*\?\"\<\>\|]) out+='_' ;;
            *) out+=$ch ;;
        esac
    done
    out=$(trim "$out")
    out=${out%.}
    out=$(trim "$out")
    [ -z "$out" ] && out=$fb
    printf '%s' "$out"
}

get_source_type() {
    [ -z "$1" ] && { printf ''; return; }
    local rest=${1#*://} host
    host=${rest%%/*}
    host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
    case $host in
        github.com|*.github.com) printf 'GitHub' ;;
        gitlab.com|*gitlab*) printf 'GitLab' ;;
        *) printf 'Other' ;;
    esac
}

url_host() { local rest=${1#*://}; printf '%s' "${rest%%/*}"; }

url_project_path() { # owner/repo
    local rest=${1#*://}
    rest=${rest#*/}
    rest=${rest%%\?*}
    rest=${rest%%\#*}
    rest=${rest%/}
    rest=${rest%.git}
    local seg1 seg2
    local oldIFS=$IFS; IFS='/'; read -r seg1 seg2 <<< "$rest"; IFS=$oldIFS
    printf '%s/%s' "$seg1" "$seg2"
}

get_clone_url() {
    local proto=${1%%://*}
    local rest=${1#*://}
    rest=${rest%%\?*}; rest=${rest%%\#*}; rest=${rest%/}; rest=${rest%.git}
    local seg1 seg2
    local oldIFS=$IFS; IFS='/'; read -r seg1 seg2 <<< "$rest"; IFS=$oldIFS
    printf '%s://%s/%s.git' "$proto" "$seg1" "$seg2"
}

get_platform_guess() {
    local n
    n=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case $n in
        *win*|*.exe|*.msi|*.msix) printf 'Windows' ;;
        *mac*|*darwin*|*osx*|*.dmg|*.pkg) printf 'macOS' ;;
        *android*|*.apk|*.aab) printf 'Android' ;;
        *ios*|*.ipa) printf 'iOS' ;;
        *linux*|*appimage*|*.deb|*.rpm|*.snap) printf 'Linux' ;;
        *) printf '' ;;
    esac
}

# ---------- 系统代理（macOS：环境变量优先，其次 scutil） ----------

detect_system_proxy() {
    PROXY_URL=''
    local e=${https_proxy:-${HTTPS_PROXY:-}}
    if [ -n "$e" ]; then PROXY_URL=$e; return 0; fi
    local out enable host port
    if command -v scutil >/dev/null 2>&1; then
        out=$(scutil --proxy 2>/dev/null)
        # scutil 的键通常带前导空格，按首字段匹配以兼容不同 macOS 版本。
        enable=$(printf '%s\n' "$out" | awk '$1 == "HTTPSEnable" {print $3; exit}')
        host=$(printf '%s\n' "$out" | awk '$1 == "HTTPSProxy" {print $3; exit}')
        port=$(printf '%s\n' "$out" | awk '$1 == "HTTPSPort" {print $3; exit}')
        if [ "$enable" = '1' ] && [ -n "$host" ] && [ -n "$port" ]; then
            PROXY_URL="http://$host:$port"
        fi
    fi
    return 0
}

sa_proxy_env() { # 输出 "http_proxy=.. https_proxy=.."（空则输出空）
    [ -n "$PROXY_URL" ] || return 0
    printf 'http_proxy=%s https_proxy=%s all_proxy=%s' "$PROXY_URL" "$PROXY_URL" "$PROXY_URL"
}

# ---------- HTTP / Release 查询 ----------

SA_JXA_SCRIPT='ObjC.import("Foundation");
function run(argv) {
  var s = $.NSString.stringWithContentsOfFileEncodingError(argv[0], 4, null);
  if (s.isNil()) { return "ERR:READFILE"; }
  var d;
  try { d = JSON.parse(s.js); } catch (e) { return "ERR:JSON:" + e.message; }
  try {
    var r = (new Function("d", "return (" + argv[1] + ");"))(d);
    if (r === null || r === undefined) { return ""; }
    return String(r);
  } catch (e) { return "ERR:EVAL:" + e.message; }
}'

jxa_run() { # jsonfile expr → stdout；失败时输出 ERR: 前缀
    osascript -l JavaScript -e "$SA_JXA_SCRIPT" -- "$1" "$2" 2>/dev/null
}

jxa_failed() { case $1 in ERR:*) return 0 ;; *) return 1 ;; esac; }

# macOS 自带 Bash 3.2 的 read 不会按 \x01 拆分字段；使用参数展开兼容解析。
# 结果写入 SA_FIELD1 / SA_FIELD2 / SA_FIELD3，多余字段忽略。
sa_split_soh3() { # value
    local value=$1 sep=$'\x01' rest
    SA_FIELD1=${value%%"$sep"*}
    [ "$SA_FIELD1" != "$value" ] || { SA_FIELD2=''; SA_FIELD3=''; return 1; }
    rest=${value#*"$sep"}
    SA_FIELD2=${rest%%"$sep"*}
    [ "$SA_FIELD2" != "$rest" ] || { SA_FIELD3=''; return 1; }
    rest=${rest#*"$sep"}
    SA_FIELD3=${rest%%"$sep"*}
    return 0
}

sa_split_soh_array() { # value → SA_SPLIT_ITEMS[]
    local value=$1 sep=$'\x01' item
    SA_SPLIT_ITEMS=()
    [ -n "$value" ] || return 0
    while :; do
        item=${value%%"$sep"*}
        SA_SPLIT_ITEMS+=("$item")
        [ "$item" = "$value" ] && break
        value=${value#*"$sep"}
    done
    return 0
}

sa_request() { # url outfile [github] → http_code
    local url=$1 out=$2 gh=${3:-} code
    local -a args=(-sS -L --max-time 30 -o "$out" -w '%{http_code}'
                   -A "SoftwareArchive/$SA_VERSION")
    if [ -n "$PROXY_URL" ]; then args+=(-x "$PROXY_URL"); fi
    if [ "$gh" = 'github' ]; then
        args+=(-H 'Accept: application/vnd.github+json'
               -H 'X-GitHub-Api-Version: 2022-11-28')
        if [ -n "${GITHUB_TOKEN:-}" ]; then
            args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
        fi
    fi
    code=$(curl "${args[@]}" "$url" 2>"$out.err") || code='000'
    [ "$code" = '000' ] && [ -s "$out.err" ] && cp "$out.err" "$out"
    rm -f "$out.err"
    printf '%s' "$code"
}

request_error_message() { # http_code → 提示文本
    local code=$1
    local msg="HTTP 状态码：$code"
    case $code in
        000) msg='网络请求失败（无法连接服务器）。' ;;
        403) msg="$msg
GitHub 可能触发了 API 频率限制。可以配置 GITHUB_TOKEN 后重试。" ;;
    esac
    printf '%s\n' "$msg"
}

# 释放查询结果：RELEASE_TAG / RELEASE_PUBLISHED / RELEASE_WEBURL / RELEASE_SOURCETYPE
# ASSET_NAMES[] / ASSET_SIZES[] / ASSET_URLS[]
# 返回 0=找到；1=无正式 Release；2=查询失败（SA_ERROR_MSG 已设置）
get_latest_release() {
    local url=$1 stype project tmp code expr meta assets
    RELEASE_TAG=''; RELEASE_PUBLISHED=''; RELEASE_WEBURL=''
    ASSET_NAMES=(); ASSET_SIZES=(); ASSET_URLS=()
    stype=$(get_source_type "$url")
    tmp=$(mktemp -t sa_rel)
    case $stype in
        GitHub)
            project=$(url_project_path "$url")
            case $project in
                */*/*|*/ |'') return 1 ;;
            esac
            if [ "$INCLUDE_DRAFT" -eq 0 ] && [ "$INCLUDE_PRERELEASE" -eq 0 ]; then
                code=$(sa_request "https://api.github.com/repos/$project/releases/latest" "$tmp" github)
                if [ "$code" = '404' ]; then
                    code=$(sa_request "https://api.github.com/repos/$project/releases?per_page=1" "$tmp" github)
                    if [ "$code" != '200' ]; then
                        sa_set_error "$(request_error_message "$code")"
                        rm -f "$tmp"; return 2
                    fi
                    rm -f "$tmp"; return 1
                fi
                if [ "$code" != '200' ]; then
                    sa_set_error "$(request_error_message "$code")"
                    rm -f "$tmp"; return 2
                fi
                meta=$(jxa_run "$tmp" 'd.tag_name+"\u0001"+(d.published_at||"")+"\u0001"+(d.html_url||"")')
                if jxa_failed "$meta"; then
                    sa_set_error "Release 解析失败：$meta"
                    rm -f "$tmp"; return 2
                fi
                [ -z "$meta" ] && { rm -f "$tmp"; return 1; }
                RELEASE_SOURCETYPE='GitHub'
            else
                code=$(sa_request "https://api.github.com/repos/$project/releases?per_page=100" "$tmp" github)
                if [ "$code" != '200' ]; then
                    sa_set_error "$(request_error_message "$code")"
                    rm -f "$tmp"; return 2
                fi
                expr='(function(rs){rs=rs.filter(function(r){return ('"$INCLUDE_DRAFT"'||!r.draft)&&('"$INCLUDE_PRERELEASE"'||!r.prerelease)});rs.sort(function(a,b){return String(b.published_at||"").localeCompare(String(a.published_at||""))});var r=rs[0];return r?r.tag_name+"\u0001"+(r.published_at||"")+"\u0001"+(r.html_url||""):""})(d)'
                meta=$(jxa_run "$tmp" "$expr")
                if jxa_failed "$meta"; then
                    sa_set_error "Release 解析失败：$meta"
                    rm -f "$tmp"; return 2
                fi
                [ -z "$meta" ] && { rm -f "$tmp"; return 1; }
                RELEASE_SOURCETYPE='GitHub'
            fi
            if ! sa_split_soh3 "$meta"; then
                sa_set_error 'Release 元数据字段格式无效。'
                rm -f "$tmp"; return 2
            fi
            RELEASE_TAG=$SA_FIELD1
            RELEASE_PUBLISHED=$SA_FIELD2
            RELEASE_WEBURL=$SA_FIELD3
            assets=$(jxa_run "$tmp" 'd.assets.map(function(a){return (a.name||"")+"\u0001"+(a.size||0)+"\u0001"+((a.url||"")||a.browser_download_url||"")}).join("\u0002")')
            rm -f "$tmp"
            if jxa_failed "$assets"; then
                sa_set_error "Release 资产解析失败：$assets"
                return 2
            fi
            local line name size aurl
            local oldIFS=$IFS
            IFS=$'\x02'
            for line in $assets; do
                if ! sa_split_soh3 "$line"; then
                    IFS=$oldIFS
                    sa_set_error 'Release 资产字段格式无效。'
                    return 2
                fi
                name=$SA_FIELD1; size=$SA_FIELD2; aurl=$SA_FIELD3
                ASSET_NAMES+=("$name"); ASSET_SIZES+=("$size"); ASSET_URLS+=("$aurl")
            done
            IFS=$oldIFS
            return 0
            ;;
        GitLab)
            local host=$(url_host "$url")
            local proto=${url%%://*}
            local encoded
            encoded=$(printf '%s' "$(url_project_path "$url")" | sed 's|/|%2F|g')
            code=$(sa_request "$proto://$host/api/v4/projects/$encoded/releases?per_page=30" "$tmp")
            if [ "$code" != '200' ]; then
                sa_set_error "$(request_error_message "$code")"
                rm -f "$tmp"; return 2
            fi
            meta=$(jxa_run "$tmp" 'd.length===0?"":(function(r){return r.tag_name+"\u0001"+(r.released_at||"")+"\u0001"+((r._links&&r._links.self)||"")})(d[0])')
            if jxa_failed "$meta"; then
                sa_set_error "Release 解析失败：$meta"
                rm -f "$tmp"; return 2
            fi
            if [ -z "$meta" ]; then rm -f "$tmp"; return 1; fi
            if ! sa_split_soh3 "$meta"; then
                sa_set_error 'Release 元数据字段格式无效。'
                rm -f "$tmp"; return 2
            fi
            RELEASE_TAG=$SA_FIELD1
            RELEASE_PUBLISHED=$SA_FIELD2
            RELEASE_WEBURL=$SA_FIELD3
            RELEASE_SOURCETYPE='GitLab'
            local baseurl="$proto://$host"
            assets=$(jxa_run "$tmp" '(function(r){var ls=(r.assets&&r.assets.links)?r.assets.links:[];return ls.map(function(l){var u=(l.direct_asset_url||l.url||"");if(u.indexOf("/")===0){u="'"$baseurl"'"+u;}return ((l.name||"")+"\u0001"+"\u0001"+u);}).join("\u0002");})(d[0])')
            rm -f "$tmp"
            if jxa_failed "$assets"; then
                sa_set_error "Release 资产解析失败：$assets"
                return 2
            fi
            local line name size aurl
            local oldIFS=$IFS
            IFS=$'\x02'
            for line in $assets; do
                if ! sa_split_soh3 "$line"; then
                    IFS=$oldIFS
                    sa_set_error 'Release 资产字段格式无效。'
                    return 2
                fi
                name=$SA_FIELD1; size=$SA_FIELD2; aurl=$SA_FIELD3
                ASSET_NAMES+=("$name"); ASSET_SIZES+=("$size"); ASSET_URLS+=("$aurl")
            done
            IFS=$oldIFS
            return 0
            ;;
    esac
    sa_set_error '当前来源无法自动查询 Release。自动查询目前支持 GitHub 和 GitLab。'
    rm -f "$tmp"
    return 2
}

format_release_time() { # ISO 时间 → 本地 yyyy-MM-dd HH:mm
    local in=$1 epoch out
    epoch=$(date -ju -f '%Y-%m-%dT%H:%M:%SZ' "$in" '+%s' 2>/dev/null)
    if [ -z "$epoch" ]; then
        epoch=$(date -u -d "$in" '+%s' 2>/dev/null)
    fi
    if [ -z "$epoch" ] || [ "$epoch" = '0' ]; then printf '%s' "$in"; return; fi
    out=$(date -r "$epoch" '+%Y-%m-%d %H:%M' 2>/dev/null)
    if [ -z "$out" ]; then out=$(date -d "@$epoch" '+%Y-%m-%d %H:%M' 2>/dev/null); fi
    printf '%s' "${out:-$in}"
}

elapsed_text() { # 秒 → hh:mm:ss
    local t=$1 out
    out=$(date -u -r "$t" '+%H:%M:%S' 2>/dev/null)
    if [ -z "$out" ]; then out=$(date -u -d "@$t" '+%H:%M:%S' 2>/dev/null); fi
    printf '%s' "${out:-00:00:00}"
}

# ---------- 下载（断点续传 + 中文进度） ----------

mb_of() { awk -v b="$1" 'BEGIN{printf "%.1f", b/1048576}'; }

print_progress_line() { # have total start_epoch
    [ -t 1 ] || return 0
    local text
    text=$(awk -v h="$1" -v t="$2" -v s="$(( $(date +%s) - $3 ))" 'BEGIN{
        line = sprintf("  已下载 %.1f MB", h/1048576);
        if (t > 0) line = line sprintf(" / %.1f MB（%d%%）", t/1048576, int(h*100/t));
        if (s > 0 && h > 0) line = line sprintf("  %.1f MB/s", (h/1048576)/s);
        printf "%s", line
    }')
    printf '\r%s   ' "$text"
    return 0
}

invoke_sa_file_download() { # url dest total_bytes
    local url=$1 dest=$2 total=${3:-0}
    local partial="$dest.partial"
    case $url in
        http://*|https://*) : ;;
        *) sa_set_error '下载地址无效或为空，请重新查询 Release。'; return 1 ;;
    esac
    case $total in ''|*[!0-9]*) total=0 ;; esac
    mkdir -p "$(dirname "$dest")" || return 1
    SA_PROGRESS_TMP=$(mktemp -t sa_prog)
    local start=$(date +%s) attempt=0 have=0 rc=0 restart=0 last_error=''
    local -a proxy_args=()
    [ -n "$PROXY_URL" ] && proxy_args=(-x "$PROXY_URL")
    # 私有仓库的 Release 附件需要经 API 资产端点下载（github.com 网页直链不接受令牌，返回 404）。
    # 设置了 GITHUB_TOKEN 时自动附加鉴权头（curl 跨域重定向到签名 CDN 后无需鉴权）。
    local -a auth_args=()
    case $url in
        https://api.github.com/repos/*/releases/assets/*)
            if [ -n "${GITHUB_TOKEN:-}" ]; then
                auth_args=(-H "Authorization: Bearer $GITHUB_TOKEN" -H 'Accept: application/octet-stream')
            fi
            ;;
        https://github.com/*/releases/download/*)
            if [ -n "${GITHUB_TOKEN:-}" ]; then
                auth_args=(-H "Authorization: Bearer $GITHUB_TOKEN")
            fi
            ;;
    esac
    while :; do
        have=0; [ -f "$partial" ] && have=$(file_size "$partial")
        if [ "$total" -gt 0 ] && [ "$have" -ge "$total" ]; then break; fi
        if [ "$restart" = '1' ]; then
            rm -f "$partial"; have=0; restart=0
        fi
        if [ "$attempt" -gt 0 ]; then
            printf '\r%s   \n' "  网络中断，从 $(mb_of "$have") MB 处继续下载……"
            sleep 2
        fi
        attempt=$((attempt + 1))
        : > "$SA_PROGRESS_TMP"
        curl -fsSL -C - "${proxy_args[@]}" ${auth_args[@]+"${auth_args[@]}"} \
             -A "SoftwareArchive/$SA_VERSION" \
             --connect-timeout 30 --speed-limit 1024 --speed-time 30 \
             -o "$partial" "$url" 2>"$SA_PROGRESS_TMP" &
        local cpid=$!
        SA_ACTIVE_DOWNLOAD_PID=$cpid
        if [ -t 1 ]; then
            while kill -0 "$cpid" 2>/dev/null; do
                sleep 1
                have=0; [ -f "$partial" ] && have=$(file_size "$partial")
                print_progress_line "$have" "$total" "$start"
            done
        fi
        wait "$cpid"; rc=$?
        SA_ACTIVE_DOWNLOAD_PID=''
        if [ -s "$SA_PROGRESS_TMP" ]; then
            last_error=$(tail -n 2 "$SA_PROGRESS_TMP" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        fi
        have=0; [ -f "$partial" ] && have=$(file_size "$partial")
        if [ "$total" -gt 0 ] && [ "$have" -ge "$total" ]; then break; fi
        # 33 = 服务器不支持断点续传，弃断点重来
        if [ "$rc" -eq 33 ]; then restart=1; fi
        if [ "$rc" -eq 0 ]; then
            if [ "$total" -le 0 ] || [ "$have" -lt "$total" ]; then
                if [ "$total" -le 0 ]; then break; fi
            fi
        fi
        if [ "$attempt" -ge 10 ]; then
            printf '\n'
            sa_set_error "下载失败（已重试 $attempt 次）。已保留断点 $(mb_of "$have") MB，可稍后从“处理未完成任务”继续。${last_error:+
下载器错误：$last_error}"
            rm -f "$SA_PROGRESS_TMP"
            return 1
        fi
    done
    rm -f "$SA_PROGRESS_TMP"
    have=$(file_size "$partial")
    if [ "$have" -eq 0 ]; then
        rm -f "$partial"
        sa_set_error '下载结果为空。'
        return 1
    fi
    printf '\r%s   \n' "  下载完成：$(mb_of "$have") MB，耗时 $(elapsed_text "$(( $(date +%s) - start ))")。"
    mv -f "$partial" "$dest"
    return 0
}

# ---------- Git ----------

require_git() {
    command -v git >/dev/null 2>&1 && return 0
    sa_set_error '未检测到 Git。请先安装：xcode-select --install（或从 git-scm.com 下载）。'
    return 1
}

git_checked() { # args...（自动附加系统代理环境）
    require_git || return 1
    local -a env_args=()
    local pe=$(sa_proxy_env)
    [ -n "$pe" ] && env_args=($pe)
    local out rc
    out=$(env "${env_args[@]}" git "$@" 2>&1)
    rc=$?
    if [ $rc -ne 0 ]; then
        sa_set_error "Git 命令执行失败（退出码 $rc）。
$out"
        return 1
    fi
    return 0
}

update_git_mirror() { # software_name source_url → stdout mirror 路径
    require_git || return 1
    local name=$1 url=$2
    local clone_url=$(get_clone_url "$url")
    local mirror="$REPOS_DIR/$name.git"
    if [ -d "$mirror" ]; then
        if ! git -C "$mirror" rev-parse --is-bare-repository 2>/dev/null | grep -q '^true'; then
            rm -rf "$mirror"
        fi
    fi
    if [ -d "$mirror" ]; then
        git_checked -C "$mirror" remote set-url origin "$clone_url" || return 1
        git_checked -C "$mirror" remote update --prune || return 1
    else
        local partial="$mirror.partial"
        rm -rf "$partial"
        if git_checked clone --mirror "$clone_url" "$partial"; then
            mv "$partial" "$mirror" || { rm -rf "$partial"; return 1; }
        else
            rm -rf "$partial"
            return 1
        fi
    fi
    printf '%s' "$mirror"
}

new_git_bundle() { # mirror_path bundle_path
    local mirror=$1 bundle=$2 partial="$2.partial"
    mkdir -p "$(dirname "$bundle")" || return 1
    rm -f "$partial"
    git_checked -C "$mirror" bundle create "$partial" --all || { rm -f "$partial"; return 1; }
    git_checked -C "$mirror" bundle verify "$partial" || { rm -f "$partial"; return 1; }
    mv -f "$partial" "$bundle"
}

# ---------- 目录、手册、校验 ----------

initialize_software_directory() { # path [maintain]
    local p=$1
    mkdir -p "$p/Packages" "$p/Docs" "$p/Archive/Packages" "$p/Archive/Source" "$p/Archive/Docs"
    [ -n "$2" ] && mkdir -p "$p/Source"
    return 0
}

new_user_manual() { # path name version platforms...
    local path=$1 name=$2 ver=${3:-} ; shift 3
    local -a plats=("$@")
    [ -f "$path" ] && return 0
    [ -n "$ver" ] || ver='待填写'
    local ptext='待填写'
    if [ ${#plats[@]} -gt 0 ]; then ptext=$(IFS='/'; echo "${plats[*]}"); fi
    write_file "$path" "# $name

> 状态：待手动完善。完成后请回到管理脚本确认“使用手册已完成”。

## 1. 软件简介

请说明软件用途和适用场景。

## 2. 主要功能

- 请填写主要功能。

## 3. 安装与启动

请说明安装方式与首次启动注意事项。

## 4. 基本使用

请说明最常用的操作流程。

## 5. 常用功能

请按需补充主要功能的使用方法。

## 6. 注意事项

请记录兼容性、特殊配置和已知问题。

## 7. 当前推荐版本

- 版本：$ver
- 适用平台：$ptext
- 补充说明：待填写
"
}

checksum_targets() { # software_path → 每行一个相对路径（正斜杠）
    local p=$1 root f
    local -a roots=("$p/Packages" "$p/Source" "$p/Archive/Packages" "$p/Archive/Source")
    local -a found=()
    for root in "${roots[@]}"; do
        [ -d "$root" ] || continue
        while IFS= read -r f; do
            found+=("${f#"$p"/}")
        done < <(find "$root" -type f 2>/dev/null)
    done
    if [ ${#found[@]} -eq 0 ]; then return 0; fi
    printf '%s\n' "${found[@]}" | LC_ALL=C sort
}

new_sa_checksums() { # software_path → 登记条数
    local p=$1 line hash count=0 content=''
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        hash=$(shasum -a 256 "$p/$line" 2>/dev/null | awk '{print $1}')
        [ -z "$hash" ] && continue
        hash=$(printf '%s' "$hash" | tr '[:upper:]' '[:lower:]')
        content+="$hash  $line"$'\n'
        count=$((count + 1))
    done < <(checksum_targets "$p")
    write_file "$p/checksums.sha256" "$content"
    return 0
}

# 校验结果：CK_RESULTS（状态列表）CK_MESSAGE CK_PASSED
test_sa_checksums() { # software_path
    local p=$1 ckfile="$1/checksums.sha256"
    CK_PASSED=0; CK_MESSAGE=''; CK_RESULTS=()
    if [ ! -f "$ckfile" ]; then
        CK_MESSAGE='缺少 checksums.sha256。'; return 1
    fi
    local line re='^([0-9A-Fa-f]{64})[[:space:]]{2}(.+)$'
    local expect rel full actual status
    local -a listed=()
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$(trim "$line")" ] && continue
        if ! [[ $line =~ $re ]]; then
            CK_RESULTS+=("Invalid|$line||"); continue
        fi
        expect=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
        rel=${BASH_REMATCH[2]}
        listed+=("$(printf '%s' "$rel" | tr '[:upper:]' '[:lower:]')")
        full="$p/$rel"
        if [ ! -f "$full" ]; then
            CK_RESULTS+=("Missing|$rel|$expect|")
            continue
        fi
        actual=$(shasum -a 256 "$full" 2>/dev/null | awk '{print $1}')
        actual=$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')
        if [ "$actual" = "$expect" ]; then
            CK_RESULTS+=("OK|$rel|$expect|$actual")
        else
            CK_RESULTS+=("Mismatch|$rel|$expect|$actual")
        fi
    done < "$ckfile"
    local low
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        low=$(printf '%s' "$rel" | tr '[:upper:]' '[:lower:]')
        local found=0 l2
        for l2 in "${listed[@]}"; do
            if [ "$l2" = "$low" ]; then found=1; break; fi
        done
        [ "$found" = '0' ] && CK_RESULTS+=("Unlisted|$rel||")
    done < <(checksum_targets "$p")
    local failed=0 r
    for r in "${CK_RESULTS[@]}"; do
        case $r in
            OK\|*|'') : ;;
            *) failed=$((failed + 1)) ;;
        esac
    done
    if [ $failed -eq 0 ]; then
        CK_PASSED=1; CK_MESSAGE='校验通过。'
    else
        CK_MESSAGE="发现 $failed 个问题。"
    fi
    return 0
}

# ---------- 资源索引.xlsx ----------

xml_escape() {
    local s=${1:-}
    s=${s//&/&amp;}
    s=${s//</&lt;}
    s=${s//>/&gt;}
    s=${s//\"/&quot;}
    printf '%s' "$s"
}

new_sa_index_workbook() {
    command -v zip >/dev/null 2>&1 || { sa_set_error '未检测到 zip 命令，无法生成 资源索引.xlsx。'; return 1; }
    get_software_records
    local build="$TEMP_DIR/xlsx_build_$$"
    local outtmp="$TEMP_DIR/xlsx_out_$$.xlsx"
    rm -rf "$build" "$outtmp"
    mkdir -p "$build/_rels" "$build/docProps" "$build/xl/_rels" "$build/xl/worksheets/_rels"
    local -a headers=('名称' '标签' '平台' '当前保存版本' '来源类型' '来源地址' '更新策略' '最后检查' '备注')
    local cols=(A B C D E F G H I)
    local rows='' hyperlinks='' relationships=''
    local header_cells='' i col
    for ((i = 0; i < 9; i++)); do
        header_cells+=$(printf '<c r="%s1" s="1" t="inlineStr"><is><t>%s</t></is></c>' "${cols[$i]}" "$(xml_escape "${headers[$i]}")")
    done
    rows+=$(printf '<row r="1" ht="26" customHeight="1">%s</row>' "$header_cells")
    local rownum=2 relid=1 ri cells style val
    local -a tags plats vals
    for ((ri = 0; ri < ${#REC_NAMES[@]}; ri++)); do
        if [ "${REC_VALID[$ri]}" = '1' ]; then
            read_info_yaml "${REC_DIRS[$ri]}/info.yml" >/dev/null 2>&1
            tags=$(IFS='/'; echo "${INFO_TAGS[*]}")
            plats=$(IFS='/'; echo "${INFO_PLATFORMS[*]}")
            vals=("$INFO_NAME" "$tags" "$plats" "$INFO_VERSION" "$INFO_SOURCE_TYPE" "$INFO_SOURCE_URL" "$INFO_POLICY" "$INFO_LASTCHECKED" "$INFO_NOTES")
        else
            vals=("${REC_NAMES[$ri]}" '' '' '' '' '' 'Invalid' '' 'info.yml 读取失败')
        fi
        cells=''
        for ((i = 0; i < 9; i++)); do
            style=2
            if [ "$i" = '5' ] && [ -n "${vals[$i]:-}" ]; then style=3; fi
            cells+=$(printf '<c r="%s%d" s="%s" t="inlineStr"><is><t xml:space="preserve">%s</t></is></c>' "${cols[$i]}" "$rownum" "$style" "$(xml_escape "${vals[$i]:-}")")
        done
        rows+=$(printf '<row r="%d" ht="22" customHeight="1">%s</row>' "$rownum" "$cells")
        if [ "${REC_VALID[$ri]}" = '1' ] && [ -n "$INFO_SOURCE_URL" ]; then
            hyperlinks+=$(printf '<hyperlink ref="F%d" r:id="rId%d"/>' "$rownum" "$relid")
            relationships+=$(printf '<Relationship Id="rId%d" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="%s" TargetMode="External"/>' "$relid" "$(xml_escape "$INFO_SOURCE_URL")")
            relid=$((relid + 1))
        fi
        rownum=$((rownum + 1))
    done
    local lastrow=$((rownum - 1))
    [ "$lastrow" -lt 1 ] && lastrow=1
    local hyperxml=''
    [ -n "$hyperlinks" ] && hyperxml="<hyperlinks>$hyperlinks</hyperlinks>"
    write_file "$build/xl/worksheets/sheet1.xml" "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>
<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">
  <dimension ref=\"A1:I$lastrow\"/>
  <sheetViews><sheetView showGridLines=\"0\" workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>
  <sheetFormatPr defaultRowHeight=\"18\"/>
  <cols><col min=\"1\" max=\"1\" width=\"24\" customWidth=\"1\"/><col min=\"2\" max=\"3\" width=\"22\" customWidth=\"1\"/><col min=\"4\" max=\"5\" width=\"16\" customWidth=\"1\"/><col min=\"6\" max=\"6\" width=\"42\" customWidth=\"1\"/><col min=\"7\" max=\"8\" width=\"15\" customWidth=\"1\"/><col min=\"9\" max=\"9\" width=\"34\" customWidth=\"1\"/></cols>
  <sheetData>$rows</sheetData>
  <autoFilter ref=\"A1:I$lastrow\"/>
  $hyperxml
</worksheet>
"
    write_file "$build/xl/worksheets/_rels/sheet1.xml.rels" "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">$relationships</Relationships>"
    write_file "$build/[Content_Types].xml" '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>'
    write_file "$build/_rels/.rels" '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>'
    write_file "$build/docProps/app.xml" '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>SoftwareArchive</Application></Properties>'
    local now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    write_file "$build/docProps/core.xml" "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:dcmitype=\"http://purl.org/dc/dcmitype/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><dc:creator>SoftwareArchive</dc:creator><cp:lastModifiedBy>SoftwareArchive</cp:lastModifiedBy><dcterms:created xsi:type=\"dcterms:W3CDTF\">$now</dcterms:created><dcterms:modified xsi:type=\"dcterms:W3CDTF\">$now</dcterms:modified></cp:coreProperties>"
    write_file "$build/xl/workbook.xml" '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView xWindow="0" yWindow="0" windowWidth="24000" windowHeight="14000"/></bookViews><sheets><sheet name="资源索引" sheetId="1" r:id="rId1"/></sheets></workbook>'
    write_file "$build/xl/_rels/workbook.xml.rels" '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>'
    write_file "$build/xl/styles.xml" '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <fonts count="3"><font><sz val="11"/><name val="Helvetica"/><family val="3"/></font><font><b/><color rgb="FFFFFFFF"/><sz val="11"/><name val="Helvetica"/><family val="3"/></font><font><u/><color rgb="FF0563C1"/><sz val="11"/><name val="Helvetica"/><family val="3"/></font></fonts>
  <fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF1F4E78"/><bgColor indexed="64"/></patternFill></fill></fills>
  <borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left/><right/><top/><bottom style="thin"><color rgb="FFD9E2F3"/></bottom><diagonal/></border></borders>
  <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
  <cellXfs count="4"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf><xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf><xf numFmtId="0" fontId="2" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf></cellXfs>
  <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>'
    (cd "$build" && zip -q -X -r "$outtmp" '[Content_Types].xml' _rels docProps xl) || {
        rm -rf "$build" "$outtmp"
        sa_set_error '打包 资源索引.xlsx 失败。'
        return 1
    }
    rm -rf "$build"
    mv -f "$outtmp" "$INDEX_FILE"
    return 0
}

# ---------- 任务（task.json + 上下文文件） ----------

json_escape() {
    local s=${1:-}
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/ }
    s=${s//$'\r'/}
    s=${s//$'\t'/ }
    printf '%s' "$s"
}

new_sa_task() { # operation software_name
    local op=$1 name=$2
    local safe
    safe=$(printf '%s' "$name" | sed -e 's|[^A-Za-z0-9._-]|_|g')
    local id="$(date '+%Y%m%d_%H%M%S')_${safe}_$(printf '%06x' $((RANDOM % 16777216)))"
    TASK_ID=$id
    TASK_OPERATION=$op
    TASK_SOFTWARENAME=$name
    TASK_STATUS='InProgress'
    TASK_STEP='Created'
    TASK_CREATEDAT=$(now_iso)
    TASK_TASKPATH="$TEMP_DIR/$id"
    TASK_STAGEPATH="$TASK_TASKPATH/Staging"
    TASK_MESSAGE=''
    mkdir -p "$TASK_STAGEPATH"
    save_sa_task
}

save_sa_task() {
    TASK_UPDATEDAT=$(now_iso)
    {
        printf '{\n'
        printf '  "Id": "%s",\n' "$(json_escape "$TASK_ID")"
        printf '  "Operation": "%s",\n' "$(json_escape "$TASK_OPERATION")"
        printf '  "SoftwareName": "%s",\n' "$(json_escape "$TASK_SOFTWARENAME")"
        printf '  "Status": "%s",\n' "$TASK_STATUS"
        printf '  "Step": "%s",\n' "$TASK_STEP"
        printf '  "CreatedAt": "%s",\n' "$TASK_CREATEDAT"
        printf '  "UpdatedAt": "%s",\n' "$TASK_UPDATEDAT"
        printf '  "TaskPath": "%s",\n' "$(json_escape "$TASK_TASKPATH")"
        printf '  "StagePath": "%s",\n' "$(json_escape "$TASK_STAGEPATH")"
        printf '  "Message": "%s"\n' "$(json_escape "$TASK_MESSAGE")"
        printf '}\n'
    } > "$TASK_TASKPATH/task.json"
}

task_field() { # task.json 路径 字段
    sed -n "s/^  \"$2\": \"\\(.*\\)\",\\{0,1\\}$/\\1/p" "$1" 2>/dev/null | head -1
}

# 任务列表：TASKS_.* 下标数组（按 UpdatedAt 倒序）
get_sa_tasks() {
    TASKS_IDS=(); TASKS_OPS=(); TASKS_NAMES=(); TASKS_STATUS=(); TASKS_STEPS=(); TASKS_UPDATED=(); TASKS_PATHS=()
    [ -d "$TEMP_DIR" ] || return 0
    local f line id op name status step updated tpath
    local -a lines=()
    while IFS= read -r f; do
        status=$(task_field "$f" Status)
        [ "$status" = 'Completed' ] && continue
        [ -z "$status" ] && continue
        tpath=$(dirname "$f")
        lines+=("$(task_field "$f" UpdatedAt)|$(task_field "$f" Id)|$(task_field "$f" Operation)|$(task_field "$f" SoftwareName)|$status|$(task_field "$f" Step)|$tpath")
    done < <(find "$TEMP_DIR" -mindepth 2 -maxdepth 2 -name task.json 2>/dev/null)
    if [ ${#lines[@]} -eq 0 ]; then return 0; fi
    local oldIFS=$IFS
    IFS=$'\n'
    local -a sorted=($(printf '%s\n' "${lines[@]}" | sort -r))
    IFS=$oldIFS
    for line in "${sorted[@]}"; do
        local oldIFS=$IFS
        IFS='|'
        read -r updated id op name status step tpath <<< "$line"
        IFS=$oldIFS
        TASKS_UPDATED+=("$updated"); TASKS_IDS+=("$id"); TASKS_OPS+=("$op")
        TASKS_NAMES+=("$name"); TASKS_STATUS+=("$status"); TASKS_STEPS+=("$step")
        TASKS_PATHS+=("$tpath")
    done
    return 0
}

remove_sa_task() { # task_path task_id
    local tp=$1 id=${2:-}
    [ -n "$tp" ] || return 0
    tp=${tp%/}
    local parent=$(dirname "$tp") leaf=$(basename "$tp")
    if [ "$(basename "$parent")" != 'Temp' ]; then
        sa_set_error '拒绝删除：任务目录不在 Work/Temp 下。'
        return 1
    fi
    if [ -n "$id" ] && [ "$leaf" != "$id" ]; then
        sa_set_error '拒绝删除：任务目录与任务 ID 不一致。'
        return 1
    fi
    rm -rf "$tp"
}

move_sa_item() { # src dest（改名失败自动降级为复制+删除）
    mv "$1" "$2" 2>/dev/null && return 0
    cp -R "$1" "$2" || return 1
    rm -rf "$1"
}

commit_sa_task() { # 使用 TASK_* 全局 → stdout 正式目录
    local err
    err=$(test_software_name "$TASK_SOFTWARENAME")
    if [ -n "$err" ]; then sa_set_error "任务中的软件名称无效：$err"; return 1; fi
    local info_file="$TASK_STAGEPATH/info.yml"
    local manual="$TASK_STAGEPATH/使用手册.md"
    [ -f "$info_file" ] || { sa_set_error '暂存任务缺少 info.yml。'; return 1; }
    [ -f "$manual" ] || { sa_set_error '暂存任务缺少 使用手册.md。'; return 1; }
    new_sa_checksums "$TASK_STAGEPATH" >/dev/null
    local target="$LIBRARY_DIR/$TASK_SOFTWARENAME"
    local backup="$TASK_TASKPATH/Previous"
    local had_existing=0
    [ -e "$target" ] && had_existing=1
    rm -rf "$backup"
    if [ "$had_existing" = '1' ]; then
        if ! move_sa_item "$target" "$backup"; then
            sa_set_error '备份旧正式目录失败，已取消提交。'
            return 1
        fi
    fi
    if ! move_sa_item "$TASK_STAGEPATH" "$target"; then
        [ "$had_existing" = '1' ] && move_sa_item "$backup" "$target"
        sa_set_error '提交暂存目录失败（可能是文件被其他程序占用），已回滚。'
        return 1
    fi
    if ! new_sa_index_workbook; then
        rm -rf "$target"
        mv "$target" "$TASK_STAGEPATH" 2>/dev/null || true
        [ "$had_existing" = '1' ] && mv "$backup" "$target" 2>/dev/null
        sa_set_error '重建资源索引失败，已回滚。'
        return 1
    fi
    rm -rf "$backup"
    TASK_STATUS='Completed'
    TASK_STEP='Committed'
    save_sa_task
    printf '%s' "$target"
}

copy_software_to_task() { # source_dir
    rm -rf "$TASK_STAGEPATH"
    cp -R "$1" "$TASK_STAGEPATH" || return 1
}

clear_expired_temp() { # retention_days
    local cutoff=$(( $(date +%s) - $1 * 86400 ))
    CLEARED_REMOVED=(); CLEARED_SKIPPED=()
    [ -d "$TEMP_DIR" ] || return 0
    local d status
    for d in "$TEMP_DIR"/*/; do
        [ -d "$d" ] || continue
        if [ -f "${d}task.json" ]; then
            status=$(task_field "${d}task.json" Status)
            if [ "$status" != 'Completed' ]; then
                CLEARED_SKIPPED+=("$(basename "$d")")
                continue
            fi
        fi
        if [ "$(file_mtime_epoch "$d")" -lt "$cutoff" ]; then
            rm -rf "$d"
            CLEARED_REMOVED+=("$(basename "$d")")
        fi
    done
    return 0
}

# 上下文文件（供断点恢复）：task 目录下的 context-*.properties

ctx_write_info() { # task_path（用 INFO_* 全局）
    write_file "$1/context-info.properties" "NAME=$(ctx_sanitize "$INFO_NAME")
PLATFORMS=$(ctx_join_array INFO_PLATFORMS)
POLICY=$(ctx_sanitize "$INFO_POLICY")
VERSION=$(ctx_sanitize "$INFO_VERSION")
SOURCE_URL=$(ctx_sanitize "$INFO_SOURCE_URL")
SOURCE_TYPE=$(ctx_sanitize "$INFO_SOURCE_TYPE")
TAGS=$(ctx_join_array INFO_TAGS)
LICENSE=$(ctx_sanitize "$INFO_LICENSE")
LASTCHECKED=$(ctx_sanitize "$INFO_LASTCHECKED")
NOTES=$(ctx_sanitize "$INFO_NOTES")
"
}

ctx_sanitize() { local s=${1:-}; s=${s//$'\n'/ }; s=${s//$'\r'/}; printf '%s' "$s"; }

ctx_join_array() { # 数组变量名 → \x01 连接
    local ref=$1 __sep=$'\x01'
    local __out='' __first=1 __x
    eval 'for __x in "${'"$ref"'[@]}"; do
        if [ "$__first" = 1 ]; then __out="$__x"; __first=0; else __out="$__out$__sep$__x"; fi
    done'
    printf '%s' "$(ctx_sanitize "$__out")"
}

ctx_prop() { # file key
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

ctx_read_info() { # task_path → INFO_*
    local f=$1/context-info.properties
    INFO_NAME=$(ctx_prop "$f" NAME)
    local p=$(ctx_prop "$f" PLATFORMS)
    sa_split_soh_array "$p"
    INFO_PLATFORMS=("${SA_SPLIT_ITEMS[@]}")
    INFO_POLICY=$(ctx_prop "$f" POLICY)
    INFO_VERSION=$(ctx_prop "$f" VERSION)
    # 兼容 1.0 早期任务：Release 三个字段可能被错误地整体写入 VERSION。
    case $INFO_VERSION in
        *$'\x01'*) sa_split_soh3 "$INFO_VERSION" && INFO_VERSION=$SA_FIELD1 ;;
    esac
    INFO_SOURCE_URL=$(ctx_prop "$f" SOURCE_URL)
    INFO_SOURCE_TYPE=$(ctx_prop "$f" SOURCE_TYPE)
    local t=$(ctx_prop "$f" TAGS)
    sa_split_soh_array "$t"
    INFO_TAGS=("${SA_SPLIT_ITEMS[@]}")
    INFO_LICENSE=$(ctx_prop "$f" LICENSE)
    INFO_LASTCHECKED=$(ctx_prop "$f" LASTCHECKED)
    INFO_NOTES=$(ctx_prop "$f" NOTES)
    [ -n "$INFO_NAME" ]
}

ctx_write_release() { # task_path（用 RELEASE_* / ASSET_*）
    local i out=''
    for ((i = 0; i < ${#ASSET_NAMES[@]}; i++)); do
        out+="$(ctx_sanitize "${ASSET_NAMES[$i]}")"$'\x01'"${ASSET_SIZES[$i]}"$'\x01'"$(ctx_sanitize "${ASSET_URLS[$i]}")"$'\n'
    done
    write_file "$1/context-release.properties" "TAG=$(ctx_sanitize "$RELEASE_TAG")
PUBLISHED=$(ctx_sanitize "$RELEASE_PUBLISHED")
WEBURL=$(ctx_sanitize "$RELEASE_WEBURL")
SOURCETYPE=$RELEASE_SOURCETYPE
ASSETS=
$out"
}

ctx_read_release() { # task_path → RELEASE_* / ASSET_*
    local f=$1/context-release.properties
    RELEASE_TAG=$(ctx_prop "$f" TAG)
    RELEASE_PUBLISHED=$(ctx_prop "$f" PUBLISHED)
    RELEASE_WEBURL=$(ctx_prop "$f" WEBURL)
    RELEASE_SOURCETYPE=$(ctx_prop "$f" SOURCETYPE)
    # 兼容 1.0 早期任务：元数据可能被错误地整体写入 TAG。
    case $RELEASE_TAG in
        *$'\x01'*)
            if sa_split_soh3 "$RELEASE_TAG"; then
                RELEASE_TAG=$SA_FIELD1
                [ -n "$RELEASE_PUBLISHED" ] || RELEASE_PUBLISHED=$SA_FIELD2
                [ -n "$RELEASE_WEBURL" ] || RELEASE_WEBURL=$SA_FIELD3
            fi
            ;;
    esac
    ASSET_NAMES=(); ASSET_SIZES=(); ASSET_URLS=()
    local line name size url in_assets=0
    while IFS= read -r line; do
        if [ "$in_assets" = '0' ]; then
            [ "$line" = 'ASSETS=' ] && in_assets=1
            continue
        fi
        [ -z "$line" ] && continue
        sa_split_soh3 "$line" || continue
        name=$SA_FIELD1; size=$SA_FIELD2; url=$SA_FIELD3
        ASSET_NAMES+=("$name"); ASSET_SIZES+=("$size"); ASSET_URLS+=("$url")
    done < "$f"
    [ -n "$RELEASE_TAG" ]
}

ctx_write_mappings() { # task_path  MAP_PLATFORMS[]/MAP_NAMES[]/MAP_URLS[]/MAP_SIZES[]
    local i out=''
    for ((i = 0; i < ${#MAP_NAMES[@]}; i++)); do
        out+="$(ctx_sanitize "${MAP_PLATFORMS[$i]}")"$'\t'"$(ctx_sanitize "${MAP_NAMES[$i]}")"$'\t'"$(ctx_sanitize "${MAP_URLS[$i]}")"$'\t'"${MAP_SIZES[$i]}"$'\n'
    done
    write_file "$1/context-mappings.tsv" "$out"
}

ctx_read_mappings() { # task_path → MAP_*
    MAP_PLATFORMS=(); MAP_NAMES=(); MAP_URLS=(); MAP_SIZES=()
    local f=$1/context-mappings.tsv
    [ -f "$f" ] || return 1
    local line plat name url size
    while IFS=$'\t' read -r plat name url size; do
        [ -z "$plat" ] && continue
        # 兼容 1.0 早期任务：name/size/url 可能全部挤在第二列。
        if [ -z "$url" ]; then
            case $name in
                *$'\x01'*)
                    if sa_split_soh3 "$name"; then
                        name=$SA_FIELD1; size=$SA_FIELD2; url=$SA_FIELD3
                    fi
                    ;;
            esac
        fi
        MAP_PLATFORMS+=("$plat"); MAP_NAMES+=("$name"); MAP_URLS+=("$url"); MAP_SIZES+=("$size")
    done < "$f"
    [ ${#MAP_NAMES[@]} -gt 0 ]
}

remove_legacy_empty_release_dirs() { # staging_path
    local pkgs=$1/Packages d
    [ -d "$pkgs" ] || return 0
    for d in "$pkgs"/*; do
        [ -d "$d" ] || continue
        case $(basename "$d") in
            *$'\x01'*)
                # 只清理由 1.0 字段解析错误生成、且不包含任何文件的目录树。
                if [ -z "$(find "$d" -type f -print -quit 2>/dev/null)" ]; then
                    find "$d" -depth -type d -exec rmdir {} \; 2>/dev/null
                fi
                ;;
        esac
    done
    return 0
}

# ---------- 删除软件 ----------

get_sa_size_text() { # path
    [ -e "$1" ] || { printf '%s' '0 KB'; return; }
    kb_text "$(dir_size_kb "$1")"
}

get_sa_software_footprint() { # software_name software_dir
    local name=$1 dir=${2:-}
    FP_LIBRARY=''
    [ -n "$dir" ] && [ -d "$dir" ] && FP_LIBRARY=$(cd "$dir" && pwd)
    FP_MIRRORS=()
    local mirror="$REPOS_DIR/$name.git"
    if [ -d "$mirror" ] && [ "$(dirname "$mirror")" = "$REPOS_DIR" ]; then
        FP_MIRRORS+=("$mirror")
    fi
    FP_TASKS=()
    get_sa_tasks
    local i
    for ((i = 0; i < ${#TASKS_NAMES[@]}; i++)); do
        if [ "${TASKS_NAMES[$i]}" = "$name" ]; then FP_TASKS+=("$i"); fi
    done
}

remove_sa_software() { # software_name software_dir → DEL_REMOVED[]/DEL_ERRORS[]
    local name=$1 dir=$2
    DEL_REMOVED=(); DEL_ERRORS=()
    get_sa_software_footprint "$name" "$dir"
    local i
    if [ -n "$FP_LIBRARY" ]; then
        local parent=$(dirname "$FP_LIBRARY") leaf=$(basename "$FP_LIBRARY")
        if [ "$parent" != "$LIBRARY_DIR" ] || [ -z "$leaf" ]; then
            sa_set_error '安全检查失败：Library 目录不是 Library 的直接子目录，已取消删除。'
            return 1
        fi
        if rm -rf "$FP_LIBRARY" 2>/dev/null; then DEL_REMOVED+=("$FP_LIBRARY")
        else DEL_ERRORS+=("Library 目录删除失败：$FP_LIBRARY"); fi
    fi
    for i in "${FP_MIRRORS[@]}"; do
        if rm -rf "$i" 2>/dev/null; then DEL_REMOVED+=("$i")
        else DEL_ERRORS+=("Git mirror 删除失败：$i"); fi
    done
    for i in "${FP_TASKS[@]}"; do
        if remove_sa_task "${TASKS_PATHS[$i]}" "${TASKS_IDS[$i]}"; then
            DEL_REMOVED+=("${TASKS_PATHS[$i]}")
        else
            DEL_ERRORS+=("未完成任务删除失败：${TASKS_PATHS[$i]}")
        fi
    done
    return 0
}

open_local_path() {
    [ -e "$1" ] || { sa_set_error "路径不存在：$1"; return 1; }
    command -v open >/dev/null 2>&1 || { sa_set_error '未找到 open 命令。'; return 1; }
    open "$1"
}
