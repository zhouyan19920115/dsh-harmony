# Pair the real phone through the discovery sheet and check what is left on the disk.
$ErrorActionPreference = 'Stop'
$HDC = 'D:\APP\Devecostudio26\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
$T = '6XE0225B29036797'
$PREF = '/data/app/el2/100/base/com.example.dshsync/haps/entry/preferences/dsh_harmony_bridge'
# 令牌从桥接的状态文件里读 —— **不写死在脚本里**(脚本也会进版本库 ✓)
$stateFile = Join-Path $env:USERPROFILE '.dsh-harmony-bridge\bridge.json'
$TOKEN = ((Get-Content $stateFile -Raw | ConvertFrom-Json).token)
. 'D:\APP\Deepseek\DSHHarmony\tools\harmony-ui.ps1'
$script:Target = $T

function Wake { & $HDC -t $T shell 'uitest uiInput keyEvent KEYCODE_WAKEUP' 2>&1 | Out-Null; Start-Sleep -Milliseconds 700 }
function Read-Pref { $out = & $HDC -t $T shell "cat $PREF" 2>&1; return (($out -join "`n")) }
function All-ByText {
  param($Layout, [string]$Text)
  $script:hits = @()
  function Walk($n) {
    if ($null -eq $n) { return }
    $a = $n.attributes
    if ($a.text -eq $Text) { $script:hits += $a }
    if ($n.children) { foreach ($c in $n.children) { Walk $c } }
  }
  Walk $Layout
  return $script:hits
}
function Show-Texts {
  param($Layout, [int]$Max = 22)
  $i = 0
  function Walk($n) {
    if ($null -eq $n -or $i -ge $Max) { return }
    $a = $n.attributes
    if ($a.text) { Write-Output ("    '{0}' {1}" -f $a.text, $a.bounds); $script:i++ }
    if ($n.children) { foreach ($c in $n.children) { Walk $c } }
  }
  $script:i = 0
  if ($null -ne $Layout) { Walk $Layout }
}
function Shot {
  param([string]$Name)
  & $HDC -t $T shell "snapshot_display -f /data/local/tmp/$Name.jpeg" 2>&1 | Out-Null
  & $HDC -t $T file recv "/data/local/tmp/$Name.jpeg" "D:\APP\Deepseek\DSHHarmony\tools\$Name.jpeg" 2>&1 | Out-Null
}

Write-Output "=== [1] install + launch ==="
& $HDC -t $T install -r 'D:\APP\Deepseek\DSHHarmony\harmony\entry\build\default\outputs\default\entry-default-signed.hap' 2>&1 | Select-Object -Last 1
& $HDC -t $T shell 'aa start -a EntryAbility -b com.example.dshsync' 2>&1
Start-Sleep -Seconds 10
Wake
Write-Output "  (the app must be in the foreground)"
Show-Texts -Layout (Get-Layout) -Max 10

Write-Output "`n=== [2] 自动探测 (the discovery sheet) ==="
Wake
$hits = All-ByText -Layout (Get-Layout) -Text '自动探测'
if ($hits.Count -gt 0) {
  $c = Get-Center $hits[0].bounds
  Write-Output ("  tap 自动探测 at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 2000 | Out-Null
}
Start-Sleep -Seconds 10
Show-Texts -Layout (Get-Layout) -Max 14
Shot 'phone-discovery'

Write-Output "`n=== [3] the sheet's 连接 button ==="
$hits = All-ByText -Layout (Get-Layout) -Text '连接'
Write-Output ("  连接 buttons: {0}" -f $hits.Count)
foreach ($h in $hits) { Write-Output ("    {0}" -f $h.bounds) }
if ($hits.Count -gt 0) {
  $btn = $hits[$hits.Count - 1]
  $c = Get-Center $btn.bounds
  Write-Output ("  tap the sheet 连接 at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 3000 | Out-Null
  Start-Sleep -Seconds 15
}
Show-Texts -Layout (Get-Layout) -Max 12
Shot 'phone-paired'

Write-Output "`n=== [4] the preferences file after pairing ==="
$pref = Read-Pref
foreach ($line in ($pref -split "`n")) { if ($line.Trim().Length -gt 0) { Write-Output ("    " + $line.Trim()) } }
Write-Output ("  full token on disk  : {0}" -f ($pref -match [regex]::Escape($TOKEN)))
Write-Output ("  a 64-hex value      : {0}" -f ($pref -match '\b[0-9a-f]{64}\b'))
Write-Output ("  lan host on disk    : {0}   (局域网地址按设计留明文)" -f ($pref -match '192\.168\.1\.112'))

Write-Output "`n=== [5] 切到远程 (the relay) ==="
Wake
$hits = All-ByText -Layout (Get-Layout) -Text '切到远程(经云中继)'
if ($hits.Count -gt 0) {
  $c = Get-Center $hits[0].bounds
  Write-Output ("  tap 切到远程 at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 4000 | Out-Null
  Start-Sleep -Seconds 15
  Show-Texts -Layout (Get-Layout) -Max 12
  Shot 'phone-remote'
} else { Write-Output '  切到远程 not found' }

Write-Output "`n=== [6] the preferences file after the switch ==="
Wake
$pref2 = Read-Pref
foreach ($line in ($pref2 -split "`n")) { if ($line.Trim().Length -gt 0) { Write-Output ("    " + $line.Trim()) } }
Write-Output ("  full token on disk  : {0}" -f ($pref2 -match [regex]::Escape($TOKEN)))
Write-Output ("  plain ip on disk    : {0}" -f ($pref2 -match '\d+\.\d+\.\d+\.\d+'))
Write-Output ("  plain host:port     : {0}" -f ($pref2 -match '[a-z0-9-]+\.[a-z0-9-]+\.[a-z]{2,}:\d+'))
Write-Output ("  acc-/dev- on disk   : {0}" -f ($pref2 -match '(acc|dev)-[0-9a-f]{4}'))

Write-Output "`n=== [7] the log ==="
$log = & $HDC -t $T shell "hilog -x -T DshHarmony | grep -iE 'token|ConfigStore|地址' | tail -18" 2>&1
foreach ($line in $log) { Write-Output ("    " + $line) }
Write-Output ("  full token in the log: {0}" -f ((($log -join "`n")) -match [regex]::Escape($TOKEN)))
Write-Output 'done'
