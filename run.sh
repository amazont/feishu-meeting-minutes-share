#!/bin/zsh
# 每日飞书会议纪要 — 入口脚本(可被 launchd/cron 调用,也可手动运行)
# 关键设计:建节点 + 本地备份 都用确定性 bash 完成,不交给 AI(避免 agent 跳过命令)。

set -e
HERE="$(cd "$(dirname "$0")" && pwd)"

# 读取个人配置:优先 config.sh,没有就提示先跑 init
if [ -f "$HERE/config.sh" ]; then
  source "$HERE/config.sh"
else
  echo "❌ 缺少 $HERE/config.sh —— 请先运行一键初始化:  ./init.sh"; exit 1
fi

# 定位 CLI:lark-cli 必需;运行器优先 sc(stepcode),否则 claude
LARK="$(command -v lark-cli)"
[ -z "$LARK" ] && { echo "❌ 未找到 lark-cli"; exit 1; }
if command -v sc >/dev/null 2>&1; then RUN=(sc claude); elif command -v claude >/dev/null 2>&1; then RUN=(claude); else echo "❌ 未找到 sc 或 claude"; exit 1; fi

LOG_DIR="$BASE_DIR/_logs"; mkdir -p "$LOG_DIR"
STAMP="$(date +%Y-%m-%d_%H%M%S)"; DAY="$(date +%Y-%m-%d)"
LOG="$LOG_DIR/daily-minutes_$STAMP.log"
cd "$HOME"
echo "===== 启动 $STAMP =====" >> "$LOG" 2>&1

# 1) 本地当天目录
LOCAL_DIR="$BASE_DIR/$DAY"; mkdir -p "$LOCAL_DIR"

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

# 3) headless 跑 workflow,把 dayNode/localDir/openId/minuteHost 通过指令传入
"${RUN[@]}" -p "用 Workflow 工具运行命名 workflow「daily-meeting-minutes」(name: \"daily-meeting-minutes\"),args 设为 {\"dayNode\":\"$DAY_NODE\",\"localDir\":\"$LOCAL_DIR\",\"openId\":\"$OPEN_ID\",\"minuteHost\":\"$MINUTE_HOST\"}。完成后简要汇报。" \
  --permission-mode bypassPermissions >> "$LOG" 2>&1
RC=$?
echo "===== 结束 退出码 $RC =====" >> "$LOG" 2>&1

# 4) 失败告警(未登录/非零退出)
if [ "$RC" -ne 0 ] || grep -q "Not logged in" "$LOG"; then
  REASON="退出码 $RC"; grep -q "Not logged in" "$LOG" && REASON="运行器未登录,请运行一次 ${RUN[*]} 重新登录"
  "$LARK" im +messages-send --user-id "$OPEN_ID" --text "⚠️ 会议纪要任务失败($STAMP):$REASON。日志:$LOG" >> "$LOG" 2>&1
  exit 1
fi

# 5) 确定性把当天节点下的文档拉回本地(不依赖 agent 写盘)
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
echo "[done] $STAMP 完成" >> "$LOG" 2>&1
