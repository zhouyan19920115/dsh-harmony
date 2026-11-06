<#
 .SYNOPSIS
   端到端验证: 鸿蒙手机端 -> 桌面 bridge -> 真实 DSH agent -> 回传到手机。
 #>
[CmdletBinding()]
param(
  [string]$BridgePort = '8787',
  [string]$Prompt = 'reply with exactly: OK-HARMONY',
  [string]$ShotDir = 'D:\APP\Deepseek\DSHHarmony\docs\screenshots',
  [int]$WaitSeconds = 50
)

$ErrorActionPreference = 'Stop'
$DevEco = 'D:\APP\Devecostudio26\DevEco Studio'
$Hdc = Join-Path $DevEco 'sdk\default\openharmony\toolchains\hdc.exe'
$W = 'D:\APP\Deepseek\DSHHarmony'
$State = "$env:USERPROFILE\.dsh-harmony-bridge\bridge.json"
$Token = (Get-Content $State -Raw | ConvertFrom-Json).token
$script:n = 0

function Hdc([string[]]$a) { & $Hdc @a }

function Dump {
  $script:n++
  $name = "e2e$script:n"
  for ($try = 0; $try -lt 5; $try++) {
    Hdc @('shell', "uitest dumpLayout -p /data/local/tmp/$name.json") | Out-Null
    Start-Sleep -Milliseconds 400
    Hdc @('file', 'recv', "/data/local/tmp/$name.json", "$W\tools\$name.json") | Out-Null
    if ((Test-Path "$W\tools\$name.json") -and (Get-Item "$W\tools\$name.json").Length -gt 50) { return $name }
    Start-Sleep -Milliseconds 900
  }
  return $name
}

function Rows([string]$n) { node "$W\tools\ui.js" "$W\tools\$n.json" 2>$null }

function TapText([string]$n, [string]$text, [string]$kind = 'Text') {
  $line = Rows $n | Where-Object { $_ -like "$kind`t$text`t*" } | Select-Object -First 1
  if (-not $line) { return $false }
  $p = $line -split "`t"
  Hdc @('shell', "uitest uiInput click $($p[2]) $($p[3])") | Out-Null
  Start-Sleep -Milliseconds 1000
  return $true
}

function InputRows([string]$n) { @(Rows $n | Where-Object { $_ -like 'TextInput`t*' }) }

function InputAt([string]$n, [int]$index, [string]$t) {
  $lines = InputRows $n
  if ($lines.Count -le $index) { return $false }
  $p = $lines[$index] -split "`t"
  Hdc @('shell', "uitest uiInput inputText $($p[2]) $($p[3]) $t") | Out-Null
  Start-Sleep -Milliseconds 1100
  return $true
}

function InputValue([string]$n, [int]$index) {
  $lines = InputRows $n
  if ($lines.Count -le $index) { return '' }
  return ($lines[$index] -split "`t")[1]
}

function Shot([string]$name) {
  Hdc @('shell', "snapshot_display -f /data/local/tmp/$name.jpeg") | Out-Null
  Hdc @('file', 'recv', "/data/local/tmp/$name.jpeg", "$ShotDir\$name.jpeg") | Out-Null
  Write-Host "  screenshot -> $ShotDir\$name.jpeg"
}

Write-Host '[1] stop DeskMate, launch app'
Hdc @('shell', 'aa force-stop com.ff.racing') | Out-Null
Hdc @('shell', 'aa force-stop com.dsh.harmony') | Out-Null
Start-Sleep -Seconds 1
Hdc @('shell', 'aa start -a EntryAbility -b com.dsh.harmony') | Out-Null
Start-Sleep -Seconds 5
$d = Dump
if (-not (TapText $d 'DSH 助手')) { Write-Host '  !! not on connect page'; exit 1 }

Write-Host '[2] fill port + token'
$d = Dump
InputAt $d 1 $BridgePort | Out-Null
$d = Dump
InputAt $d 2 $Token | Out-Null
$d = Dump
Write-Host ('  port=' + (InputValue $d 1) + '  tokenLen=' + (InputValue $d 2).Length)
Shot '20-form-filled'

Write-Host '[3] tap auto-discover'
$d = Dump
if (-not (TapText $d '自动探测')) { Write-Host '  !! no auto-discover button' }
Start-Sleep -Seconds 6
$d = Dump
Write-Host ('  result: ' + (((Rows $d) | Where-Object { $_ -match '已找到|没有探测到' } | Select-Object -First 1)))
Shot '21-auto-discover'

Write-Host '[4] tap test-connection'
$d = Dump
if (-not (TapText $d '测试连接' 'Button')) { Write-Host '  !! no test button' }
Start-Sleep -Seconds 4
$d = Dump
Write-Host ('  status: ' + (((Rows $d) | Where-Object { $_ -match '连接成功|连接失败' } | Select-Object -First 1)))
Shot '22-test-connection'

Write-Host '[5] tap connect'
$d = Dump
if (-not (TapText $d '连接' 'Button')) { Write-Host '  !! no connect button' }
Start-Sleep -Seconds 8
$d = Dump
Write-Host ('  list: ' + (((Rows $d) | Where-Object { $_ -like 'Text`t*' } | Select-Object -First 4) -join ' / '))
Shot '23-session-list'

Write-Host '[6] open first session'
$row = (Rows $d) | Where-Object { $_ -like 'Text`t*' -and $_ -notmatch '桌面会话|已连接|未连接|刷新|设置|条消息|空闲|执行中|新建会话|正在同步|127\.0|10\.0\.2|192\.168' } | Select-Object -First 1
if ($row) {
  Write-Host ('  tapping: ' + ($row -split "`t")[1])
  $p = $row -split "`t"
  Hdc @('shell', "uitest uiInput click $($p[2]) $($p[3])") | Out-Null
  Start-Sleep -Seconds 7
}
$d = Dump
Write-Host ('  page: ' + (((Rows $d) | Select-Object -First 3) -join ' / '))
Shot '24-session-detail'

Write-Host '[7] type prompt and send'
if (InputAt $d 0 $Prompt) {
  $d2 = Dump
  if (TapText $d2 '发送' 'Button') { Write-Host "  sent: $Prompt" }
}
Shot '25-prompt-sent'

Write-Host "[8] wait for desktop agent ($WaitSeconds s)"
Start-Sleep -Seconds $WaitSeconds
$d = Dump
Shot '26-reply-received'
Write-Host '  key texts:'
(Rows $d) | Where-Object { $_ -match 'OK-HARMONY|已收到|执行中|桌面端|我|发送' } | Select-Object -First 8 | ForEach-Object { Write-Host ('    ' + $_) }
Write-Host '[done]'
