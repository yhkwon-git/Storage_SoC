# Ibex (third-party)

| Item | Value |
| --- | --- |
| Source | https://github.com/lowRISC/ibex |
| Release | tag `v2.1.0`, commit `38c070939183cc10940b66c8e9e04eeca6b65470` (2024-08-23) |
| License | Apache License 2.0 (`LICENSE`, `NOTICE` in this directory); every file keeps its own header |
| Changes | None. Files are copied byte for byte |

Only the files `ibex_core` needs in this configuration are here. The configuration is RV32IMC with the fast multiplier, no B extension, no PMP, no instruction cache, no security features, and the flip-flop register file. The list was taken from the files Verilator 5.052 read when elaborating the core in that configuration (`--MMD`).

| Directory | Files |
| --- | --- |
| `rtl/` | 23 `ibex_*.sv` files and `ibex_pmp_reset_default.svh` from the Ibex `rtl/` directory |
| `vendor/lowrisc_ip/ip/prim/rtl/` | `prim_assert*` macros, `prim_cipher_pkg`, `prim_flop_macros`, `prim_lfsr`, `prim_mubi_pkg`, `prim_onehot_{check,enc,mux}`, `prim_secded_inv_{28_22,39_32}_{enc,dec}` |
| `vendor/lowrisc_ip/dv/sv/dv_utils/` | `dv_fcov_macros.svh` |

`ibex.f` lists them in compile order for Verilator (`-F rtl/vendor/ibex/ibex.f`; paths are relative to this directory). The wrapper `rtl/cpu/cpu_ibex.sv` instantiates `ibex_core` as `u_ibex_core`, the name Ibex's own hierarchical references expect, and the register file next to it, as `ibex_top` does.

To refresh: clone the repository at the tag above, copy the same paths, and re-run `make -C dv` and the SoC tests.
