#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""authenticate.py — PDL-RO 认证判决

用法: python scripts/authenticate.py <现场测量CSV> [声称身份]
  模板: logs/db_templates/ 下所有已注册板 (随机挑战档, 256 对)
  判决: 对每个模板算 HD; 若给了声称身份, 只对该身份判 ACCEPT/REJECT (门限 10%);
        否则做身份识别 (报告最近模板, 距离 >门限 视为未知设备 REJECT)
"""
import sys, csv, os, glob

THRESH = 10.0   # 可靠档: 正版复测 HD ~0.8%, 冒充 ~20%, 门限 10%

def load_live(p):
    d = {}
    for row in csv.reader(open(p, newline='', encoding='utf-8', errors='ignore')):
        if row and row[0] == 'resp':
            d[int(row[2])] = int(row[3], 16) & 1
    return d

def load_template(p):
    d = {}
    for row in csv.reader(open(p, newline='', encoding='utf-8', errors='ignore')):
        if row and row[0] == 'resp' and int(row[1]) == 0:
            d[int(row[2])] = int(row[3], 16) & 1
    return d

def main():
    live = load_live(sys.argv[1])
    claim = sys.argv[2] if len(sys.argv) > 2 else None
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    tdir = os.path.join(root, 'logs', 'db_templates')
    results = []
    for tf in sorted(glob.glob(os.path.join(tdir, 'pdlro_*.csv'))):
        name = os.path.basename(tf).replace('pdlro_', '').replace('.csv', '')
        t = load_template(tf)
        common = [i for i in live if i in t]
        hd = 100 * sum(live[i] != t[i] for i in common) / len(common)
        results.append((name, hd, len(common)))
    print("=" * 56)
    print("PUF 认证判决  (可靠档: 随机挑战 256 对, 门限 %.0f%%)" % THRESH)
    print("=" * 56)
    for name, hd, n in results:
        print("  vs 模板 %-10s : HD = %5.2f%%  (%d 位)" % (name, hd, n))
    print("-" * 56)
    if claim:
        hit = [(n, h) for n, h, _ in results if n == claim]
        if not hit:
            print("  声称身份 %s 无注册模板" % claim); return 1
        h = hit[0][1]
        if h <= THRESH:
            print("  判决: ACCEPT  — 现场板与声称身份 %s 匹配 (HD %.2f%% <= %.0f%%)" % (claim, h, THRESH))
            return 0
        else:
            print("  判决: REJECT  — 现场板冒充 %s (HD %.2f%% > %.0f%%)" % (claim, h, THRESH))
            return 1
    else:
        best = min(results, key=lambda r: r[1])
        if best[1] <= THRESH:
            print("  识别: 现场板 = %s (HD %.2f%%)  ACCEPT" % (best[0], best[1]))
            return 0
        else:
            print("  识别: 未知设备 (最近模板 %s HD %.2f%% > %.0f%%)  REJECT" % (best[0], best[1], THRESH))
            return 1

if __name__ == '__main__':
    sys.exit(main())
