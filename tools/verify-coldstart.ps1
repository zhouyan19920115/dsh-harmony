# Cold start measurement + the "send the desktop to the computer" check on the real phone.
$ErrorActionPreference = 'Continue'
$HDC = 'D:\APP\Devecostudio26\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
$T = '6XE0225B29036797'
$hap = 'D:\APP\Deepseek\DSHHarmony\harmony\entry\build\default\outputs\default\entry-default-signed.hap'

function Wake { & $HDC -t $T shell 'uitest uiInput keyEvent KEYCODE_WAKEUP' 2>&1 | Out-Null; & $HDC -t $T shell 'power-shell wakeup' 2>&1 | Out-Null; Start-Sleep -Milliseconds 800 }
function Start-App {
  $out = & $HDC -t $T shell 'aa start -a EntryAbility -b com.example.dshsync' 2>&1 | Out-String
  return ($out -match 'successfully')
}

Write-Output "=== [1] install ==="
& $HDC -t $T install -r $hap 2>&1 | Select-Object -Last 1
Start-Sleep -Seconds 3

Write-Output "=== [2] the phone has to be unlocked ==="
Wake
if (-not (Start-App)) {
  Write-Output '  the phone is locked — unlock it (biometric) and run this script again'
  exit 1
}

Write-Output "=== [3] the cold start (the app is stopped first) ==="
& $HDC -t $T shell 'aa force-stop com.example.dshsync' 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $HDC -t $T shell 'hilog -r' 2>&1 | Out-Null      # clear the log
$watch = [System.Diagnostics.Stopwatch]::StartNew()
Start-App | Out-Null
# wait until the app says the page is loaded
$loaded = $false
for ($i = 0; $i -lt 60; $i++) {
  Start-Sleep -Milliseconds 250
  $log = & $HDC -t $T shell "hilog -x | grep -i 'DshHarmony'" 2>&1 | Out-String
  if ($log -match '页面加载完成') { $loaded = $true; break }
}
$watch.Stop()
Write-Output ("  the page was loaded after {0:N2} s (found in the log: {1})" -f $watch.Elapsed.TotalSeconds, $loaded)

Write-Output "=== [4] the app's log ==="
$log = & $HDC -t $T shell "hilog -x | grep -i 'DshHarmony'" 2>&1
foreach ($l in $log) { Write-Output ("    " + $l) }

Write-Output "=== [5] a freeze in the log? ==="
$freezes = & $HDC -t $T shell "hilog -x | grep -c 'THREAD_BLOCK'" 2>&1
Write-Output ("  THREAD_BLOCK lines: {0}" -f ($freezes -join ''))

Write-Output "=== [6] the screen ==="
& $HDC -t $T shell "snapshot_display -f /data/local/tmp/dsh-cold.jpeg" 2>&1 | Out-Null
& $HDC -t $T file recv /data/local/tmp/dsh-cold.jpeg 'D:\APP\Deepseek\DSHHarmony\tools\dsh-cold.jpeg' 2>&1 | Select-Object -Last 1
Write-Output 'done'
