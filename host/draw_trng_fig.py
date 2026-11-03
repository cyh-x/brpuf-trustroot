import paths
import os
# draw_trng_fig.py — TRNG 检验配图: (a) 字节直方图 vs 期望  (b) 游程长度分布 vs 几何期望
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import json, numpy as np

plt.rcParams['font.sans-serif'] = ['SimHei']
plt.rcParams['axes.unicode_minus'] = False

store = json.load(open(paths.TRNG_STREAM))
data = bytearray()
for dev, hexes in store.items():
    for h in hexes:
        data.extend(bytes.fromhex(h))
data = bytes(data)
bits = np.frombuffer(data, dtype=np.uint8)

fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(9.4, 3.4))

# (a) 字节直方图
cnt = np.bincount(bits, minlength=256)
n = len(bits)
exp = n / 256
ax1.bar(np.arange(256), cnt, color='#4C78A8', width=1.0)
ax1.axhline(exp, color='#C25B4E', lw=1.4, ls='--', label='期望 %.0f' % exp)
chi2 = ((cnt - exp) ** 2 / exp).sum()
ax1.set_xlabel('字节值')
ax1.set_ylabel('出现次数')
ax1.set_title('(a) 字节直方图 (n=%d B, χ${^2}=%.1f/255)' % (n, chi2), fontsize=10)
ax1.legend(fontsize=8)

# (b) 游程长度分布 (观察比特流)
b = np.unpackbits(bits)
x = 2 * b.astype(int) - 1
change = np.nonzero(np.diff(x) != 0)[0]
# 游程长度
runs = np.diff(np.concatenate(([-1], change, [len(x) - 1])))
Lmax = 14
obs = np.bincount(np.minimum(runs, Lmax), minlength=Lmax + 1)[1:]  # 长度1..14+
nruns = runs.sum() if False else len(runs)
# 期望: 长度 L 的游程占比 2^-L -> 数量 nruns*2^-L (归一到同总数)
expv = np.array([2.0 ** -l for l in range(1, Lmax + 1)])
expv = expv / expv.sum() * nruns
ax2.bar(np.arange(1, Lmax + 1), obs, color='#4C78A8', label='实测')
ax2.plot(np.arange(1, Lmax + 1), expv, 'o--', color='#C25B4E', ms=4, lw=1.2, label='几何期望 2$^{-L}$')
ax2.set_xlabel('游程长度 (bit)')
ax2.set_ylabel('游程数')
ax2.set_yscale('log')
ax2.set_title('(b) 游程长度分布 (共 %d 游程, 14+ 合并)' % nruns, fontsize=10)
ax2.legend(fontsize=8)

fig.tight_layout()
fig.savefig(os.path.join(paths.FIG_DIR, 'fig_trng.png'), dpi=200, bbox_inches='tight', facecolor='white')
print('saved fig_trng.png  bytes=%d' % n)
