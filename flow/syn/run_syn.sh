#!/usr/bin/env bash
# Synthesizes soc_top onto Sky130 HD (docs/09_timing.md):
#   1. sv2v (SYNTHESIS, SKY130 defined) turns Ibex's and soc_top's
#      SystemVerilog into one Verilog-2005 file
#   2. Yosys: the SRAM macros are black boxes, the clock gates are the
#      library's dlclkp cells; synth -flatten, flops mapped with the tt
#      library, logic mapped by ABC against the ss corner
#   3. build/syn/soc_top.nl.v and an area report by block (stat)
#
#   BUILD_DIR  build root (default: build); PDK_DIR (default: build/pdk, see
#              fetch_sky130.sh); SV2V (default: sv2v on PATH, else
#              ~/.local/bin/sv2v-Linux/sv2v); ABC_DELAY target in ps (default 16000)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="${BUILD_DIR:-$root/build}/syn"
pdk="${PDK_DIR:-$root/build/pdk}"
sv2v="${SV2V:-$(command -v sv2v || echo "$HOME/.local/bin/sv2v-Linux/sv2v")}"
delay="${ABC_DELAY:-16000}"
tt="$pdk/sky130_fd_sc_hd__tt_025C_1v80.lib"
ss="$pdk/sky130_fd_sc_hd__ss_n40C_1v40.lib"
mkdir -p "$out"
cd "$root"

[ -s "$tt" ] && [ -s "$ss" ] || { echo "[SYN] Sky130 libraries missing: run flow/syn/fetch_sky130.sh"; exit 1; }

ibex=rtl/vendor/ibex
files=()
incs=()
while read -r l; do
  case "$l" in
    +incdir+*) incs+=("-I" "$ibex/${l#+incdir+}") ;;
    ""|\#*)    ;;
    *)         files+=("$ibex/$l") ;;
  esac
done < "$ibex/ibex.f"
while read -r l; do
  case "$l" in ""|\#*) ;; *) files+=("$l") ;; esac
done < "$here/rtl_files.f"

"$sv2v" -DSYNTHESIS -DSKY130 "${incs[@]}" "${files[@]}" -w "$out/soc_top.v" 2> "$out/sv2v.log" \
  || { cat "$out/sv2v.log"; exit 1; }

# Cells ABC must not use for logic: isolation and level-shifter cells (they
# belong to the power intent), clock and delay buffers, scan and tristate
# cells, and cells without logic.
dont_use=$(grep -oE 'cell \("sky130_fd_sc_hd__[a-z0-9_]+"\)' "$ss" | sed -E 's/cell \("(.*)"\)/\1/' |
  grep -E '__(lpflow_|clkbuf|clkdlybuf|clkinv|dlygate|dlymetal|probe|decap|diode|fill|tap|ebufn|einv|sdf|sdlclkp|dlclkp|macro_|conb)' |
  sed 's/^/-dont_use /' | tr '\n' ' ')

cat > "$out/synth.ys" <<EOF
read_liberty -lib $tt
read_verilog $out/soc_top.v
hierarchy -check -top soc_top
synth -top soc_top -flatten
write_json $out/soc_top_generic.json
techmap -map $here/latch_map.v
dfflibmap -liberty $tt
abc -liberty $ss -constr $here/abc.constr -D $delay $dont_use
opt_clean
hilomap -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO
setundef -zero
opt_clean -purge
autoname
tee -o $out/stat.txt stat -liberty $tt
write_verilog -noattr $out/soc_top.nl.v
EOF

start=$(date +%s)
yosys -q -l "$out/yosys.log" -s "$out/synth.ys" > /dev/null 2>&1 || { tail -30 "$out/yosys.log"; exit 1; }
echo "[SYN] soc_top mapped to Sky130 HD in $(( $(date +%s) - start )) s: $out/soc_top.nl.v"
grep -E "Chip area|Number of cells" "$out/stat.txt" | tail -2 | sed 's/^ */[SYN] /'
python3 "$here/buffer_fanout.py" "$out/soc_top.nl.v" "$ss"
