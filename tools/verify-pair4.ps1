# Pair the phone with the bridge, switch it to the relay, and check that nothing secret
# is left on the disk.
$ErrorActionPreference = 'Stop'
$HDC = 'D:\APP\Devecostudio26\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
$T = '6XE0225B29036797'
$PREF = '/data/app/el2/100/base/com.example.dshsync/haps/entry/preferences/dsh_harmony_bridge'
$TOKEN = '5d4f3969f46d677bbb0b736ac13256ecbc18c0bbb6881b506eb545b4b4301e0d'
. 'D:\APP\Deepseek\DSHHarmony\tools\harmony-ui.ps1'
$script:Target = $T

function Wake { & $HDC -t $T shell 'uitest uiInput keyEvent KEYCODE_WAKEUP' 2>&1 | Out-Null; Start-Sleep -Milliseconds 700 }
function Read-Pref { $out = & $HDC -t $T shell "cat $PREF" 2>&1; return (($out -join "`n")) }
function Fields {
  param($Layout)
  $script:fields = @()
  function Collect($n) {
    if ($null -eq $n) { return }
    $a = $n.attributes
    if ($a.type -eq 'TextInput') { $script:fields += $a }
    if ($n.children) { foreach ($c in $n.children) { Collect $c } }
  }
  Collect $Layout
  return $script:fields
}
# The phone sleeps after a few seconds: wake it and retry until the layout comes back.
function Fields-Safe {
  param([int]$Want = 1)
  for ($i = 0; $i -lt 6; $i++) {
    Wake
    $f = Fields (Get-Layout)
    if ($f -and $f.Count -ge $Want) { return $f }
    Start-Sleep -Milliseconds 700
  }
  return @()
}
function Find-ByText {
  param($Layout, [string]$Text)
  $script:hit = $null
  function Walk($n) {
    if ($null -eq $n -or $null -ne $script:hit) { return }
    $a = $n.attributes
    if ($a.text -eq $Text) { $script:hit = $a; return }
    if ($n.children) { foreach ($c in $n.children) { Walk $c } }
  }
  $script:hit = $null
  if ($null -ne $Layout) { Walk $Layout }
  return $script:hit
}
function Show-Texts {
  param($Layout, [int]$Max = 30)
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
function Clear-Field {
  param([int]$Rounds = 12)
  Invoke-Hdc shell 'uitest uiInput keyEvent 2082' | Out-Null
  for ($round = 0; $round -lt $Rounds; $round++) {
    $f = Fields-Safe -Want 1
    if ($f.Count -eq 0) { break }
    $len = if ($f[$f.Count - 1].text) { $f[$f.Count - 1].text.Length } else { 0 }
    if ($len -eq 0) { break }
    Invoke-Hdc shell 'uitest uiInput keyEvent 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055' | Out-Null
    Start-Sleep -Milliseconds 350
  }
}

Write-Output "=== [1] install + launch the new build ==="
& $HDC -t $T install -r 'D:\APP\Deepseek\DSHHarmony\harmony\entry\build\default\outputs\default\entry-default-signed.hap' 2>&1 | Select-Object -Last 1
& $HDC -t $T shell 'aa start -a EntryAbility -b com.example.dshsync' 2>&1
Start-Sleep -Seconds 9
Wake

Write-Output "`n=== [2] the address field (empty it, then type) ==="
$f = Fields-Safe -Want 2
Write-Output ("  text inputs: {0}" -f $f.Count)
if ($f.Count -lt 2) { Write-Output '  the form is not there'; exit 1 }
$c = Get-Center $f[0].bounds
Invoke-Tap -X $c.X -Y $c.Y -SettleMs 1000 | Out-Null
Clear-Field
Invoke-Type -Value '192.168.1.10:8787' -Chunk 6
Start-Sleep -Milliseconds 800
$f = Fields-Safe -Want 2
Write-Output ("  address now = '{0}'" -f $f[0].text)

Write-Output "`n=== [3] the token field ==="
$f = Fields-Safe -Want 2
$c = Get-Center $f[$f.Count - 1].bounds
Invoke-Tap -X $c.X -Y $c.Y -SettleMs 1000 | Out-Null
Start-Sleep -Milliseconds 500
Clear-Field
Invoke-Hdc shell "uitest uiInput inputText $($c.X) $($c.Y) $TOKEN" | Out-Null
Start-Sleep -Milliseconds 1500
$f = Fields-Safe -Want 2
Write-Output ("  token length now: {0} (want {1})" -f $(if ($f[$f.Count - 1].text) { $f[$f.Count - 1].text.Length } else { 0 }), $TOKEN.Length)

Write-Output "`n=== [4] 测试连接 then 连接 ==="
Wake
$btn = Dismiss-Keyboard -NeedText '测试连接'
if ($null -ne $btn) {
  $c = Get-Center $btn.bounds
  Write-Output ("  tap 测试连接 at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 2500 | Out-Null
  Start-Sleep -Seconds 5
  Show-Texts -Layout (Get-Layout) -Max 14
}
Wake
$btn = Dismiss-Keyboard -NeedText '连接'
if ($null -ne $btn) {
  $c = Get-Center $btn.bounds
  Write-Output ("  tap 连接 at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 3000 | Out-Null
  Start-Sleep -Seconds 12
}
Show-Texts -Layout (Get-Layout) -Max 12

Write-Output "`n=== [5] the preferences file after pairing ==="
$pref = Read-Pref
foreach ($line in ($pref -split "`n")) { if ($line.Trim().Length -gt 0) { Write-Output ("    " + $line.Trim()) } }
Write-Output ("  full token on disk  : {0}" -f ($pref -match [regex]::Escape($TOKEN)))
Write-Output ("  device token on disk: {0}" -f ($pref -match '1e78f5613c5135344a31198f4971a53598a4b040663febe017a5c6ec1ac588e8'))
Write-Output ("  lan host on disk    : {0}   (局域网地址按设计留明文)" -f ($pref -match '192\.168\.1\.112'))

Write-Output "`n=== [6] switch to the relay (切到远程) ==="
Wake
$lay = Get-Layout
$remote = Find-ByText -Layout $lay -Text '切到远程(经云中继)'
if ($null -ne $remote) {
  $c = Get-Center $remote.bounds
  Write-Output ("  tap 切到远程 at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 4000 | Out-Null
  Start-Sleep -Seconds 14
  Show-Texts -Layout (Get-Layout) -Max 14
} else { Write-Output '  切到远程 not found' }

Write-Output "`n=== [7] the preferences file after the switch ==="
Wake
$pref2 = Read-Pref
foreach ($line in ($pref2 -split "`n")) { if ($line.Trim().Length -gt 0) { Write-Output ("    " + $line.Trim()) } }
Write-Output ("  full token on disk  : {0}" -f ($pref2 -match [regex]::Escape($TOKEN)))
Write-Output ("  plain ip on disk    : {0}" -f ($pref2 -match '\d+\.\d+\.\d+\.\d+'))
Write-Output ("  plain host:port     : {0}" -f ($pref2 -match '[a-z0-9-]+\.[a-z0-9-]+\.[a-z]{2,}:\d+'))
Write-Output ("  acc-/dev- on disk   : {0}" -f ($pref2 -match '(acc|dev)-[0-9a-f]{4}'))

Write-Output "`n=== [8] the log ==="
$log = & $HDC -t $T shell "hilog -x -T DshHarmony | grep -iE 'token|ConfigStore' | tail -16" 2>&1
foreach ($line in $log) { Write-Output ("    " + $line) }
Write-Output ("  full token in the log: {0}" -f ((($log -join "`n")) -match [regex]::Escape($TOKEN)))
Write-Output 'done'
