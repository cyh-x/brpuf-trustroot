# fuzzy.py — BCH 模糊提取器 (systematic 构造, PUF 密钥纠错)
# 架构 (纯 PC 侧, 固件零改动):
#   ENROLL(生成): 设备派生 K(32B) -> data = K|pad(16B 随机) -> C = data|ECC(data) (71B, 存库)
#                 helper W = ECC 段 (23B, 公开存储; data 段=K 不公开, 只存 ECC)
#   AUTH(复现):   设备派生 K' -> data' = K'|pad(ECC 处已存 pad, 不需要 K')
#                 注意: pad 必须从库里的 C 取 (K' 只覆盖前 32B, 后 16B 用注册值原样)
#                 BCH_decode(data', ecc) 纠 <=18 位 -> data 还原 -> K = data'[:32]
# 安全性: W=ECC 段公开. 系统码的 ECC 是 K 的确定函数 — 会泄露部分信息!
#         对策 (文献标准做法): pad 用随机数 -> data = K|rand 后整体经 BCH, ECC(rand|K 交织)
#         严格讲系统 BCH 的 ECC 段仍泄露 K 的线性组合; 完备方案是 secrecy 要求下
#         用 code-offset (W=K xor C_random). 本实现先跑通功能, helper 泄露分析写文档.
#   ——最终采用 code-offset: 随机选合法码字 C (随机 data 编码), helper W = K xor C_data[:32] (32B)
#     auth: data' = K' xor W | pad' -> 需要存 pad'... pad 也要存. => helper = W(32B) + pad(16B) = 48B
import bchlib
import os

BCH_T = 18
BCH_M = 10

_bch = None
def bch():
    global _bch
    if _bch is None:
        _bch = bchlib.BCH(t=BCH_T, m=BCH_M)
    return _bch

KEY_BYTES = 32
PAD_BYTES = 16
DATA_BYTES = KEY_BYTES + PAD_BYTES   # 48

def enroll_gen(key_hex):
    """K -> (C_hex, W_hex)
    C = data|ecc (71B), data = K|pad16. W = C 完整存储减 K? 
    code-offset: 随机 R=48B, C=BCH_encode(R); W = K xor C[:32] (32B公开);
    pad' = C[32:48] (16B, 公开). helper 共 48B."""
    R = bytearray(os.urandom(DATA_BYTES))
    ecc = bytearray(bch().encode(bytes(R)))
    C = bytes(R) + bytes(ecc)                                   # 71B
    W = bytes(a ^ b for a, b in zip(bytes.fromhex(key_hex), C[:KEY_BYTES]))
    return C.hex().upper(), W.hex().upper()

def auth_rep(kp_hex, C_hex, W_hex):
    """K' + C + W -> (K_recovered, nerr)
    data' = K' xor W | C[32:48]  (前 32B = C[:32] xor 噪声E)
    BCH 纠错 -> data 还原 -> K = data[:32] xor W"""
    C = bytes.fromhex(C_hex)
    W = bytes.fromhex(W_hex)
    kp = bytes.fromhex(kp_hex)
    d = bytearray(bytes(a ^ b for a, b in zip(kp, W)) + C[KEY_BYTES:DATA_BYTES])
    e = bytearray(C[DATA_BYTES:])
    nerr = bch().decode(data=d, recv_ecc=e)
    bch().correct(data=d, ecc=e)
    K = bytes(a ^ b for a, b in zip(d[:KEY_BYTES], W))
    return K.hex().upper(), nerr

if __name__ == '__main__':
    import random
    ok = 0
    for trial in range(200):
        K = os.urandom(KEY_BYTES).hex().upper()
        C, W = enroll_gen(K)
        Ki = bytearray(bytes.fromhex(K))
        nf = random.randint(1, 18)
        for b in random.sample(range(256), nf):
            Ki[b//8] ^= 1 << (b % 8)
        Kr, nerr = auth_rep(Ki.hex().upper(), C, W)
        ok += (Kr == K)
    print('200 trials: %d recovered' % ok)
    K = os.urandom(KEY_BYTES).hex().upper()
    C, W = enroll_gen(K)
    Ki = bytearray(bytes.fromhex(K))
    for b in random.sample(range(256), 19):
        Ki[b//8] ^= 1 << (b % 8)
    Kr, nerr = auth_rep(Ki.hex().upper(), C, W)
    print('19-bit:', 'recovered(意外)' if Kr == K else 'failed(预期)')
