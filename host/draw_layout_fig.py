import paths
import os
# draw_layout_fig.py — 图2-4(b) 按真实布局坐标绘制 (来自 trustroot_uart_impl.dcp)
# 数据: puf_layout.csv (Vivado get_cells 实测): 64环 x=0..63 各独占一列, 16级 y=0..15, A6/B6 逐级交替
import csv, re
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mp
from matplotlib.collections import PatchCollection
import numpy as np

plt.rcParams['font.sans-serif'] = ['SimHei']
plt.rcParams['axes.unicode_minus'] = False

rows = list(csv.DictReader(open(paths.LAYOUT_CSV)))
pat = re.compile(r'g_ring\[(\d+)\]\.u_ring/g_stage\[(\d+)\]\.u_ps$')
cells = {}
for r in rows:
    m = pat.search(r['cell'])
    if m:
        cells[(int(m.group(1)), int(m.group(2)))] = (int(r['x']), int(r['y']),
                                                     'A' if 'A6LUT' in r['bel'] else 'B')

fig, (ax0, ax1) = plt.subplots(1, 2, figsize=(9.6, 3.9),
                               gridspec_kw={'width_ratios': [1, 1.35]})

# ---------- 左: 全阵列鸟瞰 (真实坐标) ----------
ax0.set_title('(b1) 64×16 阵列真实布局\n(实现后坐标, xc7z020)', fontsize=10, fontweight='bold')
C_A, C_B = '#2A5D8F', '#6B87A6'
for (rg, st), (x, y, ab) in cells.items():
    ax0.add_patch(mp.Rectangle((x - 0.42, y - 0.42), 0.84, 0.84,
                                fc=C_A if ab == 'A' else C_B, ec='none'))
# 圈出几列做标注
for x, lab in [(3, '环3'), (32, '环32'), (61, '环61')]:
    ax0.annotate(lab, xy=(x, 15.9), xytext=(x + 3, 19.2), fontsize=8,
                 arrowprops=dict(arrowstyle='-', color='#444', lw=0.7))
ax0.set_xlim(-1, 64.5)
ax0.set_ylim(-1.5, 21)
ax0.set_aspect('equal')
ax0.set_xlabel('slice 列 X (环号)', fontsize=9)
ax0.set_ylabel('slice 行 Y (环内级号)', fontsize=9)
ax0.set_xticks([0, 16, 32, 48, 63]); ax0.set_yticks([0, 5, 10, 15])
ax0.tick_params(labelsize=8)
# 图例
ax0.add_patch(mp.Rectangle((46, 17.2), 1.4, 1.2, fc=C_A, ec='none'))
ax0.text(47.8, 17.8, 'A6LUT', fontsize=7.5, va='center')
ax0.add_patch(mp.Rectangle((53, 17.2), 1.4, 1.2, fc=C_B, ec='none'))
ax0.text(54.8, 17.8, 'B6LUT', fontsize=7.5, va='center')

# ---------- 右: 单环放大 (环0 真实数据) ----------
ax1.set_title('(b2) 单环 16 级放大 (环0: X0Y0–X0Y15)', fontsize=10, fontweight='bold')
ring0 = sorted(((st, x, y, ab) for (rg, st), (x, y, ab) in cells.items() if rg == 0))
for st, x, y, ab in ring0:
    ax1.add_patch(mp.Rectangle((0.28, y - 0.38), 1.44, 0.76,
                                fc=C_A if ab == 'A' else C_B, ec='white', lw=0.8))
    ax1.text(1.0, y, 'LUT3·%s6' % ab, ha='center', va='center', fontsize=7.2, color='white')
    ax1.text(-0.05, y, 'C%-2d' % st, ha='right', va='center', fontsize=7.5, color='#C25B4E')
    ax1.text(2.9, y, 'SLICE_X0Y%d' % y, ha='left', va='center', fontsize=6.8, color='#888')
# 环闭合箭头
ax1.annotate('', xy=(0.9, 14.7), xytext=(0.9, 0.3),
             arrowprops=dict(arrowstyle='-', color='#C25B4E', lw=1.1,
                             connectionstyle='arc3,rad=0'))
ax1.text(0.35, 7.5, '环\n闭\n合', ha='center', va='center', fontsize=7.5, color='#C25B4E')
ax1.set_xlim(-1.2, 4.6)
ax1.set_ylim(-1.2, 16.2)
ax1.set_aspect('equal')
ax1.axis('off')

fig.tight_layout()
fig.savefig(os.path.join(paths.FIG_DIR, 'fig_v3_2_4b.png'), dpi=200, bbox_inches='tight', facecolor='white')
print('saved fig_v3_2_4b.png  cells=%d' % len(cells))
