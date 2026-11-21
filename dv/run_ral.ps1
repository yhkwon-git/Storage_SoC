# UVM register tests (dv/uvm) on Vivado's simulator with UVM 1.2.
# Vivado is taken from -Vivado, then XILINX_VIVADO, then the newest
# C:\Xilinx\Vivado\* or D:\Xilinx\Vivado\*. Outputs go to build\dv\ral.
# Pass: UVM_ERROR 0, UVM_FATAL 0 and the RAL summary line.
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
$out  = Join-Path $root 'build\dv\ral'
New-Item -ItemType Directory -Force $out | Out-Null

$src = @(
    'dv\uvm\apb_if.sv',
    'rtl\csr\gen\sys_regs_pkg.sv', 'rtl\csr\gen\intc_regs_pkg.sv', 'rtl\csr\gen\timer_regs_pkg.sv',
    'rtl\csr\gen\dma_regs_pkg.sv',
    'rtl\csr\gen\sys_regs.sv', 'rtl\csr\gen\intc_regs.sv', 'rtl\csr\gen\timer_regs.sv',
    'rtl\csr\gen\dma_regs.sv', 'rtl\common\fifo_sync.sv',
    'rtl\periph\apb_sys.sv', 'rtl\periph\apb_intc.sv', 'rtl\periph\apb_timer.sv', 'rtl\dma\dma.sv',
    'dv\ral\soc_apb_ral_pkg.sv', 'dv\uvm\apb_pkg.sv', 'dv\uvm\ral_test_pkg.sv', 'dv\uvm\ral_tb.sv'
) | ForEach-Object { Join-Path $root $_ }

Push-Location $out
try {
    "Vivado: $Vivado"
    & "$bin\xvlog.bat" -sv -L uvm @src | Out-Null
    if ($LASTEXITCODE -ne 0) { Get-Content xvlog.log | Select-String 'ERROR' | Select-Object -First 10; throw 'xvlog failed' }
    & "$bin\xelab.bat" -L uvm ral_tb -s ral_tb -timescale 1ns/1ps | Out-Null
    if ($LASTEXITCODE -ne 0) { Get-Content xelab.log | Select-String 'ERROR' | Select-Object -First 10; throw 'xelab failed' }
    $log = & "$bin\xsim.bat" ral_tb -R
    $log | Select-String -Pattern '\[RAL\]|\[CHECK\]|UVM_ERROR :|UVM_FATAL :|UVM_WARNING :|uvm_reg_bit_bash|uvm_reg_hw_reset|Error' |
        ForEach-Object { $_.Line.Trim() }
    $ok = ($log | Select-String -Pattern 'UVM_ERROR :\s+0$').Count -eq 1 -and
          ($log | Select-String -Pattern 'UVM_FATAL :\s+0$').Count -eq 1 -and
          ($log | Select-String -Pattern 'failures 0,').Count -eq 1
    if ($ok) { '[RAL] PASS' } else { '[RAL] FAIL'; exit 1 }
}
finally {
    Pop-Location
}
