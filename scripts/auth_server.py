#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""auth_server.py — BR-PUF 多板认证系统会话编排 (服务器端)

用法:
  python scripts/auth_server.py --cable 210512180081 [--claim b5] [--seed 自动] [--k 256]

消耗制 CRP 模型 (经典 strong PUF 认证):
  - 每设备维护 CRP 台账 (logs/auth_db/pool_<dev>.json): 已消耗挑战索引集合
  - 每次会话从未消耗池抽 K 个 -> 该批 CRP 用后即弃, 永不复用
  - 攻击者录制任意多场历史会话也无法回答新会话 (挑战集不相交)
  - 池耗尽前可认证次数 = 池大小 / K; 扩池 = 注册期多批次测量 (空间上限 2^21)

流程 (每次会话):
  1. 从该设备未消耗 CRP 池抽 K 个 -> 会话挑战文件
  2. 调 xsdb 现场测量 (brpuf2 位流, 15 票表决)
  3. 与模板库比对 (只在会话子集上比) -> 判决
     - 声称身份: ACCEPT / REJECT (门限 7%, 按 5 板校准: 正版<=1.1%, 最差冒充 11.1%)
     - 无声称: 自动识别 (最近模板且 <= 门限 -> 身份; 否则未知设备)
  4. 会话记录追加 logs/auth_sessions.log
"""
import argparse, csv, glob, os, random, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
XSDB = os.environ.get("XSDB_BIN", "xsdb")
CHAL_LIB = os.path.join(ROOT, "logs", "chal_brpuf2_1000.csv")
DB_DIR = os.path.join(ROOT, "logs", "auth_db")
THRESH = 7.0
NCHAL_LIB = 1000

def load_lib():
    lib = {}
    for line in open(CHAL_LIB):
        line = line.strip()
        if not line or line[0] in "#i":
            continue
        i, v = line.split(",")
        lib[int(i)] = int(v)
    return lib

def load_templates():
    t = {}
    for f in sorted(glob.glob(os.path.join(DB_DIR, "brpuf_*.csv"))):
        name = os.path.basename(f)[6:-4]
        d = {}
        for row in csv.reader(open(f)):
            if row and row[0] == "idx":
                continue
            d[int(row[0])] = int(row[1], 16)
        t[name] = d
    return t

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cable", required=True)
    ap.add_argument("--claim", default=None, help="声称身份, 如 b5; 缺省为自动识别")
    ap.add_argument("--seed", type=int, default=None, help="会话种子 (缺省用时间)")
    ap.add_argument("--k", type=int, default=256, help="会话挑战数")
    ap.add_argument("--no-consume", action="store_true", help="诊断模式: 不消耗 CRP")
    ap.add_argument("--replay", default=None, help="重放攻击模拟: 用历史会话录音代替现场测量")
    args = ap.parse_args()

    seed = args.seed if args.seed is not None else int(time.time())
    rng = random.Random(seed)
    lib = load_lib()
    dev = args.claim if args.claim else "idmode"
    poolf = os.path.join(DB_DIR, "pool_%s.json" % dev)
    import json
    used = set()
    if os.path.exists(poolf):
        used = set(json.load(open(poolf)))
    avail = [i for i in range(NCHAL_LIB) if i not in used]
    if len(avail) < args.k:
        print("CRP 池不足: 剩 %d < K=%d (已消耗 %d)。请扩池注册。" % (len(avail), args.k, len(used)))
        return 1
    idxs = sorted(rng.sample(avail, args.k))
    sf = os.path.join(ROOT, "logs", f"session_{seed}.csv")
    with open(sf, "w") as f:
        f.write("# session challenges seed=%d k=%d\n" % (seed, args.k))
        for i in idxs:
            f.write("%d,%d\n" % (i, lib[i]))

    out = os.path.join(ROOT, "logs", f"live_{seed}.csv")
    if args.replay:
        print("== 重放攻击模拟: 攻击者使用历史录音 %s ==" % args.replay)
        out = args.replay
    else:
        print("== 会话种子 %d | 抽取 %d/%d (未消耗池剩 %d) | 现场测量... ==" % (seed, args.k, NCHAL_LIB, len(avail)))
        r = subprocess.run([XSDB, os.path.join(ROOT, "scripts", "auth_brpuf.tcl"),
                            args.cable, sf, out, "15"],
                           capture_output=True, text=True, encoding='utf-8', errors='ignore', timeout=900)
        if not os.path.exists(out):
            print("测量失败:\n" + r.stdout[-2000:] + r.stderr[-1000:])
            return 1

    live = {}
    for row in csv.reader(open(out, encoding='utf-8', errors='ignore')):
        if row and row[0] == "resp":
            live[int(row[1])] = int(row[2], 16) & 1

    tmpls = load_templates()
    print()
    print("=" * 60)
    print("BR-PUF 多板认证  (会话 %d, %d 挑战, 门限 %.0f%%)" % (seed, args.k, THRESH))
    print("=" * 60)
    results = []
    for name, t in tmpls.items():
        ks = [i for i in live if i in t]
        hd = 100.0 * sum(live[i] != (t[i] & 1) for i in ks) / len(ks)
        results.append((name, hd, len(ks)))
    for name, hd, n in sorted(results, key=lambda r: r[1]):
        flag = "  <- 最近" if name == min(results, key=lambda r: r[1])[0] else ""
        print("  vs 模板 %-4s: HD = %5.2f%%  (%d 位)%s" % (name, hd, n, flag))
    print("-" * 60)

    verdict, ident = "", None
    if args.replay:
        # 覆盖率 = 攻击者录音与本会话挑战集的交集 (消耗制下应为 0)
        cov_idx = [i for i in idxs if i in live]
        covered = len(cov_idx)
        print("  重放覆盖率: 录音能回答 %d/%d 个本会话挑战" % (covered, args.k))
        if covered and args.claim and args.claim in tmpls:
            t = tmpls[args.claim]
            hd = 100.0 * sum(live[i] != (t[i] & 1) for i in cov_idx) / covered
            print("  被覆盖位上的 HD = %.2f%%" % hd)
        verdict = "REJECT-REPLAY"
        print("  判决: REJECT — 重放无效 (消耗制下挑战永不复用, 录音对新会话 %s)" %
              ("完全无用" if covered == 0 else "仅覆盖 %d 位, 其余只能瞎猜" % covered))
        with open(os.path.join(ROOT, "logs", "auth_sessions.log"), "a") as f:
            f.write("%s | seed=%d k=%d claim=%s verdict=%s coverage=%d/%d" %
                    (time.strftime("%Y-%m-%d %H:%M:%S"), seed, args.k, args.claim, verdict, covered, args.k))
            f.write(chr(10))
        return 1
    if args.claim:
        hit = [(n, h) for n, h, _ in results if n == args.claim]
        if not hit:
            print("  声称身份 %s 未注册" % args.claim); return 1
        h = hit[0][1]
        if h <= THRESH:
            verdict = "ACCEPT"; ident = args.claim
            print("  判决: ACCEPT — 现场设备与 %s 匹配 (HD %.2f%% <= %.0f%%)" % (args.claim, h, THRESH))
        else:
            verdict = "REJECT"
            print("  判决: REJECT — 现场设备不是 %s (HD %.2f%% > %.0f%%)" % (args.claim, h, THRESH))
    else:
        best = min(results, key=lambda r: r[1])
        if best[1] <= THRESH:
            verdict = "IDENTIFIED"; ident = best[0]
            print("  识别: 现场设备 = %s (HD %.2f%%)" % (best[0], best[1]))
        else:
            verdict = "REJECT-UNKNOWN"
            print("  识别: 未知设备 (最近 %s HD %.2f%% > %.0f%%) -> 拒绝" % (best[0], best[1], THRESH))
    rc = 0 if verdict in ("ACCEPT", "IDENTIFIED") else 1

    if not args.no_consume:
        used.update(idxs)
        json.dump(sorted(used), open(poolf, "w"))
    with open(os.path.join(ROOT, "logs", "auth_sessions.log"), "a") as f:
        f.write("%s | seed=%d k=%d claim=%s verdict=%s ident=%s consumed=%d pool_left=%d\n" %
                (time.strftime("%Y-%m-%d %H:%M:%S"), seed, args.k, args.claim, verdict, ident,
                 0 if args.no_consume else args.k, len(avail) - (0 if args.no_consume else args.k)))
    return rc

if __name__ == "__main__":
    sys.exit(main())
