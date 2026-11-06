# Start the tablet emulator, install, connect and screenshot in one go: the
# tablet instance keeps dying after a minute or two, so there is no time for
# separate round trips.
$ErrorActionPreference = 'Stop'
$OutDir = 'D:\APP\Deepseek\DSHHarmony\docs\screenshots'
$emu = 'D:\APP\Devecostudio26\DevEco Studio\tools\emulator\Emulator.exe'
$HDC = 'D:\APP\Devecostudio26\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
$hap = 'D:\APP\Deepseek\DSHHarmony\harmony\entry\build\default\outputs\default\entry-default-signed.hap'
$Host_ = '192.168.1.10:8787'
$Token = '5d4f3969f46d677bbb0b736ac13256ecbc18c0bbb6881b506eb545b4b4301e0d'

. 'D:\APP\Deepseek\DSHHarmony\tools\harmony-ui.ps1'

Write-Output "=== start the tablet ==="
$job = Start-Job -ScriptBlock {
  param($e)
  Set-Location (Split-Path $e -Parent)
  & $e -start 'MatePad Pro 13 7' 2>&1
} -ArgumentList $emu

$Target = $null
for ($i = 0; $i -lt 45; $i++) {
  Start-Sleep -Seconds 6
  $t = (& $HDC list targets) -join '|'
  foreach ($tg in ($t -split '\|')) {
    $tg = $tg.Trim(); if ($tg -eq '') { continue }
    $d = & $HDC -t $tg shell "hidumper -s DisplayManagerService -a '-a'" 2>&1 | Select-String -Pattern 'width: \d+ height' | Select-Object -First 1
    if ("$d" -match 'width: 2880 height: 1920') { $Target = $tg }
  }
  if ($i % 6 -eq 0) { Write-Output ("[{0}s] {1}" -f ($i * 6 + 6), $t) }
  if ($Target) { Write-Output ("TABLET READY: {0}" -f $Target); break }
}
if (-not $Target) { Write-Output 'TABLET NEVER APPEARED'; exit 2 }
$script:Target = $Target

Write-Output "=== install + launch ==="
& $HDC -t $Target install -r $hap 2>&1 | Select-Object -Last 1
& $HDC -t $Target shell 'aa start -a EntryAbility -b com.example.dshsync' 2>&1
Start-Sleep -Seconds 7
Invoke-Hdc shell 'power-shell setmode 602' | Out-Null
Invoke-Hdc shell 'power-shell wakeup' | Out-Null
Start-Sleep -Seconds 2

Write-Output "=== fill the form ==="
$a = Set-NthField -Type 'TextInput' -Index 0 -Value $Host_ -Chunk 5
Write-Output "  address = '$a'"
$t = Set-NthField -Type 'TextInput' -Index 1 -Value $Token -Method 'inputText' -Masked
Write-Output ("  token = {0} chars" -f $(if ($t) { $t.Length } else { 0 }))
if ($a -ne $Host_) { Write-Output "ADDRESS NOT FILLED"; exit 3 }

Write-Output "=== 测试连接 + 连接 ==="
$btn = Dismiss-Keyboard -NeedText '测试连接'
if ($null -ne $btn) {
  $c = Get-Center $btn.bounds
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 2500 | Out-Null
  Start-Sleep -Seconds 3
  $lay = Get-Layout
  $i = 0
  function W($n) {
    if ($null -eq $n -or $i -ge 8) { return }
    $a = $n.attributes
    if ($a.text) { Write-Output ("    '{0}'" -f $a.text); $script:i++ }
    if ($n.children) { foreach ($c in $n.children) { W $c } }
  }
  $script:i = 0; W $lay
}
$btn = Dismiss-Keyboard -NeedText '连接'
if ($null -ne $btn) {
  $c = Get-Center $btn.bounds
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 3000 | Out-Null
  Start-Sleep -Seconds 8
}
Save-Screenshot -Path "$OutDir\43-large-tablet-sessionlist.jpeg" | Out-Null
Write-Output 'saved 43-large-tablet-sessionlist.jpeg'

Write-Output "=== tablet layout ==="
$lay = Get-Layout
$i = 0
function W2($n) {
  if ($null -eq $n -or $i -ge 26) { return }
  $a = $n.attributes
  if ($a.text) { Write-Output ("    '{0}' {1}" -f $a.text, $a.bounds); $script:i++ }
  if ($n.children) { foreach ($c in $n.children) { W2 $c } }
}
$script:i = 0; W2 $lay
Write-Output "=== breakpoint ==="
Invoke-Hdc shell "hilog -x | grep DshHarmony | grep '断点' | tail -3" | ForEach-Object { Write-Output "  $_" }
Write-Output 'done'
