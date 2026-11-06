# One wake cycle for the HarmonyOS phone. Runs from the scheduled task "DSH Phone Wake"
# every 8 minutes so the screen (600000 ms timeout) never times out.
param(
  [string]$Target = '6XE0225B29036797',
  [string]$LogFile = 'D:\APP\Deepseek\DSHHarmony\tools\phone-wake.log'
)

$ErrorActionPreference = 'Continue'
$HDC = 'D:\APP\Devecostudio26\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'

function Write-Log([string]$Message) {
  Add-Content -LiteralPath $LogFile -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding utf8
}

try {
  $out = & $HDC -t $Target shell 'power-shell wakeup' 2>&1 | Out-String
  & $HDC -t $Target shell 'uitest uiInput keyEvent KEYCODE_WAKEUP' 2>&1 | Out-Null
  $state = & $HDC -t $Target shell 'hidumper -s PowerManagerService -a -s' 2>&1 | Out-String
  $current = if ($state -match 'Current State:\s*(\S+)') { $Matches[1] } else { 'unknown' }
  if ($current -eq 'AWAKE') {
    Write-Log "wake ok  state=$current"
  } else {
    Write-Log "wake ran but state=$current"
  }
} catch {
  Write-Log "wake error: $($_.Exception.Message)"
}
