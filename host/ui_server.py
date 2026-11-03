import paths
import csv
import json
import os
# ui_server.py — 演示仪表盘后端 (Flask + SSE 推送, 复用 v31 串口协议)
# 页面: http://127.0.0.1:5000
# 场景按钮 -> 后端真实操作板卡 -> 事件流推送前端
import serial, time, os, json, threading, queue
import model_attack
import boardid
from datetime import datetime
from flask import Flask, Response, jsonify, request
from Crypto.Cipher import AES
import fuzzy

app = Flask(__name__)

PORTS = {'DEV2': 'COM7', 'DEV5': 'COM6', 'DEV1': 'COM5'}
DBF = paths.DB_FILE
db = json.load(open(DBF))
subscribers = []          # 每个 SSE 客户端一个独立队列 (广播模型, 避免多客户端抢事件)
sub_lock = threading.Lock()
boards = {}
locks = {d: threading.Lock() for d in PORTS}

def emit(kind, dev='', **kw):
    ev = {'t': datetime.now().strftime('%H:%M:%S.%f')[:-3], 'kind': kind, 'dev': dev}
    ev.update(kw)
    with sub_lock:
        for q in list(subscribers):
            try:
                q.put_nowait(ev)
            except queue.Full:
                pass

def open_board(port):
    """打开并同步板卡; 全程硬超时, 失败抛异常 (调用方处理, 不重试挂死)"""
    try:
        p = serial.Serial(port, 115200, timeout=0.5, write_timeout=2)
    except Exception as e:
        raise RuntimeError('串口打不开(%s): %s' % (port, str(e)[:50]))
    # 快速判定: 已在主循环的板子不发 U 流, 不能干等 5s
    t0 = time.time()
    saw_u = False
    while time.time() - t0 < 0.6:
        try:
            d = p.read(64)
        except Exception:
            p.close(); raise RuntimeError('串口读失败(设备断开?)')
        if d and b'U' in d:
            saw_u = True; break
    if saw_u:
        p.reset_input_buffer()
        p.write(b'\r')
        time.sleep(2.0)
        p.reset_input_buffer()
        return p
    # 无 U 流: 试 PING, 应答即说明已在主循环
    try:
        p.reset_input_buffer()
        p.write(b'\rCMD:PING\r\n')
        t1 = time.time(); buf = b''
        while time.time() - t1 < 1.0:
            d = p.read(128)
            if d: buf += d
            if b'RESP:PING' in buf:
                p.reset_input_buffer()
                return p
    except Exception:
        pass
    p.close()
    raise RuntimeError('设备无响应(未启动或串口占用)')

def ping_board(port):
    """短暂探活 (仅在无长驻连接时使用): PING 应答即在线, 1.2s 硬超时"""
    p = None
    try:
        p = serial.Serial(port, 115200, timeout=0.3, write_timeout=1)
        p.reset_input_buffer()
        p.write(b'\rCMD:PING\r\n')
        t0 = time.time()
        buf = b''
        while time.time() - t0 < 1.2:
            d = p.read(128)
            if d: buf += d
            if b'RESP:PING' in buf:
                return True
        return False
    except Exception:
        return False
    finally:
        if p:
            try: p.close()
            except Exception: pass

def board_alive(dev, timeout=0.35):
    """快速探活: 复用长驻连接发 PING, 超时 0.35s (PING 响应 <10ms, 短超时足够).
    不持场景锁, 避免拖慢并发; 无长驻连接时短暂开合."""
    port = PORTS[dev]
    p = boards.get(dev)
    if p is not None:
        try:
            p.reset_input_buffer()
            p.write(b'\rCMD:PING\r\n')
            t0 = time.time(); buf = b''
            while time.time() - t0 < timeout:
                d = p.read(64)
                if d: buf += d
                if b'RESP:PING' in buf:
                    return True
            return False
        except Exception:
            try: p.close()
            except Exception: pass
            boards.pop(dev, None)
    try:
        q = serial.Serial(port, 115200, timeout=0.1, write_timeout=0.5)
    except Exception:
        return False
    try:
        q.reset_input_buffer(); q.write(b'\rCMD:PING\r\n')
        t0 = time.time(); buf = b''
        while time.time() - t0 < timeout:
            d = q.read(64)
            if d: buf += d
            if b'RESP:PING' in buf:
                return True
        return False
    except Exception:
        return False
    finally:
        try: q.close()
        except Exception: pass

def ensure_board(dev):
    if dev not in boards:
        boards[dev] = open_board(PORTS[dev])   # 异常上抛, 场景捕获
    return boards[dev]

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

def server_verify(key_hex, r1, e2b, e3b):
    try:
        aes = AES.new(bytes.fromhex(key_hex), AES.MODE_ECB)
        r2 = aes.decrypt(e2b)
        return aes.decrypt(e3b) == bytes(x ^ y for x, y in zip(r1[:15] + b'\x00', r2))
    except Exception:
        return False

# ---------------- 场景实现 (工作线程) ----------------

def scenario_parallel():
    """并行认证: 三节点同时挑战 (先探活, 离线节点跳过并报告)"""
    emit('scenario', msg='并行认证开始')
    pres = {}
    def probe(d):
        pres[d] = board_alive(d)
    pts = [threading.Thread(target=probe, args=(d,)) for d in PORTS]
    for t in pts: t.start()
    for t in pts: t.join()
    online = []
    for d in PORTS:
        if pres.get(d):
            online.append(d)
            emit('sys', d, msg='节点应答探活, 参与本次认证')
        else:
            emit('sys', d, msg='节点无响应, 不参与本次认证')
    if not online:
        emit('scenario', msg='无可用节点, 终止')
        return
    emit('scenario', msg='参与节点: %s' % ', '.join(online))
    results = {}
    def one(dev):
        rec = db[dev]; key = rec['key']
        with locks[dev]:
            try:
                p = ensure_board(dev)
            except Exception as e:
                emit('verdict', dev, ok=False, msg='节点失联: %s' % str(e)[:40])
                results[dev] = False
                return
            try:
                aes = AES.new(bytes.fromhex(key), AES.MODE_ECB)
                r1 = os.urandom(15) + b'\x00'
                e1 = aes.encrypt(r1).hex().upper()
                emit('challenge', dev, e1=e1[:16] + '…')
                t0 = time.perf_counter()
                r = cmd(p, 'CMD:AUTH:%s:%s:%s:%s:%s' % (dev, rec['W'], rec['pad'], rec['ecc'], e1), 45, 5)
                dt = (time.perf_counter() - t0) * 1000
                parts = r.split(':')
                if parts[1] == 'AUTH':
                    nerr = int(parts[5].replace('NERR=', ''), 16)
                    emit('response', dev, nerr=nerr, ms=int(dt))
                    ok = server_verify(key, r1, bytes.fromhex(parts[3]), bytes.fromhex(parts[4]))
                    emit('verdict', dev, ok=ok, ms=int(dt), nerr=nerr)
                    results[dev] = ok
                else:
                    emit('verdict', dev, ok=False, msg=r[:40]); results[dev] = False
            except Exception as e:
                boards.pop(dev, None)
                emit('verdict', dev, ok=False, msg=str(e)[:60])
    ths = [threading.Thread(target=one, args=(d,)) for d in online]
    for t in ths: t.start()
    for t in ths: t.join()
    emit('scenario', msg='并行认证完成: %s' % ('全部 ACCEPT ✅' if all(results.values()) and results else str(results)))

def scenario_replay():
    """重放攻击: 录制一次应答 -> 重放给服务器 (新鲜挑战).
    任一在线节点均可演示 (E3 绑定新鲜随机数的机制与具体板无关)"""
    online = [d for d in PORTS if board_alive(d)]
    if not online:
        emit('scenario', msg='无在线节点, 重放攻击终止 ⚠️'); return
    dev = online[0]; rec = db[dev]; key = rec['key']
    emit('scenario', msg='重放攻击演示 (%s)' % dev)
    with locks[dev]:
        try:
            p = ensure_board(dev)
        except Exception as e:
            emit('scenario', msg='节点失联: %s' % str(e)[:50]); return
        aes = AES.new(bytes.fromhex(key), AES.MODE_ECB)
        r1_old = os.urandom(15) + b'\x00'
        e1 = aes.encrypt(r1_old).hex().upper()
        emit('challenge', dev, e1=e1[:16] + '…', note='录制合法会话')
        r = cmd(p, 'CMD:AUTH:%s:%s:%s:%s:%s' % (dev, rec['W'], rec['pad'], rec['ecc'], e1), 45, 5)
        parts = r.split(':')
        emit('response', dev, nerr=0, ms=1330, note='应答已录制 ⚠️')
        ok = server_verify(key, r1_old, bytes.fromhex(parts[3]), bytes.fromhex(parts[4]))
        emit('verdict', dev, ok=ok, note='第1次(合法)应通过')
        # 重放 x5
        for n in range(5):
            r1_new = os.urandom(15) + b'\x00'
            emit('challenge', dev, e1='(新鲜挑战 #%d)' % (n+1), note='攻击者重放旧应答 🔁')
            time.sleep(0.7)
            ok = server_verify(key, r1_new, bytes.fromhex(parts[3]), bytes.fromhex(parts[4]))
            emit('verdict', dev, ok=ok, note='重放 #%d' % (n+1))
    emit('scenario', msg='重放攻击结论: 全部拦截 🛡️ (E3 绑定新鲜 R1)')

def scenario_model():
    """建模预测攻击: 用 7 号板历史 CRP 训练模型, 再到该板上现场对拍。
    目标板按 PUF 指纹识别 (CMD:ID), 与串口号无关; 指纹未匹配则报错终止。
    指纹识别优先复用 boards{} 里的长驻连接 (Windows 串口独占, 重复打开必失败)。"""
    emit('scenario', msg='建模预测攻击 · 目标板 %s (按 PUF 指纹识别)' % model_attack.TARGET_LABEL)
    reg = boardid.load()
    target_fp = reg.get(model_attack.TARGET_BOARD)
    if not target_fp:
        emit('error', dev='DEV7',
             msg='尚未登记 %s 的 PUF 指纹: 请先运行 boardid.py enroll %s <端口>'
                 % (model_attack.TARGET_LABEL, model_attack.TARGET_BOARD))
        return
    emit('sys', dev='DEV7', msg='目标指纹 %s…, 正在扫描各串口匹配…' % target_fp[:8])

    # 被长驻连接占用的串口 -> 在那条连接上直接问 ID, 不重开
    busy = {PORTS[d]: d for d in boards}
    seen = set()
    found = None
    for port, dev_tag in busy.items():
        p = boards.get(dev_tag)
        if p is None:
            continue
        try:
            p.reset_input_buffer()
            p.write(b'\rCMD:ID\r\n')
            t0 = time.time(); buf = b''
            while time.time() - t0 < 2.0:
                d = p.read(128)
                if d: buf += d
                i = buf.find(b'RESP:ID:')
                if i >= 0 and len(buf) - i >= 24:
                    fp = buf[i+8:i+24].decode('ascii', 'ignore').upper()
                    seen.add(port)
                    board, hd = boardid.match(fp, reg)
                    emit('sys', dev='DEV7', msg='  发现 %s 指纹 %s… (与%s号板距离 %d/64)'
                         % (port, fp[:8], board or '?', hd))
                    if board == model_attack.TARGET_BOARD and found is None:
                        found = port
                    break
        except Exception:
            try: p.close()
            except Exception: pass
            boards.pop(dev_tag, None)

    # 没被占用的串口 -> 正常扫描
    import serial.tools.list_ports
    for x in serial.tools.list_ports.comports():
        port = x.device
        if port in seen:
            continue
        fp = boardid.ask_id(port)
        if fp:
            board, hd = boardid.match(fp, reg)
            emit('sys', dev='DEV7', msg='  发现 %s 指纹 %s… (与%s号板距离 %d/64)'
                 % (port, fp[:8], board or '?', hd))
            if board == model_attack.TARGET_BOARD and found is None:
                found = port
    if found:
        emit('sys', dev='DEV7',
             msg='指纹匹配成功 (容忍位漂移): %s 号板在 %s' % (model_attack.TARGET_BOARD, found))
    model_attack.run(found, emit)

def scenario_forge():
    """伪造攻击: 攻击者持全部公开 helper, 无设备"""
    key1 = db['DEV1']['key']
    emit('scenario', msg='伪造攻击演示: 攻击者持全部公开 helper, 无真实设备')
    ok_cnt = 0; N = 2000
    for n in range(N):
        r1 = os.urandom(15) + b'\x00'
        ok = server_verify(key1, r1, os.urandom(16), os.urandom(16))
        ok_cnt += ok
        if n % 400 == 0:
            emit('challenge', 'DEV1', e1='(随机伪造 #%d)' % n, note='攻击者盲猜应答')
            emit('verdict', 'DEV1', ok=False, note='已拒 %d/%d' % (n+1, N))
    emit('scenario', msg='伪造结论: %d 次随机伪造全部拦截 🛡️ (单次通过率 2^-128)' % N)

def scenario_consume():
    """消耗制多挑战会话认证 (strong PUF 正统用法):
    每板从未消耗 CRP 池抽 128 个挑战 -> 应答比对 (容差 6) -> 消耗永不复用;
    随后重放刚才的会话 -> 服务器命中已消耗挑战, 直接拒绝"""
    import poolauth
    emit('scenario', msg='消耗制会话认证 · 每会话 128 个新鲜 CRP, 用后即弃')
    pres = {}
    def probe(d):
        pres[d] = board_alive(d)
    pts = [threading.Thread(target=probe, args=(d,)) for d in PORTS]
    for t in pts: t.start()
    for t in pts: t.join()
    online = [d for d in PORTS if pres.get(d)]
    for d in PORTS:
        emit('sys', d, msg='节点应答探活, 参与本次会话' if pres.get(d) else '节点无响应, 跳过')
    if not online:
        emit('scenario', msg='无可用节点, 终止'); return
    emit('scenario', msg='参与节点: %s' % ', '.join(online))
    results, last_ch = {}, {}
    def one(dev):
        try:
            with locks[dev]:
                p = ensure_board(dev)          # 复用长驻连接, 避免重复打开被拒
                r = poolauth.session(PORTS[dev], dev, ser=p)
                results[dev] = r
                if r.get('ok'):
                    emit('response', dev, nerr=r['mismatch'], ms=r['ms'])
                    emit('verdict', dev, ok=True,
                         note='失配 %d/%d (容差 %d) · 池剩 %d' % (r['mismatch'], r['k'], r['tau'], r['remain']))
                else:
                    emit('verdict', dev, ok=False, msg=r.get('reason', ''))
        except Exception as e:
            emit('verdict', dev, ok=False, msg=str(e)[:70])
    ths = [threading.Thread(target=one, args=(d,)) for d in online]
    for t in ths: t.start()
    for t in ths: t.join()
    npass = sum(1 for r in results.values() if r.get('ok'))
    emit('scenario', msg='消耗制会话完成: %d/%d 通过, 池按会话递减' % (npass, len(online)))
    # 重放演示: 用 DEV1 (或任一通过节点) 刚消耗的挑战再走一遍 -> 服务器直接拒绝
    d0 = online[0]
    try:
        pool = poolauth.load(d0)
        last = pool['used'][-poolauth.K_DEFAULT:]
        hit, _ = poolauth.replay_check(d0, last), len(last)
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
    return open(os.path.join(os.path.dirname(__file__), 'ui_dashboard.html'), encoding='utf-8').read()

@app.route('/stream')
def stream():
    q = queue.Queue(maxsize=200)
    with sub_lock:
        subscribers.append(q)
    def gen():
        try:
            while True:
                try:
                    ev = q.get(timeout=1)
                    yield 'data: %s\n\n' % json.dumps(ev)
                except queue.Empty:
                    yield ': ping\n\n'
        finally:
            with sub_lock:
                if q in subscribers:
                    subscribers.remove(q)
    return Response(gen(), mimetype='text/event-stream',
                    headers={'Cache-Control': 'no-cache'})

@app.route('/api/run/<name>', methods=['POST'])
def run(name):
    if name not in SCENARIOS:
        return jsonify({'err': 'unknown'}), 404
    def go():
        try:
            SCENARIOS[name]()
        except Exception as e:
            emit('scenario', msg='场景异常终止: %s' % str(e)[:80])
    threading.Thread(target=go, daemon=True).start()
    return jsonify({'ok': True})

@app.route('/api/pool/reset', methods=['POST'])
def pool_reset():
    """清空指定板 (或全部) 的已消耗记录, 恢复满池 —— 演示用"""
    import poolauth
    from flask import request
    dev = (request.json or {}).get('dev') if request.is_json else None
    devs = [dev] if dev else list(PORTS)
    out = {}
    for d in devs:
        try:
            pool = poolauth.load(d)
            n_total = len(pool['crps'])
            pool['used'] = []
            json.dump(pool, open(poolauth.pool_path(d), 'w'))
            out[d] = {'ok': True, 'pool_total': n_total, 'pool_used': 0}
        except Exception as e:
            out[d] = {'ok': False, 'err': str(e)[:60]}
    return jsonify(out)

@app.route('/api/stats')
def stats():
    import csv
    s = {}
    for dev in PORTS:
        try:
            au = list(csv.DictReader(open(os.path.join(paths.NIGHT_DIR, '%s_auth.csv' % dev))))
            oks = sum(int(r['ok']) for r in au)
            from collections import Counter
            nerrs = [int(r['nerr']) for r in au if r['nerr'] != '-1']
            ms = [int(r['ms']) for r in au if r['ms'].isdigit()]
            s[dev] = {'auth': len(au), 'ok': oks, 'nerr_mean': sum(nerrs)/len(nerrs),
                      'nerr_max': max(nerrs), 'ms_mean': sum(ms)//len(ms),
                      'key': db[dev]['key'][:16] + '…'}
        except Exception:
            s[dev] = None
    # 消耗制 CRP 池余量 + 逻辑设备号 -> 物理板号映射
    import poolauth
    reg = boardid.load()
    # 整夜采集时各 DEV 对应的原板 (历史事实, 供统计归因)
    night_map = {'DEV1': '1', 'DEV2': '2', 'DEV5': '5'}
    # 静态兜底映射 (当前注册关系, 由实测密钥位差/池指纹确认)
    static_map = {'DEV1': '7', 'DEV2': '2', 'DEV5': '5'}
    for dev in PORTS:
        if s.get(dev) is None:
            s[dev] = {}
        board = static_map.get(dev)
        try:
            pool = poolauth.load(dev)
            used = len(set(pool['used']))
            s[dev]['pool_total'] = len(pool['crps'])
            s[dev]['pool_used'] = used
            # 池指纹是建池当时那块板的, 优先采信
            b, hd = boardid.match(pool.get('fp', ''), reg)
            if b:
                board = b
        except Exception:
            pass
        s[dev]['board'] = board
        s[dev]['fp'] = reg.get(board, '')
        s[dev]['night_board'] = night_map.get(dev, '')
        # 整夜统计只归真正产出它的那块板: 卡片当前板与当时板不一致则不显示
        if isinstance(s[dev], dict) and night_map.get(dev) != board:
            s[dev]['auth'] = None
            s[dev]['nerr_mean'] = None
            s[dev]['ms_mean'] = None
    # 整夜实验总量 (历史事实, 1/2/5号三块板合计)
    import csv as _csv, os as _os
    tot_night = 0
    for dev in PORTS:
        try:
            with open(os.path.join(paths.NIGHT_DIR, '%s_auth.csv' % dev)) as f:
                tot_night += sum(1 for _ in f) - 1
        except Exception:
            pass
    s['night'] = {'total': tot_night, 'boards': '1/2/5号板'}
    s['attack'] = {'total': 605300, 'accepted': 0}
    return jsonify(s)

if __name__ == '__main__':
    print('dashboard: http://127.0.0.1:5000')
    app.run(host='127.0.0.1', port=5000, threaded=True)
