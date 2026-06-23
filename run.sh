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
# 并发互斥:workflow 偶尔 >2 分钟而 cron 为 */2,可能两实例重叠抢同一 _result.json/目录。
# flock 非阻塞锁:已有实例在跑则静默跳过本轮(在建 LOG 之前退出,不留残档/不告警)。
exec 9>"$LOG_DIR/.run.lock"
flock -n 9 || exit 0
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

# 失败告警:① 以机器人(bot)身份发,保持「机器人发通知」的观感;② 限流——同一天 + 同一 reason-key
#           最多发 1 次,避免 cron 高频下同种错误 320 连发刷屏。标记落 .alerts/<DAY>_<key>,跨天自动复位。
ALERT_DIR="$STATE_DIR/.alerts"; mkdir -p "$ALERT_DIR"
alert() {  # $1=reason-key(短标识)  $2=要发的文本
  local mark="$ALERT_DIR/${DAY}_$1"
  if [ -f "$mark" ]; then
    echo "[alert] 今日已就「$1」告警过,抑制本次(限流)。" >> "$LOG" 2>&1
    return 0
  fi
  "$LARK" im +messages-send --as bot --user-id "$OPEN_ID" --text "$2" >> "$LOG" 2>&1
  : > "$mark"
}

# 1) 本地当天目录
LOCAL_DIR="$BASE_DIR/$DAY"; mkdir -p "$LOCAL_DIR"
rm -f "$LOCAL_DIR/_result.json"  # 清理上次结果,避免误读旧数据

# 2) 确定性建/复用知识库当天容器节点(按标题查重,幂等)
DAY_TITLE="$DAY 会议纪要"
DAY_NODE="$("$LARK" wiki +node-list --as user --space-id "$SPACE_ID" --parent-node-token "$WIKI_ROOT" --page-all --format json 2>/dev/null \
  | python3 -c "import sys,json
try: d=json.load(sys.stdin)
except: sys.exit(0)
for it in (d.get('data') or {}).get('nodes') or []:
    if it.get('title')=='$DAY_TITLE': print(it.get('node_token')); break" 2>/dev/null)"
if [ -z "$DAY_NODE" ]; then
  DAY_NODE="$("$LARK" wiki +node-create --as user --space-id "$SPACE_ID" --parent-node-token "$WIKI_ROOT" --title "$DAY_TITLE" --obj-type docx --format json 2>>"$LOG" \
    | python3 -c "import sys,json
try: d=json.load(sys.stdin)
except: sys.exit(0)
print((d.get('data') or {}).get('node_token') or '')" 2>/dev/null)"
  echo "[setup] 新建当天节点: $DAY_NODE" >> "$LOG" 2>&1
else
  echo "[setup] 复用当天节点: $DAY_NODE" >> "$LOG" 2>&1
fi
[ -z "$DAY_NODE" ] && { echo "[setup] ❌ 无法获得当天节点 token,终止" >> "$LOG" 2>&1; \
  alert nodefail "⚠️ 会议纪要任务失败($STAMP):无法创建知识库当天节点" >> "$LOG" 2>&1; exit 1; }

# 3) headless 跑 workflow,把 dayNode/localDir/openId/minuteHost/skipTokens/minScore 通过指令传入
#    去重判定在 bash 端确定性完成:已建文档的永久跳过、当天 BLOCKED 满 BLOCKED_GIVEUP 次的当天放弃
SKIP_TOKENS="$(python3 "$HERE/update_state.py" skip "$LEDGER" "$DAY" "$BLOCKED_GIVEUP" 2>>"$LOG")"
echo "[dedup] 跳过 token: ${SKIP_TOKENS:-(无)}" >> "$LOG" 2>&1
#    ⚠️ 用 set +e 包住运行器调用:否则运行器非零退出时 set -e 会抢先终止,
#    导致下面的 RC 捕获与飞书告警(第 4 步)成为永远到不了的死代码。
# 运行器 prompt 抽成变量,便于瞬时错误重试时复用(避免重复维护长指令)。
PROMPT="用 Workflow 工具运行命名 workflow「daily-meeting-minutes」(name: \"daily-meeting-minutes\"),args 设为 {\"dayNode\":\"$DAY_NODE\",\"localDir\":\"$LOCAL_DIR\",\"openId\":\"$OPEN_ID\",\"minuteHost\":\"$MINUTE_HOST\",\"skipTokens\":\"$SKIP_TOKENS\",\"minScore\":$MIN_SCORE,\"redraftMax\":$REDRAFT_MAX}。完成后简要汇报。然后务必另起一行,以 ===RESULT_JSON=== 开头,紧跟 Workflow 工具返回的 JSON 单行原样(禁止代码块/省略/改写任何字段)。"
RESULT="$LOCAL_DIR/_result.json"

# 瞬时错误自动重试:仅当本轮命中「模型网关 5xx / 连接抖动」且本轮未落 _result.json 时才重试,
#   最多 RETRY_MAX 次(默认 2,即总计最多 3 次尝试),每次退避 RETRY_SLEEP 秒。
#   背景:偶发 `API Error: Internal server error` 会让 agent 0 工具调用即退出码 1,
#         触发"workflow 未完成"误报告警;此前只能等下一班次兜底,这里改为就地快速重试。
#   命中硬错误(未登录/磁盘满/lark 131006)立即停止重试 —— 这些重试也没用,交给第 4 步如实告警。
RETRY_MAX="${RETRY_MAX:-2}"; RETRY_SLEEP="${RETRY_SLEEP:-20}"
TRANSIENT_RE='Internal server error|API Error|Overloaded|overloaded_error|(^|[^0-9])50[234]([^0-9]|$)|ECONNRESET|ETIMEDOUT|socket hang up|fetch failed|network error|Service Unavailable|Bad Gateway|Gateway Time'
HARD_RE='Not logged in|ENOSPC|no space left|131006|无法获得当天节点|无法创建知识库'
# workflow「真跑到结尾」的证据:落了 ===RESULT_JSON=== 契约哨兵行,或日志含空跑静默成功标志词
#   (与第 4 步白名单保持一致)。用于识别「退出码 0 但模型空补全」这类退化轮——模型偶发返回
#   空补全(0 工具调用、根本没运行 workflow)同样会退出码 0,但既无契约也无标志词,不能当成功。
DONE_RE='===RESULT_JSON===|静默跳过|无需处理|没有需要处理|处理妙记数|未发现.*妙记|0 篇'
set +e
attempt=0
while :; do
  attempt=$((attempt+1))
  rm -f "$RESULT"   # 每轮开跑前清空契约文件,避免误读上一轮残档
  ATTEMPT_LOG="$(mktemp "${TMPDIR:-/tmp}/dms_attempt.XXXXXX")"
  "${RUN[@]}" -p "$PROMPT" --permission-mode bypassPermissions < /dev/null > "$ATTEMPT_LOG" 2>&1
  RC=$?
  cat "$ATTEMPT_LOG" >> "$LOG"   # 本轮输出汇入主日志(末尾哨兵行供第 4.0 步重建契约)
  # 收工条件:已落完成契约,或(退出码 0 且日志有 workflow 真跑过的证据)。
  #   ⚠️ 不再把「退出码 0」单独当成功 —— 模型偶发空补全也会 0 工具调用、退出码 0,
  #      那种轮次没有契约/标志词,必须落到下面的空补全重试,而不是误判为成功 break。
  if [ -f "$RESULT" ] || { [ "$RC" -eq 0 ] && grep -qE "$DONE_RE" "$ATTEMPT_LOG"; }; then rm -f "$ATTEMPT_LOG"; break; fi
  # 硬错误 → 重试无意义,立即停止,交给第 4 步告警
  if grep -qiE "$HARD_RE" "$ATTEMPT_LOG"; then rm -f "$ATTEMPT_LOG"; break; fi
  # 空补全/退化轮:退出码 0 但既无契约又无任何完成标志词 ⇒ 本轮 workflow 根本没跑起来(模型吐了空)。
  #   skipTokens 不变、workflow 幂等,退避后重跑即可自愈,避免 12:58 那类「退出码0空跑」误报。
  if [ "$attempt" -le "$RETRY_MAX" ] && [ "$RC" -eq 0 ] && [ ! -f "$RESULT" ] && ! grep -qE "$DONE_RE" "$ATTEMPT_LOG"; then
    echo "[retry] 第 $attempt 次尝试为空补全(退出码0但未运行 workflow/无哨兵行),退避 ${RETRY_SLEEP}s 后重试(上限 $RETRY_MAX 次)" >> "$LOG" 2>&1
    rm -f "$ATTEMPT_LOG"; sleep "$RETRY_SLEEP"; continue
  fi
  # 命中瞬时错误 且 仍有重试额度 → 退避后重跑(skipTokens 不变,workflow 幂等)
  if [ "$attempt" -le "$RETRY_MAX" ] && grep -qiE "$TRANSIENT_RE" "$ATTEMPT_LOG"; then
    echo "[retry] 第 $attempt 次尝试命中瞬时错误(网关5xx/连接抖动),退避 ${RETRY_SLEEP}s 后重试(上限 $RETRY_MAX 次)" >> "$LOG" 2>&1
    rm -f "$ATTEMPT_LOG"; sleep "$RETRY_SLEEP"; continue
  fi
  # 非瞬时错误 或 额度耗尽 → 退出循环,交给第 4 步判定
  rm -f "$ATTEMPT_LOG"; break
done
set -e
[ "$attempt" -gt 1 ] && echo "[retry] 本次共尝试 $attempt 次" >> "$LOG" 2>&1
echo "===== 结束 退出码 $RC =====" >> "$LOG" 2>&1

# 4) 成败判定:以 workflow 是否真完成为准,而不是看运行器退出码。
#    背景:stepcode(sc)有时在 workflow 干完后的收尾阶段弹"反馈问卷",非交互(cron)下
#    拿不到输入会以 130 退出 —— 这是假失败。workflow 每次都落 _result.json 作为完成契约,
#    且本脚本开跑前已 rm 掉它,所以"跑完后存在 _result.json"= 本次真正跑到了结尾。
# RESULT 路径已在运行器调用前定义
# 4.0) 若 workflow 的 agent 未能落 _result.json,则从运行日志的 ===RESULT_JSON=== 哨兵行确定性重建(shell 落盘,不依赖 AI 写文件)
if [ ! -f "$RESULT" ]; then
  python3 - "$LOG" "$RESULT" << 'PYJSON' >> "$LOG" 2>&1 || true
import sys, json, re
log_path, out_path = sys.argv[1], sys.argv[2]
txt = open(log_path, encoding="utf-8", errors="ignore").read()
hits = re.findall(r"===RESULT_JSON===\s*(.+)", txt)
if hits:
    raw = hits[-1].strip().strip("`").strip()
    obj = None
    try:
        obj = json.loads(raw)
    except Exception:
        e = raw.rfind("}")
        if e >= 0:
            try: obj = json.loads(raw[:e+1])
            except Exception: obj = None
    if isinstance(obj, dict) and "date" in obj:
        json.dump(obj, open(out_path, "w", encoding="utf-8"), ensure_ascii=False)
        print("[contract] 已从 ===RESULT_JSON=== 哨兵行确定性重建 _result.json")
PYJSON
fi
if grep -q "Not logged in" "$LOG"; then
  alert notloggedin "⚠️ 会议纪要任务失败($STAMP):运行器未登录,请运行一次 ${RUN[*]} 重新登录。日志:$LOG" >> "$LOG" 2>&1
  exit 1
elif [ ! -f "$RESULT" ]; then
  # 无 _result.json:区分"真失败"与"高频心跳空跑"(无新增;workflow 静默完成但 agent 未落契约文件)
  if grep -qiE "ENOSPC|no space left|Failed to run agent|Not logged in|131006|无法获得当天节点|无法创建知识库" "$LOG" \
     || ! grep -qE "===RESULT_JSON===|静默跳过|无需处理|没有需要处理|处理妙记数|未发现.*妙记|0 篇" "$LOG"; then
    alert wf_incomplete "⚠️ 会议纪要任务失败($STAMP):workflow 未完成(无 _result.json,退出码 $RC)。日志:$LOG" >> "$LOG" 2>&1
    exit 1
  fi
  echo "[warn] 空跑静默成功:无新增妙记,workflow 已完成但未落 _result.json(高频心跳静默),不告警。" >> "$LOG" 2>&1
  rm -f "$LOG"
  exit 0
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
  "$LARK" wiki +node-list --as user --space-id "$SPACE_ID" --parent-node-token "$DAY_NODE" --page-all --format json 2>>"$LOG" \
    | LARK="$LARK" DAY="$DAY" LOCAL_DIR="$LOCAL_DIR" python3 -c "
import sys,json,os,re,subprocess
d=json.load(sys.stdin); day=os.environ['DAY']; ld=os.environ['LOCAL_DIR']; lark=os.environ['LARK']
for n in (d.get('data') or {}).get('nodes') or []:
    obj=n.get('obj_token'); title=n.get('title') or obj
    if not obj: continue
    safe=re.sub(r'[\\\\/:*?\"<>|\\s]+','_',title)[:40]
    out=os.path.join(ld, f'{day}_{safe}.md')
    r=subprocess.run([lark,'docs','+fetch','--as','user','--api-version','v2','--doc',obj,'--format','json'],capture_output=True,text=True)
    try: c=((json.loads(r.stdout).get('data') or {}).get('document') or {}).get('content','')
    except Exception: c=''
    if c: open(out,'w').write(c); print('[backup] '+out)
" >> "$LOG" 2>&1
  echo "[done] $STAMP 完成,归档 $COUNT 篇" >> "$LOG" 2>&1
else
  # 静默成功:本次不留日志(失败分支在第 4 步已 exit 1,日志保留)
  rm -f "$LOG"
fi
