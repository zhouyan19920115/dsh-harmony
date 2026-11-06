<#
 .SYNOPSIS
   聚焦测试: 在模拟器里打开一个会话, 从手机发送指令, 等桌面端执行完再截图。
 #>
[CmdletBinding()]
param(
  [string]$SessionHint = 'bridge e2e check',
  [string]$Prompt = 'reply with exactly: OK-HARMONY',
  [string]$ShotDir = (Join-Path $PSScriptRoot '..\docs\screenshots'),
  [int]$WaitSeconds = 60
)
$ErrorActionPreference = 'Stop'
$DevEco = 'D:\APP\Devecostudio26\DevEco Studio'
$Hdc = Join-Path $DevEco 'sdk\default\openharmony\toolchains\hdc.exe'
$W = (Join-Path $PSScriptRoot '..')
$script:n = 0

function Hdc([string[]]$a) { & $Hdc @a }
function Dump {
  $script:n++
  $name = "snd$script:n"
  for ($try = 0; $try -lt 8; $try++) {
    Hdc @('shell', "uitest dumpLayout -p /data/local/tmp/$name.json") | Out-Null
    Start-Sleep -Milliseconds 500
    Hdc @('file', 'recv', "/data/local/tmp/$name.json", "$W\tools\$name.json") | Out-Null
    if ((Test-Path "$W\tools\$name.json") -and (Get-Item "$W\tools\$name.json").Length -gt 50) { return $name }
    Start-Sleep -Seconds 1
  }
  return $name
}
function Rows([string]$n) {
  $path = "$W\tools\$n.json"
  if (-not (Test-Path $path)) { return @() }
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $out = node "$W\tools\ui.js" $path 2>$null
  $ErrorActionPreference = $prev
  if (-not $out) { return @() }
  return $out
}
function Shot([string]$name) {
  Hdc @('shell', "snapshot_display -f /data/local/tmp/$name.jpeg") | Out-Null
  Hdc @('file', 'recv', "/data/local/tmp/$name.jpeg", "$ShotDir\$name.jpeg") | Out-Null
  Write-Host "  screenshot -> $ShotDir\$name.jpeg"
}

$d = Dump
$row = (Rows $d) | Where-Object { $_ -like "Text`t$SessionHint`t*" } | Select-Object -First 1
if (-not $row) { Write-Host "  !! session '$SessionHint' not found"; Rows $d | Select-Object -First 20 | ForEach-Object { Write-Host $_ }; exit 1 }
$p = $row -split "`t"
Write-Host ("  tapping session: " + $p[1])
Hdc @('shell', "uitest uiInput click $($p[2]) $($p[3])") | Out-Null
Start-Sleep -Seconds 8
$d = Dump
Write-Host ('  page: ' + (((Rows $d) | Select-Object -First 3) -join ' / '))
Shot '24-session-detail'

$composer = @(Rows $d | Where-Object { $_ -like "TextArea`t*" })
Write-Host ('  composer fields: ' + $composer.Count)
if ($composer.Count -eq 0) { Write-Host '  !! no composer'; exit 1 }
$pc = $composer[0] -split "`t"
Hdc @('shell', "uitest uiInput click $($pc[2]) $($pc[3])") | Out-Null
Start-Sleep -Milliseconds 900
Hdc @('shell', "uitest uiInput text '$Prompt'") | Out-Null
Start-Sleep -Seconds 2
$d = Dump
$typed = @((Rows $d) | Where-Object { $_ -like "TextArea`t*" })
Write-Host ('  composer now: ' + (($typed | Select-Object -First 1) -split "`t")[1])
Shot '25-prompt-typed'

$draft = @((Rows $d) | Where-Object { $_ -like "TextArea`t*" })
if (-not (($draft | Select-Object -First 1) -split "`t")[1]) { Write-Host '  !! composer empty, abort'; exit 1 }
$send = (Rows $d) | Where-Object { $_ -like "Button`t发送`t*" } | Select-Object -First 1
if ($send) {
  $ps = $send -split "`t"
  Hdc @('shell', "uitest uiInput click $($ps[2]) $($ps[3])") | Out-Null
  Write-Host "  sent: $Prompt"
}
Start-Sleep -Seconds 3
Shot '26-prompt-sent'

Write-Host "[wait $WaitSeconds s for desktop agent]"
Start-Sleep -Seconds $WaitSeconds
$d = Dump
Shot '27-reply-received'
Write-Host '  key texts:'
(Rows $d) | Where-Object { $_ -match 'OK-HARMONY|已收到|执行中|桌面端|发送' } | Select-Object -First 8 | ForEach-Object { Write-Host ('    ' + $_) }
Write-Host '[done]'
