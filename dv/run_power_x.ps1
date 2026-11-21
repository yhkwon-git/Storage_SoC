# Power testbench (dv/tb/tb_power.sv) on Vivado's simulator with PA_XPROP:
# while PD_HOST is off its outputs are X instead of random values, and the
# testbench fails if an X reaches the core side. Vivado is taken from
# -Vivado, then XILINX_VIVADO, then the newest C:\Xilinx\Vivado\* or
# D:\Xilinx\Vivado\*. Outputs go to build\dv\power_x.
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
$out  = Join-Path $root 'build\dv\power_x'
New-Item -ItemType Directory -Force $out | Out-Null

$src = @(
    'rtl\csr\gen\pmu_regs_pkg.sv', 'rtl\csr\gen\host_regs_pkg.sv',
    'rtl\csr\gen\pmu_regs.sv', 'rtl\csr\gen\host_regs.sv',
    'rtl\common\cdc_sync_2ff.sv', 'rtl\common\cdc_async_fifo.sv', 'rtl\common\rst_sync.sv',
    'rtl\common\clk_gate.sv', 'rtl\pmu\iso_clamp.sv', 'rtl\pmu\ret_reg.sv', 'rtl\pmu\apb_cdc.sv',
    'rtl\pmu\pmu.sv', 'rtl\host\phy_pll_model.sv', 'rtl\host\host_stub.sv', 'rtl\host\pd_host.sv',
    'rtl\host\host_if.sv', 'rtl\top\soc_pwr.sv', 'dv\tb\tb_power.sv'
) | ForEach-Object { Join-Path $root $_ }

Push-Location $out
try {
    "Vivado: $Vivado"
    & "$bin\xvlog.bat" -sv -d PA_XPROP @src | Out-Null
    if ($LASTEXITCODE -ne 0) { Get-Content xvlog.log | Select-String 'ERROR' | Select-Object -First 10; throw 'xvlog failed' }
    & "$bin\xelab.bat" tb_power -s tb_power -timescale 1ns/1ps | Out-Null
    if ($LASTEXITCODE -ne 0) { Get-Content xelab.log | Select-String 'ERROR' | Select-Object -First 10; throw 'xelab failed' }
    $fail = $false
    foreach ($t in @('directed', 'pll_stuck')) {
        # Not $args: PowerShell reserves that name. xsim.bat is a batch file,
        # which splits arguments at '=', hence the inner quotes.
        $xargs = @('tb_power', '-R', '-testplusarg', "`"test=$t`"")
        if ($t -eq 'pll_stuck') { $xargs += @('-testplusarg', 'pll_stuck') }
        $log = & "$bin\xsim.bat" @xargs
        $log | Select-String -Pattern '^\[PWR\]|Fatal|Error' | ForEach-Object { "${t}: $($_.Line.Trim())" }
        if (($log | Select-String -Pattern "^\[PWR\] ${t}: PASS").Count -ne 1) { $fail = $true }
    }
    if ($fail) { '[PWR] X run FAIL'; exit 1 } else { '[PWR] X run PASS' }
}
finally {
    Pop-Location
}
