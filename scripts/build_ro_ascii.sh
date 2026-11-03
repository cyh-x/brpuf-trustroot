#!/bin/bash
# build_ro_ascii.sh — RO-pair Strong PUF 的 ASCII 构建工作区
#   中文路径会让 jtag_axi IP 的加密 ttcl 生成失败, 故全部构建在 "$WS" 做
WS="${BRPUF_WORKSPACE:-$(cd "$(dirname "$0")/.." && pwd)}"
set -e
PROJ="$(cd "$(dirname "$0")/.." && pwd)"

VIVADO="${VIVADO_BIN:-vivado}"
echo ">> PROJ=$PROJ  WS=$WS"
mkdir -p "$WS" "$WS/logs" "$WS/pr_out"
rm -rf "$WS/rtl" "$WS/scripts" "$WS/.Xil"
cp -r "$PROJ/rtl" "$WS/rtl"
cp -r "$PROJ/scripts" "$WS/scripts"
rm -f "$WS/scripts/pins.xdc"
cd "$WS"
"$VIVADO" -mode batch -source scripts/build_ro.tcl -nolog -nojournal > logs/build.log 2>&1 || true
grep -a ">> ROPUF" logs/build.log | tail -12
if ! grep -aq ">> BUILD_DONE" logs/build.log; then
    echo ">> BUILD_FAILED"
    grep -aE "ERROR:|CRITICAL WARNING:" logs/build.log | tail -12
    exit 1
fi
mkdir -p "$PROJ/pr_out" "$PROJ/logs"
cp "$WS/pr_out/ropuf_ax7020.bit"  "$PROJ/pr_out/" 2>/dev/null || true
cp "$WS/pr_out/ropuf_impl.dcp"    "$PROJ/pr_out/" 2>/dev/null || true
cp "$WS/pr_out/ip_pr.gen/sources_1/ip/ps7_0/ps7_init.tcl" "$PROJ/pr_out/" 2>/dev/null || true
cp "$WS/logs/build.log" "$WS/logs/timing.rpt" "$WS/logs/util.rpt" "$PROJ/logs/" 2>/dev/null || true
echo ">> BUILD_OK bit -> $PROJ/pr_out/ropuf_ax7020.bit"
