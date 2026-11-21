#!/usr/bin/env bash
# Generates everything that comes from rtl/csr/rdl/soc_apb.rdl:
#   rtl/csr/gen/{sys,intc,timer}_regs{,_pkg}.sv   PeakRDL-regblock, APB4, async active-low reset,
#                                                  12-bit address (the whole 4 KiB slot), PSLVERR
#                                                  for addresses that map to nothing
#   fw/common/soc_regs.h                           PeakRDL-cheader, instance at 0x4000_0000
#   dv/ral/soc_apb_ral_pkg.sv                      PeakRDL-uvm
#   docs/regs/soc_apb.md                           PeakRDL-markdown
#
#   bash flow/rdl/gen.sh           regenerate in place
#   bash flow/rdl/gen.sh --check   regenerate into a temporary directory and fail if
#                                  any committed file differs
# PEAKRDL is the peakrdl command (default: peakrdl on PATH). Versions used are
# in flow/rdl/requirements.txt.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
peakrdl="${PEAKRDL:-peakrdl}"
# Run from the repository root with a relative source path: some generators
# copy the source path into their output.
cd "$root"
rdl="rtl/csr/rdl/soc_apb.rdl"

check=0
[ "${1:-}" = "--check" ] && check=1
if [ "$check" -eq 1 ]; then
  out="$(mktemp -d)"
else
  out="$root"
fi
mkdir -p "$out/rtl/csr/gen" "$out/fw/common" "$out/dv/ral" "$out/docs/regs"

for blk in sys_regs intc_regs timer_regs; do
  "$peakrdl" regblock "$rdl" -t "$blk" --cpuif apb4-flat --default-reset arst_n \
    --addr-width 12 --err-if-bad-addr -o "$out/rtl/csr/gen"
done
"$peakrdl" c-header "$rdl" -t soc_apb -i --inst-offset 0x40000000 -o "$out/fw/common/soc_regs.h"
"$peakrdl" uvm "$rdl" -t soc_apb -o "$out/dv/ral/soc_apb_ral_pkg.sv"
"$peakrdl" markdown "$rdl" -t soc_apb -o "$out/docs/regs/soc_apb.md"

if [ "$check" -eq 1 ]; then
  fail=0
  for f in rtl/csr/gen/sys_regs.sv rtl/csr/gen/sys_regs_pkg.sv \
           rtl/csr/gen/intc_regs.sv rtl/csr/gen/intc_regs_pkg.sv \
           rtl/csr/gen/timer_regs.sv rtl/csr/gen/timer_regs_pkg.sv \
           fw/common/soc_regs.h dv/ral/soc_apb_ral_pkg.sv docs/regs/soc_apb.md; do
    if ! cmp -s "$out/$f" "$root/$f"; then
      echo "[RDL] $f is out of date"
      fail=1
    fi
  done
  rm -rf "$out"
  [ "$fail" -eq 0 ] && echo "[RDL] generated files match soc_apb.rdl" || exit 1
else
  echo "[RDL] generated from soc_apb.rdl"
fi
