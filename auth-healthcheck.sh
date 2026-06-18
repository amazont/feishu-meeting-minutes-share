#!/bin/bash
# 会议纪要权限自检 — 每天 10 点由 cron 调用。
# 目的:提前发现 lark-cli user 身份失效(token 过期/被收回),避免会议纪要任务因 131006
#       或「未登录」每 2 分钟刷屏。正常静默(不留日志/不打扰),异常才发飞书提醒(机器人身份)。

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/bin:$HOME/.npm-global/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/config.sh" ] && source "$HERE/config.sh"

LARK="$(command -v lark-cli)"
[ -z "$LARK" ] && exit 0          # 环境暂时没有 lark-cli:不误报,直接退出
: "${OPEN_ID:?}" "${SPACE_ID:?}" "${WIKI_ROOT:?}" 2>/dev/null || { echo "config 缺失,跳过"; exit 0; }

LOG_DIR="${BASE_DIR:-$HOME/会议纪要}/_logs"; mkdir -p "$LOG_DIR"
STAMP="$(date +%Y-%m-%d_%H%M%S)"
LOG="$LOG_DIR/authcheck_$STAMP.log"
echo "===== 权限自检 $STAMP =====" >> "$LOG" 2>&1

fail() {  # $1 = 原因
  echo "[authcheck] ❌ $1" >> "$LOG" 2>&1
  "$LARK" im +messages-send --as bot --user-id "$OPEN_ID" \
    --text "⚠️ 会议纪要权限自检异常($STAMP):$1。请运行一次  lark-cli auth login --domain wiki,docs  重新扫码授权,否则定时任务会因建知识库节点失败(131006)而连续告警。" >> "$LOG" 2>&1
  exit 1
}

# 1) user 身份是否 ready
ST="$("$LARK" auth status 2>/dev/null | python3 -c "import sys,json
try: d=json.load(sys.stdin); print((d.get('identities') or {}).get('user',{}).get('status','error'))
except Exception: print('error')")"
[ "$ST" != "ready" ] && fail "lark-cli user 身份状态=$ST(token 缺失或失效)"

# 2) 实探:用 user 身份读知识库根节点,确认 token 真有效且仍有 wiki 写权(读得到≈建得了)
PROBE="$("$LARK" wiki +node-list --as user --space-id "$SPACE_ID" --parent-node-token "$WIKI_ROOT" --page-all --format json 2>/dev/null | python3 -c "import sys,json
try:
    d=json.load(sys.stdin); print('ok' if d.get('ok') else 'err:'+str((d.get('error') or {}).get('code')))
except Exception: print('parsefail')")"
[ "$PROBE" != "ok" ] && fail "wiki 读探测失败($PROBE),user token 可能失效或权限被收回"

echo "[authcheck] ✅ user 身份就绪且可访问知识库" >> "$LOG" 2>&1
rm -f "$LOG"     # 一切正常:不留日志、不发消息
exit 0
