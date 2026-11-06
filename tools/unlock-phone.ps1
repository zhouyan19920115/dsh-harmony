# Unlock the phone (swipe only, no PIN) and report whether the ability can start.
$ErrorActionPreference = 'Continue'
$HDC = 'D:\APP\Devecostudio26\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
$T = '6XE0225B29036797'

function Try-Start {
  $out = & $HDC -t $T shell 'aa start -a EntryAbility -b com.example.dshsync' 2>&1 | Out-String
  if ($out -match 'successfully') { return $true }
  return $false
}

& $HDC -t $T shell 'power-shell setmode 602' 2>&1 | Out-Null
& $HDC -t $T shell 'power-shell wakeup' 2>&1 | Out-Null
& $HDC -t $T shell 'uitest uiInput keyEvent KEYCODE_WAKEUP' 2>&1 | Out-Null
Start-Sleep -Seconds 3

$swipes = @(
  '640 2600 640 900 400',
  '640 2600 640 900 100',
  '640 2000 640 400 300',
  '640 2400 640 1200 1500',
  '640 1500 640 200 250'
)
foreach ($s in $swipes) {
  & $HDC -t $T shell "uitest uiInput swipe $s" 2>&1 | Out-Null
  Start-Sleep -Seconds 2
  if (Try-Start) { Write-Output "  unlocked with swipe '$s'"; break }
  Write-Output "  swipe '$s' did not unlock"
}
if (Try-Start) { Write-Output 'UNLOCKED' } else { Write-Output 'STILL LOCKED' }
