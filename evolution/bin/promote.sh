#!/bin/bash
# promote.sh — 把一个 git ref 打成不可变 release 快照并原子切换生产软链。
# 用法: promote.sh [git-ref]          默认 HEAD
#       promote.sh --no-switch [ref]  只打快照不切 current(金丝雀影子运行用)
# 设计:生产 cron 永远跑 releases/current/run.sh;切链前持生产 flock,
#       保证不撞上正在执行的 run;previous 始终指向上一个已知好版本(rollback 目标)。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

NO_SWITCH=0
if [ "${1:-}" = "--no-switch" ]; then NO_SWITCH=1; shift; fi
REF="${1:-HEAD}"

git rev-parse --verify "$REF" >/dev/null || { echo "❌ 无效 git ref: $REF"; exit 1; }
HASH="$(git rev-parse --short "$REF")"
VER="v$(date +%Y.%m.%d)-$HASH"
DEST="releases/$VER"

mkdir -p releases
if [ -e "$DEST" ]; then
  echo "[promote] 快照已存在: $DEST(同 ref 重复晋升,跳过导出)"
else
  mkdir -p "$DEST"
  git archive "$REF" | tar -x -C "$DEST"
  # config.sh 不入 git(含个人 open_id),以软链接入快照;kernel 解析时 ../../ 相对 vX 目录 → 仓库根
  ln -sf ../../config.sh "$DEST/config.sh"
  echo "[promote] 已导出快照: $DEST"
fi

if [ "$NO_SWITCH" -eq 1 ]; then
  echo "[promote] --no-switch:仅打快照,current 不动。金丝雀调用方式:releases/$VER/run.sh"
  exit 0
fi

# 原子切换(持生产锁,最多等 5 分钟一个 run 结束)
BASE_DIR="$(bash -c "source '$ROOT/config.sh'; printf %s \"\$BASE_DIR\"")"
LOCK="$BASE_DIR/_logs/.run.lock"
mkdir -p "$BASE_DIR/_logs"
OLD="$(readlink releases/current 2>/dev/null || true)"
exec 9>"$LOCK"
flock -w 300 9 || { echo "❌ 5 分钟内拿不到生产锁,放弃切换(快照已保留:$DEST)"; exit 1; }
if [ -n "$OLD" ] && [ "$OLD" != "$VER" ]; then
  ln -sfn "$OLD" releases/previous
fi
ln -sfn "$VER" releases/current
exec 9>&-

mkdir -p evolution
date +%s > evolution/.promoted_at
echo 0 > evolution/.fail_count
echo "[promote] ✅ current → $VER(previous: ${OLD:-无});sentinel 计数已复位"
