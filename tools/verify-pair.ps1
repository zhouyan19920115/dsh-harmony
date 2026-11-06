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
function Read-Pref {
  $out = & $HDC -t $T shell "cat $PREF 2>&1" 2>&1
  return (($out -join "`n"))
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

Write-Output "=== [1] fill in the address + token ==="
Wake
$a = Set-NthField -Type 'TextInput' -Index 0 -Value '192.168.1.10:8787' -Chunk 5
Write-Output "  address = '$a'"
$tk = Set-NthField -Type 'TextInput' -Index 1 -Value $TOKEN -Method 'inputText' -Masked
Write-Output ("  token = {0} chars" -f $(if ($tk) { $tk.Length } else { 0 }))

Write-Output "`n=== [2] 测试连接 then 连接 ==="
Wake
$btn = Dismiss-Keyboard -NeedText '测试连接'
if ($null -ne $btn) {
  $c = Get-Center $btn.bounds
  Write-Output ("  tap 测试连接 at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 2500 | Out-Null
  Start-Sleep -Seconds 4
  Show-Texts -Layout (Get-Layout) -Max 14
}
Wake
$btn = Dismiss-Keyboard -NeedText '连接'
if ($null -ne $btn) {
  $c = Get-Center $btn.bounds
  Write-Output ("  tap 连接 at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 3000 | Out-Null
  Start-Sleep -Seconds 8
}
Show-Texts -Layout (Get-Layout) -Max 12

Write-Output "`n=== [3] the preferences file after pairing ==="
$pref = Read-Pref
foreach ($line in ($pref -split "`n")) { if ($line.Trim().Length -gt 0) { Write-Output ("    " + $line.Trim()) } }
Write-Output ("  full token on disk: {0}" -f ($pref -match [regex]::Escape($TOKEN)))
Write-Output ("  lan host on disk : {0}" -f ($pref -match '192\.168\.1\.112'))

Write-Output "`n=== [4] switch to the relay (切到远程) ==="
Wake
$lay = Get-Layout
$remote = Find-ByText -Layout $lay -Text '切到远程(经云中继)'
if ($null -ne $remote) {
  $c = Get-Center $remote.bounds
  Write-Output ("  tap 切到远程 at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 4000 | Out-Null
  Start-Sleep -Seconds 8
  Show-Texts -Layout (Get-Layout) -Max 12
} else { Write-Output '  切到远程 not found' }

Write-Output "`n=== [5] the preferences file after the switch ==="
Wake
$pref2 = Read-Pref
foreach ($line in ($pref2 -split "`n")) { if ($line.Trim().Length -gt 0) { Write-Output ("    " + $line.Trim()) } }
Write-Output ("  full token on disk: {0}" -f ($pref2 -match [regex]::Escape($TOKEN)))
Write-Output ("  relay host on disk: {0}" -f ($pref2 -match '192\.168\.1\.112'))
Write-Output ("  any plain host (ip:port) on disk: {0}" -f ($pref2 -match '\d+\.\d+\.\d+\.\d+'))

Write-Output "`n=== [6] the log ==="
$log = & $HDC -t $T shell "hilog -x -T DshHarmony | grep -iE 'token|endpoint|ConfigStore|远端|地址' | tail -20" 2>&1
foreach ($line in $log) { Write-Output ("    " + $line) }
Write-Output ("  full token in the log: {0}" -f ((($log -join "`n")) -match [regex]::Escape($TOKEN)))
Write-Output 'done'
