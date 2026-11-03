import paths
import json
import os
# trng_test.py — TRNG 比特流随机性检验 (单文件实现, 无外部依赖)
# 检验项 (参考 NIST SP 800-22 思想, 按样本量自适应参数, 报告 p 值与样本量):
#   1) 单比特频数 monobit            5) 扑克 poker (M=4)
#   2) 块内频数 (M=2000)             6) 自相关 (lag 1..16)
#   3) 游程总数 runs                 7) 字节直方图卡方
#   4) 最长连1 (DP 精确分布+卡方)     8) 样本唯一性 (json 模式)
import sys, json
from math import erfc, sqrt, exp, log, lgamma


# ---------- 正则化不完全伽马 (Numerical Recipes) ----------
def _gser(a, x):
    ap, s, d = a, 1.0 / a, 1.0 / a
    for _ in range(2000):
        ap += 1.0
        d *= x / ap
        s += d
        if abs(d) < abs(s) * 1e-15:
            break
    return s * exp(-x + a * log(x) - lgamma(a))


def _gcf(a, x):
    b, c, d, h = x + 1.0 - a, 1e300, 1.0 / (x + 1.0 - a), 1.0 / (x + 1.0 - a)
    for i in range(1, 2000):
        an = -i * (i - a)
        b += 2.0
        d = an * d + b
        if abs(d) < 1e-300:
            d = 1e-300
        c = b + an / c
        if abs(c) < 1e-300:
            c = 1e-300
        d = 1.0 / d
        delt = d * c
        h *= delt
        if abs(delt - 1.0) < 1e-15:
            break
    return h * exp(-x + a * log(x) - lgamma(a))


def chi2_sf(x, k):
    """卡方生存函数 P(X > x)"""
    a, xx = k / 2.0, x / 2.0
    if x <= 0:
        return 1.0
    if xx < a + 1.0:
        return 1.0 - _gser(a, xx)
    return _gcf(a, xx)


# ---------- 输入 ----------
def bits_from_hex_lines(lines):
    b = bytearray()
    for ln in lines:
        ln = ln.strip()
        if ln:
            b.extend(bytes.fromhex(ln))
    return ''.join(format(x, '08b') for x in b), bytes(b)


# ---------- 各检验 ----------
def test_monobit(bits):
    n = len(bits)
    s = abs(2 * bits.count('1') - n) / sqrt(n)
    p = erfc(s / sqrt(2))
    return ('单比特频数', n, 'ones=%.4f' % (bits.count('1') / n), p, p >= 0.01)


def test_block_freq(bits, M=2000):
    n = len(bits)
    N = n // M
    if N < 4:
        return None
    chi = 0.0
    for i in range(N):
        pi = bits[i * M:(i + 1) * M].count('1') / M
        chi += (pi - 0.5) ** 2
    chi *= 4 * M
    p = chi2_sf(chi, N)
    return ('块内频数 M=%d' % M, N * M, 'N=%d' % N, p, p >= 0.01)


def test_runs(bits):
    n = len(bits)
    pi = bits.count('1') / n
    if abs(pi - 0.5) >= 2 / sqrt(n):
        return ('游程总数', n, '前置频数检验未过', 0.0, False)
    V = 1 + sum(1 for i in range(1, n) if bits[i] != bits[i - 1])
    p = erfc(abs(V - 2 * n * pi * (1 - pi)) / (2 * sqrt(2 * n) * pi * (1 - pi)))
    return ('游程总数', n, 'V=%d (理想%.0f)' % (V, n / 2), p, p >= 0.01)


def _p_longest_le(M, L):
    """P(M 位独立均匀比特的最长连1 <= L), 精确 DP"""
    dp = [0.0] * (L + 1)
    dp[0] = 1.0
    for _ in range(M):
        nxt = [0.0] * (L + 1)
        tot = sum(dp)
        nxt[0] = tot * 0.5
        for c in range(L):
            nxt[c + 1] += dp[c] * 0.5
        dp = nxt
    return sum(dp)


def test_longest_run(bits):
    """最长连1检验: DP 求精确分布 -> 等概率分箱卡方"""
    n = len(bits)
    for M in (10000, 1000, 128):
        N = n // M
        if N >= 40:
            break
    else:
        return None
    Lmax = 40
    cum = [_p_longest_le(M, L) for L in range(Lmax + 1)]   # P(最长<=L)
    obs = []
    for i in range(N):
        best = cur = 0
        for c in bits[i * M:(i + 1) * M]:
            cur = cur + 1 if c == '1' else 0
            if cur > best:
                best = cur
        obs.append(best)
    # 目标 6 个等概率箱: 阈值取累积分布 1/6..5/6 处
    K = 6
    thr = []
    tgt = 1.0 / K
    j = 0
    for b in range(1, K):
        while j < Lmax and cum[j] < tgt * b:
            j += 1
        thr.append(j)
    thr = sorted(set(thr))
    if len(thr) < 2:
        return None
    K = len(thr) + 1
    edges = [-1] + thr + [Lmax + 1]
    cnt = [0] * K
    for v in obs:
        for b in range(K):
            if edges[b] < v <= edges[b + 1]:
                cnt[b] += 1
                break
    expc = []
    for b in range(K):
        lo = cum[edges[b]] if edges[b] >= 0 else 0.0
        hi = cum[edges[b + 1]] if edges[b + 1] <= Lmax else 1.0
        expc.append(N * (hi - lo))
    chi = sum((c - e) ** 2 / e for c, e in zip(cnt, expc) if e > 0)
    df = sum(1 for e in expc if e > 0) - 1
    p = chi2_sf(chi, df)
    return ('最长连1 M=%d' % M, N * M, 'N=%d df=%d' % (N, df), p, p >= 0.01)


def test_poker(bits, M=4):
    n = len(bits)
    k = 2 ** M
    N = n // M
    if N < 10 * k:
        return None
    cnt = [0] * k
    for i in range(N):
        cnt[int(bits[i * M:(i + 1) * M], 2)] += 1
    chi = k * sum(c * c for c in cnt) / N - N
    p = chi2_sf(chi, k - 1)
    return ('扑克 M=%d' % M, N * M, 'N=%d' % N, p, p >= 0.01)


def test_autocorr(bits, maxlag=16):
    n = len(bits)
    X = [1 if c == '1' else -1 for c in bits]
    res = []
    for d in range(1, maxlag + 1):
        s = sum(X[i] * X[i + d] for i in range(n - d))
        p = erfc(abs(s / sqrt(n - d)) / sqrt(2))
        res.append((d, p))
    n_pass = sum(1 for _, p in res if p >= 0.01)
    worst = min(res, key=lambda t: t[1])
    return ('自相关 lag1-%d' % maxlag, n,
            '%d/%d 过 最差lag%d p=%.3f' % (n_pass, len(res), worst[0], worst[1]),
            None, n_pass == len(res))


def test_byte_hist(data):
    cnt = [0] * 256
    for x in data:
        cnt[x] += 1
    n = len(data)
    chi = sum((c - n / 256.0) ** 2 for c in cnt) / (n / 256.0)
    p = chi2_sf(chi, 255)
    return ('字节直方图卡方', n * 8, 'min/max=%d/%d' % (min(cnt), max(cnt)), p, p >= 0.01)


def uniq_check(samples):
    u = len(set(samples))
    return ('样本唯一性', len(samples), '唯一 %d/%d' % (u, len(samples)), None, u == len(samples))


def run_all(bits, data, samples=None):
    rows = []
    for t in (test_monobit(bits), test_block_freq(bits), test_runs(bits),
              test_longest_run(bits), test_poker(bits), test_byte_hist(data)):
        if t:
            rows.append(t)
    rows.append(test_autocorr(bits))
    if samples:
        rows.append(uniq_check(samples))
    return rows


def fmt(rows):
    out = []
    for name, n, note, p, ok in rows:
        ps = 'p=%.4f' % p if p is not None else '—'
        out.append('%-18s n=%-8d %-28s %8s %s' % (name, n, note, ps, 'PASS' if ok else 'FAIL'))
    return out


def report_json(src):
    """生成 trng_report.json: {per_dev:{dev:[row...]}, merged:[row...], meta:{...}}"""
    if src.endswith('.json'):
        store = json.load(open(src))
        per, all_samples = {}, []
        for dev, hexes in store.items():
            if not hexes:
                continue
            bits, data = bits_from_hex_lines(hexes)
            per[dev] = {'n_samples': len(hexes), 'n_bits': len(bits),
                        'rows': [list(r) for r in run_all(bits, data, hexes)]}
            all_samples.extend(hexes)
        bits, data = bits_from_hex_lines(all_samples)
        merged = {'n_samples': len(all_samples), 'n_bits': len(bits),
                  'rows': [list(r) for r in run_all(bits, data)]}
        out = {'per_dev': per, 'merged': merged, 'src': src}
    else:
        lines = open(src).read().split()
        bits, data = bits_from_hex_lines(lines)
        out = {'per_dev': {}, 'merged': {'n_samples': len(lines), 'n_bits': len(bits),
                                         'rows': [list(r) for r in run_all(bits, data)]},
               'src': src}
    json.dump(out, open(paths.TRNG_REPORT, 'w'), ensure_ascii=False, indent=1)
    print('saved trng_report.json')
    return out


if __name__ == '__main__':
    if len(sys.argv) > 2 and sys.argv[2] == 'json':
        rep = report_json(sys.argv[1])
        for dev, blk in rep['per_dev'].items():
            print('==', dev, blk['n_bits'], 'bit')
            print(chr(10).join(fmt([tuple(r) for r in blk['rows']])))
        m = rep['merged']
        print('== merged', m['n_bits'], 'bit')
        print(chr(10).join(fmt([tuple(r) for r in m['rows']])))
        sys.exit(0)
    if len(sys.argv) > 2 and sys.argv[2] == 'selftest':
        # 已知均匀流应 PASS, 偏置流应 FAIL
        import os
        for tag, mk, want in [('os.urandom(应过)', lambda: os.urandom(50000), True),
                              ('偏置0.7(应挂)', lambda: bytes(1 if (b % 10) < 7 else 0 for b in os.urandom(50000)), False)]:
            data = mk()
            bits = ''.join(format(x, '08b') for x in data)
            rows = run_all(bits, data)
            print('==', tag)
            print('\n'.join(fmt(rows)))
        sys.exit(0)

    src = sys.argv[1]
    if src.endswith('.json'):
        store = json.load(open(src))
        all_samples = []
        for dev, hexes in store.items():
            if not hexes:
                continue
            bits, data = bits_from_hex_lines(hexes)
            print('== %s: %d 样本 %d bit ==' % (dev, len(hexes), len(bits)))
            print('\n'.join(fmt(run_all(bits, data, hexes))))
            all_samples.extend(hexes)
        if len(all_samples):
            bits, data = bits_from_hex_lines(all_samples)
            print('== 合并: %d bit ==' % len(bits))
            print('\n'.join(fmt(run_all(bits, data))))
    else:
        lines = open(src).read().split()
        bits, data = bits_from_hex_lines(lines)
        print('== %s: %d bit ==' % (src, len(bits)))
        print('\n'.join(fmt(run_all(bits, data))))
