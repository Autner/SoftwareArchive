#!/bin/bash
# SoftwareArchive 首次初始化入口（macOS）
# 用法：bash Work/Scripts/Init.sh

DIR=$(cd "$(dirname "$0")" && pwd)
MAIN="$DIR/SoftwareArchive.sh"
if [ ! -f "$MAIN" ]; then
    printf '%s\n' "未找到 $MAIN"
    exit 1
fi
bash "$MAIN" -Action Init
rc=$?

# 设置常用脚本执行权限，之后可直接双击 .command 启动
chmod +x "$MAIN" "$DIR/SoftwareArchiveCore.sh" "$0" 2>/dev/null
ROOT=$(dirname "$(dirname "$DIR")")
if [ -f "$ROOT/启动软件档案管理.command" ]; then
    chmod +x "$ROOT/启动软件档案管理.command"
    printf '\n%s\n' "已设置执行权限，以后可双击「启动软件档案管理.command」打开主菜单。"
fi

if [ -t 0 ]; then
    printf '\n%s\n' '按任意键关闭……'
    IFS= read -rsn1 k
fi
exit $rc
