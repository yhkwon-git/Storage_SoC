#!/usr/bin/env bash
# Fetches the three Sky130 HD standard-cell liberty files used for synthesis
# and STA into build/pdk (not committed; docs/01, section 12). Source:
# siliconcompiler/lambdapdk v0.2.9, sky130hd NLDM. Each file is checked
# against its SHA-256; a mismatch fails.
#
#   PDK_DIR    where to put them (default: build/pdk)
#   PDK_CACHE  a directory that may already hold the files; matching copies are
#              taken from it instead of the network
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
pdk="${PDK_DIR:-$root/build/pdk}"
base="https://raw.githubusercontent.com/siliconcompiler/lambdapdk/v0.2.9/lambdapdk/sky130/libs/sky130hd/nldm"
mkdir -p "$pdk"

declare -A sha=(
  [sky130_fd_sc_hd__tt_025C_1v80.lib]=e66aab4e0a3eef8d0b13eb5b75aaadb725ba78b032203342eb1e419a2c111baf
  [sky130_fd_sc_hd__ss_n40C_1v40.lib]=4eca8d14037385220315b6f17511f82560d96716799f4c2fb30316483d19122c
  [sky130_fd_sc_hd__ff_100C_1v95.lib]=3980fbab70dbff25496fc48cf391362ef52c7f2a46c17f0f63a8d42cfed42558
)

ok() { [ -s "$1" ] && [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ]; }

for f in "${!sha[@]}"; do
  dst="$pdk/$f"
  if ok "$dst" "${sha[$f]}"; then
    echo "[PDK] $f present"
    continue
  fi
  if [ -n "${PDK_CACHE:-}" ] && ok "$PDK_CACHE/$f" "${sha[$f]}"; then
    cp "$PDK_CACHE/$f" "$dst"
    echo "[PDK] $f copied from PDK_CACHE"
    continue
  fi
  curl -fsSL --retry 3 --retry-delay 2 -o "$dst.gz" "$base/$f.gz"
  gunzip -f "$dst.gz"
  if ! ok "$dst" "${sha[$f]}"; then
    echo "[PDK] $f: SHA-256 mismatch" >&2
    rm -f "$dst"
    exit 1
  fi
  echo "[PDK] $f downloaded"
done
echo "[PDK] Sky130 HD tt_025C_1v80, ss_n40C_1v40, ff_100C_1v95 in $pdk"
