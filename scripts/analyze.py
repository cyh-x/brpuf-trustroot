#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""analyze.py — Strong PUF (4x4 APUF) 板上 CRP 指标分析

口径 (分母显式):
  uniqueness (NIST) = mean over 板对(i<j) of HD(resp_i, resp_j) / (6*n_chal)
                      同一挑战集 (固定种子) 双板对比; 理想 50%
  reliability       = 1 - mean over 同板 run 对 of HD / (6*n_chal)   (批间噪声)
  uniformity        = HW(resp) / (6*n_chal)  每板每 run 单独报        (理想 50%)
  unstable_ratio    = popcount(UNST 掩码) / (6*n_chal)  R 次表决内不稳定位占比
  注: 6 个 mutual_order 位编码 24 种排序, 有效信息 ~4.58 bit/挑战,
      6bit 口径的 HD 上界略低于 50%*(6/6); 排序码距离另报 (order-code HD / n_chal)

用法:
  python scripts/analyze.py logs/spuf_eval_b1.csv logs/spuf_eval_b2.csv ...
"""
import sys
import csv
import itertools

N_RACE = 6


def popcount(x):
    return bin(x).count("1")


def parse(path):
    board, chals, resp, single = None, {}, {}, []
    run_set = set()
    with open(path, newline="") as f:
        for row in csv.reader(f):
            if not row:
                continue
            if row[0] == "meta" and row[1] == "board":
                board = row[2]
            elif row[0] == "chal":
                chals[int(row[1])] = [int(w, 16) for w in row[2:6]]
            elif row[0] == "resp":
                u, i, w = int(row[1]), int(row[2]), int(row[3], 16)
                resp[(u, i)] = w
                run_set.add(u)
            elif row[0] == "single":
                single.append(int(row[2], 16))
    return {"board": board or path, "chals": chals, "resp": resp,
            "runs": sorted(run_set), "single": single}


def main(files):
    chips = [parse(p) for p in files]
    n_chal = max(len(c["chals"]) for c in chips)
    bits_total = N_RACE * n_chal

    print("=" * 72)
    print("Strong PUF (4x4 APUF) AX7020 CRP metrics   n_chal=%d  race_bits=%d  total=%d bits"
          % (n_chal, N_RACE, bits_total))
    print("=" * 72)

    def vec(chip, run):
        v = 0
        for i in range(n_chal):
            w = chip["resp"].get((run, i), 0)
            v |= (w & 0x3F) << (N_RACE * i)
        return v

    def vec_unst(chip, run):
        v = 0
        for i in range(n_chal):
            w = chip["resp"].get((run, i), 0)
            v |= ((w >> N_RACE) & 0x3F) << (N_RACE * i)
        return v

    print("\n[per-board] reliability (intra-chip, run-pairwise vote-HD / %d)" % bits_total)
    for c in chips:
        runs = c["runs"]
        if len(runs) < 2:
            print("  %-12s runs=%d (need >=2)" % (c["board"], len(runs)))
            continue
        hds = [popcount(vec(c, a) ^ vec(c, b)) for a, b in itertools.combinations(runs, 2)]
        mean_hd = sum(hds) / len(hds)
        uni = popcount(vec(c, runs[0])) / bits_total
        uns = popcount(vec_unst(c, runs[0])) / bits_total
        print("  %-12s runs=%d  mean_run_HD=%7.2f bit  reliability=%6.2f%%  uniformity=%5.2f%%  unstable=%5.2f%%"
              % (c["board"], len(runs), mean_hd, (1 - mean_hd / bits_total) * 100, uni * 100, uns * 100))
        if c["single"]:
            print("               single-shot LAST_RAW: %s"
                  % " ".join("%08X" % s for s in c["single"]))

    voted = [c for c in chips if c["runs"]]
    if len(voted) >= 2:
        print("\n[uniqueness] inter-chip, same challenge set, run-0 vote vectors (NIST, ideal 50%)")
        hds = []
        for a, b in itertools.combinations(voted, 2):
            va, vb = vec(a, a["runs"][0]), vec(b, b["runs"][0])
            d = popcount(va ^ vb)
            hds.append(d)
            print("  %-12s vs %-12s HD=%5d bit = %5.2f%%" % (a["board"], b["board"], d, d / bits_total * 100))
        u = sum(hds) / len(hds) / bits_total
        print("  => uniqueness = %.2f%% (pairs=%d, denominator=%d bits)"
              % (u * 100, len(hds), bits_total))
        print("     (6 mutual-order 位含 ~4.58 bit 独立信息, 50% 理想值按此口径略降)")
        if 0.40 <= u <= 0.60:
            print("  => PASS (40-60% acceptance band)")
        else:
            print("  => outside 40-60% band")
    else:
        print("\n[uniqueness] need >=2 board CSVs with resp rows, got %d" % len(voted))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1:])
