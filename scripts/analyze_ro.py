#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""analyze_ro.py — 配对型 RO Strong PUF 板上 CRP 指标分析

口径 (分母显式):
  uniqueness (NIST) = mean over 板对(i<j) of HD(vote_i, vote_j) / n_chal   理想 50%
  reliability       = 1 - mean over 同板 run 对 of HD / n_chal             (批间噪声)
  uniformity        = HW(vote) / n_chal   每板每 run 单独报                理想 50%
  unstable_ratio    = popcount(unstable) / n_chal   R 次表决内出现分歧的对占比
  配对距离诊断      |Δcnt|>>8 (w[9:2]) 分布: 太小 => 配对太近易翻; 恒 0 => RO 未起振
  位域: w[0]=vote w[1]=unst w[9:2]=diff_log
        (2026-10-29 修正: rp_wdata={16'd0,diff_log,unst,vote} 是 26 位零扩展,
         旧文档写的 w[15:8] 是错的, diff_log 实际落在 [9:2])

用法: python scripts/analyze_ro.py logs/ropuf_eval_b1.csv logs/ropuf_eval_b2.csv
"""
import sys
import csv
import itertools


def parse(path):
    board, chals, resp, single = None, {}, {}, []
    runs = set()
    with open(path, newline="", encoding="utf-8", errors="ignore") as f:
        for row in csv.reader(f):
            if not row:
                continue
            if row[0] == "meta" and row[1] == "board":
                board = row[2]
            elif row[0] == "chal":
                chals[int(row[1])] = (int(row[2]), int(row[3]))
            elif row[0] == "resp":
                u, i, w = int(row[1]), int(row[2]), int(row[3], 16)
                resp[(u, i)] = w
                runs.add(u)
            elif row[0] == "single":
                single.append(int(row[2], 16))
    return {"board": board or path, "chals": chals, "resp": resp,
            "runs": sorted(runs), "single": single}


def main(files):
    chips = [parse(p) for p in files]
    n_chal = max(len(c["chals"]) for c in chips)

    print("=" * 72)
    print("RO-pair Strong PUF AX7020 CRP metrics   n_chal=%d  resp=1bit/chal" % n_chal)
    print("=" * 72)

    def vec(chip, run):
        return sum(((chip["resp"].get((run, i), 0) & 1) << i) for i in range(n_chal))

    def vec_unst(chip, run):
        return sum((((chip["resp"].get((run, i), 0) >> 1) & 1) << i) for i in range(n_chal))

    print("\n[per-board] reliability (run-pairwise vote-HD / %d)" % n_chal)
    for c in chips:
        runs = c["runs"]
        if len(runs) < 2:
            print("  %-12s runs=%d (need >=2)" % (c["board"], len(runs)))
            continue
        hds = [bin(vec(c, a) ^ vec(c, b)).count("1") for a, b in itertools.combinations(runs, 2)]
        mean_hd = sum(hds) / len(hds)
        uni = bin(vec(c, runs[0])).count("1") / n_chal
        uns = bin(vec_unst(c, runs[0])).count("1") / n_chal
        print("  %-12s runs=%d  mean_run_HD=%6.2f bit  reliability=%6.2f%%  uniformity=%5.2f%%  unstable=%5.2f%%"
              % (c["board"], len(runs), mean_hd, (1 - mean_hd / n_chal) * 100, uni * 100, uns * 100))
        if c["single"]:
            print("               single (RO0 vs RO1): %s" % " ".join("%08X" % s for s in c["single"]))
        # 配对距离诊断: diff_log = |Δcnt|>>8 (w[9:2]), 恒 0 说明两个 RO 计数几乎相同(未起振)
        dlogs = [(c["resp"].get((runs[0], i), 0) >> 2) & 0xFF for i in range(n_chal)]
        dz = sum(1 for d in dlogs if d == 0)
        print("               pair-dist diff_log: min=%d med=%d max=%d  zero=%d/%d"
              % (min(dlogs), sorted(dlogs)[len(dlogs) // 2], max(dlogs), dz, n_chal))

    voted = [c for c in chips if c["runs"]]
    if len(voted) >= 2:
        print("\n[uniqueness] inter-chip, same challenge set (NIST, ideal 50%)")
        hds = []
        for a, b in itertools.combinations(voted, 2):
            va, vb = vec(a, a["runs"][0]), vec(b, b["runs"][0])
            d = bin(va ^ vb).count("1")
            hds.append(d)
            print("  %-12s vs %-12s HD=%4d bit = %5.2f%%" % (a["board"], b["board"], d, d / n_chal * 100))
        u = sum(hds) / len(hds) / n_chal
        print("  => uniqueness = %.2f%% (pairs=%d, denominator=%d)" % (u * 100, len(hds), n_chal))
        if 0.40 <= u <= 0.60:
            print("  => PASS (40-60% acceptance band)")
        else:
            print("  => outside 40-60% band")
    else:
        print("\n[uniqueness] need >=2 board CSVs with resp rows")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1:])
