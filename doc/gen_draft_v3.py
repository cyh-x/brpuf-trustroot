#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""gen_draft_v2.py — 技术文档 V2: v31b 架构 (SD引导/UART/设备端BCH/三节点并行)
夜间采集数据以 <<NIGHT:...>> 占位, 由 fill_night.py 在采集结束后回填。"""
import docx, os, csv
from collections import Counter
from docx import Document
from docx.shared import Pt, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_LINE_SPACING
from docx.oxml.ns import qn

OUT = os.path.join(os.path.dirname(__file__), "技术文档_草稿_v3.docx")
NIGHT = r"C:\spuf_build\night"

import json as _json
try:
    _tr = _json.load(open(r"C:\spuf_build\trng_report.json"))
    _m = _tr["merged"]
    TRNG_META = {"n": str(_m["n_samples"]), "bits": format(_m["n_bits"], ",")}
    TRNG_TABLE = [[r[0], format(r[1], ","), r[2],
                   ("p=%.4f" % r[3]) if r[3] is not None else "—",
                   "通过" if r[4] else "未过"] for r in _m["rows"]]
except Exception:
    TRNG_META = {"n": "<<N>>", "bits": "<<BITS>>"}
    TRNG_TABLE = [["<<待采集>>", "", "", "", ""]]

doc = Document()
style = doc.styles["Normal"]
style.font.name = "Times New Roman"
style.font.size = Pt(12)
style.element.rPr.rFonts.set(qn("w:eastAsia"), "宋体")
pf = style.paragraph_format
pf.line_spacing_rule = WD_LINE_SPACING.MULTIPLE
pf.line_spacing = 1.3

def set_cn(run, font="宋体", size=12, bold=False, color=None):
    run.font.name = "Times New Roman"
    run.font.size = Pt(size)
    run.font.bold = bold
    run.element.rPr.rFonts.set(qn("w:eastAsia"), font)
    if color:
        run.font.color.rgb = RGBColor(*color)


from docx.shared import Inches
def PIC(path, caption, width=5.8):
    if os.path.exists(path):
        doc.add_picture(path, width=Inches(width))
        doc.paragraphs[-1].alignment = WD_ALIGN_PARAGRAPH.CENTER
        FIG(caption)
    else:
        FIG(caption + " 【图缺:%s】" % os.path.basename(path))

def H(text, level=1):
    h = doc.add_heading("", level=level)
    r = h.add_run(text)
    set_cn(r, "黑体", {1: 16, 2: 14, 3: 12.5}.get(level, 12), bold=True)
    return h

def P(text, indent=True, bold=False, size=12, color=None, align=None):
    p = doc.add_paragraph()
    if indent:
        p.paragraph_format.first_line_indent = Pt(size * 2)
    if align:
        p.alignment = align
    r = p.add_run(text)
    set_cn(r, "宋体", size, bold=bold, color=color)
    return p

def FIG(text):
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    r = p.add_run(text)
    set_cn(r, "楷体", 11, color=(128, 128, 128))
    return p

def TABLE(headers, rows, widths=None):
    t = doc.add_table(rows=1 + len(rows), cols=len(headers))
    t.style = "Table Grid"
    for j, htext in enumerate(headers):
        c = t.rows[0].cells[j]
        c.text = ""
        r = c.paragraphs[0].add_run(htext)
        set_cn(r, "黑体", 10.5, bold=True)
    for i, row in enumerate(rows):
        for j, v in enumerate(row):
            c = t.rows[i + 1].cells[j]
            c.text = ""
            r = c.paragraphs[0].add_run(str(v))
            set_cn(r, "宋体", 10.5)
    return t

def night(dev, item, col, fmt="{:.2f}", compute=None):
    """读夜间 CSV 计算; 文件缺失时返回占位符"""
    path = os.path.join(NIGHT, "%s_%s.csv" % (dev, item))
    try:
        rows = list(csv.DictReader(open(path)))
        if not rows:
            raise ValueError
        if compute:
            return fmt.format(compute(rows))
        vals = [float(r[col]) for r in rows if r.get(col) not in (None, "", "-1")]
        return fmt.format(sum(vals) / len(vals)) if vals else "--"
    except Exception:
        return "<<NIGHT:%s_%s_%s>>" % (dev, item, col)

def night_int(dev, item, col):
    path = os.path.join(NIGHT, "%s_%s.csv" % (dev, item))
    try:
        rows = list(csv.DictReader(open(path)))
        return str(len(rows))
    except Exception:
        return "<<NIGHT:%s_%s_n>>" % (dev, item)

# ================= 封面 =================
P("基于FPGA的双稳环PUF硬件信任根与多节点并行认证系统", indent=False, bold=True, size=18,
  align=WD_ALIGN_PARAGRAPH.CENTER)

H("摘要")
P("针对边缘集群、无人机编队等分布式场景中设备身份认证与密钥安全存储的难题，本作品在 Zynq-7000 平台上实现了一套以"
  "双稳环PUF为物理熵源、以设备端BCH模糊提取器保证密钥可复现、以公开helper数据支持跨断电认证的多节点并行认证系统。"
  "PL端集成双稳环阵列（64环×16级，硬宏交替布局）、neoTRNG真随机源与AES-256引擎；PS端运行UART协议栈，"
  "并内置GF(2^10)域Berlekamp-Massey BCH解码器（t=18）。系统实现三项关键性质：（1）密钥永不出设备——注册身份"
  "由设备派生，认证时服务器仅下发全公开的helper数据（71字节），设备本地完成纠错与密钥恢复；（2）断电即认——重启后"
  "无需重新注册，设备重新派生的含噪密钥经设备端BCH纠错恢复注册身份，实测跨断电认证3/3通过；（3）并行线性——三节点"
  "并行认证墙钟与单节点相当（9.5秒含派生），认证延迟1.33秒/节点。BCH解码器经x86对拍验证200/200（1~18位随机噪声"
  "全纠、19位正确失败）；三块同型号板身份互异且跨夜稳定——整夜自动采集36,595次认证全部通过"
  "（成功率100.00%，延迟p95=1339ms），大规模攻击实验605,300次尝试（重放/跨板冒充/三种伪造模型）零接受。", size=11)

H("第一部分  作品概述")
H("1.1  功能与特性", 2)
P("系统实现四大功能。（1）PUF硬件信任根：PL端双稳环阵列把制造工艺的微观失配转化为芯片唯一的挑战-响应行为，"
  "密钥不出芯片、无需安全存储器；（2）设备端密钥纠错：AUTH时服务器下发公开helper，设备用内置BCH(1023,t=18)"
  "解码器把重派生密钥中的1~3位边缘环噪声纠正，恢复注册身份——断电重启后无需任何额外操作即可认证；（3）多节点"
  "并行认证：服务器经UART并发驱动多块开发板，注册与认证吞吐随节点数线性扩展；（4）密码学闭环：AES-256"
  "挑战-应答（E1/E2/E3三方交换），会话随机数来自板载neoTRNG，重放与冒充均被服务器端密钥一致性校验拒绝；"
  "（5）消耗制多挑战会话认证：在固定密钥制式之外提供strong PUF正统用法——服务器为每板维护CRP台账，"
  "每会话消耗128个新鲜挑战、用后即弃，已消耗挑战重放被服务器直接拒绝。")
PIC(r"C:\spuf_build\figs\fig_v3_1_1.png", "图1-1 系统三大功能示意", width=5.95)

H("1.2  应用领域", 2)
P("（1）边缘计算集群与芯片级身份：五块同型号板指纹互异（跨芯片唯一性inter HD的均值为25.4%），为无预置密钥的设备身份提供"
  "芯片级（芯粒级）物理标识；（2）无人机编队：地面站经一根USB-UART即可并发认证多架节点，认证时延与节点数"
  "近似无关；（3）密钥安全存储替代：根密钥由PUF现场派生+设备端纠错，掉电即消失、上电即恢复，无可提取的"
  "静态密钥物证。")
FIG("【图1-2 应用场景——待补现场照片】")

H("1.3  主要技术特点", 2)
P("（1）双稳环阵列与硬宏布局：64个16级短环各独占一列slice，逐级交替A6/B6基本单元，抵消同一位流下布线延迟"
  "的确定性；（2）跨批统计派生：利用批内相关、批间独立的物理特性，以24个独立批次的 unanimous 统计构造256位"
  "身份，单次派生仅约150毫秒；（3）设备端BCH模糊提取器：code-offset构造（helper=K⊕C，与K统计独立、不泄露"
  "密钥），GF(2^10)上Berlekamp-Massey+Chien搜索约150行C在A9裸机运行；（4）全自主启动链：SD卡三级BOOT.BIN"
  "（厂家FSBL→位流→应用），上电即成为完整认证节点，演示与部署无需JTAG/PC工具链。")

H("1.4  主要性能指标", 2)
P("表1-1 主要性能指标总表（三节点实测）", indent=False)
TABLE(
    ["指标", "数值", "条件"],
    [
        ["身份派生延迟", "约150ms", "24批×256挑战"],
        ["认证延迟（含派生）", "1.33s/节点", "helper下发+设备端纠错+AES闭环"],
        ["三节点并行认证墙钟", "9.5s", "与单节点相当，吞吐线性"],
        ["BCH纠错容量", "t=18位", "实测噪声1~10位(板间互异), 最差余量1.8×"],
        ["BCH解码器对拍", "200/200", "x86对拍，1~18位随机噪声"],
        ["跨断电认证", "3/3 PASS", "断电15s重启，免重新注册"],
        ["认证成功率", "100.00%", "三节点整夜36,595次, 零失败"],
        ["抗攻击", "0/605,300接受", "重放/冒充/三模型伪造(表3-5)"],
        ["消耗制会话认证", "K=128/τ=6, 失配≤3, ~1.0s/会话", "2万CRP池, 重放128/128拦截(表3-7)"],
        ["PL 资源", "LUT 13.8% / FF 7.1% / BRAM 2.1% / DSP 0%", "xc7z020, 富余量大"],
        ["固件占用", "代码 6.0KB + 数据 4.4KB", "A9 裸机, 含完整 BCH 解码器"],
        ["服务器端", "Python, 无板卡资源占用", "注册库全公开数据"],
        ["时序", "WNS +2.279ns @66.67MHz (0违例, hold +0.016ns)", "Vivado时序报告实测; 推算上限约78.6MHz(单路径外推,未做放宽约束重收敛)"],
        ["功耗", "约1.7W (PS7≈1.5W + PL动态≈0.05W + 静态0.14W)", "Vivado report_power估算(未提供SAIF翻转率, 默认激励, 置信度Medium); PL部分不足总功耗3%"],
    ],
)

H("1.5  主要创新点", 2)
P("对照基准说明：本作品的创新均相对公开文献与开源实现的常规做法——弱PUF密钥化方案通常把模糊提取器放在"
  "读出侧服务器（如Dodis等人的经典构造[3]，密钥或原始响应需离开设备）；FPGA PUF研究（如4x4开关块APUF[5]、"
  "RO-PUF[6]）聚焦熵源本身，不以完整认证系统交付；BR-PUF自Chen等人提出[1]以来的FPGA实现多为仿真或单板验证，"
  "罕有跨芯片表征与整机断电即认。逐点对比如下。", indent=False, size=10.5, color=(96,96,96))
P("（1）密钥化路径的设备端化：常规做法把模糊提取器（BCH解码+密钥重构）放在读出侧，原始响应或密钥需要"
  "离开设备；本作品把BCH(1023,t=18)解码器（约150行无libc的C）整体放进A9裸机固件，helper公开下发、"
  "密钥不出板卡、断电免重注册——与[3]的服务器侧构造相对。", indent=False)
P("（2）双稳环PUF批内相关性的发现与量化：常规做法以“加大重复次数+多数决”处理PUF噪声（开源RO-PUF工程"
  "即如此）；本作品实测发现同一批次内重复采样共享同一次settle锁存、独立样本数远小于采样次数，据此改用"
  "跨批统计构造身份——这是在我们调研范围内未见报告的FPGA现象与对策。", indent=False)
P("（3）7系列FPGA上的双稳环硬宏布局：相对于APUF开关块布线[5]与RO配对布局[6]这两类既有FPGA硬宏方案，"
  "本作品给出BR-PUF的列独占+逐级A6/B6交替布局，并在五块同位流芯片上实测唯一性均值25.4%——"
  "BR-PUF在Xilinx平台上此前多为仿真或单板结果[1][7]。", indent=False)
P("（4）双制式认证并存：常规实现只取其一（strong PUF文献走消耗制CRP[2][7]，weak PUF/密钥化方案走固定"
  "密钥闭环）；本作品在同一套固件上同时提供固定密钥制（BCH+AES闭环，断电即认）与消耗制多挑战会话"
  "（CRP用后即弃、重放服务器直接拒绝）——两种制式的取舍在同一硬件上可现场对比。", indent=False)
P("（5）百万CRP抗建模实测：相对于建模攻击文献以预测准确率显著超过50%论证“可克隆”[7]，本作品以更强的"
  "零学习参照（含bit0结构耦合的单比特规则67.14%）为基线：80万条训练、20万条挑战不相交留出，最优模型"
  "67.20%仅高出0.06个百分点——攻击者拿不到超出公开结构耦合的预测能力。", indent=False)

H("1.6  设计流程", 2)
P("文献调研（BR-PUF、PDL仲裁器、RO配对、SRAM锁存四条技术路线）→ 熵源对比实验（四种结构上板双芯片"
  "对比，选定双稳环）→ 双稳环硬宏实现与五芯片表征 → 密钥稳定性纵向观测 → 设备端BCH模糊提取器设计（x86对拍验证）→ 软硬协同集成（SD自主引导+UART协议栈）→ 三节点并行认证与大规模攻击实验。")
PIC(r"C:\spuf_build\figs\fig_v3_1_3.png", "图1-3 设计流程", width=5.95)


# ================= 第二部分 =================
H("第二部分  系统组成及功能说明")
H("2.1  整体介绍", 2)
P("系统由三层组成。（1）设备层：ALINX AX7020（Zynq-7020），PL端集成双稳环阵列、AXI3协议转换器、AXI-Lite"
  "多路分配、AES-256、neoTRNG；PS端裸机应用实现UART协议栈、PUF驱动与设备端BCH解码。SD卡三级BOOT.BIN"
  "（FSBL→位流→应用）上电自主引导。（2）服务器层：PC上的Python验证器，管理设备注册库（公开helper数据），"
  "经USB-UART并发驱动多节点。（3）评估层：x86对拍测试、纵向稳定性观测、百万CRP建模攻击基线。")
PIC(r"C:\spuf_build\figs\fig_v3_2_1.png", "图2-1 系统整体框图（设备层/服务器层/评估层与数据流）", width=5.95)

H("2.2  硬件系统介绍", 2)
H("2.2.1 硬件整体介绍", 3)
P("系统硬件以 ALINX AX7020（Zynq-7020，xc7z020clg400-2）为核心，单板即完整认证节点：PS 侧 Cortex-A9 运行"
  "裸机协议栈，PL 侧承载全部密码与熵源电路，SD 卡提供自主引导，USB-UART（CP2102N）为唯一对外接口。"
  "PL逻辑四部分：双稳环阵列（u_ring×64，每环16级LUT3，硬宏布局逐级交替A6/B6）；AXI3协议转换器"
  "（axi_protocol_converter，SI=AXI3/MI=AXI4-Lite，桥接PS GP0与轻量总线——修复了手写分配器与AXI3主机"
  "的协议鸿沟，并把此前因M_AXI_GP0_ACLK漏接导致的间歇性死锁一并根除）；四路AXI-Lite从机（PUF/AES/TRNG/"
  "邮箱，地址[17:16]译码）；密码引擎（AES-256 ECB、neoTRNG蜂窝自动机熵源、SHA-256）。位流时序收敛"
  "WNS=+2.7ns，LUT 7320/53200。SD卡FAT32根目录单文件BOOT.BIN三级引导：分区0=FSBL（初始化PS时钟/DDR/UART"
  "并经PCAP烧写分区1位流）、分区1=系统位流、分区2=裸机应用（DDR 0x100000），上电即成完整认证节点，"
  "全程零JTAG。")
PIC(r"C:\spuf_build\figs\fig_v3_2_2.png", "图2-2 硬件整体框图（PL各模块与PS互联、关键接口信号）", width=5.95)

H("2.2.2 机械设计介绍", 3)
P("本作品为多板卡演示系统，无自制机械结构件。机械组成即三块同型号开发板与PC的组合部署：开发板经Micro USB"
  "线独立供电，USB-UART线经一个USB Hub汇聚到认证服务器；SD卡插入每板卡槽承载BOOT.BIN。演示形态下所有"
  "板卡平铺于桌面，服务器并发驱动三节点（实物布局见图3-1）。")
FIG("【图2-3 系统部署形态（三板卡+USB Hub+服务器连线）——待补照片】")

H("2.2.3 电路各模块介绍", 3)
P("电路分三级。（1）系统级：Zynq-7000 SoC 内 PS-PL 通过 GP0（AXI3 100MHz）互联，PL 各从机经 AXI-Lite"
  "总线挂接，地址映射为 PUF 0x4000_0000 / AES 0x4001_0000 / TRNG 0x4002_0000 / 邮箱 0x4003_0000，关键"
  "接口信号为 GP0 的 AW/AR/W/R 五通道与各从机中断状态位；（2）PUF 核心电路：64×16 双稳环阵列，每级一个"
  "LUT3（INIT=8'h60）实现 O=en?I_prev⊕C_i:0，环输出经两级同步寄存器（q_s1/q_s2）采样，挑战/响应经 BRAM"
  "缓存，硬宏约束锁定每环独占一列 slice；（3）密码电路：AES-256 ECB 单块引擎（密钥扩展与轮函数全流水，"
  "AXI 寄存器 0x00-0x1C 写密钥、0x20-0x2C 写数据、0x30 控制、0x38-0x44 读结果）、neoTRNG 蜂窝自动机熵源"
  "（上电自检后按需输出 256bit 会话随机数）。各模块的输入输出信号与寄存器语义见下表。")
TABLE(["模块", "关键输入", "关键输出", "接口语义"],
      [["双稳环阵列", "ch[21:0]（环号+图案）, en, start", "resp[0]（每挑战1bit）",
        "批测量模式: 写挑战RAM→启动→轮询done→读响应RAM"],
       ["AES-256", "key[255:0], data_in[127:0], ctrl", "data_out[127:0], status",
        "ECB单块: 写密钥/数据→start→busy清零读结果"],
       ["neoTRNG", "使能/自检控制", "rand[255:0], ready",
        "256bit/次: 启动→等ready→读8字"],
       ["UART协议口", "RX字符流(命令)", "TX字符流(应答)",
        "115200 8N1, 行协议 CMD:xxx→RESP:xxx"]])
PIC(r"C:\spuf_build\figs\fig_v3_2_4_final.png", "图2-4 PUF环单元电路与硬宏布局（右侧为实现后真实布局坐标）", width=5.95)

H("2.3  软件系统介绍", 2)
H("2.3.1 软件整体介绍", 3)
P("软件由设备端固件与服务器端程序两层组成。设备端为 PS 裸机应用（ps_uart_app.c + bchdec.c，代码 6.0KB），"
  "上电自校准 UART 后进入命令循环，实现 PUF 驱动、设备端 BCH 解码与 AES 闭环应答，密钥永不出芯片；"
  "服务器端为 Python 程序组（注册/认证、自动采集、建模攻击评估），经 USB-UART 并发驱动多节点，注册库"
  "只存公开 helper 数据。两层间为单一行协议：CMD:PING/ENROLL/AUTH/ID/CRP → RESP:…，71 字节 helper 走"
  "公开信道下发。")
PIC(r"C:\spuf_build\figs\fig_v3_2_5.png", "图2-5 软件整体架构与命令流（设备固件/服务器程序/公开信道）", width=5.95)

H("2.3.2 软件各模块介绍", 3)
P("设备端固件按调用层次自顶向下：（1）主循环 uart_main：逐字符收行、分发命令，输出统一 RESP 应答，"
  "输入为行缓冲 line_buf，输出为状态行；（2）PUF 驱动 puf_measure/puf_single/puf_derive：写入挑战 RAM、"
  "启动批测量、读回 256 位表决位图，puf_derive 做 24 批 unanimous 统计输出 256 位身份，输入为批次基址与"
  "重复次数，输出为 key256[8]；（3）BCH 解码器 bch_decode(d[48],e[23])：输入为带噪码字，GF(2^10) 上"
  "Berlekamp-Massey 求错误位置多项式、Chien 搜索定位，输出为纠错后数据与纠错位数（-1 失败），约 150 行 C、"
  "无 libc 依赖；（4）AES 包装 aes_dec/aes_enc15：装载密钥、写数据、轮询状态、读结果；（5）协议处理"
  "CMD:AUTH 分支：重派生 K′→(K′⊕W)|pad 拼 71 字节码字→BCH 解码恢复注册身份 K（不出设备）→AES 解密挑战"
  "E1 得 R1、板载 TRNG 取 R2、回传 E2=Enc(K,R2) 与 E3=Enc(K,R1⊕R2)，应答附纠错位数 NERR。")
P("模糊提取器构造（code-offset）贯穿两层：注册时服务器取随机 48 字节 R，C=BCH_encode(R)=R‖ECC(R)（71"
  "字节），helper W=K⊕C[:32]（32字节）；认证时设备计算 C′=(K′⊕W)‖C[32:]，因 K′⊕K=噪声E，C′=C⊕E 恰为"
  "带≤18位错的合法码字，设备端 BCH 解码后得 C，K=C[:32]⊕W。安全性：W 与 K 统计独立（一次性密码本同款"
  "论证），公开 W 不泄露 K 的任何信息；C 全公开，服务器可零秘密存储。密钥 K 仅在设备内部出现，串口上"
  "永不可见。服务器端模块：注册程序（生成 C/W 存库）、认证程序（下发 helper、E3 闭环校验）、自动采集"
  "程序（三线程并发采集稳定性与成功率）、建模攻击评估程序（百万 CRP 训练/留出测试）。")
PIC(r"C:\spuf_build\figs\图_协议标注_v2.png", "图2-6 认证协议流程（挑战 E1 → 应答 E2/E3 → 服务器验证）", width=5.2)

# ================= 第三部分 =================
H("第三部分  完成情况及性能参数")
H("3.1  整体介绍", 2)
P("系统在5块同型号开发板上完成PUF表征；其中1/2/5号三块板完成三节点并行认证、跨断电认证、整夜自动采集与"
  "大规模攻击实验。全部指标在同一份固件与位流版本下测得。")
FIG("【图3-1 系统实物整体（正面+斜45°全局照片，三板同连）——待补照片】")

H("3.2  工程成果", 2)
H("3.2.1 机械成果", 3)
P("系统复用商用开发板与标准线缆，无自制机械件。部署形态：三块 AX7020 平铺，各自 Micro USB 供电、"
  "USB-UART 接同一 Hub，SD 卡承载 BOOT.BIN——上电即自主成为认证节点，无需任何调试器连接。"
  "（实物照片见图3-1与图2-3。）")
FIG("【图3-2 机械部署成果（三板+Hub连线实物）——待补照片】")

H("3.2.2 电路成果", 3)
P("电路成果为 PL 位流与 PS 固件的完整实现：PL 侧双稳环阵列（硬宏布局）、AXI3 协议转换、四路 AXI-Lite 从机、"
  "AES-256 与 neoTRNG 全部时序收敛（WNS +2.279ns，0违例），LUT 占用 13.8%；PS 侧裸机应用含完整 UART 协议栈"
  "与 BCH 解码器，代码 6.0KB。三级 BOOT.BIN 单文件自主引导，全程零 JTAG。")
FIG("【图3-3 电路成果（Vivado布局截图+资源/时序报告）——待补截图】")

H("3.2.3 软件成果", 3)
P("软件成果包含两端：设备端固件（命令集 CMD:PING/ENROLL/AUTH/ID/CRP，密钥不出芯片）与服务器端仪表盘"
  "（Flask 实时事件流界面，可一键执行并行认证、重放攻击、建模预测攻击、伪造攻击四个场景，全部场景驱动"
  "真实板卡并直播验证结果）。")
FIG("【图3-4 软件成果（仪表盘界面+并行认证事件流）——待补截图】")

H("3.3  特性成果", 2)
H("3.3.1 五芯片PUF表征（同位流，指纹验证）", 3)
P("跨芯片唯一性均值25.4%（11.1%~44.7%），可靠性20轮×1000挑战均值99.7%，均匀性47%~59%（聚合口径）。"
  "百万CRP抗建模实验（80万条训练/20万条留出，挑战不相交）：多数类基线53.19%；一条无需任何训练的"
  "单比特规则（预测\u201c响应=NOT挑战bit0\u201d，源自读出节点n[0]=n[15]⊕ch[0]的结构性直通项）本身可达"
  "67.14%；线性逻辑回归67.20%、双层MLP 67.19%——最优模型仅比这条零学习规则高0.06个百分点。"
  "即模型未学到任何超出已知结构耦合的规律：挑战-响应关系中不存在可建模利用的额外结构，建模克隆攻击"
  "不能获得超出公开耦合的预测能力；逐位约67%的可预测率由结构耦合决定，并非模型习得。")
H("3.3.2 密钥派生稳定性（整夜自动采集）", 3)
P("系统身份派生（24批unanimous统计）在三节点上整夜循环，每轮记录与注册身份的位差。边缘环噪声由BCH纠错"
  "吸收，认证不受影响；位差分布与密钥变体统计如下表（数据：night/目录）。")
PIC(r"C:\spuf_build\figs\fig_drift.png", "图3-5 密钥派生位差时间序列（2440轮×3节点）")
PIC(r"C:/spuf_build/figs/fig_nerr.png", "图3-6 三节点噪声指纹（36,595次认证的设备端纠错位分布）")
TABLE(["节点", "ENROLL样本", "位差均值", "位差最大", "众数占比"],
      [[dev,
        night_int(dev, 'enroll', 'n'),
        night(dev, 'enroll', 'bitdiff_vs_reg'),
        night(dev, 'enroll', 'bitdiff_vs_reg', fmt='{:.0f}',
              compute=lambda rs: max(int(r['bitdiff_vs_reg']) for r in rs if r['bitdiff_vs_reg'] != '-1')),
        "--"] for dev in ('DEV2', 'DEV5', 'DEV1')])
H("3.3.3 认证成功率与延迟（整夜自动采集）", 3)
TABLE(["节点", "AUTH样本", "成功率", "延迟均值ms", "延迟p95 ms", "nerr分布见台账"],
      [[dev,
        night_int(dev, 'auth', 'n'),
        night(dev, 'auth', 'ok', fmt='{:.3%}', compute=lambda rs: sum(int(r['ok']) for r in rs)/len(rs)),
        night(dev, 'auth', 'ms'),
        night(dev, 'auth', 'ms', fmt='{:.0f}',
              compute=lambda rs: sorted(int(r['ms']) for r in rs)[int(len(rs)*0.95)]),
        ""] for dev in ('DEV2', 'DEV5', 'DEV1')])
PIC(r"C:/spuf_build/figs/fig_latency.png", "图3-7 认证延迟分布（12,198次）")
H("3.3.4 跨断电与跨板验证", 3)
P("断电15秒重启→免重注册直接AUTH 3/3 PASS（设备端纠错nerr=1）；三节点身份互异（DEV2=C3DB37…/DEV5=43C335…/"
  "DEV1=43C830…），跨板冒充在服务器E3校验下直接拒绝（密钥不同→AES雪崩）。")
H("3.3.5 抗攻击实测（三件套，真实板卡）", 3)
P("大规模攻击实验共605,300次尝试、零接受（表3-5）。重放攻击：录制合法会话应答后，在5,000个独立新鲜挑战下"
  "重放旧(E2,E3)，服务器以E3必须绑定本次新鲜随机数R1为校验依据，5,000/5,000全部拒绝；跨板冒充：将DEV5的"
  "挑战密文发给DEV2的板子共300次完整板级会话——设备端全程正常走完协议（它用自己恢复的K2解密得到垃圾明文"
  "并如实加密回传，设备本身无从知晓自己被用于冒充），服务器端按DEV5密钥验证E3，300/300全部拒绝，证明拦截"
  "发生在密钥互异性与AES雪崩效应，与设备端是否配合无关；伪造应答：攻击者持有全部公开helper数据（W/pad/ecc，"
  "本就设计为可公开）但无真实设备，按三种攻击者模型各20万次——(a)纯随机应答、(b)持他板密钥的定向伪造、"
  "(c)截获一次合法应答后逐字节微扰——三个模型合计600,000次零通过（单次通过概率理论值2^-128）。全部实验在"
  "系统当前固件下完成。")
P("表3-5 抗攻击实验汇总（总尝试605,300次，接受0次）", indent=False)
TABLE(["攻击类型", "攻击者能力", "尝试次数", "被接受", "拦截机制"],
      [["重放", "录得合法会话完整应答", "5,000", "0", "E3绑定新鲜随机数R1"],
       ["跨板冒充", "持有另一块真实板卡", "300", "0", "密钥互异+AES雪崩（服务器端拦截）"],
       ["伪造-a", "公开helper+随机应答", "200,000", "0", "密钥未知，通过率2^-128"],
       ["伪造-b", "公开helper+他板密钥", "200,000", "0", "密钥互异，AES雪崩"],
       ["伪造-c", "截获合法应答+微扰", "200,000", "0", "R1新鲜性+R2会话独立"],
       ["合计", "—", "605,300", "0", "—"]])
H("3.3.6 并行性能", 3)
P("三节点并行注册3.5秒；并行认证1.33秒/节点、三节点墙钟9.5秒——与单节点相当，吞吐随节点数线性扩展"
  "（各节点独立串口，服务器并发驱动）。")

# ================= 第四/五部分 =================
H("3.3.7 TRNG 随机性检验", 3)
P("采集方式：认证应答 E2 用该板注册密钥解密即得会话随机数 R2 的明文前 15 字节（每次 AUTH 暴露 120 bit "
  "TRNG 原始输出，AES 仅作通道、不改变随机性）。在 v32 位流下于 7 号板连续采集 " + TRNG_META["n"] +
  " 次认证共 " + TRNG_META["bits"] + " bit，另有 JTAG 直采 256bit×64=16,384 bit 样本交叉验证。"
  "检验参考 NIST SP 800-22 的统计量与判定阈值（p≥0.01），最长连1检验的期望分布由精确动态规划计算"
  "（非查表常数），全部结果见表3-6。")
P("表3-6 TRNG 随机性检验汇总（" + TRNG_META["bits"] + " bit，7号板 v32 位流）", indent=False)
TABLE(["检验项", "样本量", "统计量/说明", "p 值", "结论"],
      TRNG_TABLE)
PIC(r"C:\spuf_build\figs\fig_trng.png", "图3-8 TRNG 输出统计: (a) 字节直方图 (b) 游程长度分布", width=5.95)
FIG("【图3-9 并行认证终端输出——待补截图】")

H("3.3.8 消耗制多挑战会话认证", 3)
P("除固定密钥制式外，系统提供strong PUF正统的消耗制认证：服务器为每板维护CRP台账（注册时随机采2万"
  "个偶校验挑战并记录响应，实测156秒/板），每次会话从未消耗池抽取128个新鲜挑战下发，设备逐个应答"
  "（复用CMD:CRP通道，固件零改动），服务器与台账比对、失配数≤6判通过，该批挑战随即标记消耗、永不复用。"
  "实测三次会话失配分别为2/128、1/128、0/128（同挑战重复一致率99.67%），单会话约1.0秒；重放刚消耗的"
  "128个挑战，服务器命中已消耗记录128/128、直接拒绝。安全参数：攻击者逐位最优猜测率约0.67（bit0结构"
  "耦合，见3.3.1），K=128、τ=6下会话伪造通过概率约2^-96，且已消耗挑战的重放为零知识服务器策略拦截、"
  "不依赖任何密码学。CRP池按会话递减，2万池支撑约156次会话，池耗尽需在可信环境重新扩池注册。")
P("表3-7 消耗制会话认证实测（7号板，v32位流）", indent=False)
TABLE(["项", "实测值"],
      [["池注册", "20,000 CRP / 156 s (CMD:CRP 7.8ms/次)"],
       ["会话规模", "K=128 挑战/会话, 容差 τ=6"],
       ["会话实测", "失配 2/1/0 (三次), 墙钟 0.96~1.13 s"],
       ["同挑战重复一致率", "299/300 = 99.67%"],
       ["重放拦截", "已消耗 128/128 命中, 服务器直接拒绝"],
       ["会话伪造概率", "≈2^-96 (逐位猜测率0.67, K=128, τ=6)"]])

H("3.4  资源占用与物理指标", 2)
P("表1-1 已列全部资源与物理指标。补充说明其测量来源与口径：（1）资源占用（LUT 7320/53200=13.8%、FF 7.1%、"
  "BRAM 2.1%、DSP 0%）取自 Vivado report_utilization，为布局布线后的最终实现值；（2）时序数据取自"
  "report_timing_summary：WNS +2.279ns、hold +0.016ns、0 条违例路径，关键路径为 u_puf/ring_sel→q_s1，"
  "数据延迟 12.635ns 中逻辑仅占 2.261ns、布线占 10.374ns（硬宏列间走线代价），故提升频率需先放宽列间距；"
  "表中所列 Fmax≈78.6MHz 系由该路径 15.000−2.279=12.721ns 反推的单路径外推值，非放宽约束重收敛实测，"
  "仅作量级参考；（3）功耗取自 report_power 估算（约 1.7W，其中 PS7 占约 1.5W、PL 动态不足 3%、静态 0.14W），"
  "该估算未提供仿真翻转率文件（SAIF），采用工具默认激励，置信度等级为 Medium，属设计阶段的量级估计而非板上实测；"
  "（4）固件占用（text 6.0KB + bss 4.4KB）取自 arm-none-eabi-size。上述口径区别在答辩与论文引用时应予保留，"
  "避免把估算值当作实测值引用。")
H("第四部分  总结")
H("4.1  可扩展之处", 2)
P("（1）环境应力：补高低温箱与电压拉偏下的位差-温度曲线，按温度分档自适应纠错阈值；（2）调理层：AES密钥"
  "过SHA-256(K‖salt)进一步合规化（SP 800-90B熵评估）；（3）消耗制池扩容：CRP空间2^21支撑约1.6万次"
  "会话，扩容需增大环阵列与挑战字宽（消耗制会话认证本身已实现，见3.3.8）；（4）芯粒/无人机场景的实物"
  "联调与更大规模节点（USB Hub扩展）。")
H("4.2  心得体会", 2)
P("其一，FPGA上某些类型的PUF本质是“与布线决定论的对抗”——同一位流在两块芯片布线延迟逐位相同，依赖路径竞赛"
  "的结构全部同质化，双稳环的振荡奇偶性成为幸存者。其二，物理规律要用物理实验裁决：测量发现批内多次采样存在相关性（共享同一亚稳态锁存，独立样本数远小于采样次数），据此采用跨批统计构造身份，而非简单加大重复次数。其三，安全系统要报分布、报最差：五芯片唯一性11.1%~44.7%、认证成功率、"
  "纠错nerr分布——所有指标给出样本量与最差值。其四，调试通道的信任要靠对拍建立：BCH解码器x86对拍200/200后"
  "才上板，一次通过；而位序/字节序这类“显然正确”的环节恰恰贡献了当晚仅有的两个bug。")

H("第五部分  参考文献")
for ref in [
    "[1] Q. Chen, G. Csaba, P. Lugli, U. Schlichtmann, U. Rührmair. The Bistable Ring PUF: A New Generation of Logic-PUFs. DATE 2011.",
    "[2] G. E. Suh, S. Devadas. Physical Unclonable Functions for Device Authentication and Secret Key Generation. DAC 2007.",
    "[3] Y. Dodis, L. Reyzin, A. Smith. Fuzzy Extractors: How to Generate Strong Keys from Biometrics and Other Noisy Data. EUROCRYPT 2004.",
    "[4] J. H. van Lint. Introduction to Coding Theory. 3rd ed., Springer. (BCH码)",
    "[5] M. Majzoobi, F. Koushanfar, et al. Automated Design and Implementation of Reconfigurable PUFs. TODAES 2014.",
    "[6] A. Maiti, P. Schaumont. Improved Ring Oscillator PUF: An FPGA-Based Secure and Stable PUF. J. Cryptographic Engineering 2012.",
    "[7] U. Rührmair, et al. PUF Modeling Attacks on Simulated and Silicon Data. IEEE TIFS 2013.",
    "[8] Xilinx. Zynq-7000 SoC Technical Reference Manual (UG585).",
    "[9] 本项目工程台账与数据集：fleet_manifest.txt、night/目录、bchdec.c对拍记录（内部资料）.",
]:
    P(ref, indent=False, size=10.5)

doc.save(OUT)
print("V2 saved:", OUT, "| paragraphs:", len(doc.paragraphs), "| tables:", len(doc.tables))
