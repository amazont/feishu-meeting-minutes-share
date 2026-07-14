#!/bin/bash
# daily-eval.sh — 评估平面每日入口(cron 22:35)。
# 对当天已发布的纪要逐篇跑 Meta-Evaluator 盲评复评 → 汇总 eval-report → golden 候选采样。
# 用法: daily-eval.sh [YYYY-MM-DD]   默认今天。
# 铁律:任何单篇失败不中断整体;FROZEN 存在即整体退出;绝不写生产数据目录(只读消费)。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EVO="$ROOT/evolution"
DAY="${1:-$(date +%F)}"

# 0) 熔断与锁
[ -f "$EVO/FROZEN" ] && { echo "[daily-eval] FROZEN 存在,进化/评估平面已熔断,退出。"; exit 0; }
BASE_DIR="$(bash -c "source '$ROOT/config.sh'; printf %s \"\$BASE_DIR\"" 2>/dev/null)"
[ -n "$BASE_DIR" ] || { echo "[daily-eval] ❌ 读不到 BASE_DIR"; exit 1; }
mkdir -p "$BASE_DIR/_logs"
exec 8>"$BASE_DIR/_logs/.evolution.lock"
flock -n 8 || { echo "[daily-eval] 已有进化平面任务在跑,跳过本轮。"; exit 0; }

MINUTE_HOST="$(bash -c "source '$ROOT/config.sh'; printf %s \"\$MINUTE_HOST\"" 2>/dev/null || true)"
RUNS="$EVO/runs/daily/$DAY"
TRANS_DIR="$RUNS/transcripts"
PROMPT_TPL="$EVO/prompts/meta-evaluator/prompt.md"
mkdir -p "$RUNS" "$TRANS_DIR" "$EVO/eval-reports" "$EVO/golden/cases"
[ -f "$PROMPT_TPL" ] || { echo "[daily-eval] ❌ 缺 meta-evaluator prompt: $PROMPT_TPL"; exit 1; }

# 运行器优先 sc(stepcode),否则 claude(与生产 run.sh 同序;远端 claude 可能未登录)
run_llm() {  # $1=prompt文本 $2=输出文件
  if command -v sc >/dev/null 2>&1; then
    timeout 1500 sc claude -p "$1" --permission-mode bypassPermissions > "$2" 2>&1
  elif command -v claude >/dev/null 2>&1; then
    timeout 1500 claude -p "$1" --permission-mode bypassPermissions > "$2" 2>&1
  else
    echo "no claude/sc available" > "$2"; return 127
  fi
}

# 1) 拿当天已发布纪要清单(TSV: token\ttitle):_result.json 优先,台账兜底合并
LIST="$(python3 - "$DAY" "$BASE_DIR" <<'PYEOF'
import json, os, sys
day, base = sys.argv[1], sys.argv[2]
rows, seen = [], set()
try:
    r = json.load(open(os.path.join(base, day, "_result.json"), encoding="utf-8"))
    for d in r.get("docs", []):
        u = str(d.get("url", ""))
        if u and not u.startswith("dryrun://") and d.get("token") not in seen:
            seen.add(d["token"]); rows.append((d["token"], d.get("title", "")))
except Exception:
    pass
try:
    for line in open(os.path.join(base, ".loop-engine", "processed.tsv"), encoding="utf-8"):
        p = line.rstrip("\n").split("\t")
        if len(p) >= 6 and p[1] == day and p[5] == "DONE" and p[0] not in seen:
            seen.add(p[0]); rows.append((p[0], p[2]))
except Exception:
    pass
for t, title in rows:
    print(f"{t}\t{title}")
PYEOF
)"
if [ -z "$LIST" ]; then
  echo "[daily-eval] $DAY 无已发布纪要,写空报告后退出。"
  python3 "$EVO/bin/eval_report.py" "$DAY" "$ROOT" "$BASE_DIR" || true
  python3 - "$EVO/state.json" <<'PYEOF' || true
import json, sys, datetime
p = sys.argv[1]
try: s = json.load(open(p, encoding="utf-8"))
except Exception: s = {}
s["last_daily_eval"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
json.dump(s, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PYEOF
  exit 0
fi

# 2) 逐篇跑 Meta-Evaluator
OK=0; FAIL=0
while IFS=$'\t' read -r TOKEN TITLE; do
  [ -n "$TOKEN" ] || continue
  echo "[daily-eval] ── $TOKEN 「$TITLE」"
  # 2a) 匹配草稿文件:先 safe(title) 子串匹配,再 H1 内容匹配
  DRAFT="$(python3 - "$BASE_DIR/$DAY" "$DAY" "$TITLE" <<'PYEOF'
import os, re, sys
d, day, title = sys.argv[1], sys.argv[2], sys.argv[3]
safe = re.sub(r'[\\/:*?"<>|\s]+', "_", title)[:40]
cands = sorted(f for f in os.listdir(d) if f.startswith(day + "_") and f.endswith(".md")) if os.path.isdir(d) else []
for f in cands:
    if safe and safe in f:
        print(os.path.join(d, f)); sys.exit(0)
key = re.sub(r'\s+', "", title)
for f in cands:
    try: h1 = open(os.path.join(d, f), encoding="utf-8").readline()
    except Exception: continue
    if key and key in re.sub(r'\s+', "", h1):
        print(os.path.join(d, f)); sys.exit(0)
PYEOF
)"
  if [ -z "$DRAFT" ] || [ ! -f "$DRAFT" ]; then
    echo "[daily-eval] ⚠️ warn: 匹配不到草稿文件,跳过 $TOKEN(title=$TITLE)"
    FAIL=$((FAIL+1)); continue
  fi
  OUT_JSON="$RUNS/$TOKEN.json"
  [ -s "$OUT_JSON" ] && { echo "[daily-eval] 已有复评结果,跳过。"; OK=$((OK+1)); continue; }
  # 2b) 组装 prompt(占位符替换)
  SAVE_PATH="$TRANS_DIR/$TOKEN.md"
  HINT="运行 lark-cli vc +notes --minute-tokens $TOKEN --format json"
  PROMPT="$(python3 - "$PROMPT_TPL" "$TOKEN" "$DRAFT" "$HINT" "$SAVE_PATH" <<'PYEOF'
import sys
tpl = open(sys.argv[1], encoding="utf-8").read()
for k, v in zip(("{{TOKEN}}", "{{DRAFT_PATH}}", "{{TRANSCRIPT_HINT}}", "{{TRANSCRIPT_SAVE_PATH}}"), sys.argv[2:6]):
    tpl = tpl.replace(k, v)
print(tpl)
PYEOF
)"
  RAW="$RUNS/$TOKEN.raw.txt"
  run_llm "$PROMPT" "$RAW" < /dev/null   # 重定向 stdin,防止 LLM CLI 吞掉 while-read 的清单
  RC=$?
  # 2c) 解析哨兵行 JSON(兼容同行/次行两种输出)
  python3 - "$RAW" "$OUT_JSON" "$TOKEN" <<'PYEOF'
import json, sys
raw, out, token = sys.argv[1], sys.argv[2], sys.argv[3]
MARK = "===META_EVAL_JSON==="
obj = None
try:
    lines = open(raw, encoding="utf-8").read().splitlines()
    for i, ln in enumerate(lines):
        if MARK in ln:
            rest = ln.split(MARK, 1)[1].strip()
            cand = rest if rest.startswith("{") else (lines[i+1].strip() if i+1 < len(lines) else "")
            try:
                o = json.loads(cand)
                if isinstance(o, dict) and "score" in o:
                    obj = o  # 取最后一个哨兵(防 prompt 示例被回显)
            except Exception:
                pass
except Exception:
    pass
if obj is None:
    sys.exit(3)
obj["token"] = obj.get("token") or token
json.dump(obj, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PYEOF
  if [ $? -eq 0 ]; then
    echo "[daily-eval] ✅ 复评落盘 $OUT_JSON"
    OK=$((OK+1))
  else
    echo "[daily-eval] ⚠️ warn: 复评输出解析失败(rc=$RC),原始输出留在 $RAW"
    FAIL=$((FAIL+1))
  fi
done <<< "$LIST"

# 3) 汇总日报
python3 "$EVO/bin/eval_report.py" "$DAY" "$ROOT" "$BASE_DIR" || echo "[daily-eval] ⚠️ eval_report 失败"

# 4) golden 候选采样:meta 分最高 + 最低各 1 篇(逐字稿存档 + 草稿作 reference)
python3 - "$DAY" "$ROOT" "$BASE_DIR" <<'PYEOF' || echo "[daily-eval] ⚠️ golden 采样失败"
import json, os, re, shutil, sys, datetime
day, root, base = sys.argv[1], sys.argv[2], sys.argv[3]
runs = os.path.join(root, "evolution", "runs", "daily", day)
trans = os.path.join(runs, "transcripts")
gdir = os.path.join(root, "evolution", "golden")
cases_dir = os.path.join(gdir, "cases")
os.makedirs(cases_dir, exist_ok=True)
report_p = os.path.join(root, "evolution", "eval-reports", f"{day}.json")
try:
    report = json.load(open(report_p, encoding="utf-8"))
except Exception:
    sys.exit(0)
scored = [m for m in report.get("minutes", []) if m.get("meta")]
if not scored:
    sys.exit(0)
scored.sort(key=lambda m: m["meta"]["score"])
picks = {scored[0]["token"]: scored[0]}
picks[scored[-1]["token"]] = scored[-1]
idx_p = os.path.join(gdir, "index.json")
try:
    idx = json.load(open(idx_p, encoding="utf-8"))
except Exception:
    idx = {"cases": []}
known = {c["token"] for c in idx["cases"]}
def find_draft(title):
    d = os.path.join(base, day)
    if not os.path.isdir(d): return None
    safe = re.sub(r'[\\/:*?"<>|\s]+', "_", title)[:40]
    for f in sorted(os.listdir(d)):
        if f.startswith(day + "_") and f.endswith(".md") and safe in f:
            return os.path.join(d, f)
    return None
added = 0
for tok, m in picks.items():
    if tok in known: continue
    src_t = os.path.join(trans, f"{tok}.md")
    src_d = find_draft(m.get("title", ""))
    if not (os.path.isfile(src_t) and src_d): continue
    cdir = os.path.join(cases_dir, tok)
    os.makedirs(cdir, exist_ok=True)
    shutil.copy(src_t, os.path.join(cdir, "transcript.md"))
    shutil.copy(src_d, os.path.join(cdir, "reference.md"))
    meta = {"token": tok, "title": m.get("title", ""), "status": "candidate",
            "source_date": day, "meta_score": m["meta"]["score"]}
    json.dump(meta, open(os.path.join(cdir, "meta.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=2)
    idx["cases"].append(meta)
    added += 1
idx["updated_at"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
json.dump(idx, open(idx_p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print(f"[daily-eval] golden 采样入库 {added} 篇(累计 {len(idx['cases'])})")
PYEOF

# 5) 状态戳
python3 - "$EVO/state.json" <<'PYEOF' || true
import json, sys, datetime
p = sys.argv[1]
try: s = json.load(open(p, encoding="utf-8"))
except Exception: s = {}
s["last_daily_eval"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
json.dump(s, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PYEOF

echo "[daily-eval] 完成:$DAY 复评成功 $OK 篇 / 失败 $FAIL 篇。"
exit 0
