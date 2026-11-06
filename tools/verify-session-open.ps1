# 真机验收: 打开一个会话, 看「加载消息失败」还会不会冒出来。
#
# 做法:
#   1) 清日志
#   2) 抓布局, 按文字找到第一条会话, 点它
#   3) 等它加载完
#   4) 看日志里有没有「加载消息失败」/「Unexpected Text in JSON」/「Invalid Token」
#   5) 抓屏
param(
  [string]$Device = '6XE0225B29036797',
  [string]$Root = 'D:\APP\Deepseek\DSHHarmony'
)

$ErrorActionPreference = 'Continue'
$HDC = 'D:\APP\Devecostudio26\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'

function Hdc([string[]]$Cmd) { & $HDC -t $Device @Cmd 2>&1 | Out-String }

function Wake {
  Hdc @('shell', 'power-shell wakeup') | Out-Null
  Hdc @('shell', 'uitest uiInput keyEvent KEYCODE_WAKEUP') | Out-Null
  Start-Sleep -Milliseconds 700
}

function Get-Layout {
  for ($try = 1; $try -le 3; $try++) {
    $json = Hdc @('shell', 'uitest dumpLayout -p /data/local/tmp/dsh-layout.json >/dev/null 2>&1; cat /data/local/tmp/dsh-layout.json')
    if ($json -and $json.Trim()) {
      try { return ($json -split "`r?`n" | Where-Object { $_.Trim() -ne '' }) -join '' | ConvertFrom-Json } catch { Start-Sleep -Milliseconds 400 }
    }
    Start-Sleep -Milliseconds 400
  }
  return $null
}

function Get-Center([string]$Bounds) {
  if ($Bounds -notmatch '\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]') { return $null }
  return [pscustomobject]@{ X = [int](([int]$Matches[1] + [int]$Matches[3]) / 2); Y = [int](([int]$Matches[2] + [int]$Matches[4]) / 2) }
}

Write-Output '=== [1] wake + clear the log ==='
Wake
Hdc @('shell', 'hilog -r') | Out-Null
Hdc @('shell', 'aa start -a EntryAbility -b com.example.dshsync') | Out-Null
Start-Sleep -Seconds 4

Write-Output '=== [2] find a session row ==='
$layout = Get-Layout
if ($null -eq $layout) { Write-Output '  the layout did not come back'; exit 1 }

$rows = @()
function Walk($n) {
  if ($null -eq $n) { return }
  $a = $n.attributes
  if ($a -and $a.type -eq 'Text' -and $a.text -and $a.text.Length -gt 3) {
    $script:rows += ,@($a.text, $a.bounds)
  }
  if ($n.children) { foreach ($c in $n.children) { Walk $c } }
}
Walk $layout

$target = $null
foreach ($r in $rows) {
  $t = $r[0]
  $c = Get-Center $r[1]
  if ($null -eq $c) { continue }
  if ($c.Y -lt 400) { continue }                       # 跳过标题栏
  if ($t -match '^http' -or $t -match '^[0-9]+$') { continue }
  if ($t -match '会话|工作区|刷新|设备|设置|新会话|未命名|已连接|未连接|重连') { continue }
  $target = $r; break
}
if ($null -eq $target) { Write-Output '  no session row found'; exit 1 }
$center = Get-Center $target[1]
Write-Output ("  tapping: {0}  at ({1},{2})" -f $target[0], $center.X, $center.Y)

Write-Output '=== [3] tap + wait ==='
Hdc @('shell', "uitest uiInput click $($center.X) $($center.Y)") | Out-Null
Start-Sleep -Seconds 6

Write-Output '=== [4] the log ==='
$log = Hdc @('shell', "hilog -x | grep -i DshHarmony")
$lines = $log -split "`r?`n" | Where-Object { $_.Trim() -ne '' }
foreach ($l in $lines) { Write-Output ('    ' + $l.Trim()) }

Write-Output '=== [5] the errors the user would see ==='
$bad = $lines | Where-Object { $_ -match '加载消息失败|Unexpected Text in JSON|Invalid Token|WebSocket 错误|未连接' }
if ($bad.Count -eq 0) {
  Write-Output '    clean: no message-load / websocket / disconnected error'
} else {
  foreach ($b in $bad) { Write-Output ('    LEAK: ' + $b.Trim()) }
}

Write-Output '=== [6] the screen ==='
$shot = Join-Path $Root 'tools\dsh-session.jpeg'
Hdc @('shell', 'snapshot_display -f /data/local/tmp/dsh-session.jpeg') | Out-Null
Hdc @('file', 'recv', '/data/local/tmp/dsh-session.jpeg', $shot) | Out-Null
Write-Output ('    ' + $shot)
Write-Output 'done'
