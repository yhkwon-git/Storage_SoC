#!/usr/bin/env bash
# Mutation check for the power testbench. Each mutant copies the power RTL into
# the build directory, plants one bug with sed and runs dv/run_power.sh on the
# copy (directed test and PLL-stuck test). The testbench must fail on every
# mutant. The repository's RTL is never modified.
#
#   BUILD_DIR  build root (default: build/dv in the repository)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
base="${BUILD_DIR:-$root/build/dv}/power_mut"

# name @ file @ sed expression @ what the bug does (fields split at @)
mutants=(
  "no_iso@pmu/iso_clamp.sv@s/assign dout = iso_en ? {WIDTH{CLAMP}} : din;/assign dout = din;/@isolation cells pass their input"
  "no_save@pmu/pmu.sv@s/return {pe, pl, hr, qr, iso, (s == P_DN_SAVE), (s == P_ON)};/return {pe, pl, hr, qr, iso, 1'b0, (s == P_ON)};/@no save pulse"
  "no_restore@pmu/pmu.sv@s/restore <= (p_next == P_UP_RESTORE) \&\& (p_state != P_UP_RESTORE) \&\& saved \&\& !chip_rst;/restore <= 1'b0;/@no restore pulse"
  "iso_early@pmu/pmu.sv@s/iso = (s != P_ON);/iso = (s < P_UP_PLL) || (s > P_ON);/@isolation released before the PLL locks"
  "idle_ignored@pmu/pmu.sv@s/if (idle_s) p_next = P_DN_ISO;/if (1'b1) p_next = P_DN_ISO;/@power-down while the host path is busy"
  "host_order@pmu/pmu.sv@s/host_rst_req_n  <= nand_rel_d \&\&/host_rst_req_n  <= nand_rel \&\&/@host reset released with the NAND reset"
  "no_timeout@pmu/pmu.sv@s/wire        timed_out = (pcnt >= tmo);/wire        timed_out = 1'b0;/@waits never time out"
  "cdc_ack@pmu/apb_cdc.sv@s/wire s_start = (s_state == S_IDLE) \&\& s_psel \&\& !ack_s;/wire s_start = (s_state == S_IDLE) \&\& s_psel;/@APB crossing starts before ack has dropped"
  "tx_when_off@host/host_if.sv@s/assign tx_push = tx_wr \&\& on_s \&\& qrst_n \&\& !tx_full;/assign tx_push = tx_wr \&\& !tx_full;/@TX accepted while PD_HOST is off"
  "no_lock_wait@pmu/pmu.sv@s/if (lock_s)         p_next = P_UP_RST;/if (1'b1)         p_next = P_UP_RST;/@power-up does not wait for the PLL"
  "no_pa_model@host/pd_host.sv@s/assign pa = pwr_ack ? raw : junk;/assign pa = raw;/@off-state model removed (testbench self-check)"
)

caught=0
total=0
for entry in "${mutants[@]}"; do
  IFS='@' read -r name file expr what <<< "$entry"
  total=$((total + 1))
  dir="$base/$name"
  mkdir -p "$dir/rtl"
  for d in common pmu host top; do
    mkdir -p "$dir/rtl/$d"
    cp "$root/rtl/$d/"*.sv "$dir/rtl/$d/"
  done
  sed -i "$expr" "$dir/rtl/$file"
  if cmp -s "$root/rtl/$file" "$dir/rtl/$file"; then
    echo "[MUT] $name: sed changed nothing, mutant not applied"
    exit 1
  fi
  if PWR_RTL="$dir/rtl" BUILD_DIR="$base" bash "$here/run_power.sh" > "$dir/run.log" 2>&1; then
    echo "[MUT] $name ($what): NOT caught"
  else
    caught=$((caught + 1))
    first=$( (grep -m1 -E 'ERROR|%Error|Assertion' "$dir/run.log" || grep -m1 'FAIL' "$dir/run.log" || true) | cut -c1-160)
    echo "[MUT] $name ($what): caught -- $first"
  fi
done

echo "[MUT] $caught of $total mutants caught"
[ "$caught" -eq "$total" ]
