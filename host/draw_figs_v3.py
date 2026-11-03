import paths
# draw_figs_v3.py — 为技术文档 v3 绘制可程序化生成的图 (matplotlib, 中文字体)
# 可绘: 图1-1 功能示意 / 图1-3 设计流程 / 图2-1 系统整体框图 /
#       图2-2 硬件整体框图 / 图2-4 PUF环单元与硬宏布局 / 图2-5 软件架构
# 不可绘 (需实物/截图): 图1-2 3-1 3-2 3-3 3-4 3-8
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mp
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch
import os

plt.rcParams['font.sans-serif'] = ['SimHei']
plt.rcParams['axes.unicode_minus'] = False
OUT = paths.FIG_DIR
os.makedirs(OUT, exist_ok=True)

C_DEV   = '#4C78A8'   # 设备层蓝
C_PL    = '#2A5D8F'   # PL 深蓝
C_PS    = '#3E8E7E'   # PS 绿
C_SRV   = '#B07AA1'   # 服务器紫
C_EVAL  = '#9C755F'   # 评估棕
C_PUB   = '#D4A24E'   # 公开信道金
C_SEC   = '#C25B4E'   # 密钥/安全红
BG      = '#F7F8FA'
EDGE    = '#3A3F45'


def box(ax, x, y, w, h, text, fc, fs=10, tc='white', bold=True, lw=1.2, round_=0.06, ec=None, alpha=1.0):
    p = FancyBboxPatch((x, y), w, h, boxstyle=f"round,pad=0.012,rounding_size={round_}",
                       fc=fc, ec=ec or EDGE, lw=lw, alpha=alpha, zorder=3)
    ax.add_patch(p)
    ax.text(x + w/2, y + h/2, text, ha='center', va='center', fontsize=fs,
            color=tc, fontweight='bold' if bold else 'normal', zorder=4, linespacing=1.45)
    return p


def arrow(ax, x1, y1, x2, y2, style='-', color=EDGE, lw=1.4, ls='-', ms=12, rad=0.0, zorder=2):
    a = FancyArrowPatch((x1, y1), (x2, y2), arrowstyle=style, mutation_scale=ms,
                        color=color, lw=lw, linestyle=ls, zorder=zorder,
                        connectionstyle=f"arc3,rad={rad}")
    ax.add_patch(a)
    return a


def new_ax(w, h, title=None):
    fig, ax = plt.subplots(figsize=(w, h))
    ax.set_xlim(0, 100); ax.set_ylim(0, 100)
    ax.axis('off')
    fig.patch.set_facecolor('white')
    return fig, ax


def save(fig, name):
    path = os.path.join(OUT, name)
    fig.savefig(path, dpi=200, bbox_inches='tight', facecolor='white')
    plt.close(fig)
    print('saved', path)


# ============ 图1-1 系统三大功能示意 ============
fig, ax = new_ax(9.2, 3.6)
# 三个功能列
cols = [
    ('① PUF 硬件信任根', [
        ('双稳环阵列\n(64环×16级)', C_PL),
        ('工艺失配 → 芯片唯一\n挑战-响应行为', C_DEV),
        ('密钥不出芯片', C_SEC)]),
    ('② 设备端密钥纠错', [
        ('重派生 K′ (含1~3位噪声)', C_DEV),
        ('设备端 BCH 解码 (t=18)', C_PL),
        ('恢复注册身份 K · 断电即认', C_SEC)]),
    ('③ 多节点并行认证', [
        ('服务器经 UART 并发', C_SRV),
        ('公开 helper (71B) 下发', C_PUB),
        ('吞吐随节点数线性扩展', C_SEC)]),
]
for i, (title, items) in enumerate(cols):
    x = 3 + i * 33
    ax.text(x + 13.5, 93, title, ha='center', fontsize=11.5, fontweight='bold', color=EDGE)
    for j, (t, c) in enumerate(items):
        y = 62 - j * 27
        box(ax, x, y, 27, 20, t, c, fs=9.5)
        if j < len(items) - 1:
            arrow(ax, x + 13.5, y, x + 13.5, y - 7, '-|>')
    if i < 2:
        arrow(ax, x + 27.6, 45, x + 32.4, 45, '-|>', color='#889', lw=1.0, ms=10)
save(fig, 'fig_v3_1_1.png')

# ============ 图1-3 设计流程 ============
fig, ax = new_ax(9.6, 2.6)
steps = [
    ('文献调研\n四条PUF路线', 0),
    ('熵源对比\n上板双芯片', 1),
    ('双稳环硬宏\n五芯片表征', 2),
    ('密钥稳定性\n纵向观测', 3),
    ('设备端BCH\nx86对拍', 4),
    ('软硬协同\nSD+UART', 5),
    ('三节点并行\n大规模攻击', 6),
]
w, gap = 12.2, 1.4
for i, (t, _) in enumerate(steps):
    x = 1 + i * (w + gap)
    shade = ['#5B7EA6', '#51719E', '#486496', '#3F578E', '#364A86', '#2D3D7E', '#243076'][i]
    box(ax, x, 34, w, 32, t, shade, fs=9)
    if i < 6:
        arrow(ax, x + w + 0.15, 50, x + w + gap - 0.15, 50, '-|>', lw=1.6)
ax.text(50, 88, '熵源选型 → 物理表征 → 纠错构造 → 系统集成 → 攻击验证', ha='center',
        fontsize=9.5, color='#666', style='italic')
save(fig, 'fig_v3_1_3.png')

# ============ 图2-1 系统整体框图 ============
fig, ax = new_ax(9.4, 5.6)
# 设备层大框
box(ax, 3, 30, 94, 66, '', BG, fs=1, ec='#9AA3AD', lw=1.5, alpha=0.55)
ax.text(50, 91.5, '设备层 · ALINX AX7020 (Zynq-7020)', ha='center', fontsize=11,
        fontweight='bold', color=EDGE)
# PL 内框
box(ax, 6, 44, 52, 42, '', '#E8EEF5', fs=1, ec=C_PL, lw=1.4)
ax.text(32, 82.5, 'PL (FPGA)', ha='center', fontsize=10, fontweight='bold', color=C_PL)
pl_mods = [
    (8.5, 66, '双稳环阵列\n64×16 LUT3'),
    (24, 66, 'AES-256\nECB 引擎'),
    (39.5, 66, 'neoTRNG\n熵源'),
    (8.5, 48, 'AXI3 协议\n转换器'),
    (24, 48, 'AXI-Lite ×4\nPUF/AES/TRNG/邮箱'),
    (39.5, 48, 'SHA-256'),
]
for x, y, t in pl_mods:
    box(ax, x, y, 13.5, 13, t, C_PL, fs=8)
# PS 内框
box(ax, 62, 44, 32, 42, '', '#E5F0EC', fs=1, ec=C_PS, lw=1.4)
ax.text(78, 82.5, 'PS (Cortex-A9)', ha='center', fontsize=10, fontweight='bold', color=C_PS)
ps_mods = [
    (64, 64, 'UART 协议栈\n命令循环'),
    (78.5, 64, 'PUF 驱动\n24批统计'),
    (64, 48, 'BCH 解码器\nBM+Chien'),
    (78.5, 48, 'AES 闭环\nE2/E3 应答'),
]
for x, y, t in ps_mods:
    box(ax, x, y, 13.5, 13, t, C_PS, fs=8)
arrow(ax, 58.2, 65, 61.8, 65, '<|-|>', color=C_PL, lw=1.8)
ax.text(60, 69, 'GP0\nAXI3', ha='center', fontsize=7.5, color=C_PL)
# SD + UART
box(ax, 8, 33, 22, 8.5, 'SD 卡 · BOOT.BIN 三级引导', '#7A8B99', fs=8.5)
box(ax, 66, 33, 26, 8.5, 'USB-UART 115200', '#7A8B99', fs=8.5)
arrow(ax, 40, 33.5, 65.8, 33.5, '-|>', color='#666', lw=1.2)
# 服务器层
box(ax, 3, 14, 60, 13, '', '#F1E9F3', fs=1, ec=C_SRV, lw=1.5)
ax.text(33, 24, '服务器层 (PC · Python)', ha='center', fontsize=10, fontweight='bold', color=C_SRV)
srv = [(5.5, '注册程序\n公开helper存库'), (24.5, '认证程序\nE3闭环校验'), (43.5, '自动采集\n三线程并发')]
for x, t in srv:
    box(ax, x, 15, 17, 7.5, t, C_SRV, fs=8)
arrow(ax, 79, 33, 55, 27.5, '-|>', color='#666', lw=1.6)
ax.text(68, 30.5, '命令 / 应答\n(公开信道)', ha='center', fontsize=7.5, color='#666')
# 评估层
box(ax, 66, 14, 31, 13, '', '#F3EEE9', fs=1, ec=C_EVAL, lw=1.5)
ax.text(81.5, 24, '评估层', ha='center', fontsize=10, fontweight='bold', color=C_EVAL)
ev = [(68, 'x86 对拍\n纵向观测'), (83, '百万CRP\n建模攻击')]
for x, t in ev:
    box(ax, x, 15, 12.5, 7.5, t, C_EVAL, fs=8)
arrow(ax, 63.4, 20.5, 65.6, 20.5, '-|>', color='#888', lw=1.2)
ax.text(50, 7, '密钥 K 仅在设备内部出现 · 注册库只存公开数据 (W/pad/ecc) · 串口上永不可见密钥',
        ha='center', fontsize=9, color=C_SEC, fontweight='bold')
save(fig, 'fig_v3_2_1.png')

# ============ 图2-2 硬件整体框图 ============
fig, ax = new_ax(9.4, 4.4)
box(ax, 2, 8, 96, 84, '', BG, fs=1, ec='#9AA3AD', lw=1.5, alpha=0.55)
ax.text(50, 87, 'PL 硬件组成与关键接口信号', ha='center', fontsize=11, fontweight='bold', color=EDGE)
# 左: PS GP0
box(ax, 4, 44, 14, 30, 'PS\nGP0\n(AXI3)', C_PS, fs=9)
# 协议转换
box(ax, 21, 44, 15, 30, 'AXI3→\nAXI4-Lite\n协议转换', C_PL, fs=8.5)
arrow(ax, 18.2, 59, 20.8, 59, '-|>', lw=1.6)
ax.text(19.5, 65.5, 'AXI3', ha='center', fontsize=7, color='#555')
# demux
box(ax, 39, 44, 12, 30, '地址译码\n[17:16]', C_PL, fs=8.5)
arrow(ax, 36.2, 59, 38.8, 59, '-|>', lw=1.6)
# 四从机
slaves = [
    (54, 68, 'PUF\n0x4000_0000', '双稳环阵列'),
    (54, 51, 'AES\n0x4001_0000', 'AES-256'),
    (54, 34, 'TRNG\n0x4002_0000', 'neoTRNG'),
    (54, 17, '邮箱\n0x4003_0000', 'SHA-256'),
]
for x, y, t1, t2 in slaves:
    arrow(ax, 49, 59, 51.2, y + 6, '-|>', lw=1.2, rad=0.0)
    box(ax, 53, y, 16, 12, t1, C_PL, fs=8)
    box(ax, 71, y, 25, 12, t2, '#6B87A6', fs=9)
    arrow(ax, 69.2, y + 6, 70.8, y + 6, '-|>', lw=1.2)
ax.text(79, 10, '时序收敛 WNS=+2.279ns @66.67MHz · LUT 13.8%', ha='center', fontsize=8.5, color='#666')
save(fig, 'fig_v3_2_2.png')

# ============ 图2-4 PUF 环单元电路与硬宏布局 ============
fig = plt.figure(figsize=(9.6, 3.9))
gs = fig.add_gridspec(1, 2, width_ratios=[1.15, 1])
ax1 = fig.add_subplot(gs[0]); ax2 = fig.add_subplot(gs[1])
for a in (ax1, ax2):
    a.set_xlim(0, 100); a.set_ylim(0, 100); a.axis('off')
# 左: 环单元
ax1.set_title('(a) 16级双稳环单元 (每级一个LUT3)', fontsize=10, fontweight='bold', color=EDGE, pad=8)
# 画 4 个显式级 + 省略
cells_x = [12, 32, 52, 72]
labels = ['n15', 'n14', 'n13', '…', 'n1', 'n0']
for i, x in enumerate(cells_x):
    box(ax1, x, 55, 14, 18, 'LUT3\nO=I₀⊕Cᵢ', C_PL, fs=8)
    ax1.text(x + 7, 47.5, 'C$_{%d}$' % (15 - i), ha='center', fontsize=8, color=C_SEC)
    if i < 3:
        arrow(ax1, x + 14, 64, x + 18, 64, '-|>', lw=1.4)
ax1.text(88, 64, '…', ha='center', fontsize=14, color='#888')
# 闭环回 n15
arrow(ax1, 86, 55, 86, 30, '-', lw=1.2)
arrow(ax1, 86, 30, 19, 30, '-', lw=1.2)
arrow(ax1, 19, 30, 19, 54.6, '-|>', lw=1.2)
ax1.text(52, 25, '环闭合: n₀ = n₁₅ ⊕ C₀ (偶校验图案→双稳态)', ha='center', fontsize=8.5, color='#555')
box(ax1, 62, 68, 26, 10, 'en=0: 全环复位 0\nen=1: 释放采样', '#7A8B99', fs=8)
box(ax1, 10, 72, 26, 10, '释放→亚稳态→\n布线偏置决定收敛方向', C_SEC, fs=8)
ax1.text(50, 10, '输出 br_out = 采样寄存器 (q₁→q₂ 两级同步)', ha='center', fontsize=8.5, color='#555')
# 右: 硬宏布局
ax2.set_title('(b) 64环硬宏布局 (每环独占一列)', fontsize=10, fontweight='bold', color=EDGE, pad=8)
import numpy as np
rng = np.random.RandomState(7)
for col in range(16):
    x = 6 + col * 5.6
    # 每列画 8 个小格代表 16 级 (压缩)
    for row in range(8):
        y = 18 + row * 8.2
        c = C_PL if (col + row) % 2 == 0 else '#6B87A6'
        cell = mp.Rectangle((x, y), 4.4, 6.6, fc=c, ec='white', lw=0.5)
        ax2.add_patch(cell)
ax2.annotate('列 = 一个环\n(16级, 交替A6/B6)', xy=(6 + 5 * 5.6 + 2, 18 + 4 * 8.2),
             xytext=(60, 66), fontsize=8.5, color=EDGE,
             arrowprops=dict(arrowstyle='->', color=EDGE, lw=1.2))
ax2.text(50, 88, 'slice 列', ha='center', fontsize=8, color='#888')
ax2.text(3, 8, '行→', fontsize=8, color='#888')
ax2.text(50, 3, '各环布线剖面互不相同 → 跨芯片唯一性', ha='center', fontsize=8.5, color='#555')
fig.tight_layout()
save(fig, 'fig_v3_2_4.png')

# ============ 图2-5 软件整体架构与命令流 ============
fig, ax = new_ax(9.4, 4.6)
# 设备端
box(ax, 3, 26, 40, 66, '', '#EDF2F7', fs=1, ec=C_PS, lw=1.5)
ax.text(23, 87.5, '设备端固件 (A9 裸机)', ha='center', fontsize=10.5, fontweight='bold', color=C_PS)
dev_mods = [
    (5.5, 70, '主循环 uart_main\n收行→分发→应答'),
    (23, 70, 'PUF 驱动\npuf_derive 24批'),
    (5.5, 55, 'BCH 解码器\nbch_decode(d,e)'),
    (23, 55, 'AES 包装\naes_dec/enc15'),
    (5.5, 40, 'TRNG 会话随机数'),
    (23, 40, 'K 只在设备内部\n(串口不可见)'),
]
for x, y, t in dev_mods:
    box(ax, x, y, 16.5, 11, t, C_PS, fs=7.8)
# 服务器
box(ax, 60, 26, 37, 66, '', '#F3ECF5', fs=1, ec=C_SRV, lw=1.5)
ax.text(78.5, 87.5, '服务器端 (Python)', ha='center', fontsize=10.5, fontweight='bold', color=C_SRV)
srv_mods = [
    (62, 70, '注册程序\n生成C/W存库'),
    (79.5, 70, '认证程序\nE3闭环校验'),
    (62, 55, '自动采集\n稳定性/成功率'),
    (79.5, 55, '建模攻击评估\n1M CRP'),
    (70.7, 40, '注册库: 全公开\n(W/pad/ecc)'),
]
for x, y, t in srv_mods:
    w = 16.5 if x != 70.7 else 24
    bx = x if x != 70.7 else 66.5
    box(ax, bx, y, w, 11, t, C_SRV, fs=7.8)
# 公开信道
box(ax, 46, 55, 10, 22, '公\n开\n信\n道\nUART', C_PUB, fs=9)
arrow(ax, 43.2, 66, 45.8, 66, '-|>', lw=1.4)
arrow(ax, 56.2, 66, 58.8, 66, '-|>', lw=1.4)
# 命令流注释
box(ax, 3, 8, 94, 13, '', BG, fs=1, ec='#BBB', lw=1.0, alpha=0.7)
ax.text(50, 16.5, 'CMD:PING / CMD:ENROLL:dev / CMD:AUTH:dev:W:pad:ecc:E1 / CMD:ID / CMD:CRP:ch',
        ha='center', fontsize=8.8, color=EDGE, fontweight='bold')
ax.text(50, 11.5, '→ RESP:PING / RESP:ENROLL:K / RESP:AUTH:E2:E3:NERR / RESP:ID:fp / RESP:CRP:b   (行协议, 115200)',
        ha='center', fontsize=8.2, color='#666')
save(fig, 'fig_v3_2_5.png')

print('ALL DONE')
