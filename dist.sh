#!/usr/bin/env bash
# 干净打包成可分发 zip:只含 git 跟踪文件,自动排除 gitignored 的 config.sh / _logs / *.log / .DS_Store。
# 这样发给别人不会泄露你的 open_id 等私密配置。
#   ./dist.sh [输出路径.zip]   默认输出到 /tmp/daily-minutes-share.zip
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-/tmp/daily-minutes-share.zip}"

command -v git >/dev/null 2>&1 || { echo "❌ 需要 git 来干净打包(git archive 只含跟踪文件)"; exit 1; }
git -C "$HERE" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "❌ $HERE 不是 git 仓库,无法用 git archive 安全打包"; exit 1; }

# git archive 只打 HEAD 跟踪的文件 → config.sh(gitignored 未跟踪)自动被排除
git -C "$HERE" archive --format=zip --prefix=daily-minutes-share/ -o "$OUT" HEAD

echo "✅ 已打包: $OUT"
echo "   内含文件(确认不含 config.sh):"
unzip -Z1 "$OUT" | sed 's/^/     /'
echo "─────────────────────────────"
echo "收到方:解压 → 装好 lark-cli/python3/node/sc(或 claude)并授权 → ./init.sh → ./run.sh"
