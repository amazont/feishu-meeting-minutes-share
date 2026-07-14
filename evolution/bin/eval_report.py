#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""eval_report.py — 汇总某日的生产 checker 结果 + Meta-Evaluator 复评,生成日评估报告。

用法: eval_report.py <date> <repo_root> <base_dir>
输入:
  $base_dir/$date/_result.json                    生产完成契约(可能被静默心跳覆盖为空 docs)
  $base_dir/.loop-engine/processed.tsv            台账兜底(token/date/title/url/score/DONE)
  $repo_root/evolution/runs/daily/$date/*.json    meta-evaluator 每篇输出
输出:
  $repo_root/evolution/eval-reports/$date.json
脱敏:报告只存 gaps 的计数与 criterion 分布,不存 desc/evidence 原文(原文留在 runs/daily)。
"""
import json, os, subprocess, sys
from datetime import datetime, timezone, timedelta

CST = timezone(timedelta(hours=8))

def sh(cmd, cwd=None):
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=30).stdout.strip()
    except Exception:
        return ""

def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None

def main():
    if len(sys.argv) != 4:
        print("usage: eval_report.py <date> <repo_root> <base_dir>", file=sys.stderr)
        return 1
    date, repo, base = sys.argv[1], sys.argv[2], sys.argv[3]
    runs_dir = os.path.join(repo, "evolution", "runs", "daily", date)
    out_dir = os.path.join(repo, "evolution", "eval-reports")
    os.makedirs(out_dir, exist_ok=True)

    # ---- 生产侧: _result.json 优先,台账兜底 ----
    result = load_json(os.path.join(base, date, "_result.json")) or {}
    docs = [d for d in result.get("docs", [])
            if d.get("url") and not str(d["url"]).startswith("dryrun://")]
    ledger_rows = []
    ledger = os.path.join(base, ".loop-engine", "processed.tsv")
    if os.path.exists(ledger):
        with open(ledger, encoding="utf-8") as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) >= 6 and p[1] == date and p[5] == "DONE":
                    ledger_rows.append({"token": p[0], "title": p[2], "url": p[3],
                                        "score": float(p[4]) if p[4].replace(".", "").isdigit() else 0,
                                        "verdict": "DONE", "gaps": []})
    if not docs:
        docs = ledger_rows
    else:
        # _result.json 只反映最后一次有产出的 run;台账里同日其他 DONE 篇合并进来
        seen = {d["token"] for d in docs}
        docs += [r for r in ledger_rows if r["token"] not in seen]

    # ---- meta 侧 ----
    metas = {}
    if os.path.isdir(runs_dir):
        for fn in sorted(os.listdir(runs_dir)):
            if not fn.endswith(".json"):
                continue
            m = load_json(os.path.join(runs_dir, fn))
            if m and m.get("token"):
                metas[m["token"]] = m

    minutes, deltas, missed_major_total = [], [], 0
    for d in docs:
        tok = d["token"]
        checker_score = float(d.get("score", 0) or 0)
        checker_gaps = d.get("gaps", []) or []
        entry = {
            "token": tok,
            "title": d.get("title", ""),
            "checker": {"score": checker_score,
                        "verdict": d.get("verdict", "DONE"),
                        "gap_count": len(checker_gaps)},
        }
        m = metas.get(tok)
        if m:
            gaps = m.get("gaps", []) or []
            major = sum(1 for g in gaps if g.get("severity") == "major")
            meta_score = float(m.get("score", 0) or 0)
            entry["meta"] = {"score": meta_score,
                             "per_criterion": m.get("per_criterion", {}),
                             "gap_count": len(gaps),
                             "major_gap_count": major,
                             "gap_criteria": sorted({g.get("criterion", "?") for g in gaps})}
            # 校准:checker 比 meta 高多少;checker 没抓到的 major gap 数
            delta = checker_score - meta_score
            missed = max(0, major - len(checker_gaps))
            entry["calibration"] = {"score_delta": round(delta, 1),
                                    "missed_gap_count": missed}
            deltas.append(delta)
            missed_major_total += missed
        else:
            entry["meta"] = None
            entry["calibration"] = None
        minutes.append(entry)

    # ---- 运营指标 ----
    scores = [float(d.get("score", 0) or 0) for d in docs]
    ops = {
        "discovered": result.get("total", len(docs)) or len(docs),
        "published": len(docs),
        "blocked": len(result.get("blocked", []) or []),
        "avg_checker_score": round(sum(scores) / len(scores), 1) if scores else 0,
        "output_tokens": result.get("outputTokens", 0) or 0,
    }

    # ---- 校准汇总 + 漂移检测(近7份报告滑动均值) ----
    mean_delta = round(sum(deltas) / len(deltas), 2) if deltas else 0.0
    max_abs = round(max((abs(x) for x in deltas), default=0.0), 2)
    summary = {"mean_score_delta": mean_delta,
               "max_abs_delta": max_abs,
               "total_missed_major_gaps": missed_major_total}
    hist = [mean_delta]
    try:
        reports = sorted(f for f in os.listdir(out_dir)
                         if f.endswith(".json") and f[:-5] != date)
        for fn in reports[-6:]:
            r = load_json(os.path.join(out_dir, fn))
            if r and r.get("calibration_summary") and r.get("minutes"):
                if any(mm.get("calibration") for mm in r["minutes"]):
                    hist.append(r["calibration_summary"]["mean_score_delta"])
    except Exception:
        pass
    sliding = sum(hist) / len(hist) if hist else 0.0
    summary["drift_flag"] = bool(deltas) and abs(sliding) > 8

    report = {
        "schema_version": 1,
        "date": date,
        "generated_at": datetime.now(CST).isoformat(timespec="seconds"),
        "meta_evaluator_version": sh(["git", "log", "-1", "--format=%h", "--",
                                      "evolution/prompts/meta-evaluator/prompt.md"], cwd=repo) or "unknown",
        "production_release": sh(["readlink", os.path.join(repo, "releases", "current")]) or "unknown",
        "ops": ops,
        "minutes": minutes,
        "calibration_summary": summary,
    }
    out = os.path.join(out_dir, f"{date}.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
    print(f"[eval_report] wrote {out} ({len(minutes)} minutes, {len(deltas)} with meta)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
