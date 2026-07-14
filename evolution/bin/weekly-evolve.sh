#!/bin/bash
# weekly-evolve.sh — 进化平面每周编排(cron 周日 14:05)。
# 流程: Planner(合约) → worktree → Generator(施工) → 回归双跑(旧vs新) → Evaluator(裁决)
#       → MERGE: 有 HUMAN_GATE 则飞书通知等人工 --apply;无则自动 apply(按快慢车道 promote)
#       → REJECT: 保留 worktree,backlog 记原因。
# 用法: weekly-evolve.sh            跑本周完整进化流程
#       weekly-evolve.sh --apply <week>   人工放行:合入指定周的 MERGE 裁决
# 铁律:本脚本任何失败最坏结果 = "这周没进化";绝不触碰生产 releases/current 以外路径的写入。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EVO="$ROOT/evolution"
cd "$ROOT"

BASE_DIR="$(bash -c "source '$ROOT/config.sh'; printf %s \"\$BASE_DIR\"" 2>/dev/null)"
OPEN_ID="$(bash -c "source '$ROOT/config.sh'; printf %s \"\$OPEN_ID\"" 2>/dev/null || true)"
[ -n "$BASE_DIR" ] || { echo "[evolve] ❌ 读不到 BASE_DIR"; exit 1; }

notify() {  # $1=文本(尽力而为,失败不中断)
  [ -n "$OPEN_ID" ] && command -v lark-cli >/dev/null 2>&1 && \
    lark-cli im +messages-send --as bot --user-id "$OPEN_ID" --text "$1" >/dev/null 2>&1 || true
}

log_changelog() {  # $1=week $2=status $3=hypothesis
  python3 - "$EVO/changelog.jsonl" "$1" "$2" "$3" <<'PYEOF' || true
import json, sys, datetime
line = json.dumps({"week": sys.argv[2], "status": sys.argv[3], "hypothesis": sys.argv[4],
                   "ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds")},
                  ensure_ascii=False)
open(sys.argv[1], "a", encoding="utf-8").write(line + "\n")
PYEOF
}

run_llm() {  # $1=prompt $2=输出文件 $3=工作目录(可选)
  local d="${3:-$ROOT}"
  if command -v sc >/dev/null 2>&1; then
    (cd "$d" && timeout 1800 sc claude -p "$1" --permission-mode bypassPermissions) > "$2" 2>&1 < /dev/null
  elif command -v claude >/dev/null 2>&1; then
    (cd "$d" && timeout 1800 claude -p "$1" --permission-mode bypassPermissions) > "$2" 2>&1 < /dev/null
  else
    echo "no claude/sc available" > "$2"; return 127
  fi
}

extract_json() {  # $1=raw文件 $2=哨兵标记 $3=输出json  → rc0=成功
  python3 - "$1" "$2" "$3" <<'PYEOF'
import json, sys
raw, mark, out = sys.argv[1], sys.argv[2], sys.argv[3]
obj = None
try:
    lines = open(raw, encoding="utf-8").read().splitlines()
    for i, ln in enumerate(lines):
        if mark in ln:
            rest = ln.split(mark, 1)[1].strip()
            cand = rest if rest.startswith("{") else (lines[i+1].strip() if i+1 < len(lines) else "")
            try:
                o = json.loads(cand)
                if isinstance(o, dict):
                    obj = o
            except Exception:
                pass
except Exception:
    pass
if obj is None:
    sys.exit(3)
json.dump(obj, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PYEOF
}

backlog_reject() {  # $1=week $2=hypothesis $3=reason
  python3 - "$EVO/backlog.yaml" "$1" "$2" "$3" <<'PYEOF' || true
import sys
p, week, hyp, reason = sys.argv[1:5]
def q(s): return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
with open(p, "a", encoding="utf-8") as f:
    f.write(f"- week: {q(week)}\n  hypothesis: {q(hyp)}\n  reject_reason: {q(reason)}\n")
PYEOF
}

# ── 快慢车道判定与合入(MERGE 路径共用) ─────────────────────────────
apply_merge() {  # $1=week  依据 runs/<week>/ 里的产物执行合入
  local WEEK="$1" RUN_DIR="$EVO/runs/$1"
  local BRANCH="evolve/$WEEK"
  git rev-parse --verify "$BRANCH" >/dev/null 2>&1 || { echo "[evolve] ❌ 分支不存在: $BRANCH"; return 1; }
  local HYP; HYP="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['hypothesis'])" "$RUN_DIR/contract.json" 2>/dev/null || echo '?')"
  # diff 文件清单 → 快慢车道
  local FILES; FILES="$(git diff --name-only "main...$BRANCH" 2>/dev/null || git diff --name-only "master...$BRANCH" 2>/dev/null)"
  [ -n "$FILES" ] || { echo "[evolve] ❌ 分支无 diff,拒绝合入"; return 1; }
  local LANE="fast"
  while IFS= read -r f; do
    case "$f" in
      config/*|evolution/prompts/planner.md|evolution/prompts/generator.md|evolution/prompts/evaluator.md) : ;;
      *) LANE="slow" ;;
    esac
  done <<< "$FILES"
  echo "[evolve] 合入 $BRANCH(车道: $LANE)文件: $(echo "$FILES" | tr '\n' ' ')"
  git merge --squash "$BRANCH" || { git merge --abort 2>/dev/null; echo "[evolve] ❌ squash merge 冲突"; return 1; }
  git commit -m "evolve($WEEK): $HYP" -m "verdict: MERGE(见 evolution/runs/$WEEK/verdict.json)" || { echo "[evolve] ❌ commit 失败"; return 1; }
  echo "$LANE" > "$RUN_DIR/lane.txt"
  if [ "$LANE" = "fast" ]; then
    "$EVO/bin/promote.sh" HEAD && log_changelog "$WEEK" "MERGED_PROMOTED" "$HYP" \
      && notify "🧬 会议纪要进化 $WEEK 已合入并晋升生产(快车道)。假设:$HYP"
  else
    "$EVO/bin/promote.sh" --no-switch HEAD && log_changelog "$WEEK" "MERGED_CANARY" "$HYP" \
      && notify "🧬 会议纪要进化 $WEEK 已合入 main 并打金丝雀快照(慢车道,current 未切换)。人工观察后在远端执行 evolution/bin/promote.sh HEAD 切换。假设:$HYP"
  fi
  # 合入后 worktree 可清理
  git worktree remove --force "worktrees/evolve-$WEEK" 2>/dev/null || true
  return 0
}

# ── --apply 分支:人工放行 ─────────────────────────────────────────
if [ "${1:-}" = "--apply" ]; then
  WEEK="${2:?用法: weekly-evolve.sh --apply <week 如 2026-W29>}"
  RUN_DIR="$EVO/runs/$WEEK"
  [ -f "$RUN_DIR/verdict.json" ] || { echo "[evolve] ❌ 无裁决文件: $RUN_DIR/verdict.json"; exit 1; }
  V="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['verdict'])" "$RUN_DIR/verdict.json")"
  [ "$V" = "MERGE" ] || { echo "[evolve] ❌ 裁决是 $V,不是 MERGE,拒绝 apply"; exit 1; }
  apply_merge "$WEEK"; exit $?
fi

# ── 主流程 ─────────────────────────────────────────────────────────
[ -f "$EVO/FROZEN" ] && { echo "[evolve] FROZEN 存在,进化平面已熔断,退出。"; exit 0; }
mkdir -p "$BASE_DIR/_logs"
exec 8>"$BASE_DIR/_logs/.evolution.lock"
flock -n 8 || { echo "[evolve] 已有进化平面任务在跑,退出。"; exit 0; }

WEEK="$(date +%G-W%V)"
RUN_DIR="$EVO/runs/$WEEK"
mkdir -p "$RUN_DIR"
[ -f "$EVO/backlog.yaml" ] || : > "$EVO/backlog.yaml"
echo "[evolve] ══ 周进化 $WEEK 开始 $(date '+%F %T') ══"

# 幂等:本周已有裁决则不重跑
[ -f "$RUN_DIR/verdict.json" ] && { echo "[evolve] 本周已有裁决,退出(人工放行用 --apply $WEEK)。"; exit 0; }

# ── Step 1: Planner ────────────────────────────────────────────────
PLANNER_PROMPT="$(python3 - "$ROOT" "$WEEK" <<'PYEOF'
import glob, os, sys
root, week = sys.argv[1], sys.argv[2]
evo = os.path.join(root, "evolution")
def read(p, limit=60000):
    try: return open(p, encoding="utf-8").read()[:limit]
    except Exception: return "(缺失)"
parts = [read(os.path.join(evo, "prompts", "planner.md")),
         f"\n\n---\n\n## 本轮 ISO 周号\n\n{week}\n",
         "\n---\n\n## policy.md\n\n" + read(os.path.join(evo, "policy.md")),
         "\n---\n\n## backlog.yaml\n\n" + (read(os.path.join(evo, "backlog.yaml")) or "(空)")]
reports = sorted(glob.glob(os.path.join(evo, "eval-reports", "*.json")))[-7:]
parts.append("\n---\n\n## 近 7 份评估报告\n")
if reports:
    for r in reports:
        parts.append(f"\n### {os.path.basename(r)}\n\n```json\n{read(r, 20000)}\n```\n")
else:
    parts.append("\n(暂无评估报告——证据不足时请输出 NO_ACTION)\n")
print("".join(parts))
PYEOF
)"
echo "[evolve] Step1 Planner…"
run_llm "$PLANNER_PROMPT" "$RUN_DIR/planner.raw.txt"
if ! extract_json "$RUN_DIR/planner.raw.txt" "===CONTRACT_JSON===" "$RUN_DIR/contract.json"; then
  echo "[evolve] ❌ Planner 输出解析失败,本周终止(原始输出: $RUN_DIR/planner.raw.txt)"
  log_changelog "$WEEK" "PLANNER_FAILED" "-"
  exit 1
fi
HYP="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('hypothesis',''))" "$RUN_DIR/contract.json")"
NFILES="$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1])).get('change_scope',{}).get('files',[])))" "$RUN_DIR/contract.json")"
echo "[evolve] 合约: $HYP(改 $NFILES 个文件)"
case "$HYP" in NO_ACTION*|no_action*)
  echo "[evolve] Planner 判定本周无可靠改进,空转。"
  log_changelog "$WEEK" "NO_ACTION" "$HYP"
  exit 0
esac
[ "$NFILES" -ge 1 ] || { echo "[evolve] 合约无声明文件,按 NO_ACTION 处理。"; log_changelog "$WEEK" "NO_ACTION" "$HYP"; exit 0; }

# ── Step 2: worktree + Generator ──────────────────────────────────
WT="$ROOT/worktrees/evolve-$WEEK"
BRANCH="evolve/$WEEK"
if [ ! -d "$WT" ]; then
  git worktree add "$WT" -b "$BRANCH" 2>>"$RUN_DIR/git.log" || \
  git worktree add "$WT" "$BRANCH" 2>>"$RUN_DIR/git.log" || \
  { echo "[evolve] ❌ worktree 创建失败"; log_changelog "$WEEK" "WORKTREE_FAILED" "$HYP"; exit 1; }
fi
GEN_PROMPT="$(python3 - "$ROOT" "$RUN_DIR/contract.json" <<'PYEOF'
import os, sys
root, cpath = sys.argv[1], sys.argv[2]
evo = os.path.join(root, "evolution")
def read(p):
    try: return open(p, encoding="utf-8").read()
    except Exception: return "(缺失)"
print(read(os.path.join(evo, "prompts", "generator.md")),
      "\n\n---\n\n## 本轮进化合约\n\n```json\n", read(cpath),
      "\n```\n\n---\n\n## policy.md\n\n", read(os.path.join(evo, "policy.md")), sep="")
PYEOF
)"
echo "[evolve] Step2 Generator(worktree: $WT)…"
run_llm "$GEN_PROMPT" "$RUN_DIR/generator.raw.txt" "$WT"
DIFF="$(git diff "main...$BRANCH" 2>/dev/null || git diff "master...$BRANCH" 2>/dev/null || true)"
if [ -z "$DIFF" ]; then
  echo "[evolve] ❌ Generator 未产生任何已提交改动,本周 REJECT。"
  backlog_reject "$WEEK" "$HYP" "generator 未产出 commit"
  log_changelog "$WEEK" "REJECTED" "$HYP"
  exit 1
fi
printf '%s\n' "$DIFF" > "$RUN_DIR/diff.patch"

# ── Step 3: 回归双跑(旧=仓库根/main,新=worktree) ────────────────
echo "[evolve] Step3 回归双跑…"
"$EVO/bin/regression.sh" "$ROOT" "$EVO/golden" "$RUN_DIR/regression_main.json" > "$RUN_DIR/regression_main.log" 2>&1 || true
"$EVO/bin/regression.sh" "$WT"   "$EVO/golden" "$RUN_DIR/regression_new.json"  > "$RUN_DIR/regression_new.log"  2>&1 || true

# ── Step 4: Evaluator ─────────────────────────────────────────────
EVAL_PROMPT="$(python3 - "$ROOT" "$RUN_DIR" "$WT" <<'PYEOF'
import os, sys
root, run, wt = sys.argv[1], sys.argv[2], sys.argv[3]
evo = os.path.join(root, "evolution")
def read(p, limit=80000):
    try: return open(p, encoding="utf-8").read()[:limit]
    except Exception: return "(缺失)"
print(read(os.path.join(evo, "prompts", "evaluator.md")),
      "\n\n---\n\n## 进化合约\n\n```json\n", read(os.path.join(run, "contract.json")),
      "\n```\n\n## diff(main...evolve 分支)\n\n```diff\n", read(os.path.join(run, "diff.patch")),
      "\n```\n\n## regression_main.json(旧版基线)\n\n```json\n", read(os.path.join(run, "regression_main.json")),
      "\n```\n\n## regression_new.json(新版)\n\n```json\n", read(os.path.join(run, "regression_new.json")),
      "\n```\n\n## policy.md\n\n", read(os.path.join(evo, "policy.md")),
      "\n\n## Generator implementation.md(不采信其结论)\n\n", read(os.path.join(wt, "implementation.md")), sep="")
PYEOF
)"
echo "[evolve] Step4 Evaluator…"
run_llm "$EVAL_PROMPT" "$RUN_DIR/evaluator.raw.txt"
if ! extract_json "$RUN_DIR/evaluator.raw.txt" "===VERDICT_JSON===" "$RUN_DIR/verdict.json"; then
  echo "[evolve] ❌ Evaluator 输出解析失败 → 按 REJECT 处理(默认拒绝)。"
  printf '{"verdict":"REJECT","gates":[],"note":"evaluator output unparsable"}\n' > "$RUN_DIR/verdict.json"
fi
VERDICT="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('verdict','REJECT'))" "$RUN_DIR/verdict.json")"
echo "[evolve] 裁决: $VERDICT"

# ── Step 5: 分流 ──────────────────────────────────────────────────
if [ "$VERDICT" = "MERGE" ]; then
  if [ -f "$EVO/HUMAN_GATE" ]; then
    log_changelog "$WEEK" "MERGE_PENDING_HUMAN" "$HYP"
    # 免 ssh 放行通道:启动飞书指令监听器(订阅用户发给机器人的消息,72h 有效)
    nohup "$EVO/bin/approval-listener.sh" "$WEEK" >> "$RUN_DIR/listener.log" 2>&1 &
    notify "🧬 会议纪要进化 $WEEK 验收通过(MERGE),等待人工放行。假设:$HYP。
👉 直接回复本机器人「同意 $WEEK」立即合入,或「拒绝 $WEEK」放弃(72 小时内有效);
也可远端执行 evolution/bin/weekly-evolve.sh --apply $WEEK。产物:evolution/runs/$WEEK/"
    echo "[evolve] HUMAN_GATE 存在,已通知并启动飞书指令监听器,等待人工放行 $WEEK。"
  else
    apply_merge "$WEEK" || { log_changelog "$WEEK" "MERGE_APPLY_FAILED" "$HYP"; exit 1; }
  fi
else
  REASON="$(python3 -c "
import json,sys
v=json.load(open(sys.argv[1]))
fails=[g for g in v.get('gates',[]) if g.get('verdict')!='PASS']
print('; '.join(f\"{g.get('id')}:{g.get('evidence','')[:80]}\" for g in fails) or v.get('note','unspecified'))" "$RUN_DIR/verdict.json" 2>/dev/null || echo unspecified)"
  backlog_reject "$WEEK" "$HYP" "$REASON"
  log_changelog "$WEEK" "REJECTED" "$HYP"
  notify "🧬 会议纪要进化 $WEEK 验收未通过(REJECT),worktree 保留待查:worktrees/evolve-$WEEK。原因:$REASON"
  echo "[evolve] REJECT,worktree 保留: $WT"
fi
echo "[evolve] ══ 周进化 $WEEK 结束 $(date '+%F %T') ══"
exit 0
