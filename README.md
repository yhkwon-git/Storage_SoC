# Storage_SoC

A small storage-controller SoC built around a DSP-based SerDes PHY.

The PHY is developed first as a stand-alone IP: a bit-true Python model, synthesizable SystemVerilog, a real-number model of the analog front end for mixed simulation, a UVM testbench, and synthesis and STA in an open-source flow. It is then integrated into an AXI4 SoC with a RISC-V CPU, firmware, power domains and a NAND-flash datapath.

한국어 요약은 [아래](#한국어-요약)에 있습니다.

## At a glance

| Item | Value |
| --- | --- |
| Current phase | Phase 0 done (toolchain checks, repository layout). Phase 1, the SerDes PHY IP, is next |
| Design | No RTL yet |
| Verification tools | Vivado simulator 2019.2 (UVM 1.2), Verilator 5.052 |
| Implementation tools | Yosys 0.52, OpenSTA 3.1.0, Nangate45 |

Every number in this repository names the commit it was measured at, and the script that produced it is in the repository.

## Architecture (planned)

```text
 Channel + AFE model (SystemVerilog real: CTLE, ADC, jitter, noise)
        | ADC codes
 +------v------------------- PSW domain ---------------+   +-- AON -----------+
 | RX DSP : FFE, DFE (LMS), Mueller-Muller CDR         |   | PMU, wake        |
 | PCS    : 8b/10b, comma align, elastic buffer (ppm)  |   | reset sequencer  |
 | Link   : framing, CRC, ACK/NAK, replay, credit      |   | iso / retention  |
 +------+----------------------------------------------+   +------------------+
        | AXI4
 +------v----------------- AXI4 interconnect ---------------------+
 | RISC-V (3rd-party) | SRAM | DMA | AXI->APB CSR | NAND ctrl + BCH |--> NAND model
 +----------------------------------------------------------------+
```

- **RX DSP.** ADC-based receiver with an FFE, a decision-feedback equalizer adapted by sign-sign LMS, and a baud-rate Mueller-Muller CDR that drives a phase-interpolator code. Several samples are processed per clock, which makes the one-tap DFE feedback the timing-critical loop.
- **PCS.** 8b/10b coding, comma alignment, and an elastic buffer that absorbs the ppm offset between the TX and RX reference clocks.
- **Analog front end.** Channel, CTLE, ADC, jitter and noise as a SystemVerilog real-number model, simulated together with the RTL.
- **PHY test logic.** PRBS generator and checker, error counters, and an eye scan by phase-interpolator sweep.
- **SoC.** AXI4 interconnect, a third-party RISC-V core, SRAM, DMA, APB CSRs generated from SystemRDL, and always-on and switchable power domains with isolation and retention.
- **Storage path.** Link layer with CRC and replay, and a NAND channel controller with BCH.

## Roadmap

| Phase | Scope | Status |
| --- | --- | --- |
| 0 | Toolchain checks, repository layout | Done |
| 1 | SerDes PHY IP: Python model, PCS, RX DSP, AFE model, PHY test logic, block-level UVM, PPA | Next |
| 2 | SoC platform: CPU, AXI4, CSR, DMA, clock/reset/power domains, firmware bring-up of the PHY | Planned |
| 3 | Link layer and storage datapath: CRC, ACK/NAK, replay, NAND controller, BCH | Planned |
| 4 | SoC-level UVM, verification plan, coverage closure | Planned |
| 5 | Full-chip synthesis and STA, documentation | Planned |

## Verification flow

| Tool | Checked version | Role |
| --- | --- | --- |
| Vivado simulator (xsim) | 2019.2 | UVM 1.2 testbenches: sequences, constrained random, covergroups |
| Verilator | 5.052 | Lint, fast regressions, line/branch/toggle coverage, covergroup bins |
| Python, NumPy | 3, 2 | Bit-true reference models, stimulus, expected data, plots |

Phase 0 findings (2026-11-21):

- xsim 2019.2 runs a UVM 1.2 sequence-to-driver test with `randomize()` and a covergroup: 50 items, coverage 100.0, UVM_ERROR 0.
- Verilator 5.052 writes all 14 covergroup bins, including the cross, to `coverage.dat` with their hit counts. `get_coverage()` on a single coverpoint does not compile, and the covergroup total reads 0.0 at run time, so Verilator coverage numbers are taken from `coverage.dat`.
- Under `-Wall`, Verilator warns about members it adds to every covergroup (`option`, `total_bins`, ...). The waiver covers the covergroup block only.

## How to run

```bash
# Verilator side (Linux or WSL)
bash flow/tools/check_verilator.sh                                   # [TOOLS] verilator PASS
```

```powershell
# Vivado simulator side (Windows)
powershell -ExecutionPolicy Bypass -File flow\tools\check_xsim.ps1   # [TOOLS] xsim UVM PASS
```

Outputs go to `build/`, which git ignores. `check_verilator.sh` takes `BUILD_DIR` to build elsewhere, and `check_xsim.ps1` takes `-Vivado <install dir>` or `XILINX_VIVADO`.

## Repository layout

```text
flow/tools/   toolchain checks: smoke_uvm.sv (xsim), smoke_cov.sv (Verilator) and their scripts
```

Each phase adds its own directories (`ip/serdes_phy/`, `soc/`, `dv/`, ...).

## Limitations

- Built from public material only. The M-PHY, UniPro and PCIe specifications are available to members only, so the PHY and link follow the general structure of those NRZ 8b/10b SerDes families and claim no compliance with any of them.
- The analog front end is a behavioral real-number model. There are no transistor-level circuits.
- Simulated BER is limited by run time. Every BER figure states how many bits it is based on.

## Development notes

An LLM assistant (Claude) is used to draft code, tests and documents. A result goes in only after it passes the regressions and checks in this repository, and commits made with the assistant carry a co-author line.

## 한국어 요약

DSP 기반 SerDes PHY를 중심에 둔 소형 스토리지 컨트롤러 SoC입니다.

- **PHY IP 우선.** PHY를 먼저 단독 IP로 만듭니다. Python bit-true 모델, 합성 가능한 SystemVerilog RTL, AFE real-number model과 RTL의 mixed simulation, UVM 검증, 오픈소스 합성과 STA까지 포함합니다.
- **SoC 통합.** 그다음 RISC-V CPU, AXI4 interconnect, firmware, power domain(AON/PSW), NAND datapath를 갖춘 SoC에 PHY를 통합합니다.
- **현재 상태.** Phase 0(도구 확인, repo 구조)이 끝났고, 다음은 Phase 1(SerDes PHY IP)입니다.
- **검증 도구.** UVM은 Vivado simulator 2019.2, lint·빠른 regression·coverage는 Verilator 5.052로 돌립니다. Verilator는 실행 중 `get_coverage()`가 0.0을 돌려주므로 coverage 수치는 `coverage.dat`에서 읽습니다.
- **범위.** 공개 자료만으로 구성하며 M-PHY, UniPro, PCIe 규격 준수를 주장하지 않습니다. AFE는 동작 모델이고 transistor 회로는 없습니다.
- **LLM 사용.** 코드, 테스트, 문서 초안에 LLM(Claude)을 쓰고, repo 안의 regression과 검사를 통과한 결과만 반영합니다.
