param(
  [switch]$StopManualBridge,
  [switch]$RestartDSH
)
# 从「手动跑桥接」切换成「插件跑桥接」。
#
#   powershell -File tools\switch-to-plugin.ps1 -StopManualBridge
#       → 停掉手动桥接（释放 8787），插件已装好，等你重启 DSH
#
#   powershell -File tools\switch-to-plugin.ps1 -StopManualBridge -RestartDSH
#       → 停手动桥接 + 重启 DSH（会中断当前 DSH 会话，谨慎）
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..").Path

if ($StopManualBridge) {
  $owners = Get-NetTCPConnection -State Listen -LocalPort 8787 -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty OwningProcess -Unique
  foreach ($pid in $owners) {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $pid" -ErrorAction SilentlyContinue
    if ($null -eq $proc) { continue }
    Write-Host ("停掉占用 8787 的进程: {0} ({1})" -f $pid, $proc.CommandLine)
    Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
  }
  Start-Sleep -Seconds 1
  $left = (Get-NetTCPConnection -State Listen -LocalPort 8787 -ErrorAction SilentlyContinue | Measure-Object).Count
  Write-Host ("8787 现在监听数: {0}" -f $left)
}

if ($RestartDSH) {
  $exe = 'D:\APP\Deepseek\DeepSeek Harness.exe'
  if (-not (Test-Path $exe)) { throw "找不到 DSH: $exe" }
  Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 3
  Start-Process -FilePath $exe
  Write-Host "DSH 已重启；插件会随 DSH 启动桥接（默认 8787）。"
} else {
  Write-Host "插件已就绪。现在手动重启 DSH 即可：关闭 DeepSeek Harness 再打开，"
  Write-Host "桥接会由插件自动启动（默认 0.0.0.0:8787），手机点「自动探测」即可。"
}
