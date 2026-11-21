# Toolchain check, Vivado simulator side: runs smoke_uvm.sv with UVM 1.2.
# Vivado is taken from -Vivado, then XILINX_VIVADO, then the newest
# C:\Xilinx\Vivado\* or D:\Xilinx\Vivado\*. Outputs go to build\tools\xsim.
param([string]$Vivado = $env:XILINX_VIVADO)

$ErrorActionPreference = 'Stop'
if (-not $Vivado) {
    $Vivado = Get-ChildItem 'C:\Xilinx\Vivado', 'D:\Xilinx\Vivado' -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name | Select-Object -Last 1 -ExpandProperty FullName
}
if (-not $Vivado) { throw 'Vivado not found: set XILINX_VIVADO or pass -Vivado' }

$bin  = Join-Path $Vivado 'bin'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out  = Join-Path $here '..\..\build\tools\xsim'
New-Item -ItemType Directory -Force $out | Out-Null

Push-Location $out
try {
    "Vivado: $Vivado"
    & "$bin\xvlog.bat" -sv -L uvm (Join-Path $here 'smoke_uvm.sv') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed, see xvlog.log' }
    & "$bin\xelab.bat" -L uvm smoke_uvm -s smoke_uvm -timescale 1ns/1ps | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'xelab failed, see xelab.log' }
    $log = & "$bin\xsim.bat" smoke_uvm -R
    $log | Select-String -Pattern 'items=|UVM_ERROR :|UVM_FATAL :' | ForEach-Object { $_.Line.Trim() }
    $ok = ($log | Select-String -Pattern 'UVM_ERROR :\s+0$').Count -eq 1 -and
          ($log | Select-String -Pattern 'UVM_FATAL :\s+0$').Count -eq 1 -and
          ($log | Select-String -Pattern 'items=50 coverage=100.0').Count -eq 1
    if ($ok) { '[TOOLS] xsim UVM PASS' } else { '[TOOLS] xsim UVM FAIL'; exit 1 }
}
finally {
    Pop-Location
}
