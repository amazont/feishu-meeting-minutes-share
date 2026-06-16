#!/usr/bin/env bash
# 每日会议纪要 · 一键初始化(零手填,自动探测所有配置)
# 前提:已装 lark-cli 并完成飞书授权;已装 sc(stepcode)或 claude 并登录。
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
echo "🔧 每日会议纪要 · 一键初始化"
echo "─────────────────────────────"

# 从混入前缀行的输出里抽出 JSON(lark-cli 有时会先打印 Resolved/Found 之类的提示)
json() { python3 -c "import sys; t=sys.stdin.read(); i=t.find('{'); sys.stdout.write(t[i:] if i>=0 else '{}')"; }

# 1) 依赖检查
command -v lark-cli >/dev/null 2>&1 || { echo "❌ 未安装 lark-cli。请先安装并运行 lark-cli config init"; exit 1; }
command -v python3  >/dev/null 2>&1 || { echo "❌ 未安装 python3(脚本解析 lark-cli 输出依赖它)"; exit 1; }
command -v node     >/dev/null 2>&1 || { echo "❌ 未安装 node(workflow 运行依赖它)"; exit 1; }
RUNNER=""
if command -v sc >/dev/null 2>&1; then RUNNER="sc claude"; elif command -v claude >/dev/null 2>&1; then RUNNER="claude"; fi
[ -n "$RUNNER" ] || { echo "❌ 未找到 sc 或 claude 命令"; exit 1; }
echo "✅ 依赖就绪:lark-cli + python3 + node + ${RUNNER}"

# 2) 自动获取你的 open_id(通知用)
OPEN_ID="$(lark-cli contact +get-user --format json 2>/dev/null | grep -oE 'ou_[a-z0-9]+' | head -1)"
if [ -z "$OPEN_ID" ]; then
  echo "❌ 拿不到你的 open_id —— 飞书可能还没授权。请运行下面一行完成授权后重试:"
  echo "   lark-cli auth login --scope \"contact:user.base:readonly minutes:minutes.search:read minutes:minutes.artifacts:read minutes:minutes.transcript:export wiki:node:retrieve wiki:node:create docx:document:create im:message.send_as_user drive:drive.metadata:readonly vc:note:read\""
  exit 1
fi
echo "✅ 你的 open_id:$OPEN_ID"

# 3) 自动解析个人知识库 space_id
NL="$(lark-cli wiki +node-list --space-id my_library --format json 2>/dev/null | json)"
SPACE_ID="$(echo "$NL" | python3 -c "import sys,json
d=json.load(sys.stdin); ns=(d.get('data') or {}).get('nodes') or []
print(ns[0].get('space_id') if ns else '')" 2>/dev/null)"
[ -n "$SPACE_ID" ] || { echo "❌ 解析个人知识库失败(可能缺 wiki:node:retrieve 授权)"; exit 1; }
echo "✅ 个人知识库 space_id:$SPACE_ID"

# 4) 创建/复用「会议纪要」根节点(当天子节点都挂它下面)
ROOT="$(echo "$NL" | python3 -c "import sys,json
d=json.load(sys.stdin); ns=(d.get('data') or {}).get('nodes') or []
print(next((n['node_token'] for n in ns if n.get('title')=='会议纪要'),''))" 2>/dev/null)"
OBJ=""
if [ -z "$ROOT" ]; then
  CR="$(lark-cli wiki +node-create --space-id my_library --title "会议纪要" --obj-type docx --format json 2>/dev/null | json)"
  ROOT="$(echo "$CR" | python3 -c "import sys,json
d=json.load(sys.stdin); print((d.get('data') or {}).get('node_token',''))" 2>/dev/null)"
  OBJ="$(echo "$CR" | python3 -c "import sys,json
d=json.load(sys.stdin); print((d.get('data') or {}).get('obj_token',''))" 2>/dev/null)"
  echo "✅ 已创建「会议纪要」根节点:$ROOT"
else
  OBJ="$(echo "$NL" | python3 -c "import sys,json
d=json.load(sys.stdin); ns=(d.get('data') or {}).get('nodes') or []
print(next((n.get('obj_token','') for n in ns if n.get('title')=='会议纪要'),''))" 2>/dev/null)"
  echo "✅ 复用已有「会议纪要」根节点:$ROOT"
fi
[ -n "$ROOT" ] || { echo "❌ 创建知识库根节点失败(可能缺 wiki:node:create 授权)"; exit 1; }

# 5) 自动探测飞书域名(从根节点文档 URL)
HOST="$(lark-cli drive metas batch_query --data "{\"request_docs\":[{\"doc_type\":\"docx\",\"doc_token\":\"$OBJ\"}],\"with_url\":true}" --format json 2>/dev/null | grep -oE 'https://[a-z0-9]+\.feishu\.cn' | head -1)"
[ -n "$HOST" ] || HOST="https://www.feishu.cn"
echo "✅ 飞书域名:$HOST"

# 6) 写 config.sh(全自动)
BASE_DIR="$HOME/会议纪要"
cat > "$HERE/config.sh" <<EOF
# 由 init.sh 自动生成,一般无需手改
WIKI_ROOT="$ROOT"
SPACE_ID="$SPACE_ID"
OPEN_ID="$OPEN_ID"
MINUTE_HOST="$HOST"
BASE_DIR="$BASE_DIR"

# checker 质量校验:低于 MIN_SCORE 自动重写(最多 REDRAFT_MAX 次额外重写)
MIN_SCORE=80
REDRAFT_MAX=1
# 同一篇 BLOCKED(取不到产物)当天最多重试几次,达到后当天放弃(高频心跳防空跑)
BLOCKED_GIVEUP=3
EOF
echo "✅ 已写入配置:$HERE/config.sh"

# 6b) 建 loop-engine 状态目录 + 初始 state.md 骨架(去重台账与人读状态都放数据侧)
STATE_DIR="$BASE_DIR/.loop-engine"; mkdir -p "$STATE_DIR"
touch "$STATE_DIR/processed.tsv"
if [ ! -f "$STATE_DIR/state.md" ]; then
  cat > "$STATE_DIR/state.md" <<EOF
# Goal: 每天把当日飞书妙记自动生成达标(score≥80)的 5 维度会议纪要并归档知识库

- 节奏: 由 launchd/cron 心跳触发(见 config.sh 的 SCHED_*)
- 模式: 无人值守
- 状态目录: $STATE_DIR
- 去重台账: $STATE_DIR/processed.tsv

## 停止条件 completion criteria(每次心跳对当日妙记求值)

- [ ] C1 覆盖度: 当日发现的妙记全部进入处理
- [ ] C2 正确性: 每篇 checker verdict=DONE
- [ ] C3 可验证性: 每篇已建知识库文档且有 url
- [ ] C4 一致性: Lark-flavored 渲染正常

## 轮次日志

(尚未运行,首次 ./run.sh 后由 update_state.py 写入)

## 当前未决缺口(下次心跳重试 / 待人复核)

- (无)

## BLOCKED / 待人决策

- (无)
EOF
fi
echo "✅ 已建状态目录:$STATE_DIR(去重台账 + state.md)"

# 7) 安装 workflow 到 Claude/stepcode workflows 目录
mkdir -p "$HOME/.claude/workflows"
cp "$HERE/daily-meeting-minutes.js" "$HOME/.claude/workflows/"
echo "✅ 已安装 workflow 到 ~/.claude/workflows/"

# 8) 配置自动运行频率(默认每天一次;直接回车全程用默认 = 保持"零手填")
echo "─────────────────────────────"
echo "⏰ 配置多久自动跑一次(直接回车 = 每天一次)"
SCHED_KIND="daily"; SCHED_HOUR=18; SCHED_MIN=47; SCHED_N=0
if [ -t 0 ]; then
  echo "  1) 每天一次(默认)"
  echo "  2) 每 N 小时一次"
  echo "  3) 每 N 分钟一次"
  echo "  4) 不自动跑(仅手动 ./run.sh)"
  read -r -p "选择 [1]: " ans || true
  case "${ans:-1}" in
    2) SCHED_KIND="hours"
       read -r -p "每几小时跑一次? [4]: " n || true
       SCHED_N="${n:-4}"; { [[ "$SCHED_N" =~ ^[0-9]+$ ]] && [ "$SCHED_N" -ge 1 ]; } || SCHED_N=4 ;;
    3) SCHED_KIND="minutes"
       read -r -p "每几分钟跑一次? [30]: " n || true
       SCHED_N="${n:-30}"; { [[ "$SCHED_N" =~ ^[0-9]+$ ]] && [ "$SCHED_N" -ge 1 ]; } || SCHED_N=30 ;;
    4) SCHED_KIND="none" ;;
    *) SCHED_KIND="daily"
       read -r -p "每天几点跑? HH:MM [18:47]: " t || true
       t="${t:-18:47}"
       if [[ "$t" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then SCHED_HOUR="${BASH_REMATCH[1]}"; SCHED_MIN="${BASH_REMATCH[2]}"; else SCHED_HOUR=18; SCHED_MIN=47; fi ;;
  esac
else
  echo "  (非交互环境,默认:每天一次 18:47)"
fi

case "$SCHED_KIND" in
  daily)   SCHED_DESC="每天 $(printf '%02d:%02d' "$SCHED_HOUR" "$SCHED_MIN")" ;;
  hours)   SCHED_DESC="每 ${SCHED_N} 小时一次" ;;
  minutes) SCHED_DESC="每 ${SCHED_N} 分钟一次" ;;
  none)    SCHED_DESC="不自动跑(仅手动)" ;;
esac

# 把频率写进 config.sh(改频率重跑 ./init.sh 即可)
cat >> "$HERE/config.sh" <<EOF

# 自动运行频率(由 init.sh 写入;改频率重跑 ./init.sh)
SCHED_KIND="$SCHED_KIND"
SCHED_HOUR="$SCHED_HOUR"
SCHED_MIN="$SCHED_MIN"
SCHED_N="$SCHED_N"
EOF

LABEL="com.example.daily-meeting-minutes"
OS="$(uname -s)"

install_launchd() {
  local plist="$HOME/Library/LaunchAgents/$LABEL.plist" sched_block
  if [ "$SCHED_KIND" = "daily" ]; then
    sched_block="    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key><integer>$SCHED_HOUR</integer>
        <key>Minute</key><integer>$SCHED_MIN</integer>
    </dict>"
  elif [ "$SCHED_KIND" = "hours" ]; then
    sched_block="    <key>StartInterval</key><integer>$((SCHED_N*3600))</integer>"
  else
    sched_block="    <key>StartInterval</key><integer>$((SCHED_N*60))</integer>"
  fi
  mkdir -p "$HOME/Library/LaunchAgents" "$BASE_DIR/_logs"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>$HERE/run.sh</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$PATH</string>
    </dict>
    <key>WorkingDirectory</key>
    <string>$HERE</string>
$sched_block
    <key>StandardOutPath</key>
    <string>$BASE_DIR/_logs/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$BASE_DIR/_logs/launchd.err.log</string>
    <key>RunAtLoad</key><false/>
</dict>
</plist>
EOF
  launchctl unload "$plist" 2>/dev/null || true
  if launchctl load "$plist" 2>/dev/null; then
    echo "✅ 已安装并加载 launchd 任务($SCHED_DESC)"
  else
    echo "⚠️ 已写入 $plist,但 launchctl load 失败,请手动: launchctl load \"$plist\""
  fi
}

install_cron() {
  local marker="# daily-meeting-minutes ($LABEL)" line cur
  case "$SCHED_KIND" in
    daily)   line="$SCHED_MIN $SCHED_HOUR * * * /bin/bash $HERE/run.sh $marker" ;;
    hours)   line="0 */$SCHED_N * * * /bin/bash $HERE/run.sh $marker" ;;
    minutes) line="*/$SCHED_N * * * * /bin/bash $HERE/run.sh $marker" ;;
  esac
  cur="$(crontab -l 2>/dev/null | grep -vF "$marker" || true)"
  if { [ -n "$cur" ] && printf '%s\n' "$cur"; printf '%s\n' "$line"; } | crontab -; then
    echo "✅ 已写入 crontab($SCHED_DESC)"
  else
    echo "⚠️ 写 crontab 失败,请手动添加一行: $line"
  fi
}

if [ "$SCHED_KIND" = "none" ]; then
  echo "ℹ️ 已选择不自动跑。需要时手动执行: $HERE/run.sh"
else
  case "$OS" in
    Darwin) install_launchd ;;
    Linux)  install_cron ;;
    *)      echo "⚠️ 未识别的系统($OS),请按 README 手动配置定时任务($SCHED_DESC)。" ;;
  esac
fi

echo "─────────────────────────────"
echo "🎉 初始化完成!自动运行频率:$SCHED_DESC"
echo "现在先手动跑一次验证:"
echo "   $HERE/run.sh"
echo "(想改频率:重跑 ./init.sh 即可;不自动跑请选 4)"
