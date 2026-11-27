#!/usr/bin/env bash
# Mutation check for the BCH testbench (tb_bch, step 3-3). Each mutant copies
# rtl/ecc into the build directory, plants one bug with sed in one of its
# files, builds tb_bch and runs it on the Python model's vectors with gaps and
# back-pressure, then back to back, stopping at the first failure. The
# testbench must fail on every mutant. The repository's RTL is never modified.
#
#   BUILD_DIR  build root (default: build/dv in the repository)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
base="${BUILD_DIR:-$root/build/dv}/bch_mut"
py="${PYTHON:-python3}"
mkdir -p "$base"
"$py" "$root/flow/bch/bch.py" --vectors "$base/vec.hex" --nv 200 --seed 1 > /dev/null

# name @ file in rtl/ecc @ sed expression @ what the bug does (fields split at @)
mutants=(
  "enc_lsb@bch_enc.sv@s/    for (int i = 7; i >= 0; i--) begin/    for (int i = 0; i < 8; i++) begin/@the encoder takes bit 0 of a byte first"
  "enc_first@bch_enc.sv@s/rem <= step(first ? {R{1'b0}} : rem, din);/rem <= step(rem, din);/@the encoder's remainder carries over into the next codeword"
  "enc_out@bch_enc.sv@s/  assign parity = rem\[R-1 -: 8\];/  assign parity = rem[R-2 -: 8];/@parity bytes taken a bit off"
  "syn_first@bch_syn.sv@s/step(first ? 13'd0 : s\[j\], SYN_A\[j\], din)/step(s[j], SYN_A[j], din)/@syndromes carry over into the next codeword"
  "syn_alpha@bch_syn.sv@s/SYN_A\[j\], din)/SYN_A[0], din)/@every syndrome computed at alpha"
  "bm_swap@bch_bm.sv@s/(dd <= {2'd0, k})/(dd < {2'd0, k})/@the correction term swapped one iteration late"
  "bm_tau@bch_bm.sv@s/: ((i > 4'd1) ? tau\[i - 4'd2\] : 13'd0);/: ((i > 4'd0) ? tau[i - 4'd1] : 13'd0);/@tau multiplied by x instead of x^2"
  "bm_gamma@bch_bm.sv@s/              gam <= d;/              gam <= gam;/@gamma never takes the discrepancy"
  "bm_even@bch_bm.sv@s/        s\[3\]  <= gf_sq(gf_sq(s_in\[0\]));/        s[3]  <= gf_sq(s_in[0]);/@S_4 taken as S_2"
  "bm_dd@bch_bm.sv@s/dd  <= {1'b0, k, 1'b1} - dd;/dd  <= {1'b0, k, 1'b0} - dd;/@the error count one short"
  "ch_init@bch_chien.sv@s/r\[n\] <= gf_mul(sig\[n\], CH_INIT\[n\]);/r[n] <= sig[n];/@the search starts at the wrong position"
  "ch_order@bch_chien.sv@s/      mask\[7 - m\] = busy/      mask[m] = busy/@bits of a byte reported in reverse"
  "ch_short@bch_chien.sv@s/      if (idx == 10'(N_BYTES - 1)) busy <= 1'b0;/      if (idx == 10'(N_BYTES - 2)) busy <= 1'b0;/@the search stops a byte early"
  "dec_verdict@bch_dec.sv@s/ || (roots != dd) || ovf;/ || ovf;/@roots not counted in the verdict"
  "dec_parity@bch_dec.sv@s/            if (ch_idx < 10'(K_BYTES)) begin/            if (1'b1) begin/@corrections reported for parity bytes"
  "dec_ready@bch_dec.sv@s/  assign ready = !pend;/  assign ready = 1'b1;/@a codeword starts before the last one's syndromes are taken"
  "dec_bp@bch_dec.sv@s/          end else if (cor_ready) begin/          end else begin/@corrections dropped under back-pressure"
)

caught=0
total=0
for entry in "${mutants[@]}"; do
  IFS='@' read -r name f expr what <<< "$entry"
  total=$((total + 1))
  dir="$base/$name"
  t="$dir/rtl/ecc"
  rm -rf "$t"
  mkdir -p "$t"
  cp "$root"/rtl/ecc/*.sv "$t/"
  sed -i "$expr" "$t/$f"
  if cmp -s "$root/rtl/ecc/$f" "$t/$f"; then
    echo "[MUT] $name: sed changed nothing, mutant not applied"
    exit 1
  fi
  verilator --binary --timing --assert -j 0 --timescale 1ns/1ps --top-module tb_bch \
    "$here/lint/waivers.vlt" "$t/bch_pkg.sv" "$t/bch_enc.sv" "$t/bch_syn.sv" "$t/bch_bm.sv" \
    "$t/bch_chien.sv" "$t/bch_dec.sv" "$here/tb/tb_bch.sv" -Mdir "$base/obj" > "$dir/build.log" 2>&1 \
    || { echo "[MUT] $name: build failed"; cat "$dir/build.log"; exit 1; }
  first=""
  for args in "+gap=30 +bp=30" "+gap=0 +bp=0"; do
    # shellcheck disable=SC2086
    if ! (cd "$dir" && timeout 900 "$base/obj/Vtb_bch" +vec="$base/vec.hex" +nv=200 $args +verilator+seed+1) \
         > "$dir/run.log" 2>&1; then
      first=$( (grep -m1 -E 'ERROR|%Error|Assertion|FAIL' "$dir/run.log" || true) | cut -c1-150)
      [ -n "$first" ] || first="non-zero exit"
      break
    fi
  done
  if [ -n "$first" ]; then
    caught=$((caught + 1))
    echo "[MUT] $name ($what): caught by $args -- $first"
  else
    echo "[MUT] $name ($what): SURVIVED"
  fi
done

echo "[MUT] $caught of $total mutants caught"
[ "$caught" -eq "$total" ]
