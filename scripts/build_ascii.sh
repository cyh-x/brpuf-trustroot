#!/bin/bash
# build_ascii.sh — strongpuf_port 的 ASCII 构建工作区 (独立于 ax7020_port 的 C:/pufv2_build)
#   中文路径会让 jtag_axi IP 的加密 ttcl 生成失败, 故全部构建在 "$WS" 做
WS="${BRPUF_WORKSPACE:-$(cd "$(dirname "$0")/.." && pwd)}"
set -e
PROJ="$(cd "$(dirname "$0")/.." && pwd)"

VIVADO="${VIVADO_BIN:-vivado}"
echo ">> PROJ=$PROJ  WS=$WS"
mkdir -p "$WS"
rm -rf "$WS/rtl" "$WS/scripts" "$WS/logs" "$WS/4x4-apuf-main"
mkdir -p "$WS/logs" "$WS/pr_out"
cp -r "$PROJ/rtl" "$WS/rtl"
cp -r "$PROJ/4x4-apuf-main" "$WS/4x4-apuf-main"
cp -r "$PROJ/scripts" "$WS/scripts"
rm -f "$WS/scripts/pins.xdc"
cd "$WS"
"$VIVADO" -mode batch -source scripts/build_bit.tcl -nolog -nojournal > logs/build.log 2>&1
tail -4 logs/build.log
grep -q ">> BUILD_DONE" logs/build.log || { echo ">> BUILD_FAILED"; exit 1; }
mkdir -p "$PROJ/pr_out" "$PROJ/logs"
cp "$WS/pr_out/spuf_xor_ax7020.bit" "$PROJ/pr_out/" 2>/dev/null || true
cp "$WS/pr_out/spuf_impl.dcp" "$PROJ/pr_out/" 2>/dev/null || true
cp "$WS/pr_out/ip_pr.gen/sources_1/ip/ps7_0/ps7_init.tcl" "$PROJ/pr_out/" 2>/dev/null || true
cp "$WS/logs/build.log" "$WS/logs/timing.rpt" "$WS/logs/util.rpt" "$PROJ/logs/" 2>/dev/null || true
echo ">> BUILD_OK bit -> $PROJ/pr_out/spuf_xor_ax7020.bit"
