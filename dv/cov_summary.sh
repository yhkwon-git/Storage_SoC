#!/usr/bin/env bash
# Summarizes a Verilator coverage.dat for the files whose path contains a
# filter (default /rtl/). A point counts once across instances and is hit if
# any instance hit it. Prints one line per type: line, branch, expr, toggle.
#
#   bash dv/cov_summary.sh <coverage.dat> [filter]
set -euo pipefail

dat="$1"
filt="${2:-/rtl/}"

awk -v filt="$filt" '
{
  cnt = $NF
  s = $0
  sub(/^C \047/, "", s)
  sub(/\047 [0-9]+$/, "", s)
  n = split(s, kv, "\001")
  f = ""; l = ""; c = ""; o = ""; t = ""
  for (i = 1; i <= n; i++) {
    split(kv[i], p, "\002")
    if (p[1] == "f") f = p[2]
    else if (p[1] == "l") l = p[2]
    else if (p[1] == "n") c = p[2]
    else if (p[1] == "o") o = p[2]
    else if (p[1] == "t") t = p[2]
  }
  if (index(f, filt) == 0 || t == "") next
  key = t SUBSEP f SUBSEP l SUBSEP c SUBSEP o
  if (!(key in seen)) { seen[key] = 1; tot[t]++ }
  if (cnt > 0 && !(key in got)) { got[key] = 1; hit[t]++ }
}
END {
  split("line branch expr toggle", order, " ")
  for (i = 1; i <= 4; i++) {
    t = order[i]
    if (t in tot) printf "[COV] %-6s %5d of %5d  %5.1f%%\n", t, hit[t], tot[t], 100.0 * hit[t] / tot[t]
  }
}' "$dat"
