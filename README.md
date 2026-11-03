# BR-PUF 硬件信任根与多节点并行认证系统

基于 Zynq-7000（ALINX AX7020 / xc7z020）的双稳环 PUF（Bistable Ring PUF）硬件信任根，
配套设备端 BCH 模糊提取器、AES-256 挑战-应答协议与三节点并行认证。

## 目录结构

```
rtl/         Verilog：双稳环阵列、AXI 基础设施、AES/TRNG 封装、顶层
ps_app/      PS 端裸机固件（C）：UART 命令协议、设备端 BCH 解码器
scripts/     Vivado 构建 Tcl、上板采集/验证脚本
host/        主机侧工具（Python）：认证服务器、消耗制会话、建模攻击评估、TRNG 检验
doc/         技术文档生成器、图表、技术文档
```

## 核心设计

**双稳环阵列**：64 个环 × 16 级，每级一个 LUT3 实现 `O = I0 ^ C_i`（`en=0` 复位为 0，
`en=1` 释放）。每环独占一列 slice，16 级占该列连续 16 行（实测 `SLICE_X{r}Y1..Y16`），
逐级交替 A6LUT/B6LUT 以抵消同一位流下布线延迟的确定性。16 位环内图案必须为偶 popcount，
否则环路成为反相振荡器。

**设备端模糊提取器**：注册时主机取随机 48 字节 R，`C = BCH_encode(R)`（71 B），
helper `W = K ^ C[:32]`；认证时设备重派生 `K'`，拼出带噪码字 `(K'^W)|C[32:]`，
在 A9 裸机上用 GF(2^10) Berlekamp-Massey + Chien 搜索纠错（t=18），恢复注册身份 K。
密钥不出设备，helper 可公开，断电免重注册。

**两种认证制式**：
- 固定密钥制：AES-256 挑战-应答（E1/E2/E3 三方交换），E3 绑定当次新鲜随机数 R1；
- 消耗制多挑战会话：服务器维护每板 CRP 台账，每会话消耗 K=128 个新鲜挑战，
  用后即弃，已消耗挑战重放由服务器直接拒绝。

## 构建

```bash
# 位流（Vivado 2026.1，xc7z020）
vivado -mode batch -source scripts/build_uart.tcl

# 裸机固件（arm-none-eabi-gcc，Cortex-A9）
arm-none-eabi-gcc -mcpu=cortex-a9 -O2 -nostdlib -T ps_app/link.ld \
    ps_app/start.S ps_app/ps_uart_app.c ps_app/bchdec.c -o ps_uart_app.elf

# SD 卡引导：FSBL + 位流 + 应用 -> BOOT.BIN（三级分区）
```

## 运行

```bash
pip install pyserial pycryptodome bchlib flask numpy matplotlib
python host/ui_server.py      # 演示仪表盘 http://127.0.0.1:5000
python host/poolauth.py enroll COM5 DEV1 20000   # 建消耗制 CRP 池
```

> `host/` 下脚本中的路径指向作者本地数据目录（`C:\spuf_build`），
> 运行前请按自己的目录结构调整脚本顶部的常量。位流、CRP 数据集、
> 设备密钥库未包含在本仓库中。

## 数据与复现说明

PUF/TRNG 的实测数据（百万 CRP 数据集、整夜认证日志、器件密钥库）体积大且包含
设备特定信息，未随代码发布。仓库内统计数字（唯一性 25.4%、认证成功率 100%、
TRNG 检验 p 值等）来自作者本地实验记录。

## 许可

见 LICENSE。第三方参考实现（4x4-APUF、RO-PUF、PUF-lab 等）未包含在本仓库，
相关许可归各自作者。
