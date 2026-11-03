# poolauth.py — 消耗制多挑战会话认证 (strong PUF 正统用法)
#   v32 固件零改动: 全部基于 CMD:CRP (任意挑战单次多数决查询)
#
# 模型 (经典消耗制 CRP):
#   注册: 服务器向设备发 N 个随机偶校验挑战, 记录响应 -> CRP 池 (台账, 按板存)
#   会话: 从未消耗池抽 K 个挑战 -> 设备逐个应答 -> 与台账比对, 失配数 <= tau 判过
#         -> 该 K 个挑战标记已消耗, 永不复用
#   重放: 已消耗挑战直接拒绝 (服务器策略, 无需设备配合)
#
# 安全参数 (K, tau) 推导:
#   攻击者最优逐位猜测率 p ≈ 0.67 (bit0 结构耦合, 见内部记录 §1)
#   伪造通过概率 = Σ_{i<=tau} C(K,i) p^i (1-p)^(K-i)
#   K=128, tau=6: ~2^-96 (二项均值 85.8, P(X<=6) 极小)
#   设备噪声: 同挑战重复失配率 ~0.2-1%, 128 个期望失配 0.3-1.3, tau=6 覆盖 4.7%
import serial, time, os, json, random, threading, sys
import boardid

POOL_DIR = r'C:\spuf_build\auth_db'
K_DEFAULT = 128
TAU_DEFAULT = 6
PORTS = {'DEV1': 'COM5', 'DEV2': 'COM7', 'DEV5': 'COM6'}


def pool_path(dev):
    return os.path.join(POOL_DIR, 'pool_%s.json' % dev)


def rand_challenge(rng):
    """随机偶校验挑战: [21:16] 环号, [15:0] 偶 popcount 图案"""
    ring = rng.randrange(64)
    pat = rng.randrange(1 << 16)
    if bin(pat).count('1') & 1:
        pat ^= 1
    return (ring << 16) | pat


class Board:
    def __init__(self, port=None, ser=None):
        # ser: 复用调用方已有的串口连接 (Windows 串口独占, 重复打开会失败)
        self.owned = ser is None
        self.p = ser if ser is not None else serial.Serial(port, 115200, timeout=0.5, write_timeout=2)
        self.p.reset_input_buffer()
        self.p.write(b'\rCMD:PING\r\n'); time.sleep(0.4); self.p.read(200)

    def ask_id(self):
        # CMD:ID 需约 4.3s (64 挑战 x reps=15 多数决); 先确认板在主循环, 再留足超时
        self.p.reset_input_buffer()
        self.p.write(b'\rCMD:PING\r\n')
        t = time.time(); buf = b''
        while time.time() - t < 1.2:
            d = self.p.read(128)
            if d: buf += d
            if b'RESP:PING' in buf:
                break
        if b'RESP:PING' not in buf:
            return None
        self.p.reset_input_buffer()
        self.p.write(b'CMD:ID\r\n')
        t = time.time(); buf = b''
        while time.time() - t < 8.0:
            d = self.p.read(128)
            if d: buf += d
            i = buf.find(b'RESP:ID:')
            if i >= 0 and len(buf) - i >= 24:
                return buf[i+8:i+24].decode('ascii', 'ignore').upper()
        return None

    def crp(self, ch):
        self.p.reset_input_buffer()
        self.p.write(('CMD:CRP:%06X\r\n' % ch).encode())
        t = time.time()
        while time.time() - t < 1.5:
            d = self.p.readline()
            if not d: continue
            s = d.decode(errors='ignore').strip()
            if s.startswith('RESP:CRP:') and 'FAIL' not in s:
                return int(s.split(':')[-1], 16) & 1
            if s.startswith('RESP:CRP_FAIL'):
                return None
        return None

    def close(self):
        if self.owned:
            try: self.p.close()
            except Exception: pass


def enroll(port, dev, n=20000, seed=None, ser=None):
    """采集 n 个 CRP 建池 (含指纹绑定)"""
    b = Board(port, ser=ser)
    try:
        fp = b.ask_id()
        rng = random.Random(seed if seed is not None else os.urandom(8).__hash__() & 0xFFFF or int(time.time()))
        pool = {'dev': dev, 'fp': fp, 'crps': {}, 'used': []}
        t0 = time.time()
        fail = 0
        while len(pool['crps']) < n:
            ch = rand_challenge(rng)
            key = '%06X' % ch
            if key in pool['crps']:
                continue
            r = b.crp(ch)
            if r is None:
                fail += 1
                if fail > 200: raise RuntimeError('CRP 查询连续失败')
                continue
            pool['crps'][key] = r
            if len(pool['crps']) % 2000 == 0:
                print('  %s %d/%d (%.0fs)' % (dev, len(pool['crps']), n, time.time() - t0), flush=True)
        os.makedirs(POOL_DIR, exist_ok=True)
        json.dump(pool, open(pool_path(dev), 'w'))
        print('%s 池注册完成: %d CRP, 指纹 %s, %.0fs' % (dev, n, fp, time.time() - t0))
        return pool
    finally:
        b.close()


def load(dev):
    return json.load(open(pool_path(dev)))


def session(port, dev, k=K_DEFAULT, tau=TAU_DEFAULT, force_challenges=None, ser=None):
    """一次消耗制会话; force_challenges 用于重放演示; ser=复用已有连接"""
    pool = load(dev)
    b = Board(port, ser=ser)
    try:
        fp = b.ask_id()
        reg = boardid.load()
        bd, hd = boardid.match(fp, reg) if fp else (None, 99)
        # 指纹核对: 该板必须与池注册时同一块 (容错距离)
        if not fp:
            return {'ok': False, 'reason': '未读取到板卡指纹 (CMD:ID 超时)', 'consumed': 0}
        if boardid.hamming(fp, pool.get('fp', '')) > 6:
            return {'ok': False, 'reason': '板卡指纹与池注册不符 (%s)' % fp, 'consumed': 0}
        used = set(pool['used'])
        avail = [c for c in pool['crps'] if c not in used]
        if force_challenges is not None:
            chs = force_challenges
        else:
            if len(avail) < k:
                return {'ok': False, 'reason': 'CRP 池不足: 剩 %d < K=%d' % (len(avail), k), 'consumed': 0}
            rng = random.Random()
            chs = ['%06X' % c for c in rng.sample([int(c, 16) for c in avail], k)]
            chs = ['%06X' % int(c) if isinstance(c, int) else c for c in chs]
        t0 = time.time()
        mism = []
        for c in chs:
            r = b.crp(int(c, 16))
            mism.append(0 if r == pool['crps'][c] else 1)
        dt = time.time() - t0
        n_mism = sum(mism)
        ok = n_mism <= tau
        # 消耗
        for c in chs:
            pool['used'].append(c)
        json.dump(pool, open(pool_path(dev), 'w'))
        remain = len(pool['crps']) - len(set(pool['used']))
        return {'ok': ok, 'k': len(chs), 'mismatch': n_mism, 'tau': tau,
                'ms': int(dt * 1000), 'remain': remain, 'fp': fp,
                'reason': '失配 %d/%d (容差 %d)' % (n_mism, len(chs), tau)}
    finally:
        b.close()


def replay_check(dev, challenges):
    """重放检测: 挑战若已消耗, 服务器直接拒绝 (不到设备)"""
    pool = load(dev)
    used = set(pool['used'])
    hit = sum(1 for c in challenges if c in used)
    return hit == len(challenges), hit


if __name__ == '__main__':
    mode = sys.argv[1] if len(sys.argv) > 1 else 'help'
    if mode == 'noise':
        # 同挑战重复查询噪声率: 300 个测两遍
        port = sys.argv[2] if len(sys.argv) > 2 else 'COM5'
        b = Board(port)
        rng = random.Random(42)
        chs = [rand_challenge(rng) for _ in range(300)]
        t0 = time.time()
        a = [b.crp(c) for c in chs]
        c2 = [b.crp(c) for c in chs]
        b.close()
        n = sum(1 for x, y in zip(a, c2) if x is not None and x == y)
        print('重复一致 %d/300 = %.4f (%.0fs)' % (n, n / 300, time.time() - t0))
    elif mode == 'enroll':
        port, dev = sys.argv[2], sys.argv[3]
        n = int(sys.argv[4]) if len(sys.argv) > 4 else 20000
        enroll(port, dev, n)
    elif mode == 'session':
        port, dev = sys.argv[2], sys.argv[3]
        r = session(port, dev)
        print(json.dumps(r, ensure_ascii=False))
    elif mode == 'replay':
        dev = sys.argv[2]
        pool = load(dev)
        last = pool['used'][-K_DEFAULT:]
        ok, hit = replay_check(dev, last)
        print('重放 %d 个已消耗挑战 -> 服务器判定: %s (命中已消耗 %d/%d)'
              % (len(last), '拒绝 🛡️' if ok else '放行 ⚠️', hit, len(last)))
    else:
        print('用法: poolauth.py noise [port] | enroll <port> <dev> [n] | session <port> <dev> | replay <dev>')
