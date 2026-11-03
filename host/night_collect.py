import paths
import json
import os
# night_collect.py — 夜间自动采集 (v31b, 三板, 零人工干预)
# 采集项:
#   A. 密钥派生稳定性: 每板循环 ENROLL, 记录 K + 时间戳 (跨夜数小时尺度)
#   B. AUTH 成功率: 每板循环 AUTH (helper 下发), 记录 PASS/FAIL + nerr + 延迟
#   D. TRNG 健康: PING 读 TRNG 状态 (长时间监测)
# 数据: $BRPUF_HOME/night/<dev>_<item>.csv (断点续采, 追加模式)
import serial, time, os, json, threading, sys
from datetime import datetime
from Crypto.Cipher import AES
import fuzzy

PORTS = {'DEV2': 'COM7', 'DEV5': 'COM6', 'DEV1': 'COM9'}
DBF = paths.DB_FILE
OUT = paths.NIGHT_DIR
os.makedirs(OUT, exist_ok=True)

def log(dev, item, fields):
    fn = os.path.join(OUT, '%s_%s.csv' % (dev, item))
    new = not os.path.exists(fn)
    with open(fn, 'a') as f:
        if new:
            f.write(','.join(fields.keys()) + '\n')
        f.write(','.join(str(v) for v in fields.values()) + '\n')

def open_board(port):
    p = serial.Serial(port, 115200, timeout=0.5)
    got = False
    t0 = time.time()
    while time.time() - t0 < 6:
        d = p.read(256)
        if d and b'U' in d: got = True; break
    p.reset_input_buffer()
    p.write(b'\r')
    time.sleep(2.0)
    p.reset_input_buffer()
    return p

def cmd(p, c, wait, need):
    p.write(c.encode() + b'\r\n')
    buf = b''
    t0 = time.time()
    while time.time() - t0 < wait:
        d = p.read(512)
        if d: buf += d
        i = buf.find(b'RESP:')
        if i >= 0:
            seg = buf[i:]
            if seg.count(b':') >= need and b'\n' in seg[seg.rfind(b':'):]:
                time.sleep(0.3); buf += p.read(512)
                return buf.decode('ascii','replace').strip()
    return buf.decode('ascii','replace').strip()

def worker(dev, deadline):
    """每板一个线程: 交替做 A(ENROLL 稳定性) 和 B(AUTH 成功率) 循环"""
    port = PORTS[dev]
    rec = json.load(open(DBF))[dev]
    key, W, pad, ecc = rec['key'], rec['W'], rec['pad'], rec['ecc']
    n_enroll = 0; n_auth = 0
    try:
        p = open_board(port)
    except Exception as e:
        log(dev, 'error', {'t': datetime.now().isoformat(), 'what': 'open:%s' % e})
        return
    while time.time() < deadline:
        # --- A: ENROLL 稳定性 ---
        try:
            t0 = time.perf_counter()
            r = cmd(p, 'CMD:ENROLL:' + dev, 60, 3)
            dt = (time.perf_counter() - t0) * 1000
            K = r.split(':')[-1].split()[-1] if 'RESP:ENROLL' in r else 'FAIL'
            bitdiff = bin(int(K, 16) ^ int(key, 16)).count('1') if K != 'FAIL' else -1
            log(dev, 'enroll', {'t': datetime.now().isoformat(timespec='seconds'),
                                'K': K, 'ms': int(dt), 'bitdiff_vs_reg': bitdiff})
            n_enroll += 1
        except Exception as e:
            try: p.close()
            except Exception: pass
            time.sleep(5)
            try: p = open_board(port)
            except Exception: return

        if time.time() >= deadline: break

        # --- B: AUTH x5 (每轮 ENROLL 之间做 5 次认证) ---
        aes = AES.new(bytes.fromhex(key), AES.MODE_ECB)
        for k in range(5):
            try:
                r1 = os.urandom(15) + b'\x00'
                e1 = aes.encrypt(r1).hex().upper()
                line = 'CMD:AUTH:%s:%s:%s:%s:%s' % (dev, W, pad, ecc, e1)
                t0 = time.perf_counter()
                r = cmd(p, line, 45, 5)
                dt = (time.perf_counter() - t0) * 1000
                parts = r.split(':')
                if parts[1] == 'AUTH':
                    e2, e3 = bytes.fromhex(parts[3]), bytes.fromhex(parts[4])
                    dec = AES.new(bytes.fromhex(key), AES.MODE_ECB)
                    r2 = dec.decrypt(e2); r12 = dec.decrypt(e3)
                    exp = bytes(x^y for x, y in zip(r1[:15]+b'\x00', r2))
                    ok = (r12 == exp)
                    nerr = int(parts[5].replace('NERR=', ''), 16) if len(parts) > 5 else -1
                    log(dev, 'auth', {'t': datetime.now().isoformat(timespec='seconds'),
                                      'ok': int(ok), 'nerr': nerr, 'ms': int(dt)})
                    n_auth += 1
                else:
                    log(dev, 'auth', {'t': datetime.now().isoformat(timespec='seconds'),
                                      'ok': 0, 'nerr': -1, 'ms': int(dt)})
            except Exception as e:
                try: p.close()
                except Exception: pass
                time.sleep(5)
                try: p = open_board(port)
                except Exception: return
    try: p.close()
    except Exception: pass
    print('[%s] 采集结束: %d ENROLL, %d AUTH' % (dev, n_enroll, n_auth))

if __name__ == '__main__':
    hours = float(sys.argv[1]) if len(sys.argv) > 1 else 7.0
    deadline = time.time() + hours * 3600
    print('夜间采集启动: %.1f 小时, 节点 %s' % (hours, list(PORTS)))
    ths = [threading.Thread(target=worker, args=(d, deadline), daemon=True) for d in PORTS]
    for t in ths: t.start()
    for t in ths: t.join()
    print('全部完成')
