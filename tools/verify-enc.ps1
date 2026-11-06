# Verify the "no plaintext" hardening on the emulator: pair, switch to the relay and
# look at what is left on the disk.
$ErrorActionPreference = 'Stop'
$HDC = 'D:\APP\Devecostudio26\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
$T = '127.0.0.1:5557'
$PREF = '/data/app/el2/100/base/com.example.dshsync/haps/entry/preferences/dsh_harmony_bridge'
$TOKEN = '5d4f3969f46d677bbb0b736ac13256ecbc18c0bbb6881b506eb545b4b4301e0d'
. 'D:\APP\Deepseek\DSHHarmony\tools\harmony-ui.ps1'
$script:Target = $T

function Keep-Awake { & $HDC -t $T shell 'power-shell setmode 602' 2>&1 | Out-Null; & $HDC -t $T shell 'power-shell wakeup' 2>&1 | Out-Null }
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
  param($Layout, [int]$Max = 24)
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
function Clear-Last {
  param([int]$Rounds = 14)
  Invoke-Hdc shell 'uitest uiInput keyEvent 2082' | Out-Null
  for ($round = 0; $round -lt $Rounds; $round++) {
    $f = Fields (Get-Layout)
    if ($f.Count -eq 0) { break }
    $len = if ($f[$f.Count - 1].text) { $f[$f.Count - 1].text.Length } else { 0 }
    if ($len -eq 0) { break }
    Invoke-Hdc shell 'uitest uiInput keyEvent 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055' | Out-Null
    Start-Sleep -Milliseconds 300
  }
}

Write-Output "=== [1] install + launch ==="
& $HDC -t $T install -r 'D:\APP\Deepseek\DSHHarmony\harmony\entry\build\default\outputs\default\entry-default-signed.hap' 2>&1 | Select-Object -Last 1
& $HDC -t $T shell 'aa start -a EntryAbility -b com.example.dshsync' 2>&1
Start-Sleep -Seconds 8
Keep-Awake
# the notification permission dialog blocks the first launch
$allow = All-ByText -Layout (Get-Layout) -Text '允许'
if ($allow.Count -gt 0) {
  $c = Get-Center $allow[0].bounds
  Write-Output ("  tap 允许 at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 2000 | Out-Null
  Start-Sleep -Seconds 3
}

Write-Output "`n=== [2] the address field ==="
$f = Fields (Get-Layout)
Write-Output ("  text inputs: {0}" -f $f.Count)
for ($i = 0; $i -lt $f.Count; $i++) { Write-Output ("    #{0} '{1}' hint='{2}' {3}" -f $i, $f[$i].text, $f[$i].hint, $f[$i].bounds) }
$c = Get-Center $f[0].bounds
Invoke-Tap -X $c.X -Y $c.Y -SettleMs 1000 | Out-Null
Invoke-Hdc shell 'uitest uiInput keyEvent 2082' | Out-Null
for ($round = 0; $round -lt 10; $round++) {
  $f = Fields (Get-Layout)
  if ($f.Count -eq 0) { break }
  if (-not $f[0].text -or $f[0].text.Length -eq 0) { break }
  Invoke-Hdc shell 'uitest uiInput keyEvent 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055 2055' | Out-Null
  Start-Sleep -Milliseconds 300
}
Invoke-Type -Value '192.168.1.10:8787' -Chunk 6
Start-Sleep -Milliseconds 800
$f = Fields (Get-Layout)
Write-Output ("  address now = '{0}'" -f $f[0].text)

Write-Output "`n=== [3] the token field ==="
$f = Fields (Get-Layout)
$c = Get-Center $f[$f.Count - 1].bounds
Invoke-Tap -X $c.X -Y $c.Y -SettleMs 1000 | Out-Null
Start-Sleep -Milliseconds 400
Clear-Last
Invoke-Hdc shell "uitest uiInput inputText $($c.X) $($c.Y) $TOKEN" | Out-Null
Start-Sleep -Milliseconds 1200
$f = Fields (Get-Layout)
Write-Output ("  token length now: {0} (want {1})" -f $(if ($f[$f.Count - 1].text) { $f[$f.Count - 1].text.Length } else { 0 }), $TOKEN.Length)

Write-Output "`n=== [4] 测试连接 then 连接 ==="
Keep-Awake
$hits = All-ByText -Layout (Get-Layout) -Text '测试连接'
if ($hits.Count -gt 0) {
  $c = Get-Center $hits[0].bounds
  Write-Output ("  tap 测试连接 at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 2500 | Out-Null
  Start-Sleep -Seconds 5
  Show-Texts -Layout (Get-Layout) -Max 12
}
Keep-Awake
$hits = All-ByText -Layout (Get-Layout) -Text '连接'
if ($hits.Count -gt 0) {
  $c = Get-Center $hits[0].bounds
  Write-Output ("  tap 连接 at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 3000 | Out-Null
  Start-Sleep -Seconds 12
}
Show-Texts -Layout (Get-Layout) -Max 12

Write-Output "`n=== [5] the preferences file after pairing ==="
$pref = Read-Pref
foreach ($line in ($pref -split "`n")) { if ($line.Trim().Length -gt 0) { Write-Output ("    " + $line.Trim()) } }
Write-Output ("  full token on disk  : {0}" -f ($pref -match [regex]::Escape($TOKEN)))
Write-Output ("  lan host on disk    : {0}   (局域网地址按设计留明文)" -f ($pref -match '192\.168\.1\.112'))
Write-Output ("  a 64-hex value      : {0}" -f ($pref -match '\b[0-9a-f]{64}\b'))

Write-Output "`n=== [6] switch to the relay (切到远程) ==="
Keep-Awake
$hits = All-ByText -Layout (Get-Layout) -Text '切到远程(经云中继)'
if ($hits.Count -gt 0) {
  $c = Get-Center $hits[0].bounds
  Write-Output ("  tap 切到远程 at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 4000 | Out-Null
  Start-Sleep -Seconds 15
  Show-Texts -Layout (Get-Layout) -Max 14
} else { Write-Output '  切到远程 not found' }

Write-Output "`n=== [7] the preferences file after the switch ==="
Keep-Awake
$pref2 = Read-Pref
foreach ($line in ($pref2 -split "`n")) { if ($line.Trim().Length -gt 0) { Write-Output ("    " + $line.Trim()) } }
Write-Output ("  full token on disk  : {0}" -f ($pref2 -match [regex]::Escape($TOKEN)))
Write-Output ("  plain ip on disk    : {0}" -f ($pref2 -match '\d+\.\d+\.\d+\.\d+'))
Write-Output ("  plain host:port     : {0}" -f ($pref2 -match '[a-z0-9-]+\.[a-z0-9-]+\.[a-z]{2,}:\d+'))
Write-Output ("  acc-/dev- on disk   : {0}" -f ($pref2 -match '(acc|dev)-[0-9a-f]{4}'))

Write-Output "`n=== [8] the log ==="
$log = & $HDC -t $T shell "hilog -x -T DshHarmony | grep -iE 'token|ConfigStore' | tail -18" 2>&1
foreach ($line in $log) { Write-Output ("    " + $line) }
Write-Output ("  full token in the log: {0}" -f ((($log -join "`n")) -match [regex]::Escape($TOKEN)))
Write-Output 'done'
