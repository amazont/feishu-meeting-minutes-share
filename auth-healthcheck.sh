#!/bin/bash
# 会议纪要权限自检 — 每天 10 点由 cron 调用。
# 目的:提前发现 lark-cli user 身份失效(token 过期/被收回),避免会议纪要任务因 131006
#       或「未登录」每 2 分钟刷屏。正常静默(不留日志/不打扰),异常才处理。
#
# v2 变更(2026-07-22):
#   1. needs_refresh 不再直接告警——access token 到期但 refresh token 有效时,任何 user 调用
#      都会触发自动续期,先做 wiki 探测(本身即触发续期),探测通过就静默,消除窗口期误报。
#   2. 真失效时不再只发文字让用户上机器敲命令:自动发起 Device Flow,生成二维码 PNG 直接
#      发到用户飞书,后台轮询 --device-code,用户扫码后自动完成登录并回报成功。

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/bin:$HOME/.npm-global/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/config.sh" ] && source "$HERE/config.sh"

LARK="$(command -v lark-cli)"
[ -z "$LARK" ] && exit 0          # 环境暂时没有 lark-cli:不误报,直接退出
: "${OPEN_ID:?}" "${SPACE_ID:?}" "${WIKI_ROOT:?}" 2>/dev/null || { echo "config 缺失,跳过"; exit 0; }

# 重新授权时申请的业务域:必须覆盖会议纪要全链路(妙记读取/建 wiki 节点/文档/云盘/发消息/查人)
AUTH_DOMAINS="${AUTH_DOMAINS:-wiki,docs,drive,minutes,im,contact,vc}"

LOG_DIR="${BASE_DIR:-$HOME/会议纪要}/_logs"; mkdir -p "$LOG_DIR"
STAMP="$(date +%Y-%m-%d_%H%M%S)"
LOG="$LOG_DIR/authcheck_$STAMP.log"
echo "===== 权限自检 $STAMP =====" >> "$LOG" 2>&1

send_text() { "$LARK" im +messages-send --as bot --user-id "$OPEN_ID" --text "$1" >> "$LOG" 2>&1; }

# 1) 读 user 身份状态(仅记录,不据此告警;needs_refresh 是可自愈状态)
ST="$("$LARK" auth status 2>/dev/null | python3 -c "import sys,json
try: d=json.load(sys.stdin); print((d.get('identities') or {}).get('user',{}).get('status','error'))
except Exception: print('error')")"
echo "[authcheck] user status=$ST" >> "$LOG" 2>&1

# 2) 实探:用 user 身份读知识库根节点。这次调用本身会触发 refresh token 自动续期,
#    所以 needs_refresh + 探测通过 = 已自愈,静默退出。
PROBE="$("$LARK" wiki +node-list --as user --space-id "$SPACE_ID" --parent-node-token "$WIKI_ROOT" --page-all --format json 2>/dev/null | python3 -c "import sys,json
try:
    d=json.load(sys.stdin); print('ok' if d.get('ok') else 'err:'+str((d.get('error') or {}).get('code')))
except Exception: print('parsefail')")"

if [ "$PROBE" = "ok" ]; then
  echo "[authcheck] ✅ 探测通过(status=$ST,已自动续期或本就正常)" >> "$LOG" 2>&1
  rm -f "$LOG"
  exit 0
fi

# ---- 真失效:自动发起 Device Flow,把二维码发给用户 ----
echo "[authcheck] ❌ 探测失败($PROBE),status=$ST,发起 Device Flow" >> "$LOG" 2>&1
cd "$LOG_DIR" || exit 1           # qrcode --output / im --image 只接受 cwd 相对路径

DF="$("$LARK" auth login --domain "$AUTH_DOMAINS" --no-wait --json 2>>"$LOG")"
URL="$(echo "$DF" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('verification_url',''))
except Exception: print('')")"
CODE="$(echo "$DF" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('device_code',''))
except Exception: print('')")"

if [ -z "$URL" ] || [ -z "$CODE" ]; then
  # Device Flow 起不来(网络/appId 问题):退回旧文字告警
  send_text "⚠️ 会议纪要权限自检异常($STAMP):user token 失效(status=$ST,探测=$PROBE),且自动发起 Device Flow 失败。请在 bingzhe-01 上手动运行  lark-cli auth login --domain $AUTH_DOMAINS  重新扫码授权。"
  exit 1
fi

QR="authcheck_qr_$STAMP.png"
"$LARK" auth qrcode "$URL" -o "$QR" >> "$LOG" 2>&1

send_text "⚠️ 会议纪要 user token 已失效(status=$ST,探测=$PROBE)。已自动发起重新授权,请在 10 分钟内用飞书扫下方二维码(或打开链接)确认;确认后会自动完成登录,无需上机器操作。
$URL"
if [ -f "$QR" ]; then
  "$LARK" im +messages-send --as bot --user-id "$OPEN_ID" --image "$QR" >> "$LOG" 2>&1
fi

# 后台轮询完成登录(device code 10 分钟有效);成功/失败都回报一条
nohup bash -c "
  if '$LARK' auth login --device-code '$CODE' >> '$LOG' 2>&1; then
    '$LARK' im +messages-send --as bot --user-id '$OPEN_ID' --text '✅ 会议纪要 user token 已通过扫码重新授权,恢复正常,定时任务无需干预。' >> '$LOG' 2>&1
  else
    '$LARK' im +messages-send --as bot --user-id '$OPEN_ID' --text '❌ 扫码授权未在 10 分钟内完成,登录未生效。下次自检会重新发二维码;也可在 bingzhe-01 上手动运行 lark-cli auth login --domain $AUTH_DOMAINS。' >> '$LOG' 2>&1
  fi
" >/dev/null 2>&1 &
disown

exit 1
