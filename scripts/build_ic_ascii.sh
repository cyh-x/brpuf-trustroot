#!/bin/bash
# build_ic_ascii.sh — v15 (协议转换版信任根) 构建
WS="${BRPUF_WORKSPACE:-$(cd "$(dirname "$0")/.." && pwd)}"
set -e
PROJ="$(cd "$(dirname "$0")/.." && pwd)"

VIVADO="${VIVADO_BIN:-vivado}"
mkdir -p "$WS" "$WS/logs" "$WS/pr_out"
rm -rf "$WS/rtl" "$WS/scripts" "$WS/.Xil"
cp -r "$PROJ/rtl" "$WS/rtl"
cp -r "$PROJ/scripts" "$WS/scripts"
rm -f "$WS/scripts/pins.xdc"
cd "$WS"
"$VIVADO" -mode batch -source scripts/build_ic.tcl -nolog -nojournal > logs/build_ic.log 2>&1 || true
grep -a ">> " logs/build_ic.log | tail -12
if ! grep -aq ">> BUILD_DONE" logs/build_ic.log; then
    echo ">> BUILD_FAILED"
    grep -aE "ERROR:|CRITICAL WARNING:" logs/build_ic.log | tail -15
    exit 1
fi
mkdir -p "$PROJ/pr_out" "$PROJ/logs"
cp "$WS/pr_out/trustroot_ic.bit" "$PROJ/pr_out/" 2>/dev/null || true
cp "$WS/pr_out/trustroot_ic_impl.dcp" "$PROJ/pr_out/" 2>/dev/null || true
cp "$WS/logs/build_ic.log" "$WS/logs/timing.rpt" "$WS/logs/util.rpt" "$PROJ/logs/" 2>/dev/null || true
echo ">> BUILD_OK bit -> $PROJ/pr_out/trustroot_ic.bit"
