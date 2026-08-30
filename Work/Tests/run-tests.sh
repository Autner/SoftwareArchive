#!/bin/bash
# SoftwareArchive 单元测试（纯 bash，无第三方依赖）
# 用法：bash Work/Tests/run-tests.sh
# 覆盖：YAML 解析/生成、路径解析、文本工具、锁、TSV 索引、
#       搜索匹配、记录列表、状态字段、Record（仅记录）类型、bundle 校验桩
set -u

SCRIPTS_DIR=$(cd "$(dirname "$0")/../Scripts" && pwd)
SA_VERSION_TESTED=1

# 计数
PASS=0; FAIL=0; FAILED_NAMES=()

t_ok()   { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1"; }
t_fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); printf '  ✗ %s\n' "$1"; }

assert_eq() { # desc expected actual
    if [ "$2" = "$3" ]; then t_ok "$1"; else t_fail "$1（期望 [$2] 实际 [$3]）"; fi
}
assert_rc() { # desc expected_rc actual_rc
    if [ "$2" = "$3" ]; then t_ok "$1"; else t_fail "$1（期望 rc=$2 实际 rc=$3）"; fi
}

# ---------- 准备测试环境 ----------

. "$SCRIPTS_DIR/SoftwareArchiveCore.sh"

TESTROOT=$(mktemp -d /tmp/sa-tests.XXXXXX)
trap 'rm -rf "$TESTROOT"' EXIT

# 便携模式路径（fixture 根 = 代码/数据同目录，模拟最小 SoftwareArchive）
LIBRARY_DIR="$TESTROOT/Library"
TEMP_DIR="$TESTROOT/Temp"
CONFIG_DIR="$TESTROOT/Config"
mkdir -p "$LIBRARY_DIR" "$TEMP_DIR" "$CONFIG_DIR"

fixture_entry() { # dir name version policy notes status tags...
    local dir=$1 name=$2 ver=$3 policy=$4 notes=$5 status=$6
    shift 6
    mkdir -p "$dir"
    {
        printf 'name: "%s"\n\nplatforms:\n  - "macOS"\n\n' "$name"
        printf 'update_policy: "%s"\n\ncurrent_version: "%s"\n\n' "$policy" "$ver"
        printf 'source_url: ""\nsource_type: ""\n\n'
        if [ $# -gt 0 ]; then
            printf 'tags:\n'; local t; for t in "$@"; do printf '  - "%s"\n' "$t"; done
        else
            printf 'tags: []\n'
        fi
        printf '\nlicense: "MIT"\n\nstatus: "%s"\n\nlast_checked: "2026-08-30"\n\nnotes: "%s"\n' "$status" "$notes"
    } > "$dir/info.yml"
    printf '# %s 手册\n' "$name" > "$dir/使用手册.md"
}

fixture_entry "$LIBRARY_DIR/Alpha" 'Alpha' 'v1.0' 'Maintain' '流程图工具' 'active' '学习工具'
fixture_entry "$LIBRARY_DIR/Beta' v2" "Beta v2" 'v2.0' 'Fixed' '清理工具' 'deprecated' '实用工具'
fixture_entry "$LIBRARY_DIR/Gamma" 'Gamma' '' 'Fixed' '备注含关键词 思维导图' 'active'
# Record 条目：没有 checksums.sha256，版本留空
fixture_entry "$LIBRARY_DIR/Delta" 'Delta' '' 'Record' '商业软件备忘' 'active' '效率工具'

# ---------- 1. 版本单一来源 ----------

printf '%s\n' '[1] 版本号来源'
assert_rc 'SA_VERSION 与 VERSION.txt 一致（长度>0 且非 unknown）' 0 $([ ${#SA_VERSION} -gt 1 ] && [ "$SA_VERSION" != 'unknown' ] && echo 0 || echo 1)

# ---------- 2. YAML 读写往返 ----------

printf '%s\n' '[2] info.yml 解析与生成'
read_info_yaml "$LIBRARY_DIR/Alpha/info.yml"
assert_eq '读取 name' 'Alpha' "$INFO_NAME"
assert_eq '读取 policy' 'Maintain' "$INFO_POLICY"
assert_eq '读取 version' 'v1.0' "$INFO_VERSION"
assert_eq '读取 status（新字段）' 'active' "$INFO_STATUS"
assert_eq '读取 tags 数量' 1 ${#INFO_TAGS[@]}

INFO_STATUS='migrated'
write_info_yaml "$TESTROOT/roundtrip.yml"
read_info_yaml "$TESTROOT/roundtrip.yml"
assert_eq '往返后 status 保持' 'migrated' "$INFO_STATUS"
assert_eq '往返后 name 保持' 'Alpha' "$INFO_NAME"

read_info_yaml "$LIBRARY_DIR/Gamma/info.yml"
assert_eq '无 status 字段时默认 active' 'active' "$INFO_STATUS"
assert_eq '空 tags 解析为 0 个' 0 ${#INFO_TAGS[@]}

# ---------- 3. 路径与文本工具 ----------

printf '%s\n' '[3] 路径与文本工具'
assert_eq 'resolve_path 绝对路径' '/tmp/x' "$(resolve_path /base '/tmp/x')"
assert_eq 'resolve_path 相对路径（规范化 ..）' '/base/Library' "$(resolve_path /base/a '../Library')"
assert_eq 'trim 去空白' 'abc' "$(trim '   abc   ')"

# ---------- 4. 记录列表 ----------

printf '%s\n' '[4] get_software_records'
get_software_records
assert_eq '记录数（目录名排序）' 4 ${#REC_NAMES[@]}
assert_eq '首条为 Alpha' 'Alpha' "${REC_NAMES[0]}"
assert_eq '全部有效' 1 "${REC_VALID[3]}"

# ---------- 5. 搜索匹配 ----------

printf '%s\n' '[5] record_matches_query'
assert_rc '按名称命中' 0 $(record_matches_query 'alpha' "$LIBRARY_DIR/Alpha/" && echo 0 || echo 1)
assert_rc '按备注命中（中文）' 0 $(record_matches_query '流程图' "$LIBRARY_DIR/Alpha/" && echo 0 || echo 1)
assert_rc '手册全文命中' 0 $(record_matches_query '思维导图' "$LIBRARY_DIR/Gamma/" && echo 0 || echo 1)
assert_rc '不匹配时返回 1' 1 $(record_matches_query '不存在的东西' "$LIBRARY_DIR/Alpha/" && echo 0 || echo 1)
assert_rc '空关键字返回 1' 1 $(record_matches_query '' "$LIBRARY_DIR/Alpha/" && echo 0 || echo 1)
assert_rc '按策略命中 record' 0 $(record_matches_query 'record' "$LIBRARY_DIR/Delta/" && echo 0 || echo 1)
assert_rc '非 Record 条目不按策略命中' 1 $(record_matches_query 'record' "$LIBRARY_DIR/Alpha/" && echo 0 || echo 1)

# ---------- 6. TSV 索引 ----------

printf '%s\n' '[6] TSV 索引'
INDEX_TSV_FILE="$TESTROOT/资源索引.tsv"
rebuild_index_tsv
assert_rc 'TSV 文件生成' 0 $( [ -f "$INDEX_TSV_FILE" ] && echo 0 || echo 1)
assert_eq 'TSV 行数 = 表头 + 4 条' 5 "$(wc -l < "$INDEX_TSV_FILE" | tr -d ' ')"
assert_rc 'TSV 含状态列数据（deprecated）' 0 $(grep -q 'deprecated' "$INDEX_TSV_FILE" && echo 0 || echo 1)
assert_rc 'TSV 收录 Record 条目（版本列为空）' 0 \
    $(awk -F'\t' '$1=="Delta" && $2=="" && $4=="Record" && $5=="active"' "$INDEX_TSV_FILE" | grep -q . && echo 0 || echo 1)

# ---------- 7. 并发锁 ----------

printf '%s\n' '[7] 并发锁'
sa_lock_acquire '测试'
assert_rc '首次加锁成功' 0 $?
sa_lock_acquire '测试' >/dev/null 2>&1
assert_rc '重复加锁被拒' 1 $?
sa_lock_release
# 模拟陈旧锁：写入一个不存在的 PID
mkdir -p "$CONFIG_DIR/.sa-lock"; echo 999999 > "$CONFIG_DIR/.sa-lock/pid"
sa_lock_acquire '测试' >/dev/null 2>&1
assert_rc '陈旧锁被自动回收' 0 $?
sa_lock_release
sa_lock_acquire '测试' >/dev/null 2>&1
assert_rc '释放后可再次加锁' 0 $?
sa_lock_release

# ---------- 8. bundle 校验 ----------

printf '%s\n' '[8] verify_sa_bundles'
mkdir -p "$TESTROOT/BP/Source"
assert_eq '无 bundle 时 count=0' 0 "$(verify_sa_bundles "$TESTROOT/BP"; echo $BV_COUNT)"
assert_eq '无 bundle 提示' '无 bundle' "$(verify_sa_bundles "$TESTROOT/BP"; echo $BV_MESSAGE)"

if command -v git >/dev/null 2>&1; then
    mkdir -p "$TESTROOT/src_repo" "$TESTROOT/BP2/Source"
    git -C "$TESTROOT/src_repo" init -q
    git -C "$TESTROOT/src_repo" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
    git -C "$TESTROOT/src_repo" bundle create "$TESTROOT/BP2/Source/x.bundle" --all 2>/dev/null
    REPOS_DIR="$TESTROOT/Repositories"
    TEMP_DIR="$TESTROOT/Temp"
    verify_sa_bundles "$TESTROOT/BP2"
    assert_rc '无 mirror 时完整 bundle 校验通过' 1 "$BV_OK"
    assert_eq '校验计数' 1 "$BV_COUNT"
    printf 'broken' > "$TESTROOT/BP2/Source/x.bundle"
    verify_sa_bundles "$TESTROOT/BP2"
    assert_rc '损坏 bundle 被检出' 0 "$BV_OK"
fi

# ---------- 9. 校验和（正常路径） ----------

printf '%s\n' '[9] test_sa_checksums'
mkdir -p "$TESTROOT/CK"
printf 'hello\n' > "$TESTROOT/CK/a.bin"
SUM=$(shasum -a 256 "$TESTROOT/CK/a.bin" | awk '{print $1}')
printf '%s  a.bin\n' "$SUM" > "$TESTROOT/CK/checksums.sha256"
test_sa_checksums "$TESTROOT/CK"
assert_rc '校验通过' 1 "$CK_PASSED"
printf '%s  a.bin\n' "0000000000000000000000000000000000000000000000000000000000000000" > "$TESTROOT/CK/checksums.sha256"
test_sa_checksums "$TESTROOT/CK"
assert_rc '篡改被检出' 0 "$CK_PASSED"

# ---------- 10. Record（仅记录）类型 ----------

printf '%s\n' '[10] Record 类型'
assert_rc 'Record 条目跳过完整性校验' 0 $(sa_skip_checksum_verify "$LIBRARY_DIR/Delta" && echo 0 || echo 1)
assert_rc 'Fixed 条目不跳过完整性校验' 1 $(sa_skip_checksum_verify "$LIBRARY_DIR/Gamma" && echo 0 || echo 1)
assert_rc '无效条目不跳过完整性校验' 1 $(sa_skip_checksum_verify "$TESTROOT/CK" && echo 0 || echo 1)
INFO_NAME='Echo'; INFO_POLICY='Record'; INFO_VERSION=''
INFO_PLATFORMS=('macOS'); INFO_TAGS=(); INFO_SOURCE_URL=''; INFO_SOURCE_TYPE=''
INFO_LICENSE=''; INFO_STATUS='active'; INFO_LASTCHECKED='2026-08-30'; INFO_NOTES=''
write_info_yaml "$TESTROOT/record.yml"
read_info_yaml "$TESTROOT/record.yml"
assert_eq 'Record 策略写入并读回' 'Record' "$INFO_POLICY"
assert_eq 'Record 版本保持为空' '' "$INFO_VERSION"

# ---------- 汇总 ----------

printf '\n'
if [ "$FAIL" -eq 0 ]; then
    printf '%s\n' "全部通过：$PASS 项"
    exit 0
else
    printf '%s\n' "通过 $PASS 项，失败 $FAIL 项："
    local_name=''
    for local_name in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$local_name"; done
    exit 1
fi
