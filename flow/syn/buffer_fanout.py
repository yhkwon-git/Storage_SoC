#!/usr/bin/env python3
"""Buffer high-load nets of a Yosys netlist mapped to Sky130 HD.

ABC buffers and sizes the logic it maps, but not nets it does not see: flop
outputs and ports driving many pins. Before layout there is no resizer, so
this pass inserts trees of sky130_fd_sc_hd__buf_8 wherever a driver's load
(the sum of the input pin capacitances it drives) exceeds 90% of its
max_capacitance at the given corner. Each leaf buffer drives at most 90% of
its own limit; stages are added until the driver's load fits.

Not touched: nets that reach a clock pin (CLK, the clocks are ideal before
layout) and nets that reach an asynchronous reset or set pin (reset trees
are left to layout; flow/sta/sta.tcl does not time them). The same idea as
AXI_PCIe_Subsystem's asic/buffer_fanout.py (commit b64e36a); this version
builds trees of any depth and skips clock and reset nets.

Usage: python3 flow/syn/buffer_fanout.py <netlist.v> <liberty.lib>
"""
import re
import sys
from collections import defaultdict

BUF = "sky130_fd_sc_hd__buf_8"
MARGIN = 0.90
SKIP_PINS = {"CLK", "RESET_B", "SET_B"}


def parse_liberty(path):
    """{cell: {pin: {"dir", "cap", "max_cap"}}} for the cells and pins."""
    cells = {}
    cur = pin = None
    depth = cell_depth = pin_depth = 0
    for line in open(path, encoding="latin1"):
        s = line.strip()
        if cur is None:
            m = re.search(r'cell\s*\(\s*"([^"]+)"\s*\)', line)
            if m:
                cur = cells.setdefault(m.group(1), {})
                cell_depth = depth + 1
        elif pin is None:
            m = re.search(r'^\s*pin\s*\(\s*"([^"]+)"\s*\)', line)
            if m:
                pin = cur.setdefault(m.group(1), {"dir": None, "cap": 0.0, "max_cap": None})
                pin_depth = depth + 1
        if pin is not None:
            if s.startswith("direction") and pin["dir"] is None:
                pin["dir"] = s.split(":")[1].strip().strip('";')
            elif s.startswith("capacitance ") or s.startswith("capacitance:"):
                pin["cap"] = float(s.split(":")[1].strip().strip(";"))
            elif s.startswith("max_capacitance"):
                pin["max_cap"] = float(s.split(":")[1].strip().strip(";"))
        depth += line.count("{") - line.count("}")
        if pin is not None and depth < pin_depth:
            pin = None
        if cur is not None and depth < cell_depth:
            cur = None
            pin = None
    return cells


# Instance names are plain or escaped (\name, ended by a space).
INST_RE = re.compile(r"^  (sky130_fd_sc_hd__\w+) (\\\S+ |\S+) ?\((.*?)\n  \);", re.S | re.M)
PIN_RE = re.compile(r"\.(\w+)\(([^()]*)\)")


def main():
    path, lib = sys.argv[1], sys.argv[2]
    cells = parse_liberty(lib)
    buf_in = cells[BUF]["A"]["cap"]
    buf_max = cells[BUF]["X"]["max_cap"]
    text = open(path, encoding="utf-8").read()

    insts = []
    for m in INST_RE.finditer(text):
        pins = [[p.group(1), p.group(2).strip()] for p in PIN_RE.finditer(m.group(3))]
        insts.append({"cell": m.group(1), "name": m.group(2), "pins": pins, "span": m.span()})

    loads = defaultdict(list)    # net -> [(inst, pin index, cap, pin name)]
    driver = {}                  # net -> max_cap of its single cell driver
    skip = set()
    for ii, inst in enumerate(insts):
        info = cells.get(inst["cell"], {})
        for pi, (pin, net) in enumerate(inst["pins"]):
            if not net or net.startswith("{") or "'" in net:
                continue
            meta = info.get(pin)
            if meta is None:
                continue
            if meta["dir"] == "input":
                loads[net].append((ii, pi, meta["cap"], pin))
                if pin in SKIP_PINS or inst["cell"].endswith("dlclkp_1") and pin == "CLK":
                    skip.add(net)
            elif meta["dir"] == "output":
                driver[net] = meta["max_cap"] if net not in driver else None

    extra = []
    nbuf = 0
    nnets = 0
    seq = 0

    decls = []

    def esc(n):
        # An escaped identifier ends at white space. "\base [3]" (a bit of an
        # escaped vector) already has its space; "\name[3]" (an escaped name
        # with brackets in it, from an unpacked array) does not.
        return n + " " if n.startswith("\\") and " " not in n else n

    def new_net():
        nonlocal seq
        n = f"_fanbuf_n{seq}_"
        seq += 1
        decls.append(f"  wire {n};")
        return n

    def add_buf(a, x):
        nonlocal nbuf
        extra.append(f"  {BUF} _fanbuf_u{nbuf}_ (\n    .A({esc(a)}),\n    .X({x})\n  );")
        nbuf += 1

    for net, max_cap in driver.items():
        if max_cap is None or net in skip:
            continue
        items = loads.get(net, [])
        total = sum(c for _, _, c, _ in items)
        if total <= MARGIN * max_cap:
            continue
        nnets += 1
        # Leaves: groups of loads, each within a buffer's limit.
        level = []
        group, acc = [], 0.0
        for it in items:
            if group and acc + it[2] > MARGIN * buf_max:
                level.append(group)
                group, acc = [], 0.0
            group.append(it)
            acc += it[2]
        level.append(group)
        leaf_nets = []
        for g in level:
            n = new_net()
            leaf_nets.append(n)
            for ii, pi, _, _ in g:
                insts[ii]["pins"][pi][1] = n
        # Upper stages until the driver can feed the remaining buffer inputs.
        nodes = leaf_nets
        limit = MARGIN * max_cap
        while len(nodes) * buf_in > limit:
            per = max(1, int(MARGIN * buf_max // buf_in))
            parents = []
            for k in range(0, len(nodes), per):
                p = new_net()
                for child in nodes[k:k + per]:
                    add_buf(p, child)
                parents.append(p)
            nodes = parents
        for child in nodes:
            add_buf(net, child)

    if nbuf:
        out = []
        last = 0
        for inst in insts:
            a, b = inst["span"]
            out.append(text[last:a])
            pin_txt = ",\n".join(f"    .{p}({esc(n)})" for p, n in inst["pins"])
            out.append(f"  {inst['cell']} {inst['name']} (\n{pin_txt}\n  );")
            last = b
        out.append(text[last:])
        text = "".join(out)
        # New wires are declared before their first use, with the others.
        first_wire = text.index("\n  wire ")
        text = text[:first_wire] + "\n" + "\n".join(decls) + text[first_wire:]
        text = text.replace("\nendmodule", "\n" + "\n".join(extra) + "\nendmodule", 1)
        open(path, "w", encoding="utf-8", newline="\n").write(text)
    print(f"[SYN] buffered {nnets} nets with {nbuf} {BUF} (input {buf_in:.4f} pF, limit {buf_max:.4f} pF)")


if __name__ == "__main__":
    main()
