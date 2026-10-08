#!/usr/bin/env python3
"""d1-traffic3.py 結果統計。用法：traffic3-summary.py <前綴> <起 epoch> <迄 epoch>
每組：總請求數、失敗數（非 200，含 NO_HEALTHY_NODE）、最長連續失敗時間（第一筆失敗到最後一筆連續失敗的時間差；單筆失敗記 0.0 秒）、p99（全部請求的耗時）、
     以及健康檢查判定 DOWN 的區間（驗證量具用）。另外：各節點不經健康檢查的最長中斷、API Server 單台最長中斷與三台同時無回應秒數。"""
import csv, sys, datetime as dt
from collections import Counter, defaultdict
pre, T0, T1 = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
f = lambda t: dt.datetime.fromtimestamp(t).strftime('%H:%M:%S')


def rows(kind):
    return [r for r in csv.DictReader(open(f'{pre}.{kind}.tsv'), delimiter='\t') if T0 <= float(r['ts']) <= T1]


def longest(rs, ok):
    best = (0.0, None, None, 0); s = l = None; c = 0
    for r in rs:
        t = float(r['ts'])
        if not ok(r): s = s if s is not None else t; l = t; c += 1
        else:
            if s is not None and (l - s, c) > (best[0], best[3]): best = (l - s, s, l, c)
            s = None; c = 0
    if s is not None and (l - s, c) > (best[0], best[3]): best = (l - s, s, l, c)
    return best


ok200 = lambda r: r['result'] == '200'
for g in 'ABC':
    rs = rows(f'lb-{g}'); bad = [r for r in rs if not ok200(r)]
    ms = sorted(float(r['ms']) for r in rs if r['result'] != 'NO_HEALTHY_NODE')
    p99 = ms[min(len(ms) - 1, int(len(ms) * 0.99))] if ms else 0
    # 三台輪流送，所以「連續失敗」依節點算：同一台從第一筆失敗到最後一筆失敗、中間沒有成功（06 修正：04 版依整條請求序列算，失敗之間夾著別台的成功，會被算成 0 秒）
    pn = [(n, longest([r for r in rs if r['node'] == n], ok200)) for n in sorted({r['node'] for r in rs if r['node'] != '-'})]
    n_, b = max(pn, key=lambda x: (x[1][0], x[1][3])) if pn else ('-', (0.0, None, None, 0))
    print(f'== 組 {g}: 請求 {len(rs)}，失敗 {len(bad)} {dict(Counter(r["result"] for r in bad))}，p99 {p99:.0f} ms；單一節點最長連續失敗 {b[0]:.1f} 秒（{n_}，{b[3]} 筆）'
          + (f' {f(b[1])}~{f(b[2])}' if b[1] else ''))
    print('   失敗分布：' + '、'.join(f'{n} {sum(1 for r in bad if r["node"] == n)} 筆' for n in sorted({r['node'] for r in bad})))
    hc = rows(f'hc-{g}'); down = defaultdict(list)
    for r in hc: down[r['node']].append((float(r['ts']), r['state']))
    for n, ev in sorted(down.items()):
        iv = []; s = None
        for t, st in ev:
            if st == 'DOWN' and s is None: s = t
            if st == 'UP' and s is not None: iv.append((s, t)); s = None
        if s is not None: iv.append((s, None))
        if iv: print(f'   健康檢查判定 DOWN：{n} ' + '、'.join(f'{f(a)}~{f(b) if b else "結束"}' for a, b in iv))
nr = rows('node')
print('== 各節點不經健康檢查（每秒 1 筆）')
for n in sorted({r['node'] for r in nr}):
    rs = [r for r in nr if r['node'] == n]; b = longest(rs, ok200)
    print(f'   {n}: 失敗 {sum(not ok200(r) for r in rs)}/{len(rs)}，最長中斷 {b[0]:.1f} 秒' + (f' {f(b[1])}~{f(b[2])}' if b[1] else ''))
ar = rows('api'); okapi = lambda r: r['result'].isdigit()
print('== API Server')
for n in sorted({r['node'] for r in ar}):
    rs = [r for r in ar if r['node'] == n]; b = longest(rs, okapi)
    print(f'   {n}: 無回應 {sum(not okapi(r) for r in rs)}/{len(rs)}，單台最長中斷 {b[0]:.1f} 秒')
bk = defaultdict(dict)
for r in ar: bk[int(float(r['ts']))][r['node']] = okapi(r)
print('   三台同時無回應秒數:', sum(1 for v in bk.values() if len(v) == 3 and not any(v.values())))
