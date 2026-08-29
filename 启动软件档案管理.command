#!/bin/bash
# SoftwareArchive 启动入口（macOS：双击运行，或在终端中 bash 运行）
cd "$(dirname "$0")" || exit 1
if [ ! -f "Work/Scripts/SoftwareArchive.sh" ]; then
    printf '%s\n' '未找到 Work/Scripts/SoftwareArchive.sh，请确认目录结构完整。'
    if [ -t 0 ]; then IFS= read -rsn1 k; fi
    exit 1
fi
# 私有 GitHub 仓库支持：从 gh CLI 的钥匙串读取令牌（未安装 gh 或未登录时自动跳过，不影响公开仓库）
if [ -z "${GITHUB_TOKEN:-}" ]; then
    gh_bin="$(command -v gh 2>/dev/null || true)"
    if [ -z "$gh_bin" ] && [ -x /opt/homebrew/bin/gh ]; then gh_bin=/opt/homebrew/bin/gh; fi
    if [ -n "$gh_bin" ]; then
        _tok="$("$gh_bin" auth token 2>/dev/null || true)"
        if [ -n "$_tok" ]; then
            export GITHUB_TOKEN="$_tok"
            printf '%s\n' '已启用 GitHub 私有仓库访问令牌。'
        fi
        unset _tok gh_bin
    fi
fi
bash Work/Scripts/SoftwareArchive.sh
rc=$?
if [ $rc -ne 0 ]; then
    printf '\n%s\n' "脚本执行出现错误（退出码 $rc），请保留窗口中的错误信息。"
    if [ -t 0 ]; then IFS= read -rsn1 k; fi
fi
exit $rc
