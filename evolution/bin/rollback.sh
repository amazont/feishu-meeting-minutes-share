#!/bin/bash
# rollback.sh — 秒级回滚:current 软链切回 previous。哨兵自动回滚与人工排障共用。
# 用法: rollback.sh [原因说明]
# 设计:纯软链切换,不做任何 git 操作、不依赖任何 agent;持生产锁避免撞上正在跑的 run。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
REASON="${1:-manual}"

PREV="$(readlink releases/previous 2>/dev/null || true)"
CUR="$(readlink releases/current 2>/dev/null || true)"
[ -z "$PREV" ] && { echo "❌ 无 releases/previous,无法回滚"; exit 1; }
[ "$PREV" = "$CUR" ] && { echo "[rollback] current 已指向 $PREV,无需回滚"; exit 0; }

BASE_DIR="$(bash -c "source '$ROOT/config.sh'; printf %s \"\$BASE_DIR\"")"
LOCK="$BASE_DIR/_logs/.run.lock"
exec 9>"$LOCK"
flock -w 300 9 || { echo "❌ 5 分钟内拿不到生产锁,回滚失败"; exit 1; }
ln -sfn "$PREV" releases/current
exec 9>&-

# 回滚后冻结进化平面(人工确认根因前不再自动改动),并复位哨兵计数
mkdir -p evolution
echo "rolled back $(date '+%F %T'): $CUR -> $PREV ($REASON)" > evolution/FROZEN
echo 0 > evolution/.fail_count
echo "[rollback] ✅ current: $CUR → $PREV;进化平面已冻结(evolution/FROZEN)"

# 飞书告警(尽力而为,失败不影响回滚本身)
OPEN_ID="$(bash -c "source '$ROOT/config.sh'; printf %s \"\$OPEN_ID\"" 2>/dev/null || true)"
if [ -n "$OPEN_ID" ] && command -v lark-cli >/dev/null 2>&1; then
  lark-cli im +messages-send --as bot --user-id "$OPEN_ID" \
    --text "🔙 会议纪要系统已回滚:$CUR → $PREV(原因:$REASON)。进化平面已冻结,请排查后删除 evolution/FROZEN 解冻。" \
    >/dev/null 2>&1 || true
fi
