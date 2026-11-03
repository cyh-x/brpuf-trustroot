#!/bin/bash
# build_apuf_ascii.sh — PDL 仲裁 PUF 的 ASCII 构建封装
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
"$VIVADO" -mode batch -source scripts/build_apuf.tcl -nolog -nojournal > logs/build_apuf.log 2>&1 || true
grep -a ">> APUF" logs/build_apuf.log | tail -10
if ! grep -aq ">> BUILD_DONE" logs/build_apuf.log; then
    echo ">> BUILD_FAILED"
    grep -aE "ERROR:|CRITICAL WARNING:" logs/build_apuf.log | tail -12
    exit 1
fi
mkdir -p "$PROJ/pr_out" "$PROJ/logs"
cp "$WS/pr_out/apuf_ax7020.bit" "$PROJ/pr_out/" 2>/dev/null || true
cp "$WS/pr_out/apuf_impl.dcp"   "$PROJ/pr_out/" 2>/dev/null || true
cp "$WS/pr_out/ip_pr.gen/sources_1/ip/ps7_0/ps7_init.tcl" "$PROJ/pr_out/" 2>/dev/null || true
cp "$WS/logs/build_apuf.log" "$WS/logs/timing.rpt" "$WS/logs/util.rpt" "$PROJ/logs/" 2>/dev/null || true
echo ">> BUILD_OK bit -> $PROJ/pr_out/apuf_ax7020.bit"
