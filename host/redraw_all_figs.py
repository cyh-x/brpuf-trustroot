# redraw_all_figs.py — 文档全部示意图统一重绘: 白底、黑字、黑线, 无彩色, 无渐变无圆角阴影
# 覆盖: 图1-1 功能示意 / 图2-1 系统框图 / 图2-2 硬件框图 / 图2-4 PUF环单元 /
#       图2-5 TRNG电路 / 图2-6 软件架构 / 图2-7 协议流程 / 图3-4/3-5/3-6/3-7 统计图
# 数据来自 night/*.csv (真实采集) 与文档既定口径
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mp
from matplotlib.patches import FancyArrowPatch
import numpy as np, csv, os

plt.rcParams['font.sans-serif'] = ['Microsoft YaHei']
plt.rcParams['axes.unicode_minus'] = False
plt.rcParams['axes.edgecolor'] = 'black'
plt.rcParams['axes.linewidth'] = 1.0

OUT = r'C:\Users\cheny\Desktop\learning\FPGA设计创新竞赛\redraw'
os.makedirs(OUT, exist_ok=True)
K = 'black'
F = '#FFFFFF'
GF = '#E8E8E8'   # 唯一允许的次级灰 (B6/次要框)
NIGHT = r'C:\spuf_build\night'


def box(ax, x, y, w, h, text, fs=9, lw=1.0, fill='white'):
    ax.add_patch(mp.Rectangle((x, y), w, h, fc=fill, ec=K, lw=lw, zorder=2))
    if text:
        ax.text(x + w/2, y + h/2, text, ha='center', va='center', fontsize=fs,
                color=K, zorder=3, linespacing=1.3)


def arrow(ax, x1, y1, x2, y2, lw=1.0, style='-|>', ls='-'):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle=style,
                                 mutation_scale=11, color=K, lw=lw, ls=ls,
                                 shrinkA=0, shrinkB=0, zorder=2))


def save(fig, name):
    fig.savefig(os.path.join(OUT, name), dpi=200, bbox_inches='tight', facecolor='white')
    plt.close(fig)
    print('saved', name)


# ==================== 图1-1 系统功能示意 (四大功能) ====================
fig, ax = plt.subplots(figsize=(9.6, 4.6))
ax.set_xlim(0, 100); ax.set_ylim(0, 100); ax.axis('off')
cols = [
    ('① PUF硬件信任根', ['双稳环阵列', '64环×16级', '工艺失配 → 芯片唯一', '挑战-响应行为', '密钥不出芯片']),
    ('② 设备端密钥纠错', ['服务器下发公开helper', '内置BCH(1023,t=18)', '纠正1~3位边缘噪声', '恢复注册身份K', '断电免重注册']),
    ('③ 多节点并行认证', ['服务器经UART', '并发驱动多块开发板']),
    ('④ 密码学闭环', ['AES-256挑战-应答', 'E1/E2/E3三方交换', 'R2来自板载neoTRNG', '一致性校验拒绝']),
]
for i, (title, items) in enumerate(cols):
    x = 1.5 + i * 24.8
    ax.text(x + 11.5, 94, title, ha='center', fontsize=10, fontweight='bold')
    for j, it in enumerate(items):
        y = 84 - j * 15.5
        ax.add_patch(mp.Rectangle((x, y - 7), 23, 12.5, fc='white', ec=K, lw=0.9, zorder=2))
        ax.text(x + 11.5, y - 0.5, it, ha='center', va='center', fontsize=7.6, color=K, zorder=3)
        if j < len(items) - 1:
            arrow(ax, x + 11.5, y - 7.4, x + 11.5, y - 8.4, lw=0.9)
save(fig, '图1-1_系统功能示意.png')

# ==================== 图2-1 系统整体框图 ====================
fig, ax = plt.subplots(figsize=(9.4, 5.2))
ax.set_xlim(0, 100); ax.set_ylim(0, 100); ax.axis('off')
rect = (3, 32, 94, 62)
ax.add_patch(mp.Rectangle(rect[:2], rect[2], rect[3], fc='none', ec=K, lw=1.4, zorder=1))
ax.text(50, 90, '设备层 · ALINX AX7020 (Zynq-7020)', ha='center', fontsize=10.5, fontweight='bold')
# PL
ax.add_patch(mp.Rectangle((6, 46), 50, 38, fc='none', ec=K, lw=1.1, ls='--', zorder=1))
ax.text(31, 80.5, 'PL (FPGA)', ha='center', fontsize=9.5, fontweight='bold')
pl = [(8.5, 64, '双稳环阵列\n64×16'), (24, 64, 'AES-256\nECB'), (39.5, 64, 'neoTRNG'),
      (8.5, 48, 'AXI3 协议\n转换器'), (24, 48, 'AXI-Lite×4\nPUF/AES/TRNG/邮箱'), (39.5, 48, 'SHA-256')]
for x, y, t in pl:
    box(ax, x, y, 14, 12, t, fs=7.8)
# PS
ax.add_patch(mp.Rectangle((62, 46), 32, 38, fc='none', ec=K, lw=1.1, ls='--', zorder=1))
ax.text(78, 80.5, 'PS (Cortex-A9)', ha='center', fontsize=9.5, fontweight='bold')
ps = [(64, 64, 'UART 协议栈'), (78.5, 64, 'PUF 驱动\n24批统计'),
      (64, 48, 'BCH 解码器\nBM+Chien'), (78.5, 48, 'AES 闭环\nE2/E3 应答')]
for x, y, t in ps:
    box(ax, x, y, 13.5, 12, t, fs=7.8)
arrow(ax, 56.2, 65, 61.8, 65)
ax.text(59, 69.5, 'GP0 AXI3', ha='center', fontsize=7.5)
# 底部小框
box(ax, 8, 35, 22, 8, 'SD 卡 BOOT.BIN 三级引导', fs=8.2)
box(ax, 66, 35, 26, 8, 'USB-UART 115200', fs=8.2)
arrow(ax, 30.2, 39, 65.8, 39, lw=0.9)
# 服务器层
ax.add_patch(mp.Rectangle((3, 14), 58, 13, fc='none', ec=K, lw=1.2, zorder=1))
ax.text(32, 23.5, '服务器层 (PC · Python)', ha='center', fontsize=9.5, fontweight='bold')
sv = [(5, '注册程序\n公开helper存库'), (24, '认证程序\nE3闭环校验'), (43, '自动采集\n三线程并发')]
for x, t in sv:
    box(ax, x, 15.5, 16, 7.5, t, fs=7.8)
arrow(ax, 79, 35, 55, 27.2)
ax.text(68, 31, '命令 / 应答\n(公开信道)', ha='center', fontsize=7.5)
# 评估层
ax.add_patch(mp.Rectangle((64, 14), 33, 13, fc='none', ec=K, lw=1.2, zorder=1))
ax.text(80.5, 23.5, '评估层', ha='center', fontsize=9.5, fontweight='bold')
ev = [(66, 'x86对拍\n纵向观测'), (82, '百万CRP\n建模攻击')]
for x, t in ev:
    box(ax, x, 15.5, 12.5, 7.5, t, fs=7.8)
arrow(ax, 61.4, 20.5, 63.6, 20.5, lw=1.0)
ax.text(50, 6, '密钥 K 仅在设备内部出现 · 注册库只存公开数据 (W/pad/ecc) · 串口上永不可见密钥',
        ha='center', fontsize=9)
save(fig, '图2-1_系统整体框图.png')

# ==================== 图2-2 硬件整体框图 ====================
fig, ax = plt.subplots(figsize=(9.2, 4.2))
ax.set_xlim(0, 100); ax.set_ylim(0, 100); ax.axis('off')
ax.text(50, 95, 'PL 硬件组成与关键接口信号', ha='center', fontsize=11, fontweight='bold')
box(ax, 2, 40, 13, 28, 'PS GP0\n(AXI3)', fs=9)
arrow(ax, 15.2, 54, 18.8, 54, lw=1.4)
ax.text(17, 60, 'AXI3', ha='center', fontsize=7.5)
box(ax, 19, 40, 16, 28, 'AXI3→\nAXI4-Lite\n协议转换', fs=8.5)
arrow(ax, 35.2, 54, 37.8, 54, lw=1.4)
box(ax, 38, 40, 12, 28, '地址译码\n[17:16]', fs=8.5)
slaves = [(56, 70, 'PUF\n0x4000_0000', '双稳环阵列'),
          (56, 51, 'AES\n0x4001_0000', 'AES-256 引擎'),
          (56, 32, 'TRNG\n0x4002_0000', 'neoTRNG'),
          (56, 13, '邮箱\n0x4003_0000', 'SHA-256')]
for y, t1, t2 in [(s[1], s[2], s[3]) for s in slaves]:
    arrow(ax, 50, 54, 52.4, y + 6, lw=1.0)
    box(ax, 53, y, 17, 12, t1, fs=8)
    arrow(ax, 70.2, y + 6, 72.8, y + 6, lw=1.0)
    box(ax, 73, y, 24, 12, t2, fs=9)
ax.text(50, 4, '时序收敛 WNS=+2.279ns @66.67MHz（0 违例）· LUT 13.8% / FF 7.1% / BRAM 2.1% / DSP 0%',
        ha='center', fontsize=8.5)
save(fig, '图2-2_硬件整体框图.png')

# ==================== 图2-4 PUF 环单元电路 ====================
fig, ax = plt.subplots(figsize=(9.0, 3.8))
ax.set_xlim(0, 100); ax.set_ylim(0, 100); ax.axis('off')
ax.text(50, 95, '16 级双稳环单元（每级一个 LUT3）', ha='center', fontsize=11, fontweight='bold')
tbox_y = 80
box(ax, 16, tbox_y - 5, 26, 10, '$en=0$：全环复位 0', fs=9)
box(ax, 52, tbox_y - 5, 26, 10, '$en=1$：释放采样', fs=9)
xs = [10, 30, 50, 70]
bs = []
for i, x in enumerate(xs):
    box(ax, x, 50, 17, 16, 'LUT3\n$O=I_0\\oplus C_{%d}$' % (15 - i), fs=9)
    bs.append((x, x + 17))
    ax.text(x + 8.5, 43, '$C_{%d}$' % (15 - i), ha='center', fontsize=10)
    if i < 3:
        arrow(ax, x + 17, 58, xs[i + 1], 58)
ax.text(91, 58, '…', ha='center', fontsize=15)
# 闭环: 右端 -> 底 -> 左端入
rx = 91.5
arrow(ax, xs[3] + 17, 58, rx, 58, lw=1.0, style='-')
arrow(ax, rx, 58, rx, 20, lw=1.0, style='-')
arrow(ax, rx, 20, 8, 20, lw=1.0, style='-')
arrow(ax, 8, 20, 8, 50, lw=1.0)
ax.text(50, 12, '环闭合：$n_0 = n_{15} \\oplus C_0$　（偶校验图案 → 双稳态）',
        ha='center', fontsize=10)
ax.text(50, 4, '输出 $br\\_out$ 经两级同步寄存器采样', ha='center', fontsize=9)
save(fig, '图2-4_PUF环单元电路.png')

# ==================== 图2-5 TRNG 电路 ====================
fig, ax = plt.subplots(figsize=(9.2, 5.0))
ax.set_xlim(0, 100); ax.set_ylim(0, 100); ax.axis('off')
ax.text(50, 96, 'neoTRNG 电路：熵源单元 + 去偏提取 + 熵压缩（3 单元 / 首单元 5 级 / 64 位→1 字节）',
        ha='center', fontsize=10.5, fontweight='bold')
cy = [80, 62, 44]
inv = ['5 级', '7 级', '9 级']
for i, y in enumerate(cy):
    box(ax, 4, y - 7, 20, 14, '熵源单元 %d\n环振 %s（奇数级）\n锁存去耦+同步' % (i + 1, inv[i]), fs=8)
    arrow(ax, 24, y, 33, 62)
box(ax, 33, 55, 12, 14, 'XOR\n合并', fs=9)
arrow(ax, 45, 62, 50, 62)
box(ax, 50, 55, 15, 14, 'von Neumann\n提取器\n01→1, 10→0\n00/11 丢弃', fs=7.8)
arrow(ax, 65, 62, 69, 62)
box(ax, 69, 55, 14, 14, 'CRC 式\n移位寄存器\n64 位→1 字节', fs=7.8)
arrow(ax, 83, 62, 87, 62)
box(ax, 87, 55, 11, 14, '随机\n字节', fs=8.5)
notes = [(39, '各环频率互异 → 抖动近似独立, 系统性偏置相消'),
         (58.5, '不重叠位对取跳变, 输出 1:1 精确（吞吐率减半）'),
         (78, '凑满 64 位时 valid 拉高一个周期')]
for x, t in notes:
    ax.text(x, 40, t, ha='center', fontsize=7.6)
box(ax, 28, 14, 44, 13, '固件 trng_key()：写 0x00=1 启动 → 轮询 valid\n连读 8 字节 = 256 位会话随机数 R2（E3 绑定 → 防重放）', fs=8.5)
arrow(ax, 92.5, 55, 92.5, 27, lw=1.0, style='-')
arrow(ax, 92.5, 27, 72, 24, lw=1.0)
ax.text(50, 4, '锁存去耦：每级反相器后置锁存器, 使能移位寄存器逐位打开 → 各级逻辑互不相同, 综合器无法优化掉环振',
        ha='center', fontsize=8.2)
save(fig, '图2-5_TRNG电路.png')

# ==================== 图2-6 软件整体架构 ====================
fig, ax = plt.subplots(figsize=(9.2, 4.4))
ax.set_xlim(0, 100); ax.set_ylim(0, 100); ax.axis('off')
ax.text(50, 96, '软件整体架构与命令流', ha='center', fontsize=11, fontweight='bold')
# 设备端
ax.add_patch(mp.Rectangle((3, 30), 40, 58, fc='none', ec=K, lw=1.2, zorder=1))
ax.text(23, 84.5, '设备端固件（A9 裸机）', ha='center', fontsize=10, fontweight='bold')
dm = [(5, 68, '主循环\n收行→分发→应答'), (23, 68, 'PUF 驱动\n24批统计'),
      (5, 53, 'BCH 解码器\nBM+Chien'), (23, 53, 'AES 封装\ndec/enc15'),
      (14, 38, 'TRNG 会话随机数 ｜ K 只在设备内部（串口不可见）')]
box(ax, 5, 68, 16.5, 11, dm[0][2], fs=7.8)
box(ax, 23, 68, 16.5, 11, dm[1][2], fs=7.8)
box(ax, 5, 53, 16.5, 11, dm[2][2], fs=7.8)
box(ax, 23, 53, 16.5, 11, dm[3][2], fs=7.8)
box(ax, 5, 38, 34.5, 11, dm[4][2], fs=7.8)
# 服务器
ax.add_patch(mp.Rectangle((57, 30), 40, 58, fc='none', ec=K, lw=1.2, zorder=1))
ax.text(77, 84.5, '服务器端（Python）', ha='center', fontsize=10, fontweight='bold')
sm = [(59, 68, '注册程序\n生成C/W存库'), (77, 68, '认证程序\nE3闭环校验'),
      (59, 53, '自动采集\n稳定性/成功率'), (77, 53, '建模攻击评估\n1M CRP'),
      (59, 38, '注册库：全公开数据（W/pad/ecc）')]
box(ax, 59, 68, 16.5, 11, sm[0][2], fs=7.8)
box(ax, 77, 68, 16.5, 11, sm[1][2], fs=7.8)
box(ax, 59, 53, 16.5, 11, sm[2][2], fs=7.8)
box(ax, 77, 53, 16.5, 11, sm[3][2], fs=7.8)
box(ax, 59, 38, 34.5, 11, sm[4][2], fs=7.8)
# 公开信道
box(ax, 45.5, 53, 9, 15, '公\n开\n信\n道', fs=8.5)
arrow(ax, 43.4, 60, 45.3, 60)
arrow(ax, 54.7, 60, 56.8, 60)
# 命令流
box(ax, 3, 8, 94, 15, 'CMD:PING / CMD:ENROLL:dev / CMD:AUTH:dev:W:pad:ecc:E1 / CMD:ID / CMD:CRP:ch\n'
   '→ RESP:PING / RESP:ENROLL:K / RESP:AUTH:E2:E3:NERR / RESP:ID:fp / RESP:CRP:b    （行协议, 115200）', fs=8.6)
save(fig, '图2-6_软件整体架构.png')

# ==================== 图2-7 协议流程 ====================
fig, ax = plt.subplots(figsize=(9.2, 4.6))
ax.set_xlim(0, 100); ax.set_ylim(0, 100); ax.axis('off')
ax.text(50, 95, '认证协议流程（挑战 E1 → 应答 E2/E3 → 服务器验证）',
        ha='center', fontsize=11, fontweight='bold')
# 泳道
ax.add_patch(mp.Rectangle((4, 30), 30, 58, fc='none', ec=K, lw=1.2))
ax.text(19, 91, '服务器', ha='center', fontsize=10, fontweight='bold')
ax.add_patch(mp.Rectangle((66, 30), 30, 58, fc='none', ec=K, lw=1.2))
ax.text(81, 91, '设备', ha='center', fontsize=10, fontweight='bold')
# 步骤框
box(ax, 7, 72, 24, 12, '① 生成新鲜随机数 R1\nE1 = Enc(K, R1)', fs=8)
arrow(ax, 31, 78, 68.5, 78)
label = 'E1（公开信道）'
ax.text(50, 81, label, ha='center', fontsize=8)
box(ax, 69, 62, 24, 12, '② 重派生 K′ → BCH 纠错\n恢复 K → R1 = Dec(K, E1)', fs=8)
box(ax, 69, 46, 24, 12, '③ R2 = TRNG()\nE2 = Enc(K, R2)\nE3 = Enc(K, R1⊕R2)', fs=8)
arrow(ax, 81, 62, 81, 58)
arrow(ax, 68.5, 52, 31.5, 52)
ax.text(50, 55, 'E2, E3, NERR（公开信道）', ha='center', fontsize=8)
box(ax, 7, 36, 24, 12, '④ Dec(K, E2)=R2\n校验 Dec(K, E3)=R1⊕R2', fs=8)
arrow(ax, 31.5, 42, 68.5, 42, lw=0.9, ls='--')
ax.text(50, 45, '校验通过 → 认证成立', ha='center', fontsize=8)
ax.text(50, 22, '密钥 K 永不出设备：E1/E2/E3 均为密文, 串口只见公开 helper 与密文\n'
                'E3 绑定当次 R1 → 重放失效; R2 来自 TRNG → 会话不可预测',
        ha='center', fontsize=8.5)
save(fig, '图2-7_协议流程.png')

# ==================== 统计图 (真实数据) ====================
COLORS = ['black', '#666666', '#999999']
STYLES = ['-', '--', '-.']

# ---- 图3-4 位差时间序列 ----
fig, ax = plt.subplots(figsize=(8.6, 3.4))
for i, dev in enumerate(['DEV2', 'DEV5', 'DEV1']):
    rows = list(csv.DictReader(open(os.path.join(NIGHT, '%s_enroll.csv' % dev))))
    y = [int(r['bitdiff_vs_reg']) for r in rows if r['bitdiff_vs_reg'] not in ('-1', '')]
    ax.plot(range(len(y)), y, ls=STYLES[i], color=COLORS[i], lw=1.0,
            label='%s (均值 %.2f, 最大 %d)' % (dev, np.mean(y), max(y)))
ax.set_xlabel('ENROLL 轮次', fontsize=9)
ax.set_ylabel('与注册身份的位差 (bit)', fontsize=9)
ax.legend(fontsize=8, frameon=False)
ax.set_xlim(0, 2450)
fig.savefig(os.path.join(OUT, '图3-4_位差时间序列.png'), dpi=200,
            bbox_inches='tight', facecolor='white')
plt.close(fig)
print('saved 图3-4')

# ---- 图3-5 nerr 分布 (噪声指纹) ----
fig, axes = plt.subplots(1, 3, figsize=(9.4, 2.9), sharey=True)
for i, dev in enumerate(['DEV2', 'DEV5', 'DEV1']):
    rows = list(csv.DictReader(open(os.path.join(NIGHT, '%s_auth.csv' % dev))))
    nerr = [int(r['nerr']) for r in rows if r['nerr'] != '-1']
    cnt = np.bincount(nerr, minlength=11)
    axes[i].bar(range(len(cnt)), cnt, color='black', width=0.7)
    axes[i].set_title('%s  n=%d' % (dev, len(nerr)), fontsize=9)
    axes[i].set_xlabel('纠错位数 nerr', fontsize=8.5)
    if i == 0:
        axes[i].set_ylabel('次数', fontsize=8.5)
    axes[i].set_xlim(-0.5, 10.5)
    axes[i].tick_params(labelsize=8)
axes[0].set_ylabel('次数')
fig.savefig(os.path.join(OUT, '图3-5_噪声指纹.png'), dpi=200,
            bbox_inches='tight', facecolor='white')
plt.close(fig)
print('saved 图3-5')

# ---- 图3-6 延迟分布 ----
fig, ax = plt.subplots(figsize=(8.6, 3.2))
allms = {}
for i, dev in enumerate(['DEV2', 'DEV5', 'DEV1']):
    rows = list(csv.DictReader(open(os.path.join(NIGHT, '%s_auth.csv' % dev))))
    ms = [int(r['ms']) for r in rows if r['ms'].isdigit()]
    allms[dev] = ms
bins = np.linspace(1290, 1400, 46)
ax.hist(allms['DEV2'], bins=bins, histtype='step', color='black', ls='-', label='DEV2 (n=%d)' % len(allms['DEV2']))
ax.hist(allms['DEV5'], bins=bins, histtype='step', color='black', ls='--', label='DEV5 (n=%d)' % len(allms['DEV5']))
ax.hist(allms['DEV1'], bins=bins, histtype='step', color='black', ls='-.', label='DEV1 (n=%d)' % len(allms['DEV1']))
ax.axvline(1339, color='black', lw=0.8, ls=':')
ax.text(1340, ax.get_ylim()[1]*0.9, 'p95=1339ms', fontsize=8)
ax.set_xlabel('认证延迟 (ms)', fontsize=9)
ax.set_ylabel('次数', fontsize=9)
ax.legend(fontsize=8, frameon=False)
fig.savefig(os.path.join(OUT, '图3-6_延迟分布.png'), dpi=200,
            bbox_inches='tight', facecolor='white')
plt.close(fig)
print('saved 图3-6')

# ---- 图3-7 TRNG 输出统计 (用已采数据 trng_stream.json) ----
import json
store = json.load(open(r'C:\spuf_build\trng_stream.json'))
data = bytearray()
for dev, hexes in store.items():
    for hx in hexes:
        data.extend(bytes.fromhex(hx))
data = bytes(data)
bits = np.unpackbits(np.frombuffer(data, dtype=np.uint8))
fig, (a1, a2) = plt.subplots(1, 2, figsize=(9.4, 3.2))
cnt = np.bincount(np.frombuffer(data, dtype=np.uint8), minlength=256)
exp = len(data) / 256
a1.bar(np.arange(256), cnt, color='black', width=1.0)
a1.axhline(exp, color='black', lw=1.0, ls='--')
a1.text(128, exp + (cnt.max()-exp)*0.15, '期望 %.0f' % exp, ha='center', fontsize=8)
chi2 = ((cnt - exp) ** 2 / exp).sum()
a1.set_title('(a) 字节直方图 (n=%d B)' % len(data), fontsize=9)
a1.set_xlabel('字节值', fontsize=8.5)
a1.set_ylabel('出现次数', fontsize=8.5)
b = bits.astype(int)
ch = np.nonzero(np.diff(b) != 0)[0]
runs = np.diff(np.concatenate(([-1], ch, [len(b) - 1])))
L = 14
obs = np.bincount(np.minimum(runs, L), minlength=L + 1)[1:]
nr = len(runs)
expv = np.array([2.0 ** -l for l in range(1, L + 1)])
expv = expv / expv.sum() * nr
a2.bar(np.arange(1, L + 1), obs, color='black', width=0.6)
a2.plot(np.arange(1, L + 1), expv, 'o--', color='black', ms=3.5, lw=1.0)
a2.set_yscale('log')
a2.set_title('(b) 游程长度分布 (共 %d 游程, ≥14 合并)' % nr, fontsize=9)
a2.set_xlabel('游程长度 (bit)', fontsize=8.5)
a2.set_ylabel('游程数', fontsize=8.5)
fig.tight_layout()
fig.savefig(os.path.join(OUT, '图3-7_TRNG统计.png'), dpi=200,
            bbox_inches='tight', facecolor='white')
plt.close(fig)
print('saved 图3-7')
print('ALL DONE ->', OUT)
