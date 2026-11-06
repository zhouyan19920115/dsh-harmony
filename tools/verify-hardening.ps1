# Acceptance checks for the "no plaintext" hardening on the real phone.
$ErrorActionPreference = 'Stop'
$HDC = 'D:\APP\Devecostudio26\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
$T = '192.168.1.20:40663'
$hap = 'D:\APP\Deepseek\DSHHarmony\harmony\entry\build\default\outputs\default\entry-default-signed.hap'
$token = '5d4f3969f46d677bbb0b736ac13256ecbc18c0bbb6881b506eb545b4b4301e0d'

function Wake {
  & $HDC -t $T shell 'uitest uiInput keyEvent KEYCODE_WAKEUP' 2>&1 | Out-Null
  Start-Sleep -Milliseconds 800
}

Write-Output "=== install ==="
& $HDC -t $T install -r $hap 2>&1 | Select-Object -Last 1
Start-Sleep -Seconds 2
Write-Output "=== launch ==="
& $HDC -t $T shell 'aa start -a EntryAbility -b com.example.dshsync' 2>&1
Start-Sleep -Seconds 10
Wake
Start-Sleep -Seconds 3

Write-Output "`n=== [1] the preferences file on the phone ==="
$pref = '/data/app/el2/100/base/com.example.dshsync/haps/entry/preferences/dsh_harmony_bridge'
$out = & $HDC -t $T shell "cat $pref" 2>&1
$text = ($out -join "`n")
Write-Output "  raw:"
foreach ($line in ($text -split "`n")) { if ($line.Trim().Length -gt 0) { Write-Output ("    " + $line.Trim()) } }
Write-Output ("  full token present: {0}" -f ($text -match [regex]::Escape($token)))
$hostLeak = $text -match '192\.168\.1\.112'
Write-Output ("  remote host (192.168.1.10) present: {0}" -f $hostLeak)

Write-Output "`n=== [2] hilog: every line that mentions a token ==="
Wake
$log = & $HDC -t $T shell "hilog -x -T DshHarmony | grep -i token" 2>&1
foreach ($line in $log) { Write-Output ("    " + $line) }
$logText = ($log -join "`n")
Write-Output ("  full token in the log: {0}" -f ($logText -match [regex]::Escape($token)))

Write-Output "`n=== [3] the endpoint the app is using (from the log, masked?) ==="
$log2 = & $HDC -t $T shell "hilog -x -T DshHarmony | grep -iE 'ConfigStore|断点|endpoint' | tail -12" 2>&1
foreach ($line in $log2) { Write-Output ("    " + $line) }

Write-Output "`n=== [4] is the app connected? ==="
$ui = & $HDC -t $T shell "uitest dumpLayout -p /data/local/tmp/dsh-hard.json" 2>&1
Start-Sleep -Seconds 2
& $HDC -t $T file recv /data/local/tmp/dsh-hard.json 'D:\APP\Deepseek\DSHHarmony\tools\dsh-hard.json' 2>&1 | Out-Null
if (Test-Path 'D:\APP\Deepseek\DSHHarmony\tools\dsh-hard.json') {
  $j = Get-Content 'D:\APP\Deepseek\DSHHarmony\tools\dsh-hard.json' -Raw
  $texts = [regex]::Matches($j, '"text":"([^"]{1,40})"') | ForEach-Object { $_.Groups[1].Value }
  Write-Output '  visible texts:'
  foreach ($t in ($texts | Select-Object -First 25)) { Write-Output ("    '$t'") }
  Write-Output ("  full token visible in the ui: {0}" -f ($j -match [regex]::Escape($token)))
}
Write-Output 'done'
