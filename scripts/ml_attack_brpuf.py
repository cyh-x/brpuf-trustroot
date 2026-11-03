#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""ml_attack_brpuf.py — BR-PUF 抗建模攻击测试

攻击模型 (模拟窃听 N 个会话的攻击者, 在留出挑战上预测响应):
  M1 线性 LR      : [ring one-hot(64) | pattern(16)] 80 维
  M2 度-2 交互 LR : M1 特征 + 全部两两乘积 (~3240 维)
  M3 双层 MLP     : 80-64-1, numpy 手写 SGD
基线: 全体多数类 (若数据本身 55% 为 1, 猜多数即得 55% —— 攻击必须显著超过此基线才算破)
判据: 测试准确率 ≈ 基线 => 抗建模; 显著高于基线 => 可被建模
用法: python scripts/ml_attack_brpuf.py logs/brpuf_bulk_boardX.csv [n_train] [n_test]
"""
import csv, sys
import numpy as np

def load(path):
    X, Y = [], []
    for row in csv.reader(open(path, encoding="utf-8", errors="ignore")):
        if not row or row[0] != "crp":
            continue
        w = int(row[3], 16)
        chal = int(row[3])
        ring = (chal >> 16) & 0x3F
        pat = chal & 0xFFFF
        feats = np.zeros(80)
        feats[ring] = 1.0
        for b in range(16):
            feats[64 + b] = 1.0 if (pat >> b) & 1 else -1.0
        X.append(feats)
        Y.append(w & 1)
    return np.array(X), np.array(Y)

def lr_train(X, Y, iters=300, lr=0.5, reg=1e-3):
    n, d = X.shape
    w = np.zeros(d); b = 0.0
    Ys = Y * 2.0 - 1.0
    for it in range(iters):
        z = X @ w + b
        p = 1.0 / (1.0 + np.exp(-z))
        g = X.T @ (p - Ys) / n + reg * w
        w -= lr * g; b -= lr * np.mean(p - Ys)
    return w, b

def acc(X, Y, w, b):
    return float(np.mean(((X @ w + b) > 0).astype(int) == Y))

def mlp_train(X, Y, h=64, iters=400, lr=0.3):
    n, d = X.shape
    rng = np.random.RandomState(0)
    W1 = rng.randn(d, h) * np.sqrt(2.0 / d); b1 = np.zeros(h)
    W2 = rng.randn(h) * np.sqrt(2.0 / h); b2 = 0.0
    Ys = Y * 2.0 - 1.0
    for it in range(iters):
        z1 = X @ W1 + b1; a1 = np.tanh(z1)
        z2 = a1 @ W2 + b2
        p = np.tanh(z2)
        dz2 = (p - Ys) * (1 - p * p)
        dW2 = a1.T @ dz2 / n; db2 = dz2.mean()
        da1 = np.outer(dz2, W2)
        dz1 = da1 * (1 - a1 * a1)
        dW1 = X.T @ dz1 / n; db1 = dz1.mean(axis=0)
        W2 -= lr * dW2; b2 -= lr * db2
        W1 -= lr * dW1; b1 -= lr * db1
    return W1, b1, W2, b2

def mlp_acc(X, Y, W1, b1, W2, b2):
    a1 = np.tanh(X @ W1 + b1)
    return float(np.mean((((a1 @ W2 + b2) > 0).astype(int)) == Y))

def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "logs/brpuf_bulk_boardX.csv"
    ntr = int(sys.argv[2]) if len(sys.argv) > 2 else 10000
    nte = int(sys.argv[3]) if len(sys.argv) > 3 else 2000
    X, Y = load(path)
    rng = np.random.RandomState(42)
    perm = rng.permutation(len(Y))
    tr, te = perm[:ntr], perm[ntr:ntr + nte]
    Xtr, Ytr, Xte, Yte = X[tr], Y[tr], X[te], Y[te]
    base = max(Yte.mean(), 1 - Yte.mean())
    print("=" * 62)
    print("BR-PUF 建模攻击: 训练 %d / 测试 %d (测试集多数类基线 %.1f%%)" % (ntr, nte, base * 100))
    print("=" * 62)
    w, b = lr_train(Xtr, Ytr)
    a1 = acc(Xte, Yte, w, b)
    print("  M1 线性 LR       : 测试准确率 %.2f%%  (超基线 %+0.2f 点)" % (a1 * 100, a1 * 100 - base * 100))
    # M2: 交互特征
    def inter(Xa):
        return np.hstack([Xa, np.array([Xa[:, i] * Xa[:, j]
                                        for i in range(80) for j in range(i + 1, 80)]).T])
    Xtr2, Xte2 = inter(Xtr), inter(Xte)
    w2, b2 = lr_train(Xtr2, Ytr, iters=400)
    a2 = acc(Xte2, Yte, w2, b2)
    print("  M2 度-2 交互 LR   : 测试准确率 %.2f%%  (超基线 %+0.2f 点)" % (a2 * 100, a2 * 100 - base * 100))
    W1, bb1, W2, bb2 = mlp_train(Xtr, Ytr)
    a3 = mlp_acc(Xte, Yte, W1, bb1, W2, bb2)
    print("  M3 双层 MLP       : 测试准确率 %.2f%%  (超基线 %+0.2f 点)" % (a3 * 100, a3 * 100 - base * 100))
    print("-" * 62)
    worst = max(a1, a2, a3)
    verdict = "抗建模 ✔ (最好模型仅超基线 %.2f 点, 等价于噪声)" % ((worst - base) * 100) if worst < base + 0.02 \
        else ("部分可建模 ✘ (最好模型超基线 %.2f 点)" % ((worst - base) * 100))
    print("  结论: " + verdict)

if __name__ == "__main__":
    main()
