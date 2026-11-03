/* bchdec.h — 设备端 BCH(1023, t=18) 解码器, m=10, GF(2^10)
 * 位序与 bchlib 对齐: 数据按字节 LSB-first 展开成比特流 (bchlib 约定)
 * 接口: bch_decode(d[48], e[23]) — 就地纠错, 返回纠正的错误位数 (-1=失败)
 */
#ifndef BCHDEC_H
#define BCHDEC_H
#include <stdint.h>

#define BCH_N     1023
#define BCH_M      10
#define BCH_T      18
#define BCH_DATA_BYTES 48
#define BCH_ECC_BYTES  23

int bch_decode(uint8_t *d, uint8_t *e);

#endif
