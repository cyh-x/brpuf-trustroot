/* ps_app.c — Zynq-7020 PS(A9) 裸机: 通过 PL 邮箱 BRAM 服务 PC 认证命令 (v13)
 *
 * 邮箱: PL 内 64 字双口 BRAM, PC 经 JTAG-AXI/demux @0x40030000, PS 经 GP0 @0x40030000
 * 协议:
 *   [0]=命令字 (PC 写, bit31:16=0xA5A5, bit15:0=命令码; PS 执行后写 0)
 *   [1]=参数0  [2]=参数1
 *   [2..9]     数据区 (AES key 8 字 + 明文 4 字 = 12 字, 复用 [2..13])
 *   [16]=状态 (PS 上电写 0x100; 完成命令后写 0x8000|命令码)
 *   [17..24]=结果区 8 字
 * 命令码: 1=PING  2=AES加密(读[2..9] key, [10..13]明文, 写[17..20]密文)
 *         3=TRNG 256bit  4=PUF单挑战([1]=挑战字, 写[17]=vote/unst/diff)
 *         5=读PUF版本  6=读三引擎状态
 */
typedef unsigned int  u32;

#define MB_BASE   0x40030000u
#define MB(i)     (*(volatile u32*)(MB_BASE + 4u*(i)))

#define PUF_BASE  0x40000000u
#define AES_BASE  0x40010000u
#define TRNG_BASE 0x40020000u

#define R32(a)   (*(volatile u32*)(a))
#define W32(a,v) (*(volatile u32*)(a) = (v))

static u32 res[8];

static void trng_key(u32 *out) {
    u32 i;
    W32(TRNG_BASE + 0x00, 0x01);
    while (!(R32(TRNG_BASE + 0x04) & 0x02)) { }
    for (i = 0; i < 8; i++) out[i] = R32(TRNG_BASE + 0x10 + 4u*i);
    W32(TRNG_BASE + 0x00, 0x03);
    W32(TRNG_BASE + 0x00, 0x01);
}

static int aes_enc(const u32 *key, const u32 *in, u32 *out) {
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

int main(void) {
    u32 i, cmd, magic;
    u32 key[8], din[4];

    MB(16) = 0x100;                       /* 就绪 */
    for (i = 0; i < 8; i++) MB(17 + i) = 0;
    MB(0) = 0;

    for (;;) {
        magic = MB(0);
        if ((magic >> 16) != 0xA5A5u) continue;
        cmd = magic & 0xFFFFu;

        for (i = 0; i < 8; i++) res[i] = 0;

        if (cmd == 1) {                   /* PING */
            res[0] = 0xB00C;              /* PS app 存活标记 */
            res[1] = R32(PUF_BASE + 0x00);
            res[2] = R32(TRNG_BASE + 0x04);
            res[3] = R32(AES_BASE + 0x34);
        } else if (cmd == 2) {            /* AES */
            for (i = 0; i < 8; i++) key[i] = MB(2 + i);
            for (i = 0; i < 4; i++) din[i] = MB(10 + i);
            if (aes_enc(key, din, res) == 0) res[4] = 0x600D;
        } else if (cmd == 3) {            /* TRNG */
            trng_key(res);
        } else if (cmd == 4) {            /* PUF 单挑战 */
            u32 ch = MB(1) & 0x3FFFFFu;
            W32(PUF_BASE + 0x20, ch);
            W32(PUF_BASE + 0x24, 0);
            W32(PUF_BASE + 0x08, 0x04);
            {
                u32 t = 0;
                while (!(R32(PUF_BASE + 0x0C) & 0x02)) { if (++t > 300000) break; }
            }
            res[0] = 0x4000u | (R32(PUF_BASE + 0x1C) & 0xFFFFu);
            res[1] = R32(PUF_BASE + 0x00);
        } else if (cmd == 5) {            /* PUF 版本 */
            res[0] = R32(PUF_BASE + 0x00);
        } else {                          /* 未知 */
            res[0] = 0xDEAD0000u | cmd;
        }

        for (i = 0; i < 8; i++) MB(17 + i) = res[i];
        MB(16) = 0x8000u | cmd;           /* 完成标志 */
        MB(0) = 0;                        /* 消费命令 */
    }
}
