#!/bin/zsh
# 每日飞书会议纪要 — 入口脚本(可被 launchd/cron 调用,也可手动运行)
# 关键设计:建节点 / 写台账 / 写 state / 本地备份 都用确定性 bash 完成,不交给 AI。
#           质量判定交给 workflow 里的独立 checker。

set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
# 防御性 PATH:launchd/cron 的 PATH 极简,补上常见安装目录,避免找不到 lark-cli/sc/node/python3
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/bin:$HOME/.npm-global/bin:$PATH"

# 读取个人配置:优先 config.sh,没有就提示先跑 init
if [ -f "$HERE/config.sh" ]; then
  source "$HERE/config.sh"
else
  echo "❌ 缺少 $HERE/config.sh —— 请先运行一键初始化:  ./init.sh"; exit 1
fi
MIN_SCORE="${MIN_SCORE:-80}"; REDRAFT_MAX="${REDRAFT_MAX:-1}"; BLOCKED_GIVEUP="${BLOCKED_GIVEUP:-3}"

# 定位 CLI:lark-cli 必需;运行器优先 sc(stepcode),否则 claude;python3/node 必需
LARK="$(command -v lark-cli)"
[ -z "$LARK" ] && { echo "❌ 未找到 lark-cli"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "❌ 未找到 python3(脚本解析 lark-cli 输出依赖它)"; exit 1; }
command -v node    >/dev/null 2>&1 || { echo "❌ 未找到 node(workflow 运行依赖它)"; exit 1; }
if command -v sc >/dev/null 2>&1; then RUN=(sc claude); elif command -v claude >/dev/null 2>&1; then RUN=(claude); else echo "❌ 未找到 sc 或 claude"; exit 1; fi

LOG_DIR="$BASE_DIR/_logs"; mkdir -p "$LOG_DIR"
# 日志轮转:清理 14 天前的运行日志
find "$LOG_DIR" -name 'daily-minutes_*.log' -mtime +14 -delete 2>/dev/null || true
STAMP="$(date +%Y-%m-%d_%H%M%S)"; DAY="$(date +%Y-%m-%d)"
LOG="$LOG_DIR/daily-minutes_$STAMP.log"
cd "$HOME"
echo "===== 启动 $STAMP =====" >> "$LOG" 2>&1

# loop-engine 状态目录(去重台账 + 人读 state),放数据侧、不随包分发
STATE_DIR="$BASE_DIR/.loop-engine"; mkdir -p "$STATE_DIR"
LEDGER="$STATE_DIR/processed.tsv"; touch "$LEDGER"
STATE_MD="$STATE_DIR/state.md"

# 1) 本地当天目录
LOCAL_DIR="$BASE_DIR/$DAY"; mkdir -p "$LOCAL_DIR"
rm -f "$LOCAL_DIR/_result.json"  # 清理上次结果,避免误读旧数据

# 2) 确定性建/复用知识库当天容器节点(按标题查重,幂等)
DAY_TITLE="$DAY 会议纪要"
DAY_NODE="$("$LARK" wiki +node-list --space-id "$SPACE_ID" --parent-node-token "$WIKI_ROOT" --page-all --format json 2>/dev/null \
  | python3 -c "import sys,json
try: d=json.load(sys.stdin)
except: sys.exit(0)
for it in (d.get('data') or {}).get('nodes') or []:
    if it.get('title')=='$DAY_TITLE': print(it.get('node_token')); break" 2>/dev/null)"
if [ -z "$DAY_NODE" ]; then
  DAY_NODE="$("$LARK" wiki +node-create --space-id "$SPACE_ID" --parent-node-token "$WIKI_ROOT" --title "$DAY_TITLE" --obj-type docx --format json 2>>"$LOG" \
    | python3 -c "import sys,json
try: d=json.load(sys.stdin)
except: sys.exit(0)
print((d.get('data') or {}).get('node_token') or '')" 2>/dev/null)"
  echo "[setup] 新建当天节点: $DAY_NODE" >> "$LOG" 2>&1
else
  echo "[setup] 复用当天节点: $DAY_NODE" >> "$LOG" 2>&1
fi
[ -z "$DAY_NODE" ] && { echo "[setup] ❌ 无法获得当天节点 token,终止" >> "$LOG" 2>&1; \
  "$LARK" im +messages-send --user-id "$OPEN_ID" --text "⚠️ 会议纪要任务失败($STAMP):无法创建知识库当天节点" >> "$LOG" 2>&1; exit 1; }

# 3) headless 跑 workflow,把 dayNode/localDir/openId/minuteHost/skipTokens/minScore 通过指令传入
#    去重判定在 bash 端确定性完成:已建文档的永久跳过、当天 BLOCKED 满 BLOCKED_GIVEUP 次的当天放弃
SKIP_TOKENS="$(python3 "$HERE/update_state.py" skip "$LEDGER" "$DAY" "$BLOCKED_GIVEUP" 2>>"$LOG")"
echo "[dedup] 跳过 token: ${SKIP_TOKENS:-(无)}" >> "$LOG" 2>&1
#    ⚠️ 用 set +e 包住运行器调用:否则运行器非零退出时 set -e 会抢先终止,
#    导致下面的 RC 捕获与飞书告警(第 4 步)成为永远到不了的死代码。
set +e
"${RUN[@]}" -p "用 Workflow 工具运行命名 workflow「daily-meeting-minutes」(name: \"daily-meeting-minutes\"),args 设为 {\"dayNode\":\"$DAY_NODE\",\"localDir\":\"$LOCAL_DIR\",\"openId\":\"$OPEN_ID\",\"minuteHost\":\"$MINUTE_HOST\",\"skipTokens\":\"$SKIP_TOKENS\",\"minScore\":$MIN_SCORE,\"redraftMax\":$REDRAFT_MAX}。完成后简要汇报。" \
  --permission-mode bypassPermissions < /dev/null >> "$LOG" 2>&1
RC=$?
set -e
echo "===== 结束 退出码 $RC =====" >> "$LOG" 2>&1

# 4) 成败判定:以 workflow 是否真完成为准,而不是看运行器退出码。
#    背景:stepcode(sc)有时在 workflow 干完后的收尾阶段弹"反馈问卷",非交互(cron)下
#    拿不到输入会以 130 退出 —— 这是假失败。workflow 每次都落 _result.json 作为完成契约,
#    且本脚本开跑前已 rm 掉它,所以"跑完后存在 _result.json"= 本次真正跑到了结尾。
RESULT="$LOCAL_DIR/_result.json"
if grep -q "Not logged in" "$LOG"; then
  "$LARK" im +messages-send --user-id "$OPEN_ID" --text "⚠️ 会议纪要任务失败($STAMP):运行器未登录,请运行一次 ${RUN[*]} 重新登录。日志:$LOG" >> "$LOG" 2>&1
  exit 1
elif [ ! -f "$RESULT" ]; then
  # 没有完成契约 → workflow 没跑到结尾,是真失败
  "$LARK" im +messages-send --user-id "$OPEN_ID" --text "⚠️ 会议纪要任务失败($STAMP):workflow 未完成(无 _result.json,退出码 $RC)。日志:$LOG" >> "$LOG" 2>&1
  exit 1
elif [ "$RC" -ne 0 ]; then
  # 有完成契约但退出码非零 → 多半是 sc 反馈问卷收尾干扰,记一行、按成功继续,不告警
  echo "[warn] 运行器退出码 $RC,但已检测到 _result.json,判定 workflow 已完成(疑似 stepcode 反馈问卷干扰),按成功处理。" >> "$LOG" 2>&1
fi

# 5) 读 _result.json:始终更新去重台账/state(廉价,含 BLOCKED 放弃计数),并取本次成功归档数
COUNT=0
if [ -f "$RESULT" ]; then
  python3 "$HERE/update_state.py" update "$RESULT" "$DAY" "$LEDGER" "$STATE_MD" "$STAMP" "$MIN_SCORE" "$BLOCKED_GIVEUP" >> "$LOG" 2>&1 \
    || echo "[state] update_state.py 执行失败(详见上)" >> "$LOG" 2>&1
  COUNT="$(python3 -c "import json
try: print(int((json.load(open('$RESULT')).get('count') or 0)))
except Exception: print(0)" 2>/dev/null)"; COUNT="${COUNT:-0}"
fi

# 6) 仅当本次有成功归档(= 发了飞书通知)时:拉回备份 + 保留本次日志。
#    无新增 / 纯 BLOCKED 的静默成功:不拉备份、删掉本次日志(按需求:只在失败或成功推送时留日志)。
if [ "$COUNT" -gt 0 ]; then
  "$LARK" wiki +node-list --space-id "$SPACE_ID" --parent-node-token "$DAY_NODE" --page-all --format json 2>>"$LOG" \
    | LARK="$LARK" DAY="$DAY" LOCAL_DIR="$LOCAL_DIR" python3 -c "
import sys,json,os,re,subprocess
d=json.load(sys.stdin); day=os.environ['DAY']; ld=os.environ['LOCAL_DIR']; lark=os.environ['LARK']
for n in (d.get('data') or {}).get('nodes') or []:
    obj=n.get('obj_token'); title=n.get('title') or obj
    if not obj: continue
    safe=re.sub(r'[\\\\/:*?\"<>|\\s]+','_',title)[:40]
    out=os.path.join(ld, f'{day}_{safe}.md')
    r=subprocess.run([lark,'docs','+fetch','--api-version','v2','--doc',obj,'--format','json'],capture_output=True,text=True)
    try: c=((json.loads(r.stdout).get('data') or {}).get('document') or {}).get('content','')
    except Exception: c=''
    if c: open(out,'w').write(c); print('[backup] '+out)
" >> "$LOG" 2>&1
  echo "[done] $STAMP 完成,归档 $COUNT 篇" >> "$LOG" 2>&1
else
  # 静默成功:本次不留日志(失败分支在第 4 步已 exit 1,日志保留)
  rm -f "$LOG"
fi
