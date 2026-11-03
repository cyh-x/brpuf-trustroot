import paths
import os
# night_report.py — 夜间采集数据汇总分析
# 输出: 各板 ENROLL 稳定性 / AUTH 成功率+nerr分布 / 延迟统计 → 文档可直接引用
import csv, os, sys
from collections import Counter
from datetime import datetime

OUT = paths.NIGHT_DIR
DEVS = ['DEV2', 'DEV5', 'DEV1']

def read(fn):
    path = os.path.join(OUT, fn)
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return list(csv.DictReader(f))

print('=' * 72)
print('夜间采集报告 — v31b 架构, 三节点, 自动采集')
print('=' * 72)

for dev in DEVS:
    en = read('%s_enroll.csv' % dev)
    au = read('%s_auth.csv' % dev)
    print('\n### %s' % dev)
    if en:
        ks = [r['K'] for r in en if r['K'] != 'FAIL']
        fails = len(en) - len(ks)
        cnt = Counter(ks)
        reg = max(cnt, key=cnt.get) if cnt else '?'
        ones = bin(int(reg, 16)).count('1') if reg != '?' else 0
        durs = [int(r['ms']) for r in en if r['ms'].isdigit()]
        print('ENROLL: %d 次 (失败 %d)' % (len(en), fails))
        print('  密钥变体数: %d' % len(cnt))
        for k, c in cnt.most_common(5):
            print('    %s x%d' % (k, c))
        print('  众数密钥 1 位占比: %d/256' % ones)
        bd = [int(r['bitdiff_vs_reg']) for r in en if r['bitdiff_vs_reg'] != '-1']
        if bd:
            print('  与注册密钥位差: min=%d max=%d mean=%.2f 分布=%s' % (
                min(bd), max(bd), sum(bd)/len(bd), dict(Counter(bd))))
        if durs:
            print('  派生延迟: mean=%dms p50=%dms p95=%dms' % (
                sum(durs)//len(durs), sorted(durs)[len(durs)//2], sorted(durs)[int(len(durs)*0.95)]))
        t0, t1 = en[0]['t'], en[-1]['t']
        print('  采集窗口: %s ~ %s' % (t0, t1))
    if au:
        oks = [int(r['ok']) for r in au]
        nerrs = [int(r['nerr']) for r in au if r['nerr'] != '-1']
        durs = [int(r['ms']) for r in au if r['ms'].isdigit()]
        print('AUTH: %d 次, 成功率 %.2f%%' % (len(au), 100.0 * sum(oks) / len(au)))
        print('  设备纠错 nerr 分布: %s (BCH 容量 18)' % dict(Counter(nerrs)))
        if durs:
            print('  认证延迟: mean=%dms p50=%dms p95=%dms' % (
                sum(durs)//len(durs), sorted(durs)[len(durs)//2], sorted(durs)[int(len(durs)*0.95)]))

# 跨板唯一性
print('\n### 跨板唯一性 (众数密钥两两汉明距离/256)')
regs = {}
for dev in DEVS:
    en = read('%s_enroll.csv' % dev)
    ks = [r['K'] for r in en if r['K'] != 'FAIL']
    if ks:
        regs[dev] = Counter(ks).most_common(1)[0][0]
if len(regs) == 3:
    import itertools
    for a, b in itertools.combinations(regs, 2):
        d = bin(int(regs[a], 16) ^ int(regs[b], 16)).count('1')
        print('  %s vs %s: %d/256 = %.1f%%' % (a, b, d, 100.0*d/256))
