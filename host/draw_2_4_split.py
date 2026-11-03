import paths
# draw_2_4_split.py — 图2-4 拆分版: (a) 环单元电路 / (c) 单环放大
# 所有方框用 text 的 bbox 自动撑开, 箭头连在真实 bbox 边缘 -> 不会出现文字溢出
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mp
from matplotlib.patches import FancyArrowPatch
import csv, re

plt.rcParams['font.sans-serif'] = ['Microsoft YaHei']
plt.rcParams['axes.unicode_minus'] = False
OUT = paths.FIG_DIR
EDGE = '#3A3F45'
C_PL = 'white'      # 白底
C_SEC = 'black'     # 黑字（原红色强调位）
C_GRAY = 'white'    # 白底


def tbox(ax, cx, cy, text, fc, fs=10, tc='black', pad=0.55):
    return ax.text(cx, cy, text, ha='center', va='center', fontsize=fs, color=tc,
                   bbox=dict(boxstyle='round,pad=%.2f' % pad, fc=fc, ec=EDGE, lw=1.1),
                   zorder=3, linespacing=1.45)


def bbox_of(fig, ax, t):
    fig.canvas.draw()
    bb = t.get_window_extent()
    inv = ax.transData.inverted()
    (x0, y0), (x1, y1) = inv.transform([[bb.x0, bb.y0], [bb.x1, bb.y1]])
    return x0, y0, x1, y1


def arrow(ax, x1, y1, x2, y2, color=EDGE, lw=1.3, style='-|>'):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle=style,
                                 mutation_scale=13, color=color, lw=lw, zorder=2,
                                 shrinkA=0, shrinkB=0))


# ==================== (a) 16 级双稳环单元 ====================
fig, ax = plt.subplots(figsize=(9.0, 4.2))
ax.set_xlim(0, 100); ax.set_ylim(0, 100); ax.axis('off')

ax.text(50, 95, '16 级双稳环单元（每级一个 LUT3）', ha='center', fontsize=12,
        fontweight='bold', color=EDGE)

tbox(ax, 20, 82, '$en=0$：全环复位 0', C_GRAY, fs=9.5)
tbox(ax, 62, 82, '$en=1$：释放采样', C_GRAY, fs=9.5)

xs = [12, 32, 52, 72]
boxes = []
for i, x in enumerate(xs):
    boxes.append(tbox(ax, x, 58, 'LUT3\n$O = I_0 \\oplus C_{%d}$' % (15 - i), C_PL, fs=9.5))
ax.text(86, 58, '…', ha='center', va='center', fontsize=16, color='#888')

fig.canvas.draw()
bb = [bbox_of(fig, ax, b) for b in boxes]
for i in range(3):
    arrow(ax, bb[i][2] + 0.35, 58, bb[i + 1][0] - 0.35, 58)

for i, x in enumerate(xs):
    ax.text(x, bb[0][1] - 5, '$C_{%d}$' % (15 - i), ha='center', va='center',
            fontsize=10, color=C_SEC)

# 闭环回路: 右出 -> 下行 -> 左行 -> 上入
rx = bb[3][2] + 4
ly = 28
arrow(ax, bb[3][2] + 0.3, 58, rx, 58, style='-', lw=1.0)
arrow(ax, rx, 58, rx, ly, style='-', lw=1.0)
arrow(ax, rx, ly, bb[0][0] - 4, ly, style='-', lw=1.0)
arrow(ax, bb[0][0] - 4, ly, bb[0][0] - 4, 58, style='-', lw=1.0)
arrow(ax, bb[0][0] - 4, 58, bb[0][0] - 0.2, 58, lw=1.0)

ax.text(50, 14, '环闭合：$n_0 = n_{15} \\oplus C_0$', ha='center', fontsize=10.5, color='#555')
ax.text(50, 5, '偶校验图案 → 双稳态；输出经两级同步寄存器采样', ha='center',
        fontsize=9.5, color='#555')
fig.savefig(OUT + '\\fig_2_4a_dianlu.png', dpi=200, bbox_inches='tight', facecolor='white')
plt.close(fig)


# ==================== (c) 单环 16 级放大（真实坐标） ====================
rows = list(csv.DictReader(open(paths.LAYOUT_CSV)))
pat = re.compile(r'g_ring\[(\d+)\]\.u_ring/g_stage\[(\d+)\]\.u_ps$')
cells = {}
for r in rows:
    m = pat.search(r['cell'])
    if m:
        cells[(int(m.group(1)), int(m.group(2)))] = (
            int(r['x']), int(r['y']), 'A6' if 'A6LUT' in r['bel'] else 'B6')
C_A, C_B = 'white', '#F2F2F2'   # A6 纯白, B6 浅灰(仅靠灰度区分)

fig, ax = plt.subplots(figsize=(5.8, 6.4))
ax.set_title('单环 16 级放大（环 0，真实布局 SLICE_X0Y1–X0Y16）',
             fontsize=11, fontweight='bold', color=EDGE, pad=12)
W, H = 2.2, 0.80
for (rg, st), (x, y, ab) in sorted(cells.items(), key=lambda kv: -kv[0][1]):
    if rg != 0:
        continue
    ax.add_patch(mp.Rectangle((0.9, y - H/2), W, H,
                              fc=C_A if ab == 'A6' else C_B, ec='black', lw=0.9))
    ax.text(0.9 + W/2, y, ab, ha='center', va='center', fontsize=8.5, color='black')
    ax.text(0.75, y, '$C_{%d}$' % st, ha='right', va='center', fontsize=9, color=C_SEC)
    ax.text(0.9 + W + 0.22, y, 'X%dY%d' % (x, y), ha='left', va='center',
            fontsize=8.5, color='#777')

# 完整闭合回路：底级左出 → 竖直上行 → 顶级左入
loop_x = -0.55
arrow(ax, 0.88, 0.62, loop_x, 0.62, color=C_SEC, lw=1.2, style='-')
arrow(ax, loop_x, 0.62, loop_x, 16.38, color=C_SEC, lw=1.2, style='-')
arrow(ax, loop_x, 16.38, 0.88, 16.38, color=C_SEC, lw=1.2)
ax.text(-1.55, 8.5, '环\n闭\n合', ha='center', va='center', fontsize=8.5, color=C_SEC)
ax.set_xlim(-2.7, 6.2)
ax.set_ylim(-1.2, 17.2)
ax.set_aspect('equal')
ax.axis('off')
fig.savefig(OUT + '\\fig_2_4c_danhuan.png', dpi=200, bbox_inches='tight', facecolor='white')
plt.close(fig)
print('a & c saved')
