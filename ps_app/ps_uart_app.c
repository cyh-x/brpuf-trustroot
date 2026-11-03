/* ps_uart_app.c — PS(A9) UART 协议应用 v14: 三引擎信任根 + ENROLL/AUTH 协议
 *
 * UART1 (MIO 48/49), 115200 baud, 直接寄存器访问 (无 BSP 依赖)
 * 协议格式 (与 vitistest helloworld.c 兼容):
 *   CMD:ENROLL:<dev_id>\r\n          → RESP:ENROLL:<dev_id>:<64 hex>\r\n
 *   CMD:AUTH:<dev_id>:<32 hex E1>\r\n → RESP:AUTH:<dev_id>:<32 hex E2>:<32 hex E3>\r\n
 *   CMD:PING\r\n                     → RESP:PING:OK:PUF_VER:<hex>:AES_ST:<hex>:TRNG_ST:<hex>\r\n
 *
 * PL 基址 (GP0): 0x4000_0000 BR-PUF / 0x4001_0000 AES / 0x4002_0000 TRNG
 */
typedef unsigned int  u32;
typedef unsigned char u8;
#include "bchdec.h"

#define UART_BASE   0xE0001000u    /* UART1 */
#define PUF_BASE    0x40000000u
#define AES_BASE    0x40010000u
#define TRNG_BASE   0x40020000u

#define R32(a)   (*(volatile u32*)(a))
#define W32(a,v) (*(volatile u32*)(a) = (v))

/* ---- UART1 寄存器 (Zynq-7000 PS) ---- */
#define UART_CR   (UART_BASE + 0x00)
#define UART_MR   (UART_BASE + 0x04)
#define UART_IER  (UART_BASE + 0x08)
#define UART_IDR  (UART_BASE + 0x0C)
#define UART_IMR  (UART_BASE + 0x10)
#define UART_ISR  (UART_BASE + 0x14)
#define UART_BAUD (UART_BASE + 0x18)
#define UART_SR   (UART_BASE + 0x2C)
#define UART_FIFO (UART_BASE + 0x30)

#define SR_TXFULL  0x10
#define SR_RXEMPTY 0x02

#define UART_REF   (0xF8000154u)   /* SLCR UART1_CLK_CTRL */

/* TX 回显环形缓冲 (0x1FF100, 256B): 应用写入 FIFO 的每个字节都留痕,
   JTAG 读它即可知道应用到底发了什么、发到哪里卡住 */
#define TXLOG ((volatile char*)0x001FF100u)
static unsigned txlog_pos = 0;
static void uart_putc(char c) {
    while (R32(UART_SR) & SR_TXFULL) { }
    *(volatile char*)UART_FIFO = c;
    TXLOG[txlog_pos++ & 0xFF] = c;
}

static void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}

static char uart_getc(void) {
    while (R32(UART_SR) & SR_RXEMPTY) { }
    return *(volatile char*)UART_FIFO;
}

static void uart_puthex32(u32 v) {
    static const char hex[] = "0123456789ABCDEF";
    int i;
    for (i = 28; i >= 0; i -= 4) uart_putc(hex[(v >> i) & 0xF]);
}

/* 诊断信标 (默认 DDR 0x001FF000; OCM 版本用 -DBEACON_ADDR=0x20000 覆盖):
   JTAG 侧直接读这 7 个字即可判定应用是否执行、UART 寄存器是否可写 */
#ifndef BEACON_ADDR
#define BEACON_ADDR 0x001FF000u
#endif
#define BEACON ((volatile u32*)BEACON_ADDR)
#define BEACON_MAGIC 0x5AA5C0DEu

/* ---- PS 硬件自初始化 (SD 卡引导, 无 ps7_init/FSBL 依赖) ----
 * 寄存器序列逐条移植自 pr_out/ps7_init_uart.tcl (v14 PS7 IP 生成),
 * UART1 分频按 IOPLL=33.333MHz*58/2=966.67MHz, /32=30.21MHz 重算:
 * CD=131, BDIV=1 -> 115.3k (误差 0.087%); IP 自带 CD=124/BDIV=6 需要
 * 100MHz 参考钟, 与其自身分频配置 (IOPLL/32) 矛盾, 故不采用。 */
static void mw(u32 addr, u32 mask, u32 val) {
    u32 r = R32(addr);
    R32(addr) = (r & ~mask) | (val & mask);
}

static void ps_init(void) {
    /* ps7_pll_init: IO/ARM/DDR PLL (0xDF0D 序列与 IP 生成文件一致) */
    R32(0xF8000008u) = 0x0000767Bu;   /* SLCR 解锁 (真密钥; IP 生成文件里的 0xDF0D 是无效值) */
    mw(0xF8000110u, 0x003FFFF0u, 0x000FA220u);          /* ARM_PLL_CFG: FBDIV=40 -> 666.67MHz */
    mw(0xF8000100u, 0x0007F000u, 0x00028000u);          /* ARM_PLL_CTRL */
    mw(0xF8000100u, 0x00000010u, 0x00000010u);
    mw(0xF8000100u, 0x00000001u, 0x00000001u);
    mw(0xF8000100u, 0x00000001u, 0x00000000u);
    while ((R32(0xF800010Cu) & 0x1u) == 0u) { }          /* ARM PLL lock */
    mw(0xF8000100u, 0x00000010u, 0x00000000u);
    mw(0xF8000120u, 0x1F003F30u, 0x1F000200u);
    mw(0xF8000114u, 0x003FFFF0u, 0x0012C220u);          /* DDR_PLL_CFG */
    mw(0xF8000104u, 0x0007F000u, 0x00020000u);
    mw(0xF8000104u, 0x00000010u, 0x00000010u);
    mw(0xF8000104u, 0x00000001u, 0x00000001u);
    mw(0xF8000104u, 0x00000001u, 0x00000000u);
    while ((R32(0xF800010Cu) & 0x2u) == 0u) { }          /* DDR PLL lock */
    mw(0xF8000104u, 0x00000010u, 0x00000000u);
    mw(0xF8000124u, 0xFFF00003u, 0x0C200003u);          /* DDR_CLK_CTRL */
    mw(0xF8000118u, 0x003FFFF0u, 0x000FA240u);          /* IO_PLL_CFG: FBDIV=58 -> 966.67MHz */
    mw(0xF8000108u, 0x0007F000u, 0x00030000u);          /* IO_PLL_CTRL */
    mw(0xF8000108u, 0x00000010u, 0x00000010u);
    mw(0xF8000108u, 0x00000001u, 0x00000001u);
    mw(0xF8000108u, 0x00000001u, 0x00000000u);
    while ((R32(0xF800010Cu) & 0x4u) == 0u) { }          /* IO PLL lock */
    mw(0xF8000108u, 0x00000010u, 0x00000000u);
    R32(0xF8000004u) = 0x0000767Bu;
    BEACON[7] = 1;                                       /* 阶段1: PLL 完成 */

    /* ps7_clock_init */
    R32(0xF8000008u) = 0x0000767Bu;   /* SLCR 解锁 (真密钥; IP 生成文件里的 0xDF0D 是无效值) */
    mw(0xF8000128u, 0x03F03F01u, 0x00700F01u);
    mw(0xF8000168u, 0x00003F31u, 0x00000801u);          /* PCAP_CLK_CTRL */
    mw(0xF8000170u, 0x03F03F30u, 0x00400600u);          /* FCLK0 */
    mw(0xF80001C4u, 0x00000001u, 0x00000001u);
    mw(0xF800012Cu, 0x01FFCCCDu, 0x014C000Du);
    R32(0xF8000004u) = 0x0000767Bu;
    BEACON[7] = 2;                                       /* 阶段2: 时钟完成 */

    /* UART1 参考时钟: CLKACT=1, DIV0=2, DIV1=16 -> 30.21MHz */
    R32(0xF8000008u) = 0x0000767Bu;
    mw(0xF8000154u, 0x01F03F33u, 0x00011002u);
    R32(0xF8000004u) = 0x0000767Bu;
    BEACON[7] = 3;                                       /* 阶段3: UART 参考钟完成 */

    /* ps7_mio_init: SDIO/GEM 时钟默认值 + MIO48/49 = UART1 (TX/RX) */
    R32(0xF8000008u) = 0x0000767Bu;   /* SLCR 解锁 (真密钥; IP 生成文件里的 0xDF0D 是无效值) */
    mw(0xF8000B40u, 0x00000FFFu, 0x00000600u);
    mw(0xF8000B44u, 0x00000FFFu, 0x00000600u);
    mw(0xF8000B48u, 0x00000FFFu, 0x00000672u);
    mw(0xF8000B4Cu, 0x00000FFFu, 0x00000672u);
    mw(0xF8000B50u, 0x00000FFFu, 0x00000674u);
    mw(0xF8000B54u, 0x00000FFFu, 0x00000674u);
    mw(0xF8000B58u, 0x00000FFFu, 0x00000600u);
    mw(0xF8000B5Cu, 0xFFFFFFFFu, 0x0018C61Cu);
    mw(0xF8000B60u, 0xFFFFFFFFu, 0x00F9861Cu);
    mw(0xF8000B64u, 0xFFFFFFFFu, 0x00F9861Cu);
    mw(0xF8000B68u, 0xFFFFFFFFu, 0x00F9861Cu);
    mw(0xF8000B6Cu, 0x00007FFFu, 0x00000260u);
    mw(0xF8000B70u, 0x00000001u, 0x00000001u);
    mw(0xF8000B70u, 0x00000021u, 0x00000020u);
    mw(0xF8000B70u, 0x07FEFFFFu, 0x00000823u);
    mw(0xF80007C0u, 0x00003FFFu, 0x000006E0u);          /* MIO_PIN_48 = UART1 TX */
    mw(0xF80007C4u, 0x00003FFFu, 0x000007E1u);          /* MIO_PIN_49 = UART1 RX */
    R32(0xF8000004u) = 0x0000767Bu;

    /* ps7_peripherals_init: MIO 供电压平 + UART1 寄存器 */
    R32(0xF8000008u) = 0x0000767Bu;   /* SLCR 解锁 (真密钥; IP 生成文件里的 0xDF0D 是无效值) */
    mw(0xF8000B48u, 0x00000180u, 0x00000180u);
    mw(0xF8000B4Cu, 0x00000180u, 0x00000180u);
    mw(0xF8000B50u, 0x00000180u, 0x00000180u);
    mw(0xF8000B54u, 0x00000180u, 0x00000180u);
    R32(0xF8000004u) = 0x0000767Bu;
    R32(0xF8000008u) = 0x0000767Bu;                     /* APER_CLK_CTRL: UART 时钟门控 */
    mw(0xF800012Cu, 0x00300000u, 0x00300000u);          /* bit20/21 = UART0/1 CPU_1x 时钟
                                                           (注意: APER 真地址 0x12C; 0x120 是 ARM_CLK_CTRL) */
    R32(0xF8000004u) = 0x0000767Bu;
    mw(0xE0001034u, 0x000000FFu, 0x00000001u);          /* UART1 BDIV=1 */
    mw(0xE0001018u, 0x0000FFFFu, 0x00000083u);          /* UART1 CD=131 */
    mw(0xE0001000u, 0x000001FFu, 0x00000017u);          /* CR: TXRES+RXRES+RXEN+TXEN */
    mw(0xE0001004u, 0x000003FFu, 0x00000020u);          /* MR: 8N1 (Xilinx PARITY_NONE) */
    mw(0xE000D000u, 0x00080000u, 0x00080000u);
    mw(0xF8007000u, 0x20000000u, 0x00000000u);
    BEACON[7] = 4;                                       /* 阶段4: 外设/UART 完成 */

    /* ps7_post_config: 全部电平移位器使能 (GP0 访问 PL 必需) */
    R32(0xF8000008u) = 0x0000767Bu;   /* SLCR 解锁 (真密钥; IP 生成文件里的 0xDF0D 是无效值) */
    mw(0xF8000900u, 0x0000000Fu, 0x0000000Fu);
    mw(0xF8000240u, 0xFFFFFFFFu, 0x00000000u);
    R32(0xF8000004u) = 0x0000767Bu;
    BEACON[7] = 5;                                       /* 阶段5: post_config 完成 */
}

static void uart_init(void) {
    /* FSBL 已配好 MIO/时钟/波特率; 这里只做 FSBL 同款 "复位+使能" 一笔写:
       CR = TXRES(bit0)|RXRES(bit1)|RXEN(bit2)|TXEN(bit4) = 0x17 (厂家 FSBL 原值)
       (旧值 0x0A = RXRST|RX_DIS, 是错的 —— xuartps: RXEN=0x4 TXEN=0x10) */
    W32(UART_CR, 0x00000017);
    BEACON[2] = R32(UART_CR);
    BEACON[3] = R32(UART_MR);
    BEACON[4] = R32(UART_BAUD);
    BEACON[5] = R32(UART_SR);
}

/* ---- 三引擎驱动 ---- */
/* asm 版 puf_version: LDR 之后 NOP 再 BX LR —— PL 不可达触发 data abort 时,
   skip_abort 向量跳到 NOP 之后 (即 BX LR), 函数安全返回而不挂死 */
u32 puf_version(void);   /* asm 实现, 见下 */
__asm(
    ".global puf_version\n"
    "puf_version:\n"
    "    ldr r0, =0x40000000\n"
    "    ldr r0, [r0]\n"
    "    nop\n"
    "    bx lr\n"
);

static void trng_key(u32 *out) {
    u32 i;
    W32(TRNG_BASE + 0x00, 0x01);
    while (!(R32(TRNG_BASE + 0x04) & 0x02)) { }
    for (i = 0; i < 8; i++) out[i] = R32(TRNG_BASE + 0x10 + 4u*i);
    W32(TRNG_BASE + 0x00, 0x03);
    W32(TRNG_BASE + 0x00, 0x01);
}

static int aes_dec(const u32 *key, const u32 *in, u32 *out) {
    u32 i, t;
    for (i = 0; i < 8; i++) W32(AES_BASE + 4u*i, key[i]);
    W32(AES_BASE + 0x30, 0x01);                  /* start=1 encrypt=0 */
    W32(AES_BASE + 0x30, 0x00);
    t = 0;
    while (!(R32(AES_BASE + 0x34) & 0x04)) { if (++t > 100000) return -1; }
    for (i = 0; i < 4; i++) W32(AES_BASE + 0x20 + 4u*i, in[i]);
    W32(AES_BASE + 0x30, 0xFFFF000Cu);           /* keep=16B last valid dec */
    W32(AES_BASE + 0x30, 0xFFFF0008u);
    t = 0;
    while (R32(AES_BASE + 0x34) & 0x01) { if (++t > 200000) return -2; }
    for (i = 0; i < 4; i++) out[i] = R32(AES_BASE + 0x38 + 4u*i);
    return 0;
}

static int aes_enc15(const u32 *key, const u32 *in, u32 *out) {
    u32 i, t;
    for (i = 0; i < 8; i++) W32(AES_BASE + 4u*i, key[i]);
    W32(AES_BASE + 0x30, 0x03);
    W32(AES_BASE + 0x30, 0x02);
    t = 0;
    while (!(R32(AES_BASE + 0x34) & 0x04)) { if (++t > 100000) return -1; }
    for (i = 0; i < 4; i++) W32(AES_BASE + 0x20 + 4u*i, in[i]);
    W32(AES_BASE + 0x30, 0xFFFE000Eu);
    W32(AES_BASE + 0x30, 0xFFFE000Au);
    t = 0;
    while (R32(AES_BASE + 0x34) & 0x01) { if (++t > 200000) return -2; }
    for (i = 0; i < 4; i++) out[i] = R32(AES_BASE + 0x38 + 4u*i);
    return 0;
}

/* PUF: 取根密钥 (256 bit = 32 个挑战响应) */
/* 一批测量: 256 偶校验挑战 × REP_N 次 (base 决定挑战组), 读回带校验 */
static int puf_measure(u32 *vote, u32 *unst, u32 n, u32 base, u32 reps) {
    u32 i, t;
    for (i = 0; i < 8; i++) { vote[i] = 0; unst[i] = 0; }
    for (i = 0; i < n; i++) {
        /* 挑战 pattern 偶校验: 偶校验->双稳态; 奇校验->不振荡 */
        u32 pat = (base + i) & 0xFFFFu;
        u32 x = pat, par = 0;
        while (x) { par ^= (x & 1u); x >>= 1; }
        if (par) pat ^= 1u;
        u32 ch = ((((base >> 16) + i) & 0x3Fu) << 16) | pat;
        W32(PUF_BASE + 0x20, ch & 0x3FFFFFu);
        W32(PUF_BASE + 0x34, ((i << 2)) | 1);
    }
    W32(PUF_BASE + 0x10, reps);
    W32(PUF_BASE + 0x14, n);
    W32(PUF_BASE + 0x08, 0x01);
    t = 0;
    while (!(R32(PUF_BASE + 0x0C) & 0x02)) { if (++t > 60000000u) return -1; }
    for (i = 0; i < n; i++) {
        u32 a = PUF_BASE + 0x100 + 4u*i;
        u32 w = R32(a), w2 = R32(a), w3;
        if (w != w2) { w3 = R32(a); w = (w == w3) ? w : w2; }
        vote[i >> 5] |= ((w & 1u) << (i & 31));
        unst[i >> 5] |= (((w >> 1) & 1u) << (i & 31));
    }
    return 0;
}

/* v31 派生: 24 批跨批统计 (批内相关, 批独立), c==24 全票收 1, 其余 0.
   稳定性由 AUTH 时 BCH 纠错保证 (设备端 bchdec.c), 不再需要灰区筛选 */
static int puf_derive(u32 *key256) {
    u32 v[8], u[8], c[256], i, b;
    for (i = 0; i < 256; i++) c[i] = 0;
    for (b = 0; b < 24; b++) {
        if (puf_measure(v, u, 256, 0x12345678u, 1) != 0) return -1;
        for (i = 0; i < 256; i++) c[i] += (v[i >> 5] >> (i & 31)) & 1u;
    }
    for (i = 0; i < 8; i++) key256[i] = 0;
    for (i = 0; i < 256; i++)
        if (c[i] >= 24u) key256[i >> 5] |= (1u << (i & 31));
    return 0;
}

/* 单挑战测量: 写入 1 个挑战, rep 次重复多数决, 返回响应位 (0/1) 或 -1 */
static int puf_single(u32 ch, u32 reps) {
    u32 t;
    W32(PUF_BASE + 0x20, ch & 0x3FFFFFu);
    W32(PUF_BASE + 0x34, 0x1);                 /* 挑战 RAM[0] */
    W32(PUF_BASE + 0x10, reps);
    W32(PUF_BASE + 0x14, 1);
    W32(PUF_BASE + 0x08, 0x01);
    t = 0;
    while (!(R32(PUF_BASE + 0x0C) & 0x02)) { if (++t > 20000000u) return -1; }
    return (int)(R32(PUF_BASE + 0x100) & 1u);
}

/* 板卡指纹: 64 个固定挑战 (偶校验) 的多数决响应 -> 64bit, 用于响应级身份识别 */
static void puf_fingerprint(u32 *id2) {
    u32 i;
    id2[0] = 0; id2[1] = 0;
    for (i = 0; i < 64; i++) {
        u32 pat = (0xA5C3u + i * 977u) & 0xFFFFu;
        u32 x = pat, par = 0;
        while (x) { par ^= (x & 1u); x >>= 1; }
        if (par) pat ^= 1u;
        u32 ch = ((((0x2A5u + i * 7u) & 0x3Fu) << 16) | pat) & 0x3FFFFFu;
        int b = puf_single(ch, 15);
        if (b == 1) id2[i >> 5] |= (1u << (i & 31));
    }
}

/* ---- 协议 ---- */
static u32 cached_key[8];
static int key_ready = 0;
int strlen_(const char *s);
static char line_buf[256];
static int buf_pos = 0;

static u8 hex2byte(char h, char l) {
    u8 v = 0;
    if (h >= '0' && h <= '9') v = (h - '0') << 4;
    else if (h >= 'A' && h <= 'F') v = (h - 'A' + 10) << 4;
    else if (h >= 'a' && h <= 'f') v = (h - 'a' + 10) << 4;
    if (l >= '0' && l <= '9') v |= (l - '0');
    else if (l >= 'A' && l <= 'F') v |= (l - 'A' + 10);
    else if (l >= 'a' && l <= 'f') v |= (l - 'a' + 10);
    return v;
}

static void hex2u32(const char *hex, u32 *out, int nw) {
    int i;
    for (i = 0; i < nw; i++) {
        out[i] = (hex2byte(hex[i*8+0], hex[i*8+1]) << 24) |
                 (hex2byte(hex[i*8+2], hex[i*8+3]) << 16) |
                 (hex2byte(hex[i*8+4], hex[i*8+5]) <<  8) |
                 (hex2byte(hex[i*8+6], hex[i*8+7]));
    }
}

void _puthex(const u32 *w, int nw) {
    int i;
    for (i = 0; i < nw; i++) uart_puthex32(w[i]);
}

int main(void) {

    /* 教训 (厂家 Linux A/B 实测): FSBL 配好的 UART_CLK_CTRL=0xA02 + CD=124/BDIV=6
       = 115200 完全正确; 任何"自修"改写 (如 DIVISOR0=0 非法值) 反而会把时钟关死 */
    BEACON[0] = BEACON_MAGIC;
    BEACON[1] = 0;
    uart_init();
    BEACON[4] = R32(UART_CR);
    BEACON[5] = R32(UART_BAUD);

    uart_puts("\r\n=== Trust Root v14 (UART) ===\r\n");
    BEACON[7] = 1;

    /* 串口自校准: 连续发 'U'(0x55) 直到收到任一字节 (PC 扫频锁定后回发) */
    {
        unsigned guard = 0;
        while (guard++ < 2000000u) {
            uart_putc('U');
            if (!(R32(UART_SR) & SR_RXEMPTY)) { (void)*(volatile char*)UART_FIFO; break; }
        }
    }
    BEACON[7] = 2;
    uart_puts("\r\nCAL_OK\r\nSYSTEM_READY\r\n");
    BEACON[7] = 3;   /* v16: 主循环前零 PL 访问, PL 只在 CMD:PING 时读 */

    BEACON[7] = 5;
    for (;;) {
        char c;
        BEACON[1]++;
        c = uart_getc();
        if (c == '\r' || c == '\n') {
            if (buf_pos == 0) continue;
            line_buf[buf_pos] = '\0';

            /* CMD:PING */
            if (line_buf[0]=='C' && line_buf[1]=='M' && line_buf[2]=='D' &&
                line_buf[3]==':' && line_buf[4]=='P') {
                uart_puts("RESP:PING:OK:PUF=");
                uart_puthex32(puf_version());
                uart_puts(":TRNG=");
                uart_puthex32(R32(TRNG_BASE + 0x04));
                uart_puts(":AES=");
                uart_puthex32(R32(AES_BASE + 0x34));
                uart_puts("\r\n");
            }
            /* CMD:ID — 板卡 PUF 指纹 (64 位), 用于响应级身份识别 */
            else if (line_buf[0]=='C' && line_buf[3]==':' && line_buf[4]=='I') {
                u32 id2[2];
                puf_fingerprint(id2);
                uart_puts("RESP:ID:");
                _puthex(id2, 2);
                uart_puts("\r\n");
            }
            /* CMD:CRP:<6hex ch> — 任意挑战的单次多数决响应 (建模攻击现场对拍)
               格式: CMD:CRP:XXXXXX  -> 十六进制从索引 8 开始, 6 字符 */
            else if (line_buf[0]=='C' && line_buf[4]=='C') {
                int ok = 1;
                u32 ch = 0;
                int k;
                for (k = 0; k < 3; k++) {
                    char hi = line_buf[8 + 2*k], lo = line_buf[9 + 2*k];
                    if (hi == 0 || lo == 0) { ok = 0; break; }
                    ch = (ch << 8) | (u32)hex2byte(hi, lo);
                }
                if (ok) {
                    int b = puf_single(ch & 0x3FFFFFu, 15);
                    if (b < 0) uart_puts("RESP:CRP_FAIL:TIMEOUT\r\n");
                    else {
                        uart_puts("RESP:CRP:");
                        uart_puthex32((u32)b);
                        uart_puts("\r\n");
                    }
                } else {
                    uart_puts("RESP:CRP_FAIL:FMT\r\n");
                }
            }
            /* CMD:ENROLL:<dev_id> — v31: 原始位图注册 (可信产线环境, K 直出) */
            else if (line_buf[0]=='C' && line_buf[4]=='E') {
                uart_puts("RESP:ENROLL:");
                uart_puts(line_buf + 11);
                uart_puts(":");
                if (puf_derive(cached_key) == 0) {
                    key_ready = 1;
                    _puthex(cached_key, 8);
                } else {
                    uart_puts("FAIL");
                }
                uart_puts("\r\n");
            }
            /* CMD:AUTH:<dev>:<W 64hex>:<pad 32hex>:<ecc 46hex>:<E1 32hex>
               v31: helper 走公开信道下发, 设备端 BCH 解码恢复注册 K (K 不出设备) */
            else if (line_buf[0]=='C' && line_buf[4]=='A') {
                char *dev = line_buf + 9;
                char *fld[4] = {0,0,0,0};
                int i, nf = 0;
                for (i = 9; line_buf[i]; i++) {
                    if (line_buf[i] == ':') {
                        line_buf[i] = '\0';
                        if (nf < 4) fld[nf++] = &line_buf[i+1];
                    }
                }
                /* fld: W(64hex=32B) pad(32hex=16B) ecc(46hex=23B) E1(32hex) */
                if (nf == 4 && strlen_(fld[0]) == 64 && strlen_(fld[1]) == 32 &&
                    strlen_(fld[2]) == 46 && strlen_(fld[3]) == 32) {
                    u32 kp[8], Wh[8], E1[4], R1p[4], R2[4], Rmix[4], E2[4], E3[4];
                    uint8_t d[48], e[23];
                    hex2u32(fld[0], Wh, 8);
                    if (puf_derive(kp) != 0) { uart_puts("RESP:AUTH_FAIL:PUF\r\n"); goto auth_done; }
                    /* data' = (K' (+) W) | pad */
                    for (i = 0; i < 32; i++)
                        d[i] = (uint8_t)((kp[i>>2] >> (24 - 8*(i&3))) & 0xFF) ^
                               (uint8_t)((Wh[i>>2] >> (24 - 8*(i&3))) & 0xFF);
                    for (i = 0; i < 16; i++) {
                        d[32+i] = hex2byte(fld[1][2*i], fld[1][2*i+1]);
                    }
                    for (i = 0; i < 23; i++) {
                        e[i] = hex2byte(fld[2][2*i], fld[2][2*i+1]);
                    }
                    int nerr = bch_decode(d, e);
                    if (nerr < 0) { uart_puts("RESP:AUTH_FAIL:ECC\r\n"); goto auth_done; }
                    /* K = data'[:32] (+) W (字节级), 再按大端组装成 u32[8]
                       (与 ENROLL 路径 cached_key 的字节序一致, AES 寄存器按大端取) */
                    for (i = 0; i < 8; i++) {
                        cached_key[i] = ((u32)(d[4*i]   ^ (u8)((Wh[i] >> 24) & 0xFF)) << 24) |
                                        ((u32)(d[4*i+1] ^ (u8)((Wh[i] >> 16) & 0xFF)) << 16) |
                                        ((u32)(d[4*i+2] ^ (u8)((Wh[i] >>  8) & 0xFF)) <<  8) |
                                        (u32)(d[4*i+3] ^ (u8)((Wh[i]      ) & 0xFF));
                    }
                    key_ready = 1;
                    hex2u32(fld[3], E1, 4);
                    if (aes_dec(cached_key, E1, R1p) == 0) {
                        R1p[3] &= 0xFFFFFF00u;
                        trng_key(R2);
                        R2[3] &= 0xFFFFFF00u;
                        for (i = 0; i < 4; i++) Rmix[i] = R1p[i] ^ R2[i];
                        Rmix[3] &= 0xFFFFFF00u;
                        if (aes_enc15(cached_key, R2, E2) == 0 &&
                            aes_enc15(cached_key, Rmix, E3) == 0) {
                            uart_puts("RESP:AUTH:");
                            uart_puts(dev);
                            uart_puts(":");
                            _puthex(E2, 4);
                            uart_puts(":");
                            _puthex(E3, 4);
                            uart_puts(":NERR=");
                            uart_puthex32((u32)nerr);
                            uart_puts("\r\n");
                        } else {
                            uart_puts("RESP:AUTH_FAIL:AES\r\n");
                        }
                    } else {
                        uart_puts("RESP:AUTH_FAIL:DEC\r\n");
                    }
                } else {
                    uart_puts("RESP:AUTH_FAIL:FMT\r\n");
                }
                auth_done: ;
            }
            else {
                uart_puts("RESP:UNKNOWN:");
                uart_puts(line_buf);
                uart_puts("\r\n");
            }
            buf_pos = 0;
        } else {
            if (buf_pos < 250) line_buf[buf_pos++] = c;
        }
    }
}



int strlen_(const char *s) { int n = 0; while (*s++) n++; return n; }
