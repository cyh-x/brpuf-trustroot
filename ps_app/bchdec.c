/* bchdec.c — BCH(1023,t=18) 解码器, GF(2^10), 本原多项式 x^10+x^3+1 (0x485 <=> 615?)
 * bchlib m=10 默认本原多项式: 0x409 (x^10+x^6+x^7+x^9+1)? 必须与 bchlib 一致.
 * bchlib 源码 (bch.c): prim_poly 默认表 m=10 -> 0x409. 校验方法: PC 对拍.
 * 约束: BM 迭代求错误位置多项式, Chien 搜索找根, syndromes 用 alpha^1..alpha^2t.
 * 位流展开: byte i 的 bit j (LSB=bit0) -> 流的第 i*8+j 位; 流第 p 位对应码字位置 p.
 * (bchlib swap_bits=False 的约定: 字节内 LSB 是低地址端? 对拍确认, 若反了改 GETBIT.)
 */
#include <stdint.h>
#include <string.h>
#include "bchdec.h"

/* freestanding 环境无 libc: 自带 memcpy/memset */
void *memcpy_(void *dst, const void *src, unsigned n);
void *memset_(void *dst, int v, unsigned n);
#define memcpy memcpy_
#define memset memset_

#define GF_EXP_SZ  (BCH_N + 1)          /* alpha^0..alpha^1022 */
#define GF_LOG_SZ  (1 << BCH_M)         /* log 表 0..1023 */

static int16_t exp_tab[GF_EXP_SZ];
static int16_t log_tab[GF_LOG_SZ];
static int gf_ready = 0;

static void gf_init(void) {
    int x = 1;
    /* 本原多项式 0x409: x^10+x^6+x^5+x^3+1? bchlib 用 (1<<m)|0x9 ?? 对拍定 */
    const uint32_t prim = 1033u;            /* bchlib m=10 默认: 1033 = 0x409 */
    for (int i = 0; i < BCH_N; i++) {
        exp_tab[i] = (int16_t)x;
        log_tab[x] = (int16_t)i;
        x <<= 1;
        if (x & (1u << BCH_M)) x ^= prim;
    }
    exp_tab[BCH_N] = exp_tab[0];
    gf_ready = 1;
}

#define GF_MUL(a, b) ((a) == 0 || (b) == 0 ? 0 : exp_tab[(log_tab[a] + log_tab[b]) % BCH_N])
#define GF_DIV(a, b) ((a) == 0 ? 0 : exp_tab[(log_tab[a] - log_tab[b] + BCH_N) % BCH_N])
#define GF_POW(a, n) ((a) == 0 ? 0 : exp_tab[(log_tab[a] * (n)) % BCH_N])
#define GF_INV(a)    exp_tab[(BCH_N - log_tab[a]) % BCH_N]

/* 位流约定 (与 bchlib 对齐, PC 暴力校准确认): 字节流 MSB-first,
   多项式系数降幂: 流位置 q 的系数索引 coeff = COEF_MAX - q */
#define CW_BYTES (BCH_DATA_BYTES + BCH_ECC_BYTES)
#define COEF_MAX (CW_BYTES * 8)      /* 568 */

static int getbit(const uint8_t *d, const uint8_t *e, int q) {
    if (q < BCH_DATA_BYTES * 8) return (d[q >> 3] >> (7 - (q & 7))) & 1;
    q -= BCH_DATA_BYTES * 8;
    return (e[q >> 3] >> (7 - (q & 7))) & 1;
}
static void clrbit(uint8_t *d, uint8_t *e, int q) {
    if (q < BCH_DATA_BYTES * 8) d[q >> 3] &= (uint8_t)~(1u << (7 - (q & 7)));
    else { q -= BCH_DATA_BYTES * 8; e[q >> 3] &= (uint8_t)~(1u << (7 - (q & 7))); }
}

int bch_decode(uint8_t *d, uint8_t *e) {
    static uint8_t cw[BCH_DATA_BYTES + BCH_ECC_BYTES];
    if (!gf_ready) gf_init();
    memcpy(cw, d, BCH_DATA_BYTES);
    memcpy(cw + BCH_DATA_BYTES, e, BCH_ECC_BYTES);

    /* syndromes S_i = C(alpha^i), i=1..2t */
    int16_t S[2 * BCH_T];
    int nonzero = 0;
    for (int i = 1; i <= 2 * BCH_T; i++) {
        int s = 0;
        for (int q = 0; q < COEF_MAX; q++) {
            if (getbit(cw, cw + BCH_DATA_BYTES, q))
                s ^= exp_tab[(int)((long)i * (COEF_MAX - 1 - q) % BCH_N)];
        }
        S[i - 1] = (int16_t)s;
        if (s) nonzero = 1;
    }
    if (!nonzero) { memcpy(d, cw, BCH_DATA_BYTES); memcpy(e, cw + BCH_DATA_BYTES, BCH_ECC_BYTES); return 0; }

    /* Berlekamp-Massey */
    int16_t C[BCH_T + 1], B[BCH_T + 1];
    for (int zq = 0; zq <= BCH_T; zq++) { C[zq] = 0; B[zq] = 0; }
    C[0] = 1; B[0] = 1;
    int L = 0, m = 1, b = 1;
    for (int nn = 0; nn < 2 * BCH_T; nn++) {
        int16_t disc = S[nn];
        for (int i = 1; i <= L; i++)
            disc ^= GF_MUL(C[i], S[nn - i]);
        if (disc == 0) { m++; continue; }
        int16_t T[BCH_T + 1];
        memcpy(T, C, sizeof(C));
        int16_t coef = GF_MUL(disc, GF_INV(b));
        for (int i = 0; i + m <= BCH_T; i++)
            C[i + m] ^= GF_MUL(coef, B[i]);
        if (2 * L <= nn) {
            memcpy(B, T, sizeof(B));
            L = nn + 1 - L;
            b = disc;
            m = 1;
        } else {
            m++;
        }
    }
    if (L > BCH_T) return -1;

    /* Chien search: 找 C(x) 的根 alpha^(-p) => 错误位置 p */
    int nfix = 0;
    for (int q = 0; q < COEF_MAX; q++) {
        int coeff = COEF_MAX - 1 - q;
        /* 根 = alpha^(-coeff) = alpha^(N-coeff) */
        int16_t x = exp_tab[(BCH_N - coeff) % BCH_N];
        int v = 0;
        for (int j = 0; j <= L; j++)
            if (C[j]) v ^= GF_MUL(C[j], GF_POW(x, j));
        if (v == 0) {
            /* 纠错 = 翻转该位 (不是清零! 1->0 和 0->1 两种方向都要处理) */
            cw[q >> 3] ^= (uint8_t)(1u << (7 - (q & 7)));   /* 翻内部 cw, 最后统一回写 */
            nfix++;
        }
    }
        if (nfix != L) {
        return -1;
    }

    /* 最终校验: 重算 syndrome 应全零 */
    for (int i = 1; i <= 2 * BCH_T; i++) {
        int s = 0;
        for (int q = 0; q < COEF_MAX; q++)
            if (getbit(cw, cw + BCH_DATA_BYTES, q))
                s ^= exp_tab[(int)(((long)i * (COEF_MAX - 1 - q)) % BCH_N)];
        if (s) {
            return -1;
        }
    }
    memcpy(d, cw, BCH_DATA_BYTES);
    memcpy(e, cw + BCH_DATA_BYTES, BCH_ECC_BYTES);
    return nfix;
}

void *memcpy_(void *dst, const void *src, unsigned n) {
    unsigned char *d8 = (unsigned char*)dst;
    const unsigned char *s8 = (const unsigned char*)src;
    while (n--) *d8++ = *s8++;
    return dst;
}
void *memset_(void *dst, int v, unsigned n) {
    unsigned char *d8 = (unsigned char*)dst;
    while (n--) *d8++ = (unsigned char)v;
    return dst;
}
