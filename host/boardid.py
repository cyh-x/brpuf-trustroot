# boardid.py — 板卡响应级身份识别 (替代端口号假设)
# 每块板出厂时通过 CMD:ID 得到 64 位 PUF 指纹, 存入 board_ids.json:
#   { "7": "A1B2C3D4E5F60708", "2": "...", ... }   键 = 板号, 值 = 指纹 hex(16)
# 之后任何端口上只要 ID 匹配, 就认定为那块板; 端口号变化/换 USB 口都不影响。
import json, os, serial, time

REG = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'board_ids.json')

def load():
    try:
        return json.load(open(REG, encoding='utf-8'))
    except Exception:
        return {}

def save(d):
    json.dump(d, open(REG, 'w', encoding='utf-8'), indent=1, ensure_ascii=False)

def ask_id(port, timeout=2.0):
    """向指定串口询问 PUF 指纹; 返回 16 位 hex 或 None"""
    p = None
    try:
        p = serial.Serial(port, 115200, timeout=0.3, write_timeout=1)
        # 兼容: 若板在 U 校准态, 先发一个确认字节
        p.reset_input_buffer()
        p.write(b'\r')
        time.sleep(0.15)
        p.reset_input_buffer()
        p.write(b'CMD:ID\r\n')
        t0 = time.time(); buf = b''
        while time.time() - t0 < timeout:
            d = p.read(128)
            if d: buf += d
            i = buf.find(b'RESP:ID:')
            if i >= 0:
                tail = buf[i + 8:]
                if len(tail) >= 17 and tail[16:17] in (b'\r', b'\n'):
                    return tail[:16].decode('ascii', 'ignore').upper()
        return None
    except Exception:
        return None
    finally:
        if p:
            try: p.close()
            except Exception: pass

def list_ports():
    """枚举可用串口"""
    try:
        from serial.tools import list_ports
        return [x.device for x in list_ports.comports()]
    except Exception:
        return ['COM%d' % i for i in range(3, 16)]

def scan():
    """扫描全部串口, 返回 {port: fingerprint}"""
    res = {}
    for port in list_ports():
        fp = ask_id(port)
        if fp:
            res[port] = fp
    return res

def hamming(a, b):
    """两个 16 位 hex 指纹的汉明距离; 解析失败返回 64"""
    try:
        return bin(int(a, 16) ^ int(b, 16)).count('1')
    except Exception:
        return 64

def match(fp, reg=None, max_hd=4):
    """按指纹匹配板号, 返回 (board, hd) 或 (None, hd)
    允许 max_hd 位漂移: 实测 7 号板的 64 位指纹会有 1~2 位随测量翻动
    (reps=15 多数决压在近平局环上), 而不同板之间实测 HD≈16 位, 阈值 4 不会误配。"""
    reg = reg or load()
    best, best_hd = None, 65
    for board, known in reg.items():
        hd = hamming(fp, known)
        if hd < best_hd:
            best, best_hd = board, hd
    if best_hd <= max_hd:
        return best, best_hd
    return None, best_hd

def find_port(board, reg=None, max_hd=4):
    """扫描所有串口, 返回该板号的端口; 找不到返回 (None, 最佳距离)"""
    reg = reg or load()
    target = reg.get(str(board))
    if not target:
        return None, None
    best_port, best_hd = None, 65
    for port, fp in scan().items():
        hd = hamming(fp, target)
        if hd < best_hd:
            best_port, best_hd = port, hd
    if best_hd <= max_hd:
        return best_port, best_hd
    return None, best_hd

def identify(reg=None):
    """返回 {board_no: port} — 按指纹匹配已知板号 (容忍少量位漂移)"""
    reg = reg or load()
    out = {}
    for port, fp in scan().items():
        board, hd = match(fp, reg)
        if board:
            out[board] = port
    return out

if __name__ == '__main__':
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == 'enroll':
        # 交互式登记: python boardid.py enroll 7 COM5
        board, port = sys.argv[2], sys.argv[3]
        fp = ask_id(port)
        if not fp:
            print('端口 %s 无 ID 应答 (板子未上电/未刷 v32?)' % port); sys.exit(1)
        d = load(); d[board] = fp; save(d)
        print('已登记: %s 号板 -> %s (%s)' % (board, fp, port))
    else:
        for port, fp in scan().items():
            print('%s -> %s' % (port, fp))
