#!/usr/bin/env python3
"""Standard-cell area of build/syn/soc_top.nl.v by top-level block.

The netlist is flat; autoname gives each cell a name that starts with the
instance path it came from (u_cpu..., u_xbar..., u_pwr...), and the fanout
buffers are counted on their own. Areas are from the tt liberty file. The
SRAM macros have no area model and are not counted.

Usage: python3 flow/syn/area_by_block.py [netlist] [liberty]
"""
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NETLIST = ROOT / "build/syn/soc_top.nl.v"
LIB = ROOT / "build/pdk/sky130_fd_sc_hd__tt_025C_1v80.lib"
BLOCKS = [
    ("u_cpu", "CPU (Ibex and its clock gate)"),
    ("u_ibus", "Instruction-port adapter"),
    ("u_dbus", "Data-port adapter"),
    ("u_xbar", "AXI4 crossbar"),
    ("u_dma", "DMA"),
    ("g_mem", "Memory controllers (macros not counted)"),
    ("u_apb", "AXI-to-APB bridge"),
    ("u_sys", "SYS"),
    ("u_intc", "INTC"),
    ("u_timer", "TIMER"),
    # Transaction layer (step 2-1), before the rest of u_pwr: first match wins.
    ("u_pwr.u_host_if.u_tl.u_bm", "TL bus master (tags, write buffer)"),
    ("u_pwr.u_host_if.u_tl.u_rd", "TL completer (completion buffer, jobs)"),
    ("u_pwr.u_host_if.u_tl.u_rxbuf", "TL receive buffer"),
    ("u_pwr.u_host_if.u_tl.u_unpack", "TL unpack"),
    ("u_pwr.u_host_if.u_tl.u_pack", "TL pack"),
    ("u_pwr.u_host_if.u_tl.u_msix", "TL MSI-X table"),
    ("u_pwr.u_host_if.u_tl.u_wr", "TL write engine"),
    ("u_pwr.u_host_if.u_tl.u_cfg", "TL configuration space"),
    ("u_pwr.u_host_if.u_tl", "TL dispatcher, arbiter, AXI slices"),
    ("u_pwr.u_host_if.u_tlp_", "TLP dual-clock FIFOs"),
    # NVMe controller (steps 2-2 and 2-3), by instance name: a flop that
    # drives an output takes the name of that output in the parent, so the
    # split is approximate (the generated registers are not split off at all).
    ("u_pwr.u_host_if.u_nvme.u_lbuf", "NVMe buffer (16 words of flops)"),
    ("u_pwr.u_host_if.u_nvme.u_prp", "NVMe PRP engine"),
    ("u_pwr.u_host_if.u_nvme.u_cqe", "NVMe completion poster"),
    ("u_pwr.u_host_if.u_nvme", "NVMe registers, queues, fetch, requesters"),
    ("g_nand[0].u_nand.u_seq", "NAND0 bus sequencer (clk_nand)"),
    ("g_nand[0].u_nand.u_pbuf", "NAND0 page buffer port (macro not counted)"),
    ("g_nand[0].u_nand", "NAND0 registers, queues, data mover, crossings"),
    ("g_nand[1].u_nand.u_seq", "NAND1 bus sequencer (clk_nand)"),
    ("g_nand[1].u_nand.u_pbuf", "NAND1 page buffer port (macro not counted)"),
    ("g_nand[1].u_nand", "NAND1 registers, queues, data mover, crossings"),
    ("g_nand", "NAND reset synchronizers"),
    ("u_pwr", "PMU, crossing, PD_HOST, HOST registers, placeholder FIFOs"),
    ("u_rst_dma", "DMA reset synchronizer"),
    ("_fanbuf", "Fanout buffers (flow/syn/buffer_fanout.py)"),
]


def lib_areas(path):
    areas, cur = {}, None
    for line in open(path, encoding="latin1"):
        m = re.search(r'cell\s*\(\s*"([^"]+)"\s*\)', line)
        if m:
            cur = m.group(1)
        elif cur and line.strip().startswith("area"):
            areas[cur] = float(line.split(":")[1].strip().strip(";"))
            cur = None
    return areas


def main():
    netlist = Path(sys.argv[1]) if len(sys.argv) > 1 else NETLIST
    lib = Path(sys.argv[2]) if len(sys.argv) > 2 else LIB
    areas = lib_areas(lib)
    by = defaultdict(lambda: [0, 0.0])
    other = [0, 0.0]
    for m in re.finditer(r"^  (sky130_fd_sc_hd__\w+) \\?(\S+)", netlist.read_text(), re.M):
        cell, name = m.group(1), m.group(2)
        a = areas.get(cell, 0.0)
        for prefix, _ in BLOCKS:
            if name.startswith(prefix):
                by[prefix][0] += 1
                by[prefix][1] += a
                break
        else:
            other[0] += 1
            other[1] += a
    total = sum(v[1] for v in by.values()) + other[1]
    print(f"{'Block':45s} {'cells':>7s} {'area um2':>11s} {'share':>6s}")
    for prefix, label in BLOCKS:
        n, a = by[prefix]
        if n:
            print(f"{label:45s} {n:7d} {a:11.0f} {100 * a / total:5.1f}%")
    if other[0]:
        print(f"{'Other (top-level glue)':45s} {other[0]:7d} {other[1]:11.0f} {100 * other[1] / total:5.1f}%")
    print(f"{'Total':45s} {sum(v[0] for v in by.values()) + other[0]:7d} {total:11.0f}")


if __name__ == "__main__":
    main()
