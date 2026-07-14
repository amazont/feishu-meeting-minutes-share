#!/bin/bash
# approval-listener.sh — 人工放行的飞书命令通道(免 ssh)。
# weekly-evolve.sh 判 MERGE 且 HUMAN_GATE 存在时 nohup 启动本脚本;
# 通过 `lark-cli event consume im.message.receive_v1` 订阅用户发给机器人的消息,
# 等待白名单命令并执行:
#   「同意/批准/approve/merge/apply [week]」 → 执行 weekly-evolve.sh --apply <week>
#   「拒绝/reject [week]」                   → 记 backlog + changelog,放弃本轮
# 安全铁律:
#   ① 只认 config.sh 中 OPEN_ID 用户发来的文本消息(jq 端过滤,其余事件根本不出管道);
#   ② 只匹配白名单动词,消息里带 week 号时必须与本轮一致,否则忽略并提示;
#   ③ 绝不把消息内容当命令执行——能触发的动作只有 --apply 与"记拒绝"两个固定分支。
# 超时(默认 72h)自动过期并提醒;过期后仍可 ssh 手动 --apply。
# 用法: approval-listener.sh <week> [timeout,默认 72h]
set -uo pipefail
WEEK="${1:?用法: approval-listener.sh <week> [timeout]}"
TIMEOUT="${2:-72h}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EVO="$ROOT/evolution"
RUN_DIR="$EVO/runs/$WEEK"
mkdir -p "$RUN_DIR"

OPEN_ID="$(bash -c "source '$ROOT/config.sh'; printf %s \"\$OPEN_ID\"" 2>/dev/null || true)"
[ -n "$OPEN_ID" ] || { echo "[listener] ❌ 读不到 OPEN_ID"; exit 1; }
command -v lark-cli >/dev/null 2>&1 || { echo "[listener] ❌ 无 lark-cli"; exit 1; }

# 单实例:同一周只允许一个监听器
exec 7>"$RUN_DIR/.listener.lock"
flock -n 7 || { echo "[listener] $WEEK 已有监听器在跑,退出。"; exit 0; }

reply() {  # 发飞书回复(尽力而为)
  lark-cli im +messages-send --as bot --user-id "$OPEN_ID" --text "$1" >/dev/null 2>&1 || true
}
log_changelog() {  # $1=status $2=note
  python3 - "$EVO/changelog.jsonl" "$WEEK" "$1" "$2" <<'PYEOF' || true
import json, sys, datetime
open(sys.argv[1], "a", encoding="utf-8").write(json.dumps(
  {"week": sys.argv[2], "status": sys.argv[3], "hypothesis": sys.argv[4],
   "ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds")},
  ensure_ascii=False) + "\n")
PYEOF
}

echo "[listener] $WEEK 开始监听(超时 $TIMEOUT,只认 $OPEN_ID 的文本消息)…"

# 只放行"目标用户发来的文本消息正文";其余事件在 jq 端被 select 吞掉,不出管道
JQ="select(.sender_id==\"$OPEN_ID\" and .message_type==\"text\") | .content"
PIPE="$(mktemp -u "${TMPDIR:-/tmp}/dmm_listener.XXXXXX")"
mkfifo "$PIPE"
lark-cli event consume im.message.receive_v1 --as bot --timeout "$TIMEOUT" \
  --jq "$JQ" > "$PIPE" 2>>"$RUN_DIR/listener.consume.log" &
CONSUME_PID=$!
cleanup() { kill -TERM "$CONSUME_PID" 2>/dev/null; rm -f "$PIPE"; }
trap cleanup EXIT

DECISION=""
exec 6<"$PIPE"
while IFS= read -r msg <&6; do
  echo "[listener] 收到: $msg"
  # 消息里出现周号(20xx-Wxx / Wxx)时必须匹配本轮,否则忽略并提示
  ref_week="$(printf '%s' "$msg" | grep -oiE '20[0-9]{2}-?W[0-9]{1,2}' | head -1 | tr 'w' 'W')"
  if [ -n "$ref_week" ]; then
    norm_ref="$ref_week"; case "$norm_ref" in 20*W*) [ "${norm_ref:4:1}" = "-" ] || norm_ref="${norm_ref:0:4}-${norm_ref:4}";; esac
    if [ "$norm_ref" != "$WEEK" ]; then
      reply "🤔 当前待放行的是 $WEEK,你提到的是 $norm_ref,已忽略。请回复「同意 $WEEK」或「拒绝 $WEEK」。"
      continue
    fi
  fi
  if printf '%s' "$msg" | grep -qiE '(^|[^一-龥a-z])(同意|批准|approve|merge|apply)([^一-龥a-z]|$)'; then
    DECISION="approve"; break
  elif printf '%s' "$msg" | grep -qiE '(^|[^一-龥a-z])(拒绝|驳回|reject)([^一-龥a-z]|$)'; then
    DECISION="reject"; break
  else
    reply "🤖 没识别出指令。放行回复「同意 $WEEK」,放弃回复「拒绝 $WEEK」(也可远端执行 evolution/bin/weekly-evolve.sh --apply $WEEK)。"
  fi
done
exec 6<&-

case "$DECISION" in
  approve)
    reply "✅ 收到「同意」,开始合入 $WEEK…"
    if "$EVO/bin/weekly-evolve.sh" --apply "$WEEK" >> "$RUN_DIR/apply.log" 2>&1; then
      echo "[listener] --apply $WEEK 成功"
      # apply_merge 内部已按快慢车道各自 notify,这里不再重复
    else
      echo "[listener] --apply $WEEK 失败"
      reply "❌ $WEEK 合入失败,详见远端 evolution/runs/$WEEK/apply.log,请人工处理。"
    fi
    ;;
  reject)
    HYP="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('hypothesis','?'))" "$RUN_DIR/contract.json" 2>/dev/null || echo '?')"
    python3 - "$EVO/backlog.yaml" "$WEEK" "$HYP" <<'PYEOF' || true
import sys
p, week, hyp = sys.argv[1:4]
def q(s): return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
with open(p, "a", encoding="utf-8") as f:
    f.write(f"- week: {q(week)}\n  hypothesis: {q(hyp)}\n  reject_reason: {q('人工拒绝(飞书指令)')}\n")
PYEOF
    log_changelog "REJECTED_BY_HUMAN" "$HYP"
    echo "[listener] 人工拒绝 $WEEK"
    reply "🗑️ 已记录「拒绝」,$WEEK 不合入(worktree 保留待查:worktrees/evolve-$WEEK)。"
    ;;
  *)
    echo "[listener] 超时未收到指令,过期。"
    reply "⏰ $WEEK 的放行确认已超时($TIMEOUT)。如仍需合入,远端执行 evolution/bin/weekly-evolve.sh --apply $WEEK。"
    ;;
esac
exit 0
