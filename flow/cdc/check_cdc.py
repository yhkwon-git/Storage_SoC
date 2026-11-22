#!/usr/bin/env python3
"""Structural clock-domain-crossing check of soc_top (docs/01, section 2;
docs/09_timing.md).

Input: build/syn/soc_top_generic.json, the flattened generic netlist Yosys
writes during flow/syn/run_syn.sh (before mapping to Sky130). Every flop is
put in the domain of the clock port its clock pin traces back to, through the
dlclkp clock gates. For every flop input (D, enable, synchronous reset) the
combinational cone is traced back to its sources: flops, latches, SRAM
outputs and input ports. An input whose sources include another domain, or
an asynchronous input port, is a crossing, and each crossing must be one of:

  SYNC       the first stage of a synchronizer (cdc_sync_2ff stage1), fed by a
             single register with no logic in between (logic before a
             synchronizer can glitch, and a glitch can be captured)
  HANDSHAKE  a request or response register of apb_cdc, which the
             request/acknowledge handshake holds stable while it is read
  FIFO       a memory word of a cdc_async_fifo, read through the read side's
             address after the Gray pointer said it was written
  CONTROL    a PMU output that changes only while what it drives is idle:
             iso_en (PD_HOST's outputs are idle or in reset when it changes)
             and save (the PD_HOST logic is idle while it is high)

Anything else fails. Asynchronous reset and set pins are not data inputs and
are not checked here: every reset reaches its flops through a rst_sync.

Usage: python3 flow/cdc/check_cdc.py [netlist.json]
"""
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NETLIST = ROOT / "build/syn/soc_top_generic.json"

CLOCK_PORTS = {"clk_sys": "clk_sys", "clk_aon": "clk_aon", "clk_nand": "clk_nand", "pclk_in": "pclk"}
ASYNC_PORTS = {"por_n", "host_pwr_ack", "host_wake"}
IDX = r"(\[\d+\])*$"
SYNC_STAGE1 = re.compile(r"\.stage1" + IDX)
HANDSHAKE = re.compile(r"\.u_cdc\.(q_addr|q_write|q_wdata|q_strb|d_rdata|d_slverr)" + IDX)
FIFO_MEM = re.compile(r"_fifo\.mem" + IDX)
CONTROL = re.compile(r"\.u_pmu\.(iso_en|save)" + IDX)

# Pins of generic flops: clock, data-like inputs, outputs. Async R/S pins are
# left out on purpose (see the docstring).
FF_CLK = "C"
FF_DATA = {"D", "E"}
SRAM_CELLS = {"sram_2048x64", "sram_8192x64", "sram_512x64"}


def main():
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else NETLIST
    mod = json.loads(path.read_text())["modules"]["soc_top"]
    cells = mod["cells"]

    # Bit names: every public name of each bit (a bit has one per level of
    # hierarchy it passes); the longest is reported, all are matched.
    all_names = defaultdict(list)
    for nm, info in mod["netnames"].items():
        if info.get("hide_name"):
            continue
        for i, b in enumerate(info["bits"]):
            if isinstance(b, int):
                all_names[b].append(nm if len(info["bits"]) == 1 else f"{nm}[{i}]")
    names = {b: max(ns, key=len) for b, ns in all_names.items()}

    def matches(b, pattern):
        return any(pattern.search(n) for n in all_names.get(b, []))
    port_bits = {}
    for pn, p in mod["ports"].items():
        for b in p["bits"]:
            if isinstance(b, int):
                port_bits[b] = pn

    # Drivers: bit -> (cell, port) for cell outputs.
    driver = {}
    for cn, c in cells.items():
        for pn, bits in c["connections"].items():
            if c["port_directions"].get(pn) == "output":
                for b in bits:
                    if isinstance(b, int):
                        driver[b] = (cn, pn)

    def is_ff(c):
        return c["type"].startswith(("$_DFF", "$_SDFF", "$_DFFE", "$_SDFFE", "$_SDFFCE", "$_ALDFF", "$_DFFSR"))

    def is_latch(c):
        return c["type"].startswith("$_DLATCH")

    def is_icg(c):
        return c["type"].endswith("dlclkp_1")

    # Clock domain of a clock bit, through clock gates.
    def clock_of(b, depth=0):
        if b in port_bits and port_bits[b] in CLOCK_PORTS:
            return CLOCK_PORTS[port_bits[b]]
        d = driver.get(b)
        if d and is_icg(cells[d[0]]) and depth < 8:
            return clock_of(cells[d[0]]["connections"]["CLK"][0], depth + 1)
        return None

    # Domain of each sequential source, keyed by output bit.
    seq_domain = {}
    for cn, c in cells.items():
        if is_ff(c):
            dom = clock_of(c["connections"][FF_CLK][0])
            for b in c["connections"]["Q"]:
                seq_domain[b] = dom
        elif c["type"] in SRAM_CELLS:
            dom = clock_of(c["connections"]["CLK"][0])
            for b in c["connections"]["Q"]:
                seq_domain[b] = dom

    # Latches (retention shadows) take the domain of their data.
    latch_cells = [cn for cn, c in cells.items() if is_latch(c)]

    memo = {}

    def sources(b, stack=0):
        """Set of (kind, bit) sources of a bit, and whether logic was crossed."""
        if not isinstance(b, int):
            return frozenset(), False
        if b in memo:
            return memo[b]
        if b in seq_domain or b in port_bits:
            res = (frozenset([b]), False)
        else:
            d = driver.get(b)
            if d is None:
                res = (frozenset(), False)
            else:
                c = cells[d[0]]
                if is_latch(c):
                    res = (frozenset([("latch", d[0])]), False)
                else:
                    acc, logic = set(), True
                    if c["type"] in ("$_BUF_",):
                        logic = False
                    for pn, bits in c["connections"].items():
                        if c["port_directions"].get(pn) == "input":
                            for ib in bits:
                                s, _ = sources(ib, stack + 1)
                                acc |= s
                    res = (frozenset(acc), logic)
        memo[b] = res
        return res

    def dom_of_src(s):
        if isinstance(s, tuple):  # latch: its D's domain
            c = cells[s[1]]
            doms = {dom_of_src(x) for x in sources(c["connections"]["D"][0])[0]}
            doms.discard(None)
            return next(iter(doms)) if len(doms) == 1 else "mixed"
        if s in seq_domain:
            return seq_domain[s]
        if s in port_bits:
            p = port_bits[s]
            if p in ASYNC_PORTS:
                return "async"
            if p in CLOCK_PORTS:
                return None
            return "clk_sys"   # chip ports are constrained against clk_sys
        return None

    def src_bit(s):
        return cells[s[1]]["connections"]["Q"][0] if isinstance(s, tuple) else s

    def src_name(s):
        b = src_bit(s)
        return names.get(b, port_bits.get(b, f"bit{b}"))

    def src_is(s, pattern):
        return matches(src_bit(s), pattern)

    counts = defaultdict(int)
    violations = []
    n_ff = 0
    checked = []
    for cn, c in cells.items():
        if is_ff(c):
            dom = clock_of(c["connections"][FF_CLK][0])
            pins = [p for p in c["connections"] if p in FF_DATA]
            qb = c["connections"]["Q"][0]
            n_ff += 1
            checked.append((dom, pins, c, names.get(qb, cn), all_names.get(qb, [])))
        elif c["type"] in SRAM_CELLS:
            dom = clock_of(c["connections"]["CLK"][0])
            pins = [p for p in c["connections"] if p not in ("CLK", "Q")]
            checked.append((dom, pins, c, cn, []))
    for cn in latch_cells:
        c = cells[cn]
        # A shadow latch: its enable comes from the PMU (save).
        for s in sources(c["connections"]["E"][0])[0]:
            if not src_is(s, CONTROL) and dom_of_src(s) != "pclk":
                violations.append(f"latch {cn}: enable from {src_name(s)}")
        counts["CONTROL"] += 1

    if any(d is None for d, _, _, _, _ in checked):
        bad = [q for d, _, _, q, _ in checked if d is None][:5]
        print(f"[CDC] ERROR flops with no clock domain: {bad}")
        return 1

    for dom, pins, c, qname, qnames in checked:
        for p in pins:
            for b in c["connections"][p]:
                srcs, logic = sources(b)
                foreign = [s for s in srcs if dom_of_src(s) not in (None, dom)]
                if not foreign:
                    continue
                q = qname
                if any(SYNC_STAGE1.search(n) for n in qnames):
                    if logic or len(srcs) != 1:
                        violations.append(f"{q}: logic or several sources before a synchronizer: "
                                          + ", ".join(sorted(src_name(s) for s in srcs)[:4]))
                    else:
                        counts["SYNC"] += 1
                    continue
                kinds = set()
                for s in foreign:
                    if src_is(s, HANDSHAKE):
                        kinds.add("HANDSHAKE")
                    elif src_is(s, FIFO_MEM):
                        kinds.add("FIFO")
                    elif src_is(s, CONTROL):
                        kinds.add("CONTROL")
                    else:
                        violations.append(f"{q} ({dom}) <- {src_name(s)} ({dom_of_src(s)})")
                        kinds.add("BAD")
                for k in kinds - {"BAD"}:
                    counts[k] += 1

    print(f"[CDC] {n_ff} flops, {len(latch_cells)} latches, 4 SRAM macros checked")
    print("[CDC] crossings: " + ", ".join(f"{k} {counts[k]}" for k in ("SYNC", "HANDSHAKE", "FIFO", "CONTROL")))
    for v in violations[:30]:
        print(f"[CDC] VIOLATION {v}")
    if violations:
        print(f"[CDC] FAIL: {len(violations)} crossings of no allowed kind")
        return 1
    print("[CDC] PASS: every crossing is a synchronizer, a handshake register, a FIFO word or a PMU control")
    return 0


if __name__ == "__main__":
    sys.exit(main())
