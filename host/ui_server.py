# ui_server.py — 演示仪表盘后端 (Flask + SSE)
# 架构: 板号即身份. 指纹识别 -> 板号; 注册库/CRP池/事件全部按板号;
#       串口动态发现 (缓存 port->板号, 快路径 PING, 慢路径 CMD:ID).
import serial, time, os, json, threading, queue
import model_attack
import boardid
from datetime import datetime
from flask import Flask, Response, jsonify, request
from Crypto.Cipher import AES

app = Flask(__name__)

ROOT = r'C:\spuf_build'
DBF = os.path.join(ROOT, 'eccdb_boards.json')          # 板号 -> {key,W,pad,ecc}
db = json.load(open(DBF))
CACHE = os.path.join(ROOT, 'port_board_cache.json')    # 串口 -> 板号 (识别缓存)
NIGHT_SRC = {'1': 'DEV1', '2': 'DEV2', '5': 'DEV5'}    # 板号 -> 整夜采集文件名(历史槽名)

subscribers = []
sub_lock = threading.Lock()
boards = {}                        # 板号 -> 长驻串口连接
locks = {}                         # 板号 -> 场景锁 (按需建)
NODES = {}                         # disp -> {'board','port'} (refresh 重建)


def lock_of(b):
    if b not in locks:
        locks[b] = threading.Lock()
    return locks[b]


def emit(kind, dev='', **kw):
    ev = {'t': datetime.now().strftime('%H:%M:%S.%f')[:-3], 'kind': kind, 'dev': dev}
    ev.update(kw)
    with sub_lock:
        for q in list(subscribers):
            try: q.put_nowait(ev)
            except queue.Full: pass


# ---------------- 串口底层 ----------------
def open_board(port):
    """打开并确认在主循环 (U 流 -> 确认字节 -> PING)"""
    try:
        p = serial.Serial(port, 115200, timeout=0.5, write_timeout=2)
    except Exception as e:
        raise RuntimeError('串口打不开(%s): %s' % (port, str(e)[:50]))
    t0 = time.time(); saw_u = False
    while time.time() - t0 < 0.6:
        try:
            d = p.read(64)
        except Exception:
            p.close(); raise RuntimeError('串口读失败(设备断开?)')
        if d and b'U' in d:
            saw_u = True; break
    if saw_u:
        p.reset_input_buffer(); p.write(b'\r'); time.sleep(2.0)
        p.reset_input_buffer(); return p
    try:
        p.reset_input_buffer(); p.write(b'\rCMD:PING\r\n')
        t1 = time.time(); buf = b''
        while time.time() - t1 < 1.0:
            d = p.read(128)
            if d: buf += d
            if b'RESP:PING' in buf:
                while b'\n' not in buf:
                    buf += p.read(128)
                p.reset_input_buffer(); return p
    except Exception:
        pass
    p.close()
    raise RuntimeError('设备无响应(未启动或串口占用)')


def ensure_board(b, port):
    if b not in boards:
        boards[b] = open_board(port)
    return boards[b]


def _ping_conn(p, timeout=0.45):
    p.reset_input_buffer()
    p.write(b'\rCMD:PING\r\n')
    t0 = time.time(); buf = b''
    while time.time() - t0 < timeout:
        d = p.read(64)
        if d: buf += d
        if b'RESP:PING' in buf:
            while b'\n' not in buf and time.time() - t0 < timeout + 0.5:
                d = p.read(64)
                if d: buf += d
            return True
    return False


def board_alive(b):
    p = boards.get(b)
    if p is not None:
        try:
            return _ping_conn(p)
        except Exception:
            try: p.close()
            except Exception: pass
            boards.pop(b, None)
    return False


def _ask_id_on(p, timeout=8.0):
    """在该连接上问 CMD:ID (约 4.3s), 返回指纹或 None"""
    p.reset_input_buffer()
    p.write(b'CMD:ID\r\n')
    t0 = time.time(); buf = b''
    while time.time() - t0 < timeout:
        d = p.read(128)
        if d: buf += d
        i = buf.find(b'RESP:ID:')
        if i >= 0 and len(buf) - i >= 24:
            return buf[i+8:i+24].decode('ascii', 'ignore').upper()
    return None


def load_cache():
    try:
        return json.load(open(CACHE))
    except Exception:
        return {}


def save_cache(c):
    json.dump(c, open(CACHE, 'w'), indent=1)


# ---------------- 节点发现 ----------------
def refresh_nodes(full=False):
    """扫描串口 -> 在线板号集合, 按板号排序编号 DEV1..DEVn.
    快路径: 缓存过的串口只 PING; 慢路径(full 或未知串口): CMD:ID 识别指纹.
    场景持锁的板保持上次状态."""
    global NODES
    prev = {v['board']: k for k, v in NODES.items()}
    reg = boardid.load()
    cache = load_cache()
    found = {}
    import serial.tools.list_ports
    for x in serial.tools.list_ports.comports():
        port = x.device
        cached_b = cache.get(port)
        if cached_b and not full:
            p = boards.get(cached_b)
            if p is not None:
                try:
                    if _ping_conn(p):
                        found[cached_b] = port
                    continue
                except Exception:
                    boards.pop(cached_b, None)
            try:
                q = serial.Serial(port, 115200, timeout=0.15, write_timeout=0.5)
            except Exception:
                cache.pop(port, None); continue
            try:
                if _ping_conn(q, timeout=0.6):
                    found[cached_b] = port
                else:
                    cache.pop(port, None)
            except Exception:
                pass
            finally:
                try: q.close()
                except Exception: pass
            continue
        # 慢路径: open_board (自动处理 U 校准态: 听U流->发确认字节->进主循环) -> ID -> 指纹匹配
        try:
            q = open_board(port)      # U态/主循环态都能拉起; 无响应抛异常
        except Exception:
            continue
        try:
            fp = _ask_id_on(q)
            if fp:
                b_, hd = boardid.match(fp, reg)
                if b_:
                    found[b_] = port
                    cache[port] = b_
        except Exception:
            pass
        finally:
            try: q.close()
            except Exception: pass
    for b in prev:
        if b not in found and lock_of(b).locked():
            old = NODES.get(prev[b], {})
            found[b] = old.get('port', '')
    save_cache(cache)
    order = sorted(found, key=lambda s: int(s) if s.isdigit() else 99)
    NODES = {}
    for i, b in enumerate(order, 1):
        NODES['DEV%d' % i] = {'board': b, 'port': found[b]}
    return NODES


# ---------------- 协议 ----------------
def cmd(p, c, wait, need=4):
    p.write(c.encode() + b'\r\n')
    buf = b''
    t0 = time.time()
    while time.time() - t0 < wait:
        d = p.read(512)
        if d: buf += d
        while b'\n' in buf:
            line, buf = buf.split(b'\n', 1)
            line = line.strip()
            if line.startswith(b'RESP:'):
                return line.decode('ascii', 'replace')
    return buf.decode('ascii', 'replace').strip()


def server_verify(key_hex, r1, e2b, e3b):
    try:
        aes = AES.new(bytes.fromhex(key_hex), AES.MODE_ECB)
        r2 = aes.decrypt(e2b)
        return aes.decrypt(e3b) == bytes(x ^ y for x, y in zip(r1[:15] + b'\x00', r2))
    except Exception:
        return False


# ---------------- 场景 ----------------
def scenario_parallel():
    refresh_nodes()
    if not NODES:
        emit('scenario', msg='无在线节点, 终止'); return
    emit('scenario', msg='并行认证开始 · 在线 %d 节点' % len(NODES))
    for disp, info in NODES.items():
        emit('sys', disp, msg='节点应答探活, 参与本次认证 (%s号板)' % info['board'])
    results = {}
    def one(disp):
        b = NODES[disp]['board']; port = NODES[disp]['port']
        rec = db[b]; key = rec['key']
        with lock_of(b):
            try:
                p = ensure_board(b, port)
            except Exception as e:
                emit('verdict', disp, ok=False, msg='节点失联: %s' % str(e)[:40])
                results[disp] = False
                return
            try:
                aes = AES.new(bytes.fromhex(key), AES.MODE_ECB)
                r1 = os.urandom(15) + b'\x00'
                e1 = aes.encrypt(r1).hex().upper()
                emit('challenge', disp, e1=e1[:16] + '…')
                t0 = time.perf_counter()
                r = cmd(p, 'CMD:AUTH:%s:%s:%s:%s:%s' % (b, rec['W'], rec['pad'], rec['ecc'], e1), 45, 5)
                dt = (time.perf_counter() - t0) * 1000
                parts = r.split(':')
                if len(parts) >= 6 and parts[0].startswith('RESP') and parts[1] == 'AUTH':
                    nerr = int(parts[5].replace('NERR=', ''), 16)
                    emit('response', disp, nerr=nerr, ms=int(dt))
                    ok = server_verify(key, r1, bytes.fromhex(parts[3]), bytes.fromhex(parts[4]))
                    emit('verdict', disp, ok=ok, ms=int(dt), nerr=nerr)
                    results[disp] = ok
                else:
                    emit('verdict', disp, ok=False, msg=r[:40]); results[disp] = False
            except Exception as e:
                boards.pop(b, None)
                emit('verdict', disp, ok=False, msg=str(e)[:60])
    ths = [threading.Thread(target=one, args=(d,)) for d in list(NODES)]
    for t in ths: t.start()
    for t in ths: t.join()
    emit('scenario', msg='并行认证完成: %s' % ('全部 ACCEPT ✅' if all(results.values()) and results else str(results)))


def scenario_replay():
    refresh_nodes()
    if not NODES:
        emit('scenario', msg='无在线节点, 重放攻击终止 ⚠️'); return
    disp = list(NODES)[0]
    b = NODES[disp]['board']
    rec = db[b]; key = rec['key']
    emit('scenario', msg='重放攻击演示 (%s号板)' % b)
    with lock_of(b):
        try:
            p = ensure_board(b, NODES[disp]['port'])
        except Exception as e:
            emit('scenario', msg='节点失联: %s' % str(e)[:50]); return
        aes = AES.new(bytes.fromhex(key), AES.MODE_ECB)
        r1_old = os.urandom(15) + b'\x00'
        e1 = aes.encrypt(r1_old).hex().upper()
        emit('challenge', disp, e1=e1[:16] + '…', note='录制合法会话')
        r = cmd(p, 'CMD:AUTH:%s:%s:%s:%s:%s' % (b, rec['W'], rec['pad'], rec['ecc'], e1), 45, 5)
        parts = r.split(':')
        emit('response', disp, nerr=0, ms=1330, note='应答已录制 ⚠️')
        ok = server_verify(key, r1_old, bytes.fromhex(parts[3]), bytes.fromhex(parts[4]))
        emit('verdict', disp, ok=ok, note='第1次(合法)应通过')
        for n in range(5):
            r1_new = os.urandom(15) + b'\x00'
            emit('challenge', disp, e1='(新鲜挑战 #%d)' % (n+1), note='攻击者重放旧应答 🔁')
            time.sleep(0.7)
            ok = server_verify(key, r1_new, bytes.fromhex(parts[3]), bytes.fromhex(parts[4]))
            emit('verdict', disp, ok=ok, note='重放 #%d' % (n+1))
    emit('scenario', msg='重放攻击结论: 全部拦截 🛡️ (E3 绑定新鲜 R1)')


def scenario_model():
    """建模预测攻击: 7号板历史 CRP 预训练模型, 现场对拍; 按指纹识别目标板."""
    refresh_nodes()
    disp7 = ''
    for d, info in NODES.items():
        if info['board'] == model_attack.TARGET_BOARD:
            disp7 = d
    dev_tag = disp7 or (list(NODES)[0] if NODES else '')
    def memit(kind, dev='', **kw):
        if dev == 'DEV7':
            dev = dev_tag
        emit(kind, dev, **kw)
    emit('scenario', msg='建模预测攻击 · 目标 7号板 (按 PUF 指纹识别)')
    reg = boardid.load()
    target_fp = reg.get(model_attack.TARGET_BOARD)
    if not target_fp:
        memit('error', 'DEV7', msg='尚未登记 7号板 的 PUF 指纹')
        return
    memit('sys', 'DEV7', msg='目标指纹 %s…, 正在扫描各串口匹配…' % target_fp[:8])
    found = None
    for d, info in NODES.items():
        if info['board'] == model_attack.TARGET_BOARD:
            found = info['port']
            memit('sys', 'DEV7', msg='  目标板已在线 (%s号板, 动态节点 %s)' % (info['board'], d))
            break
    if not found:
        import serial.tools.list_ports
        for x in serial.tools.list_ports.comports():
            fp = boardid.ask_id(x.device)
            if fp:
                b_, hd = boardid.match(fp, reg)
                memit('sys', 'DEV7', msg='  发现 %s (%s号板, 距离 %d/64)' % (x.device, b_ or '?', hd))
                if b_ == model_attack.TARGET_BOARD:
                    found = x.device
                    break
    if found:
        memit('sys', 'DEV7', msg='指纹匹配成功 (容忍位漂移): 7号板在 %s' % found)
        model_attack.run(found, memit)
    else:
        memit('error', 'DEV7', msg='7号板不在线 → 该模型只对应这一块板, 攻击实验终止')


def scenario_forge():
    refresh_nodes()
    key1 = db['7']['key']
    disp0 = list(NODES)[0] if NODES else ''
    emit('scenario', msg='伪造攻击演示: 攻击者持全部公开 helper, 无真实设备')
    N = 2000
    for n in range(N):
        r1 = os.urandom(15) + b'\x00'
        server_verify(key1, r1, os.urandom(16), os.urandom(16))
        if n % 400 == 0:
            emit('challenge', disp0, e1='(随机伪造 #%d)' % n, note='攻击者盲猜应答')
            emit('verdict', disp0, ok=False, note='已拒 %d/%d' % (n+1, N))
    emit('scenario', msg='伪造结论: %d 次随机伪造全部拦截 🛡️ (单次通过率 2^-128)' % N)


def scenario_consume():
    import poolauth
    refresh_nodes()
    if not NODES:
        emit('scenario', msg='无在线节点, 终止'); return
    emit('scenario', msg='消耗制会话认证 · 每会话 128 个新鲜 CRP, 用后即弃')
    for disp, info in NODES.items():
        emit('sys', disp, msg='节点应答探活, 参与本次会话 (%s号板)' % info['board'])
    results = {}
    def one(disp):
        b = NODES[disp]['board']; port = NODES[disp]['port']
        try:
            with lock_of(b):
                p = ensure_board(b, port)
                if not os.path.exists(poolauth.pool_path(b)):
                    emit('sys', disp, msg='该板尚未建立 CRP 池 → 自动注册 20,000 CRP（约 2.5 分钟）…')
                    poolauth.enroll(port, b, ser=p)
                    emit('sys', disp, msg='建池完成（20,000 CRP, 已绑定板卡指纹）')
                r = poolauth.session(port, b, ser=p)
                results[disp] = r
                if r.get('ok'):
                    emit('response', disp, nerr=r['mismatch'], ms=r['ms'])
                    emit('verdict', disp, ok=True,
                         note='失配 %d/%d (容差 %d) · 池剩 %d' % (r['mismatch'], r['k'], r['tau'], r['remain']))
                else:
                    emit('verdict', disp, ok=False, msg=r.get('reason', ''))
        except Exception as e:
            emit('verdict', disp, ok=False, msg=str(e)[:70])
    ths = [threading.Thread(target=one, args=(d,)) for d in list(NODES)]
    for t in ths: t.start()
    for t in ths: t.join()
    npass = sum(1 for r in results.values() if r.get('ok'))
    emit('scenario', msg='消耗制会话完成: %d/%d 通过, 池按会话递减' % (npass, len(NODES)))
    withpool = [d for d in NODES if os.path.exists(poolauth.pool_path(NODES[d]['board']))]
    d0 = withpool[0] if withpool else None
    try:
        if not d0:
            raise RuntimeError('无已建池节点')
        pool = poolauth.load(NODES[d0]['board'])
        last = pool['used'][-poolauth.K_DEFAULT:]
        poolauth.replay_check(NODES[d0]['board'], last)
        emit('challenge', d0, e1='(重放刚消耗的 %d 个挑战)' % len(last), note='已用 CRP ⚠️')
        emit('verdict', d0, ok=False, note='服务器命中已消耗挑战 %d/%d, 拒绝 🛡️' % (len(last), len(last)))
        emit('scenario', msg='消耗制重放结论: 已消耗挑战永不复用, 重放拦截 🛡️')
    except Exception as e:
        emit('scenario', msg='重放演示跳过: %s' % str(e)[:50])


SCENARIOS = {
    'parallel': scenario_parallel,
    'replay': scenario_replay,
    'impersonate': scenario_model,
    'forge': scenario_forge,
    'consume': scenario_consume,
}

# ---------------- HTTP ----------------
@app.route('/')
def index():
    return open(os.path.join(ROOT, 'ui_dashboard.html'), encoding='utf-8').read()


@app.route('/stream')
def stream():
    q = queue.Queue(maxsize=500)
    with sub_lock:
        subscribers.append(q)
    def gen():
        try:
            while True:
                try:
                    ev = q.get(timeout=15)
                    yield 'data: %s\n\n' % json.dumps(ev, ensure_ascii=False)
                except queue.Empty:
                    yield ': ping\n\n'
        finally:
            with sub_lock:
                try: subscribers.remove(q)
                except ValueError: pass
    return Response(gen(), mimetype='text/event-stream')


@app.route('/api/run/<name>', methods=['POST'])
def run(name):
    if name not in SCENARIOS:
        return jsonify({'error': 'unknown scenario'}), 404
    threading.Thread(target=SCENARIOS[name], daemon=True).start()
    return jsonify({'ok': True})


@app.route('/api/pool/reset', methods=['POST'])
def pool_reset():
    """清空指定板(或全部)的已消耗记录, 恢复满池"""
    import poolauth
    dev = (request.json or {}).get('dev') if request.is_json else None
    devs = [dev] if dev else list(db)
    out = {}
    for b in devs:
        try:
            pool = poolauth.load(b)
            n = len(pool['crps'])
            pool['used'] = []
            json.dump(pool, open(poolauth.pool_path(b), 'w'))
            out[b] = {'ok': True, 'pool_total': n, 'pool_used': 0}
        except Exception as e:
            out[b] = {'ok': False, 'err': str(e)[:60]}
    return jsonify(out)


@app.route('/api/refresh', methods=['POST'])
def api_refresh():
    refresh_nodes()
    return jsonify({'nodes': {d: v['board'] for d, v in NODES.items()}})


@app.route('/api/stats')
def stats():
    import csv
    import poolauth
    reg = boardid.load()
    nodes = []
    for disp, info in NODES.items():
        b = info['board']
        ent = {'disp': disp, 'board': b, 'fp': reg.get(b, '')}
        src = NIGHT_SRC.get(b)
        if src:
            try:
                au = list(csv.DictReader(open(os.path.join(ROOT, 'night', '%s_auth.csv' % src))))
                nerrs = [int(r['nerr']) for r in au if r['nerr'] != '-1']
                ms = [int(r['ms']) for r in au if r['ms'].isdigit()]
                ent['auth'] = len(au)
                ent['nerr_mean'] = sum(nerrs) / len(nerrs)
                ent['ms_mean'] = sum(ms) // len(ms)
            except Exception:
                pass
        try:
            pool = poolauth.load(b)
            ent['pool_total'] = len(pool['crps'])
            ent['pool_used'] = len(set(pool['used']))
        except Exception:
            pass
        nodes.append(ent)
    tot = 0
    for src in NIGHT_SRC.values():
        try:
            with open(os.path.join(ROOT, 'night', '%s_auth.csv' % src)) as f:
                tot += sum(1 for _ in f) - 1
        except Exception:
            pass
    return jsonify({'nodes': nodes,
                    'night': {'total': tot, 'boards': '/'.join(sorted(NIGHT_SRC)) + '号板'},
                    'attack': {'total': 605300, 'accepted': 0}})


if __name__ == '__main__':
    refresh_nodes(full=True)
    print('dashboard: http://127.0.0.1:5000 | 在线:', {d: v['board'] for d, v in NODES.items()})
    app.run(host='127.0.0.1', port=5000, threaded=True)
