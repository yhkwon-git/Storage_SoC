#!/usr/bin/env python3
"""Check that the RTL and the UPF agree on PD_HOST's isolation and retention.

The RTL instantiates its isolation cells and retention registers itself
(no tool in this flow reads UPF), so the two can drift apart. This script
reads:

  rtl/host/pd_host.sv     every iso_clamp: the port it drives and its CLAMP
                          value; and every output port of pd_host
  rtl/host/host_stub.sv   every ret_reg instance
  syn/upf/storage_soc.upf set_isolation elements with -clamp_value, and
                          set_retention elements

and fails unless
  * every output port of pd_host is driven by an iso_clamp,
  * the UPF isolates exactly those ports, each with the RTL's clamp value,
  * the UPF retains exactly the ret_reg instances of host_stub.

Usage: python3 flow/power/check_iso.py   (from the repository root or anywhere)
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PD_HOST = ROOT / "rtl/host/pd_host.sv"
STUB = ROOT / "rtl/host/host_stub.sv"
UPF = ROOT / "syn/upf/storage_soc.upf"
HOST_PATH = "u_pwr/u_pd_host"
STUB_PATH = HOST_PATH + "/u_stub"


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def rtl_isolation(text):
    """{port: clamp} from iso_clamp instances."""
    found = {}
    pat = re.compile(r"iso_clamp\s*#\s*\((?P<params>[^;]*?)\)\s*(?P<inst>\w+)\s*\((?P<conns>[^;]*?)\)\s*;", re.S)
    for m in pat.finditer(text):
        clamp = re.search(r"\.CLAMP\s*\(\s*1'b([01])\s*\)", m.group("params"))
        dout = re.search(r"\.dout\s*\(\s*(\w+)\s*\)", m.group("conns"))
        if not clamp or not dout:
            sys.exit(f"[ISO] cannot parse iso_clamp {m.group('inst')}")
        found[dout.group(1)] = int(clamp.group(1))
    return found


def rtl_outputs(text):
    header = re.search(r"module\s+pd_host\s*\((.*?)\);", text, re.S)
    if not header:
        sys.exit("[ISO] pd_host port list not found")
    return set(re.findall(r"output\s+(?:logic|wire)?\s*(?:\[[^\]]*\])?\s*(\w+)", header.group(1)))


def rtl_retention(text):
    return set(re.findall(r"ret_reg\s*#\s*\([^;]*?\)\s*(\w+)\s*\(", text, re.S))


def upf_commands(text):
    """UPF commands with line continuations joined, comments removed."""
    lines = [re.sub(r"#.*", "", l) for l in text.splitlines()]
    joined = "\n".join(lines).replace("\\\n", " ")
    return [c.strip() for c in joined.splitlines() if c.strip()]


def braces(cmd, opt):
    m = re.search(re.escape(opt) + r"\s*\{([^}]*)\}", cmd)
    return m.group(1).split() if m else []


def main():
    pd = strip_comments(PD_HOST.read_text())
    stub = strip_comments(STUB.read_text())
    cmds = upf_commands(UPF.read_text())

    iso_rtl = rtl_isolation(pd)
    outs = rtl_outputs(pd)
    ret_rtl = rtl_retention(stub)

    iso_upf = {}
    ret_upf = set()
    for c in cmds:
        if c.startswith("set_isolation ") and "-clamp_value" in c:
            clamp = int(re.search(r"-clamp_value\s+([01])", c).group(1))
            for e in braces(c, "-elements"):
                if not e.startswith(HOST_PATH + "/"):
                    sys.exit(f"[ISO] isolation element outside PD_HOST: {e}")
                iso_upf[e[len(HOST_PATH) + 1:]] = clamp
        if c.startswith("set_retention ") and "-elements" in c:
            for e in braces(c, "-elements"):
                if not e.startswith(STUB_PATH + "/"):
                    sys.exit(f"[ISO] retention element outside host_stub: {e}")
                ret_upf.add(e[len(STUB_PATH) + 1:])

    errors = []
    for o in sorted(outs - set(iso_rtl)):
        errors.append(f"pd_host output {o} has no iso_clamp")
    for p in sorted(set(iso_rtl) - set(iso_upf)):
        errors.append(f"iso_clamp on {p} missing from the UPF")
    for p in sorted(set(iso_upf) - set(iso_rtl)):
        errors.append(f"UPF isolates {p}, which has no iso_clamp")
    for p in sorted(set(iso_rtl) & set(iso_upf)):
        if iso_rtl[p] != iso_upf[p]:
            errors.append(f"{p}: clamp {iso_rtl[p]} in RTL, {iso_upf[p]} in UPF")
    for r in sorted(ret_rtl ^ ret_upf):
        where = "RTL only" if r in ret_rtl else "UPF only"
        errors.append(f"retention register {r}: {where}")

    for e in errors:
        print(f"[ISO] ERROR {e}")
    if errors:
        print("[ISO] FAIL")
        return 1
    print(f"[ISO] PASS: {len(iso_rtl)} isolated outputs ({', '.join(f'{p}={v}' for p, v in sorted(iso_rtl.items()))}), "
          f"{len(ret_rtl)} retention registers ({', '.join(sorted(ret_rtl))}) match the UPF")
    return 0


if __name__ == "__main__":
    sys.exit(main())
