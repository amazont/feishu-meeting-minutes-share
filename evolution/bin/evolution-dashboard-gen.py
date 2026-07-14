#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""evolution-dashboard-gen.py — 生成进化看板数据 JSON(stdout)。
cron: 21 6 * * *  python3 .../evolution-dashboard-gen.py > /var/www/html/posts/minutes-evolution.data.json

输入(全部尽力而为,缺失不报错):
  evolution/eval-reports/*.json   每日评估报告
  evolution/changelog.jsonl       进化流水
  evolution/runs/<week>/{contract.json,verdict.json,lane.txt}
  evolution/golden/index.json     golden set
  evolution/state.json  evolution/FROZEN  evolution/.promoted_at  releases/current
脱敏:只输出指标与计数,绝不输出纪要正文/gap desc/evidence 原文。
"""
import json, os, sys
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EVO = os.path.join(ROOT, "evolution")
CST = timezone(timedelta(hours=8))

def load_json(p, default=None):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default

def main():
    now = datetime.now(CST)

    # ── trends: 近90天日粒度 ─────────────────────────────────────
    trends = []
    rep_dir = os.path.join(EVO, "eval-reports")
    cutoff = (now - timedelta(days=90)).strftime("%Y-%m-%d")
    if os.path.isdir(rep_dir):
        for fn in sorted(os.listdir(rep_dir)):
            if not fn.endswith(".json"):
                continue
            date = fn[:-5]
            if date < cutoff:
                continue
            r = load_json(os.path.join(rep_dir, fn))
            if not r:
                continue
            mins = r.get("minutes", [])
            metas = [m["meta"]["score"] for m in mins if m.get("meta")]
            cal = r.get("calibration_summary", {}) or {}
            ops = r.get("ops", {}) or {}
            trends.append({
                "date": date,
                "avg_checker_score": ops.get("avg_checker_score", 0),
                "avg_meta_score": round(sum(metas) / len(metas), 1) if metas else None,
                "calibration_delta": cal.get("mean_score_delta") if metas else None,
                "missed_major_gaps": cal.get("total_missed_major_gaps", 0),
                "published": ops.get("published", 0),
                "blocked": ops.get("blocked", 0),
                "output_tokens": ops.get("output_tokens", 0),
                "drift_flag": bool(cal.get("drift_flag")),
            })

    # ── changelog / evolution cards ──────────────────────────────
    cards, markers = [], []
    log_p = os.path.join(EVO, "changelog.jsonl")
    entries = []
    if os.path.isfile(log_p):
        for line in open(log_p, encoding="utf-8"):
            try:
                entries.append(json.loads(line))
            except Exception:
                pass
    # 每周取最新一条状态
    by_week = {}
    for e in entries:
        by_week[e.get("week", "?")] = e
    for week, e in sorted(by_week.items(), reverse=True):
        run = os.path.join(EVO, "runs", week)
        contract = load_json(os.path.join(run, "contract.json"), {}) or {}
        verdict = load_json(os.path.join(run, "verdict.json"), {}) or {}
        lane = ""
        try:
            lane = open(os.path.join(run, "lane.txt"), encoding="utf-8").read().strip()
        except Exception:
            pass
        cards.append({
            "week": week,
            "status": e.get("status", "?"),
            "ts": e.get("ts", ""),
            "hypothesis": e.get("hypothesis", "") or contract.get("hypothesis", ""),
            "change_files": (contract.get("change_scope", {}) or {}).get("files", []),
            "change_type": (contract.get("change_scope", {}) or {}).get("type", ""),
            "expected_improvement": contract.get("expected_improvement", []),
            "gates": [{"id": g.get("id"), "verdict": g.get("verdict")}
                      for g in (verdict.get("gates") or [])],
            "verdict": verdict.get("verdict", ""),
            "lane": lane,
        })
        if str(e.get("status", "")).startswith("MERGED"):
            markers.append({"date": (e.get("ts", "") or "")[:10], "week": week,
                            "label": e.get("hypothesis", "")[:40]})

    # ── golden set ───────────────────────────────────────────────
    gidx = load_json(os.path.join(EVO, "golden", "index.json"), {"cases": []}) or {"cases": []}
    gcases = gidx.get("cases", [])
    golden = {
        "total": len(gcases),
        "candidates": sum(1 for c in gcases if c.get("status") == "candidate"),
        "references": sum(1 for c in gcases if c.get("status") == "reference"),
        "updated_at": gidx.get("updated_at", ""),
    }

    # ── health ───────────────────────────────────────────────────
    state = load_json(os.path.join(EVO, "state.json"), {}) or {}
    promoted_at = ""
    try:
        ts = int(open(os.path.join(EVO, ".promoted_at"), encoding="utf-8").read().strip())
        promoted_at = datetime.fromtimestamp(ts, CST).isoformat(timespec="seconds")
    except Exception:
        pass
    current = ""
    try:
        current = os.readlink(os.path.join(ROOT, "releases", "current"))
    except Exception:
        pass
    health = {
        "frozen": os.path.isfile(os.path.join(EVO, "FROZEN")),
        "human_gate": os.path.isfile(os.path.join(EVO, "HUMAN_GATE")),
        "auto_rollback": os.path.isfile(os.path.join(EVO, "AUTO_ROLLBACK")),
        "last_daily_eval": state.get("last_daily_eval", ""),
        "promoted_at": promoted_at,
        "report_count": len(trends),
        "last_report_date": trends[-1]["date"] if trends else "",
        "rollbacks_90d": sum(1 for e in entries if "ROLLBACK" in str(e.get("status", ""))),
    }

    out = {
        "schema_version": 1,
        "generated_at": now.isoformat(timespec="seconds"),
        "current_release": current,
        "trends": trends,
        "release_markers": markers,
        "evolution_cards": cards,
        "golden_set": golden,
        "health": health,
    }
    json.dump(out, sys.stdout, ensure_ascii=False, indent=1)
    sys.stdout.write("\n")

if __name__ == "__main__":
    main()
