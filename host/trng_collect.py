import paths
import json
import os
# trng_collect.py — 通过 AUTH 应答的 E2 采集 TRNG 输出 (R2 = AES_dec(K, E2) 的前15字节)
#   E2 = AES_enc(K, R2|0x01) (keep=15+PKCS7), K 是该板注册密钥 -> 解密即得 R2 明文
#   R2 = 板载 neoTRNG 每次会话的 256bit 输出 (低 8bit 被清零+填充, 有效 248bit/次... 实际
#   固件 trng_key 取 8 字后 R2[3] &= 0xFFFFFF00, 再 enc15 只加密前 15 字节)
#   所以每次 AUTH 可恢复 R2 的 120 bit (15 字节) TRNG 原始输出。
# 用三块板并行采集: 每板 ~8000 次 AUTH -> 3 x 8000 x 120 bit ≈ 360 KB 比特流, 拼接后做检验。
import serial, time, os, json, threading, sys
from Crypto.Cipher import AES

DB = json.load(open(paths.DB_FILE))
PORTS = {'DEV1': 'COM5', 'DEV2': 'COM7', 'DEV5': 'COM6'}
if len(sys.argv) > 2:                       # 只采指定板: trng_collect.py N DEV1,DEV5
    keep = set(sys.argv[2].split(','))
    PORTS = {d: p for d, p in PORTS.items() if d in keep}
N_PER_BOARD = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
OUT = paths.TRNG_STREAM


def cmd(p, c, wait, need):
    p.write(c.encode() + b'\r\n')
    buf, t0 = b'', time.time()
    while time.time() - t0 < wait:
        d = p.read(512)
        if d:
            buf += d
        i = buf.find(b'RESP:')
        if i >= 0:
            seg = buf[i:]
            if seg.count(b':') >= need and b'\n' in seg[seg.rfind(b':'):]:
                time.sleep(0.15); buf += p.read(512)
                return buf.decode('ascii', 'replace').strip()
    return buf.decode('ascii', 'replace').strip()


def collect(dev, port, rec, store, lock):
    key = bytes.fromhex(rec['key'])
    aes = AES.new(key, AES.MODE_ECB)
    r2s = []
    try:
        p = serial.Serial(port, 115200, timeout=0.5, write_timeout=2)
        p.reset_input_buffer(); p.write(b'\rCMD:PING\r\n'); time.sleep(0.4); p.read(200)
        for i in range(N_PER_BOARD):
            r1 = os.urandom(15) + b'\x00'
            e1 = aes.encrypt(r1).hex().upper()
            r = cmd(p, 'CMD:AUTH:%s:%s:%s:%s:%s' % (dev, rec['W'], rec['pad'], rec['ecc'], e1), 30, 5)
            parts = r.split(':')
            if len(parts) >= 6 and parts[1] == 'AUTH':
                r2 = aes.decrypt(bytes.fromhex(parts[3]))[:15]   # 前15字节 = TRNG 明文
                r2s.append(r2.hex())
            if (i + 1) % 500 == 0:
                with lock:
                    store[dev] = list(r2s)
                print('%s %d/%d' % (dev, i + 1, N_PER_BOARD), flush=True)
        p.close()
    except Exception as e:
        print(dev, 'ERR', str(e)[:60], flush=True)
    with lock:
        store[dev] = r2s


store, lock = {}, threading.Lock()
ths = [threading.Thread(target=collect, args=(d, pt, DB[d], store, lock)) for d, pt in PORTS.items()]
t0 = time.time()
for t in ths: t.start()
for t in ths: t.join()
json.dump(store, open(OUT, 'w'))
tot = sum(len(v) for v in store.values())
print('done %.1fs: %d samples -> %d bit' % (time.time() - t0, tot, tot * 120))
