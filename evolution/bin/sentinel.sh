#!/bin/bash
# sentinel.sh — 生产健康哨兵。由 run.sh 结束时(trap EXIT)调用,不依赖任何 agent 在线。
# 用法: sentinel.sh <run退出码>
# 逻辑:切换 release 后 24h 内连续 ≥3 次 run 失败 → 告警;若 evolution/AUTO_ROLLBACK
#       标记文件存在(观察期后人工启用)→ 自动执行 rollback.sh。
# 铁律:本脚本任何失败都不得影响生产 run 的退出码(调用方已 || true 包裹,内部也全程防御)。
RC="${1:-0}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)" || exit 0
EVO="$ROOT/evolution"
mkdir -p "$EVO" 2>/dev/null || exit 0
FAIL_F="$EVO/.fail_count"
PROMOTED_F="$EVO/.promoted_at"

# 连续失败计数
COUNT=0
[ -f "$FAIL_F" ] && COUNT="$(cat "$FAIL_F" 2>/dev/null || echo 0)"
case "$COUNT" in (*[!0-9]*|'') COUNT=0;; esac
if [ "$RC" -eq 0 ]; then
  [ "$COUNT" -ne 0 ] && echo 0 > "$FAIL_F"
  exit 0
fi
COUNT=$((COUNT+1))
echo "$COUNT" > "$FAIL_F"

# 仅在"新版本观察窗(晋升后 24h)内"触发——老版本的偶发失败交给 run.sh 自身告警
NOW="$(date +%s)"
PROMOTED_AT=0
[ -f "$PROMOTED_F" ] && PROMOTED_AT="$(cat "$PROMOTED_F" 2>/dev/null || echo 0)"
case "$PROMOTED_AT" in (*[!0-9]*|'') PROMOTED_AT=0;; esac
AGE=$((NOW - PROMOTED_AT))
[ "$PROMOTED_AT" -eq 0 ] && exit 0
[ "$AGE" -gt 86400 ] && exit 0
[ "$COUNT" -lt 3 ] && exit 0

CUR="$(readlink "$ROOT/releases/current" 2>/dev/null || echo '?')"
OPEN_ID="$(bash -c "source '$ROOT/config.sh'; printf %s \"\$OPEN_ID\"" 2>/dev/null || true)"

if [ -f "$EVO/AUTO_ROLLBACK" ]; then
  # 自动回滚模式:rollback.sh 自带告警 + 冻结进化 + 复位计数
  "$ROOT/evolution/bin/rollback.sh" "sentinel:新版本 $CUR 晋升后24h内连续 ${COUNT} 次 run 失败" || {
    # 回滚失败 = 最高级告警(不限流)+ 冻结
    echo "rollback FAILED $(date '+%F %T')" > "$EVO/FROZEN"
    [ -n "$OPEN_ID" ] && command -v lark-cli >/dev/null 2>&1 && \
      lark-cli im +messages-send --as bot --user-id "$OPEN_ID" \
        --text "🆘 会议纪要哨兵:自动回滚失败!当前版本 $CUR 连续 ${COUNT} 次失败且无法切回 previous,请立即人工介入。" \
        >/dev/null 2>&1
  }
else
  # 观察期:只告警不回滚(每个版本窗口只告警一次)
  MARK="$EVO/.sentinel_alerted_$CUR"
  if [ ! -f "$MARK" ]; then
    : > "$MARK"
    [ -n "$OPEN_ID" ] && command -v lark-cli >/dev/null 2>&1 && \
      lark-cli im +messages-send --as bot --user-id "$OPEN_ID" \
        --text "🚨 会议纪要哨兵:新版本 $CUR 晋升后24h内已连续 ${COUNT} 次 run 失败。当前为观察模式(仅告警);确认需回滚请在远端执行 evolution/bin/rollback.sh,或创建 evolution/AUTO_ROLLBACK 启用自动回滚。" \
        >/dev/null 2>&1
  fi
fi
exit 0
