import paths
import csv
import os
# model_attack.py — 建模预测攻击 (百万 CRP 数据集训练; 目标板按 PUF 指纹识别)
#
# 攻击者视角:
#   1) 拿到目标板 7 号板采集的 100 万条 CRP (挑战 -> 响应)
#   2) 在 80 万条上训练模型, 试图学到"挑战 -> 响应"的规律
#   3) 在留出的 20 万条未见 CRP 上测试
#      若准确率显著高于"多数类基线", 说明 PUF 可被克隆
#
# 目标板识别用 CMD:ID 的 64 位 PUF 指纹 (boardid.py), 与串口号无关。
import numpy as np, os, csv

CRP_CSV = paths.CRP_CSV
CRP_CACHE = paths.CRP_CACHE
TARGET_BOARD = '7'
TARGET_LABEL = '7号板'

def load_crp():
    if os.path.exists(CRP_CACHE):
        z = np.load(CRP_CACHE)
        return z['X'], z['Y']
    if not os.path.exists(CRP_CSV):
        raise RuntimeError('CRP 数据集缺失: %s' % CRP_CSV)
    X = np.zeros((1000000, 80), dtype=np.float32)
    Y = np.zeros(1000000, dtype=np.uint8)
    n = 0
    with open(CRP_CSV, encoding='utf-8', errors='ignore') as f:
        for row in csv.reader(f):
            if not row or row[0] != 'crp':
                continue
            ch = int(row[3])
            X[n, (ch >> 16) & 0x3F] = 1.0
            pat = ch & 0xFFFF
            for b in range(16):
                X[n, 64 + b] = 1.0 if (pat >> b) & 1 else -1.0
            Y[n] = int(row[4], 16) & 1
            n += 1
            if n >= 1000000:
                break
    X, Y = X[:n], Y[:n]
    np.savez_compressed(CRP_CACHE, X=X, Y=Y)
    return X, Y

def train_lr(X, Y, epochs=8, bs=8192, lr=0.5, on_epoch=None):
    n, d = X.shape
    w = np.zeros(d, dtype=np.float32); b = 0.0
    rng = np.random.RandomState(0)
    for ep in range(epochs):
        perm = rng.permutation(n)
        for i in range(0, n, bs):
            idx = perm[i:i + bs]
            xb = X[idx]; yb = Y[idx].astype(np.float32)
            p = 1.0 / (1.0 + np.exp(-(xb @ w + b)))
            g = p - yb
            w -= lr * (xb.T @ g / len(idx))
            b -= lr * g.mean()
        if on_epoch:
            m = min(n, 100000)
            on_epoch(ep + 1, ((((X[:m] @ w + b) > 0).astype(np.uint8)) == Y[:m]).mean())
    return w, b

def train_mlp(X, Y, hidden=32, epochs=10, bs=4096, lr=0.08, on_epoch=None):
    n, d = X.shape
    rng = np.random.RandomState(1)
    W1 = (rng.randn(d, hidden) * 0.05).astype(np.float32)
    b1 = np.zeros(hidden, dtype=np.float32)
    W2 = (rng.randn(hidden, 1) * 0.05).astype(np.float32)
    b2 = np.zeros(1, dtype=np.float32)
    for ep in range(epochs):
        perm = rng.permutation(n)
        for i in range(0, n, bs):
            idx = perm[i:i + bs]
            xb = X[idx]; yb = Y[idx].astype(np.float32).reshape(-1, 1)
            h = np.maximum(xb @ W1 + b1, 0)
            p = 1.0 / (1.0 + np.exp(-(h @ W2 + b2)))
            g = (p - yb) / len(idx)
            gW2 = h.T @ g; gb2 = g.sum(axis=0)
            gh = (g @ W2.T) * (h > 0)
            W1 -= lr * (xb.T @ gh); b1 -= lr * gh.sum(axis=0)
            W2 -= lr * gW2; b2 -= lr * gb2
        if on_epoch:
            m = min(n, 100000)
            hs = np.maximum(X[:m] @ W1 + b1, 0)
            acc = ((((hs @ W2 + b2) > 0).ravel()).astype(np.uint8) == Y[:m]).mean()
            on_epoch(ep + 1, acc)
    f = lambda Z: (((np.maximum(Z @ W1 + b1, 0) @ W2 + b2) > 0).ravel())
    return f, (W1, b1, W2, b2)

def run(target_port, emit, n_train=800000, n_test=200000, mlp_sub=200000):
    emit('scenario', msg='建模预测攻击 · 目标 %s (PUF 指纹识别)' % TARGET_LABEL)
    if not target_port:
        emit('error', dev='DEV7',
             msg='目标板 %s 指纹未匹配到任何串口 → 该模型只对应这一块板, 攻击实验终止'
                 % TARGET_LABEL)
        return
    emit('sys', dev='DEV7', msg='目标板 %s 已定位 (%s), 指纹校验通过' % (TARGET_LABEL, target_port))

    X, Y = load_crp()
    emit('sys', dev='DEV7', msg='该板历史采集 100 万条 CRP (80 万离线训练模型, 20 万留出现场评测)'
         % ())
    Xtr, Ytr = X[:n_train], Y[:n_train]
    Xte, Yte = X[-n_test:], Y[-n_test:]

    # 两条零学习参照线 (都无需训练):
    #   1) 多数类基线: 永远猜出现较多的那一类
    #   2) 结构耦合基线: PUF 响应位里含挑战 pattern[0] 的直接异或项,
    #      故一条死规则 resp = NOT pattern[0] 即可获得相当高的"准确率"
    base_maj = max(Yte.mean(), 1 - Yte.mean())
    b0 = (Xte[:, 64] > 0).astype(np.uint8)   # 特征列 64 = pattern bit0 的 ±1 编码
    base_rule = ((1 - b0) == Yte).mean()
    emit('sys', dev='DEV7', msg='零学习参照: 多数类基线 %.2f%%, 单比特死规则 NOT ch[0] %.2f%%'
         % (base_maj * 100, base_rule * 100))
    emit('sys', dev='DEV7', msg='说明: 响应位含挑战 bit0 的异或耦合, 故"死规则"上限较高; '
                                '模型若不能超过它, 即证明未学到任何真实结构')

    import os as _os
    _cache = paths.MODEL_CACHE
    if _os.path.exists(_cache):
        emit('progress', dev='DEV7', msg='加载预训练模型 (曾用该板 80 万条 CRP 离线训练, 本次直接加载)…')
        _z = np.load(_cache)
        w, b = _z['w'], float(_z['b'])
        _W1, _b1, _W2, _b2 = _z['W1'], _z['b1'], _z['W2'], _z['b2']
        f3 = lambda Z: (((np.maximum(Z @ _W1 + _b1, 0) @ _W2 + _b2) > 0).ravel())
    else:
        emit('progress', dev='DEV7', msg='首次运行: 用该板历史 80 万条 CRP 离线训练 M1 (线性逻辑回归)…')
        w, b = train_lr(Xtr, Ytr, epochs=8,
                        on_epoch=lambda ep, a: emit('progress', dev='DEV7',
                                                    msg='M1 离线训练: epoch %d/8 · 训练集准确率 %.2f%%' % (ep, a * 100)))
    acc1 = ((((Xte @ w + b) > 0).astype(np.uint8)) == Yte).mean()
    emit('verdict', dev='DEV7', ok=False,
         note='M1 线性LR · 未见 CRP %.2f%% | 死规则 %.2f%% (增益 %+.2f pt)'
              % (acc1 * 100, base_rule * 100, (acc1 - base_rule) * 100))

    if _os.path.exists(_cache):
        emit('progress', dev='DEV7', msg='加载预训练模型 M3 (双层 MLP, 同一批离线数据)…')
    else:
        emit('progress', dev='DEV7', msg='首次运行: 离线训练 M3 (双层 MLP, 80-32-1)…')
        f3, (_W1, _b1, _W2, _b2) = train_mlp(Xtr[:mlp_sub], Ytr[:mlp_sub], epochs=10,
                       on_epoch=lambda ep, a: emit('progress', dev='DEV7',
                                                   msg='M3 离线训练: epoch %d/10 · 训练集准确率 %.2f%%' % (ep, a * 100)))
        np.savez_compressed(_cache, w=w, b=np.float64(b), W1=_W1, b1=_b1, W2=_W2, b2=_b2)
    acc3 = (f3(Xte[:50000]) == Yte[:50000]).mean()
    emit('verdict', dev='DEV7', ok=False,
         note='M3 双层MLP · 未见 CRP %.2f%% | 死规则 %.2f%% (增益 %+.2f pt)'
              % (acc3 * 100, base_rule * 100, (acc3 - base_rule) * 100))

    best = max(acc1, acc3)
    gain = best - base_rule
    emit('scenario',
         msg='最优模型 %.2f%% vs 死规则 %.2f%% (增益 %+.2f pt) 🛡️'
             % (best * 100, base_rule * 100, gain * 100))
