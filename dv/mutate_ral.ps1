# Mutation check for the UVM register tests (dv/run_ral.ps1). Each mutant
# copies one source file into build\dv\ral_mut\<name>, plants one bug with a
# literal text replacement, compiles the register testbench with the copy in
# place of the original, and runs it. The test must fail on every mutant.
# The repository's sources are never modified.
param([string]$Vivado = $env:XILINX_VIVADO)

$ErrorActionPreference = 'Stop'
if (-not $Vivado) {
    $Vivado = Get-ChildItem 'C:\Xilinx\Vivado', 'D:\Xilinx\Vivado' -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name | Select-Object -Last 1 -ExpandProperty FullName
}
if (-not $Vivado) { throw 'Vivado not found: set XILINX_VIVADO or pass -Vivado' }

$bin  = Join-Path $Vivado 'bin'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

$src = @(
    'dv\uvm\apb_if.sv',
    'rtl\csr\gen\sys_regs_pkg.sv', 'rtl\csr\gen\intc_regs_pkg.sv', 'rtl\csr\gen\timer_regs_pkg.sv',
    'rtl\csr\gen\dma_regs_pkg.sv', 'rtl\csr\gen\pmu_regs_pkg.sv', 'rtl\csr\gen\host_regs_pkg.sv',
    'rtl\csr\gen\nvme_regs_pkg.sv', 'rtl\csr\gen\nand_regs_pkg.sv',
    'rtl\csr\gen\sys_regs.sv', 'rtl\csr\gen\intc_regs.sv', 'rtl\csr\gen\timer_regs.sv',
    'rtl\csr\gen\dma_regs.sv', 'rtl\csr\gen\pmu_regs.sv', 'rtl\csr\gen\host_regs.sv',
    'rtl\csr\gen\nvme_regs.sv', 'rtl\csr\gen\nand_regs.sv',
    'rtl\common\fifo_sync.sv', 'rtl\common\cdc_sync_2ff.sv', 'rtl\common\cdc_async_fifo.sv',
    'rtl\common\rst_sync.sv', 'rtl\common\clk_gate.sv',
    'rtl\pmu\iso_clamp.sv', 'rtl\pmu\ret_reg.sv', 'rtl\pmu\apb_cdc.sv', 'rtl\pmu\pmu.sv',
    'rtl\axi\axi_channel_reg_slice.sv',
    'rtl\host\tl\tl_pkg.sv', 'rtl\host\tl\tl_dw_align.sv', 'rtl\host\tl\tl_rx_buf.sv',
    'rtl\host\tl\tl_rx_unpack.sv', 'rtl\host\tl\tl_tx_pack.sv', 'rtl\host\tl\tl_cfg.sv',
    'rtl\host\tl\tl_msix.sv', 'rtl\host\tl\tl_wr.sv', 'rtl\host\tl\tl_rd.sv', 'rtl\host\tl\tl_bm.sv',
    'rtl\host\tl\tl_core.sv', 'rtl\host\tl\tl_port.sv', 'rtl\host\nvme\nvme_lbuf.sv', 'rtl\host\nvme\nvme_prp.sv', 'rtl\host\nvme\nvme_cqe.sv', 'rtl\host\nvme\nvme_ctrl.sv',
    'rtl\host\phy_pll_model.sv', 'rtl\host\host_stub.sv', 'rtl\host\pd_host.sv', 'rtl\host\host_if.sv',
    'rtl\top\soc_pwr.sv',
    'rtl\mem\mem_array.sv', 'rtl\nand\nand_pkg.sv', 'rtl\nand\nand_seq.sv', 'rtl\nand\nand_pbuf.sv', 'rtl\nand\nand_ctrl.sv',
    'rtl\periph\apb_sys.sv', 'rtl\periph\apb_intc.sv', 'rtl\periph\apb_timer.sv', 'rtl\dma\dma.sv',
    'dv\ral\soc_apb_ral_pkg.sv', 'dv\uvm\apb_pkg.sv', 'dv\uvm\ral_test_pkg.sv', 'dv\uvm\ral_tb.sv'
)

# name, file, text to find, replacement, what the bug does
$mutants = @(
    @('reset_value', 'rtl\csr\gen\timer_regs.sv',
      "field_storage.MTIMECMP_LO.value.value <= 32'hffffffff;",
      "field_storage.MTIMECMP_LO.value.value <= 32'h0;",
      'MTIMECMP_LO resets to 0 instead of all ones'),
    @('stuck_bit', 'rtl\csr\gen\sys_regs.sv',
      "field_storage.SCRATCH.value.value <= field_combo.SCRATCH.value.next;",
      "field_storage.SCRATCH.value.value <= field_combo.SCRATCH.value.next | 32'h100;",
      'SCRATCH bit 8 stuck at 1 after any write'),
    @('claim_order', 'rtl\periph\apb_intc.sv',
      'for (int i = 31; i >= 1; i--) begin',
      'for (int i = 1; i <= 31; i++) begin',
      'CLAIM returns the highest pending ID instead of the lowest'),
    @('no_decode_err', 'rtl\csr\gen\sys_regs.sv',
      'decoded_err = ~is_valid_addr & decoded_req;',
      "decoded_err = 1'b0;",
      'no PSLVERR for unmapped SYS offsets')
)

$caught = 0
foreach ($m in $mutants) {
    $name, $file, $find, $repl, $what = $m
    $dir = Join-Path $root "build\dv\ral_mut\$name"
    New-Item -ItemType Directory -Force $dir | Out-Null
    $orig = Get-Content -Raw (Join-Path $root $file)
    if (-not $orig.Contains($find)) { throw "[MUT] ${name}: text not found in $file" }
    $mutFile = Join-Path $dir (Split-Path -Leaf $file)
    [IO.File]::WriteAllText($mutFile, $orig.Replace($find, $repl))
    $files = $src | ForEach-Object { if ($_ -eq $file) { $mutFile } else { Join-Path $root $_ } }
    Push-Location $dir
    try {
        & "$bin\xvlog.bat" -sv -L uvm @files | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "[MUT] ${name}: compile failed" }
        & "$bin\xelab.bat" -L uvm ral_tb -s ral_tb -timescale 1ns/1ps | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "[MUT] ${name}: elaboration failed" }
        $log = & "$bin\xsim.bat" ral_tb -R
        $errs = ($log | Select-String -Pattern 'UVM_ERROR :\s+(\d+)').Matches.Groups[1].Value
        $first = ($log | Select-String -Pattern '^UVM_ERROR ' | Select-Object -First 1).Line
        if ([int]$errs -gt 0) {
            $caught++
            $msg = if ($first) { ($first -replace '^.*\] ', '') } else { '' }
            if ($msg.Length -gt 110) { $msg = $msg.Substring(0, 110) }
            "[MUT] $name ($what): caught, UVM_ERROR $errs -- $msg"
        } else {
            "[MUT] $name ($what): NOT caught"
        }
    }
    finally {
        Pop-Location
    }
}
"[MUT] $caught of $($mutants.Count) mutants caught"
if ($caught -ne $mutants.Count) { exit 1 }
