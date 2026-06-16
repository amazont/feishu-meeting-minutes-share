#!/usr/bin/env python3
# 去重台账 + 人读 state 维护(确定性,由 run.sh 调用)。两种模式:
#   update_state.py skip   <ledger.tsv> <day> <giveup>
#       打印本次应跳过的 token(逗号分隔):已建文档的(防重复建档,永久跳过)
#       + 当天 BLOCKED 已达 giveup 次的(当天放弃,不再每心跳重试)
#   update_state.py update <result.json> <day> <ledger.tsv> <state.md> <stamp> <minscore> <giveup>
#       读 workflow 的 _result.json → upsert 台账(BLOCKED 累计当天尝试次数)+ 刷新 state.md
#
# 台账列(TSV,每 token 一行,upsert):
#   token  date  title  url  score  verdict  attempts  updated_at
import sys, os, json, re

COLS = ['token', 'date', 'title', 'url', 'score', 'verdict', 'attempts', 'updated_at']


def read_ledger(path):
    rows = {}
    if os.path.exists(path):
        for line in open(path):
            line = line.rstrip('\n')
            if not line:
                continue
            p = line.split('\t')
            while len(p) < len(COLS):
                p.append('')
            d = dict(zip(COLS, p[:len(COLS)]))
            if d['token']:
                rows[d['token']] = d
    return rows


def write_ledger(path, rows):
    with open(path, 'w') as f:
        for d in rows.values():
            f.write('\t'.join(d.get(c, '') for c in COLS) + '\n')


def _attempts(d):
    try:
        return int(d.get('attempts') or 0)
    except ValueError:
        return 0


def cmd_skip(ledger, day, giveup):
    giveup = int(giveup or 3)
    rows = read_ledger(ledger)
    skip = []
    for tok, d in rows.items():
        if d.get('url'):  # 已建文档 → 永久跳过(防重复建档)
            skip.append(tok)
        elif d.get('verdict') == 'BLOCKED' and d.get('date') == day and _attempts(d) >= giveup:
            skip.append(tok)  # 当天 BLOCKED 满 giveup 次 → 当天放弃
    print(','.join(skip))


def cmd_update(result_json, day, ledger, state, stamp, minsc, giveup):
    res = json.load(open(result_json))
    docs = res.get('docs') or []
    blocked = res.get('blocked') or []
    rows = read_ledger(ledger)

    # upsert 台账
    for d in docs:
        tok = d.get('token', '')
        if not tok:
            continue
        prev = rows.get(tok, {})
        title = (d.get('title', '') or '').replace('\t', ' ')
        if d.get('url'):  # 已建文档(DONE 或 待复核)→ 终态,记 url,attempts 保留
            rows[tok] = {'token': tok, 'date': day, 'title': title, 'url': d.get('url', ''),
                         'score': str(d.get('score', '')), 'verdict': d.get('verdict', ''),
                         'attempts': prev.get('attempts', '') or '1', 'updated_at': stamp}
        else:  # BLOCKED → 累计当天尝试次数
            a = _attempts(prev) if prev.get('date') == day else 0
            rows[tok] = {'token': tok, 'date': day, 'title': title, 'url': '',
                         'score': str(d.get('score', '')), 'verdict': 'BLOCKED',
                         'attempts': str(a + 1), 'updated_at': stamp}
    write_ledger(ledger, rows)

    # 本轮无已建文档(纯 BLOCKED / 无新增)→ 不刷 state.md,避免高频心跳撑爆轮次日志
    url_docs = [d for d in docs if d.get('url')]
    if not url_docs:
        gv = int(giveup or 3)
        gave_up = [d for d in docs if not d.get('url') and _attempts(rows.get(d.get('token', ''), {})) >= gv]
        note = f',其中 {len(gave_up)} 篇已达放弃阈值({gv}次)' if gave_up else ''
        print(f'[state] 本轮无已建文档({len(blocked)} BLOCKED{note}),仅更新台账计数,不刷 state')
        return

    count = len(url_docs)
    total = res.get('total', len(docs))

    def crit(ok):
        return '[x]' if ok else '[ ]'
    c1 = (total > 0 and count == total) or total == 0
    c2 = all(d.get('verdict') == 'DONE' for d in docs) if docs else True
    c3 = all(d.get('url') for d in docs) if docs else True
    c4 = c2

    gaps = []
    for d in docs:
        if d.get('verdict') != 'DONE':
            for g in (d.get('gaps') or []):
                gaps.append(f"{d.get('title', '?')}: {g}")

    lines = [f"### Round {stamp}",
             f"- 发现待处理 {total} 篇,成功归档 {count} 篇,阈值 MIN_SCORE={minsc}"]
    for d in docs:
        lines.append(f"- {d.get('title', '?')}: score {d.get('score', '?')}/100 "
                     f"verdict {d.get('verdict', '?')} → {d.get('url') or '(未归档)'}")
    for b in blocked:
        lines.append(f"- ❌ BLOCKED {b.get('title', '?')}: {b.get('reason', '')}")
    round_entry = '\n'.join(lines)

    old_rounds = ''
    if os.path.exists(state):
        t = open(state).read()
        m = re.search(r'## 轮次日志\n(.*?)\n## 当前未决缺口', t, re.S)
        if m:
            old_rounds = m.group(1).strip()
    hist = (round_entry + ('\n\n' + old_rounds if old_rounds else '')).splitlines()
    hist = '\n'.join(hist[:60])

    gaps_block = '\n'.join(f'- {g}' for g in gaps) if gaps else '- (无)'
    blocked_block = ('\n'.join(f"- {b.get('title', '?')}: {b.get('reason', '')}" for b in blocked)
                     if blocked else '- (无)')

    body = f"""# Goal: 每天把当日飞书妙记自动生成达标(score≥{minsc})的 5 维度会议纪要并归档知识库

- 节奏: 由 launchd/cron 心跳触发(见 config.sh 的 SCHED_*)
- 模式: 无人值守
- 状态目录: {os.path.dirname(state)}
- 去重台账: {ledger}

## 停止条件 completion criteria(每次心跳对当日妙记求值)

- {crit(c1)} C1 覆盖度: 当日发现的妙记全部进入处理      ← 验证: Discover token ⊆ 已处理
- {crit(c2)} C2 正确性: 每篇 checker verdict=DONE        ← 验证: checker 打分
- {crit(c3)} C3 可验证性: 每篇已建知识库文档且有 url      ← 验证: docs +create 返回
- {crit(c4)} C4 一致性: Lark-flavored 渲染正常            ← 验证: checker C4

## 轮次日志

{hist}

## 当前未决缺口(下次心跳重试 / 待人复核)

{gaps_block}

## BLOCKED / 待人决策

{blocked_block}
"""
    open(state, 'w').write(body)
    print(f'[state] 台账+state.md 已更新: {count}/{total} 篇已归档, {len(blocked)} 篇 BLOCKED')


def main():
    if len(sys.argv) < 2:
        sys.exit('usage: update_state.py {skip|update} ...')
    mode = sys.argv[1]
    if mode == 'skip':
        cmd_skip(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else '3')
    elif mode == 'update':
        cmd_update(*sys.argv[2:9])
    else:
        sys.exit(f'unknown mode: {mode}')


if __name__ == '__main__':
    main()
