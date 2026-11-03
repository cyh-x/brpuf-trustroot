"""paths.py — 统一的路径配置（所有 host 脚本共用）

数据根目录由环境变量 BRPUF_HOME 指定；未设置时默认使用仓库根下的 data/ 目录：

    <repo>/data/
        eccdb31.json        设备注册库（含密钥，切勿公开）
        board_ids.json      板卡 PUF 指纹登记表
        crp_cache.npz       百万 CRP 特征缓存
        model_m1_m3.npz     预训练模型缓存
        trng_stream.json    TRNG 采样原始数据
        trng_report.json    TRNG 检验结果
        puf_layout.csv      由 Vivado DCP 导出的 LUT 布局坐标
        auth_db/            消耗制 CRP 台账（每板一个 pool_<dev>.json）
        logs/               采集日志、批量 CRP 数据集
        night/              整夜稳定性/认证采集结果
        figs/               生成的图表

用法：
    export BRPUF_HOME=/path/to/data      # Linux/macOS
    setx BRPUF_HOME D:\\puf_data          # Windows

注意：eccdb31.json 与 auth_db/ 含设备派生密钥，不应提交到公开仓库。
"""
import os

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOME = os.environ.get('BRPUF_HOME') or os.path.join(_REPO_ROOT, 'data')


def p(*parts):
    """拼出数据目录下的路径，并确保父目录存在"""
    path = os.path.join(HOME, *parts)
    return path


def ensure(*parts):
    """拼路径并创建父目录"""
    path = p(*parts)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    return path


# ---- 常用文件 ----
DB_FILE = p('eccdb31.json')          # 设备注册库（密钥）
BOARD_IDS = p('board_ids.json')      # 板卡指纹登记
POOL_DIR = p('auth_db')              # 消耗制 CRP 台账
LOG_DIR = p('logs')                  # 采集日志/批量 CRP
NIGHT_DIR = p('night')               # 整夜采集结果
FIG_DIR = p('figs')                  # 图表输出
CRP_CSV = p('logs', 'brpuf_bulk_b7_1m.csv')
CRP_CACHE = p('crp_cache.npz')
MODEL_CACHE = p('model_m1_m3.npz')
TRNG_STREAM = p('trng_stream.json')
TRNG_REPORT = p('trng_report.json')
LAYOUT_CSV = p('puf_layout.csv')


def ensure_all():
    """创建所有输出目录"""
    for d in (POOL_DIR, LOG_DIR, NIGHT_DIR, FIG_DIR):
        os.makedirs(d, exist_ok=True)


if __name__ == '__main__':
    print('BRPUF_HOME =', HOME)
    for k in ('DB_FILE', 'BOARD_IDS', 'POOL_DIR', 'LOG_DIR', 'NIGHT_DIR',
              'FIG_DIR', 'CRP_CSV', 'CRP_CACHE', 'MODEL_CACHE',
              'TRNG_STREAM', 'TRNG_REPORT', 'LAYOUT_CSV'):
        v = globals()[k]
        print('%-12s %-48s %s' % (k, v, '存在' if os.path.exists(v) else '-'))
