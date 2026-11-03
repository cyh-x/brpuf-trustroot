#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""ml_attack_big.py — BR-PUF 大规模抗建模攻击 (百万级 CRP)

模型:
  M1 线性 LR       (80 维, 全量小批量训练)
  M2 度-2 交互 LR   (3240 维, 子样本训练 —— 全量特征矩阵需 13GB, 子样本 30 万足够检验)
  M3 双层 MLP      (80-64-1, 全量小批量)
基线: 测试集多数类
用法: python scripts/ml_attack_big.py logs/brpuf_b7_1m.csv [n_train] [n_test] [m2_sub]
"""
import csv, sys
import numpy as np

def features(chal):
    f = np.zeros(80, dtype=np.float32)
    f[(chal >> 16) & 0x3F] = 1.0
    pat = chal & 0xFFFF
    for b in range(16):
        f[64 + b] = 1.0 if (pat >> b) & 1 else -1.0
    return f

def load_stream(path, limit=None):
    X = []; Y = []
    with open(path, encoding="utf-8", errors="ignore") as f:
        for row in csv.reader(f):
            if not row or row[0] != "crp":
                continue
            X.append(features(int(row[2])))
            Y.append(int(row[4], 16) & 1)
            if limit and len(Y) >= limit:
                break
    return np.array(X, dtype=np.float32), np.array(Y, dtype=np.uint8)

def lr_minibatch(X, Y, iters=20, bs=65536, lr=0.5, reg=1e-4):
    n, d = X.shape
    w = np.zeros(d); b = 0.0
    rng = np.random.RandomState(0)
    for it in range(iters):
        perm = rng.permutation(n)
        for s in range(0, n, bs):
            idx = perm[s:s+bs]
            z = X[idx] @ w + b
            p = 1.0 / (1.0 + np.exp(-z))
            g = (X[idx].T @ (p - Y[idx])) / len(idx) + reg * w
            w -= lr * g; b -= lr * np.mean(p - Y[idx])
    return w, b

def interact(Xa):
    n = Xa.shape[0]
    out = np.empty((n, 3160), dtype=np.float32)
    cols = [(i, j) for i in range(80) for j in range(i+1, 80)]
    for k, (i, j) in enumerate(cols):
        out[:, k] = Xa[:, i] * Xa[:, j]
    return np.hstack([Xa, out])

def mlp(X, Y, h=64, epochs=10, bs=4096, lr=0.2):
    n, d = X.shape
    rng = np.random.RandomState(0)
    W1 = (rng.randn(d, h) * np.sqrt(2.0/d)).astype(np.float32); b1 = np.zeros(h, dtype=np.float32)
    W2 = (rng.randn(h) * np.sqrt(2.0/h)).astype(np.float32); b2 = np.float32(0.0)
    Yf = Y.astype(np.float32) * 2 - 1
    for ep in range(epochs):
        perm = rng.permutation(n)
        for s in range(0, n, bs):
            idx = perm[s:s+bs]
            xb, yb = X[idx], Yf[idx]
            a1 = np.tanh(xb @ W1 + b1)
            p = np.tanh(a1 @ W2 + b2)
            dz2 = (p - yb) * (1 - p*p)
            dW2 = (a1.T @ dz2) / len(idx); db2 = dz2.mean()
            da1 = np.outer(dz2, W2); dz1 = da1 * (1 - a1*a1)
            dW1 = (xb.T @ dz1) / len(idx); db1 = dz1.mean(axis=0)
            W2 -= lr*dW2; b2 -= lr*db2; W1 -= lr*dW1; b1 -= lr*db1
    return W1, b1, W2, b2

def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "logs/brpuf_b7_1m.csv"
    ntr = int(sys.argv[2]) if len(sys.argv) > 2 else 800000
    nte = int(sys.argv[3]) if len(sys.argv) > 3 else 200000
    sub2 = int(sys.argv[4]) if len(sys.argv) > 4 else 300000
    print("载入 %s ..." % path)
    X, Y = load_stream(path, ntr + nte)
    print("  共 %d CRP" % len(Y))
    rng = np.random.RandomState(42)
    perm = rng.permutation(len(Y))
    tr, te = perm[:ntr], perm[ntr:ntr+nte]
    Xtr, Ytr, Xte, Yte = X[tr], Y[tr], X[te], Y[te]
    base = max(Yte.mean(), 1 - Yte.mean())
    print("=" * 62)
    print("建模攻击(百万级): 训练 %d / 测试 %d (基线 %.2f%%)" % (ntr, nte, base*100))
    print("=" * 62)
    w, b = lr_minibatch(Xtr, Ytr)
    a1 = float(np.mean(((Xte @ w + b) > 0).astype(np.uint8) == Yte))
    atr = float(np.mean(((Xtr @ w + b) > 0).astype(np.uint8) == Ytr))
    print("  M1 线性 LR     : 训练 %.2f%%  测试 %.2f%%  (超基线 %+.2f 点)" % (atr*100, a1*100, a1*100-base*100))
    k = min(sub2, ntr)
    Xs, Ys = Xtr[:k], Ytr[:k]
    Xs2 = interact(Xs); Xte2 = interact(Xte[:50000]); Yte2 = Yte[:50000]
    w2, b2 = lr_minibatch(Xs2, Ys, iters=30)
    a2 = float(np.mean(((Xte2 @ w2 + b2) > 0).astype(np.uint8) == Yte2))
    atr2 = float(np.mean(((Xs2 @ w2 + b2) > 0).astype(np.uint8) == Ys))
    print("  M2 度-2 LR(%dk): 训练 %.2f%%  测试 %.2f%%  (超基线 %+.2f 点)" % (k//1000, atr2*100, a2*100, a2*100-base*100))
    W1, bb1, W2, bb2 = mlp(Xtr, Ytr)
    a3 = float(np.mean(((np.tanh(Xte @ W1 + bb1) @ W2 + bb2) > 0).astype(np.uint8) == Yte))
    a3tr = float(np.mean(((np.tanh(Xtr @ W1 + bb1) @ W2 + bb2) > 0).astype(np.uint8) == Ytr))
    print("  M3 双层 MLP    : 训练 %.2f%%  测试 %.2f%%  (超基线 %+.2f 点)" % (a3tr*100, a3*100, a3*100-base*100))
    print("-" * 62)
    worst = max(a1, a2, a3)
    if worst < base + 0.005:
        print("  结论: 抗建模 ✔ —— 百万级训练后最好模型仍不超过基线 0.5 点 (纯噪声水平)")
    else:
        print("  结论: 存在可学习结构 ✘ (最好模型超基线 %.2f 点)" % ((worst-base)*100))

if __name__ == "__main__":
    main()
