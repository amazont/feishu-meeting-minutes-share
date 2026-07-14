#!/bin/bash
# regression.sh — golden set 离线回归:对指定代码目录逐 case 跑离线 workflow,汇总打分。
# 用法: regression.sh <code_dir> <golden_dir> <out_json>
#   code_dir   被测代码目录(仓库根或 worktree),需含 daily-meeting-minutes.js 与 config/checker-rubric.md
#   golden_dir golden 目录(evolution/golden 或直接是 cases/ 的父目录)
#   out_json   汇总结果输出路径 {cases:[{token,ok,score,verdict}],pass_l0,avg_score}
# 铁律:单 case 失败不中断;dry-run 离线模式,绝不触网发布/通知。
set -uo pipefail
CODE_DIR="${1:?用法: regression.sh <code_dir> <golden_dir> <out_json>}"
GOLDEN_DIR="${2:?缺 golden_dir}"
OUT_JSON="${3:?缺 out_json}"

JS="$CODE_DIR/daily-meeting-minutes.js"
RUBRIC="$CODE_DIR/config/checker-rubric.md"
[ -f "$JS" ] || { echo "[regression] ❌ 缺 $JS"; exit 1; }
CASES_DIR="$GOLDEN_DIR/cases"; [ -d "$CASES_DIR" ] || CASES_DIR="$GOLDEN_DIR"

WORK="$(mktemp -d /tmp/regression.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

run_llm() {
  if command -v sc >/dev/null 2>&1; then
    timeout 1800 sc claude -p "$1" --permission-mode bypassPermissions
  elif command -v claude >/dev/null 2>&1; then
    timeout 1800 claude -p "$1" --permission-mode bypassPermissions
  else
    echo "no claude/sc available"; return 127
  fi
}

ROWS="$WORK/rows.ndjson"; : > "$ROWS"
FOUND=0
for CDIR in "$CASES_DIR"/*/; do
  [ -d "$CDIR" ] || continue
  TOKEN="$(basename "$CDIR")"
  [ -f "$CDIR/transcript.md" ] || { echo "[regression] ⚠️ $TOKEN 缺 transcript.md,跳过"; continue; }
  FOUND=$((FOUND+1))
  IN="$WORK/in-$TOKEN"; OUT="$WORK/out-$TOKEN"
  mkdir -p "$IN/$TOKEN" "$OUT"
  cp "$CDIR/transcript.md" "$IN/$TOKEN/transcript.md"
  [ -f "$CDIR/meta.json" ] && cp "$CDIR/meta.json" "$IN/$TOKEN/meta.json"
  echo "[regression] ── case $TOKEN"
  ARGS="{\"scriptPath\":\"$JS\",\"args\":{\"localDir\":\"$OUT\",\"offlineInput\":\"$IN\",\"dryRun\":true,\"rubricFile\":\"$RUBRIC\"}}"
  run_llm "用 Workflow 工具运行 $ARGS。完成后简要汇报。" > "$WORK/run-$TOKEN.log" 2>&1 < /dev/null
  python3 - "$OUT/_result.json" "$TOKEN" >> "$ROWS" <<'PYEOF'
import json, sys
path, token = sys.argv[1], sys.argv[2]
row = {"token": token, "ok": False, "score": 0, "verdict": "NO_RESULT"}
try:
    r = json.load(open(path, encoding="utf-8"))
    docs = r.get("docs", [])
    d = next((x for x in docs if x.get("token") == token), docs[0] if docs else None)
    if d and str(d.get("url", "")).startswith("dryrun://"):
        row = {"token": token, "ok": True, "score": float(d.get("score", 0) or 0),
               "verdict": d.get("verdict", "?")}
    elif d:
        row = {"token": token, "ok": False, "score": float(d.get("score", 0) or 0),
               "verdict": d.get("verdict", "BLOCKED")}
except Exception as e:
    row["verdict"] = f"ERROR:{type(e).__name__}"
print(json.dumps(row, ensure_ascii=False))
PYEOF
done

[ "$FOUND" -eq 0 ] && echo "[regression] ⚠️ golden 目录无可用 case: $CASES_DIR"

mkdir -p "$(dirname "$OUT_JSON")"
python3 - "$ROWS" "$OUT_JSON" <<'PYEOF'
import json, sys
rows = []
try:
    rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
except Exception:
    pass
oks = [r for r in rows if r["ok"]]
out = {"cases": rows,
       "pass_l0": bool(rows) and all(r["ok"] for r in rows),
       "avg_score": round(sum(r["score"] for r in oks) / len(oks), 1) if oks else 0}
json.dump(out, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print(f"[regression] {len(oks)}/{len(rows)} ok, avg={out['avg_score']}, pass_l0={out['pass_l0']} → {sys.argv[2]}")
PYEOF
exit 0
