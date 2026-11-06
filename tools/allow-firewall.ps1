# 允许手机访问桥接端口（Windows 防火墙）。
#
# 需要「以管理员身份运行」的 PowerShell：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\allow-firewall.ps1
#
# 背景：桥接由 DSH 插件拉起时，进程是 "DeepSeek Harness.exe"，不是 node.exe。
# Windows 把 WiFi 判成「公用网络」时，默认阻止入站 —— 手机就会扫描不到电脑。
# 这个脚本给桥接进程和端口加一条入站放行规则。
param(
  [int]$Port = 8787
)
$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host '需要管理员权限：请以「管理员身份」打开 PowerShell 再运行本脚本。' -ForegroundColor Red
  exit 1
}

$targets = @(
  @{ Name = 'DSH Harmony Bridge (DSH exe)'; Program = 'D:\APP\Deepseek\DeepSeek Harness.exe' },
  @{ Name = 'DSH Harmony Bridge (node.exe)'; Program = 'D:\APP\Node\node.exe' }
)
foreach ($t in $targets) {
  if (-not (Test-Path $t.Program)) {
    Write-Host ("跳过（程序不存在）: {0}" -f $t.Program)
    continue
  }
  $existing = Get-NetFirewallRule -DisplayName $t.Name -ErrorAction SilentlyContinue
  if ($existing) {
    Write-Host ("已存在规则: {0}" -f $t.Name)
    continue
  }
  New-NetFirewallRule -DisplayName $t.Name -Direction Inbound -Program $t.Program `
    -Protocol TCP -LocalPort $Port -Action Allow -Profile Any | Out-Null
  Write-Host ("已添加规则: {0}  (TCP {1})" -f $t.Name, $Port) -ForegroundColor Green
}
Write-Host '完成。手机再点「自动探测」即可。'
