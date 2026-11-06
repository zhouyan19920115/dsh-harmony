# 真机验收: 错误提示中文化 + 连接状态稳定。
#
# 做四件事:
#   1) 装上刚构建的 HAP
#   2) 拉起 App, 把日志清干净
#   3) 扫 App 自己的日志, 找出**还带着裸英文/裸代码**的错误提示
#   4) 抓屏, 让人能直接看
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File tools\verify-i18n-errors.ps1
param(
  [string]$Device = '6XE0225B29036797',
  [string]$Root = 'D:\APP\Deepseek\DSHHarmony'
)

$ErrorActionPreference = 'Continue'
$HDC = 'D:\APP\Devecostudio26\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
$hap = Join-Path $Root 'harmony\entry\build\default\outputs\default\entry-default-signed.hap'

function Hdc([string[]]$Cmd) { & $HDC -t $Device @Cmd 2>&1 | Out-String }

Write-Output '=== [1] install ==='
if (-not (Test-Path $hap)) {
  Write-Output "  HAP not found: $hap"
  Write-Output '  build it first: powershell -ExecutionPolicy Bypass -File tools\build-hap.ps1'
  exit 1
}
$install = Hdc @('install', '-r', $hap)
Write-Output ('  ' + ($install -replace "`r?`n", ' ').Trim())
Start-Sleep -Seconds 3

Write-Output '=== [2] wake + start ==='
Hdc @('shell', 'uitest uiInput keyEvent KEYCODE_WAKEUP') | Out-Null
Hdc @('shell', 'power-shell wakeup') | Out-Null
Start-Sleep -Milliseconds 800
$start = Hdc @('shell', 'aa start -a EntryAbility -b com.example.dshsync')
if ($start -notmatch 'successfully') {
  Write-Output '  the phone is locked - unlock it (biometric) and run this script again'
  exit 1
}
Start-Sleep -Seconds 6

Write-Output '=== [3] the app log ==='
$log = Hdc @('shell', 'hilog -x | grep -i DshHarmony')
$lines = $log -split "`r?`n" | Where-Object { $_.Trim() -ne '' }
foreach ($l in $lines) { Write-Output ('    ' + $l.Trim()) }
if ($lines.Count -eq 0) { Write-Output '    (nothing in the log)' }

Write-Output '=== [4] raw english/code still leaking into the user? ==='
# 只看"会冒到界面上"的那几类: 抛异常 / 提示 / 连接状态。
$noise = $lines | Where-Object {
  $_ -match 'WebSocket 错误|加载消息失败|连接状态|已连接|未连接|重连' -and
  $_ -notmatch '[\u4e00-\u9fa5]'
}
if ($noise.Count -eq 0) {
  Write-Output '    clean: every notice carries Chinese text'
} else {
  foreach ($n in $noise) { Write-Output ('    LEAK: ' + $n.Trim()) }
}

Write-Output '=== [5] the screen ==='
$shot = Join-Path $Root 'tools\dsh-i18n.jpeg'
Hdc @('shell', 'snapshot_display -f /data/local/tmp/dsh-i18n.jpeg') | Out-Null
Hdc @('file', 'recv', '/data/local/tmp/dsh-i18n.jpeg', $shot) | Out-Null
Write-Output ('    ' + $shot)
Write-Output 'done'
