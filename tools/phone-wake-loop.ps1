# Keep the HarmonyOS phone awake: wake the screen every ~8.5 minutes so it never times out.
#
# The phone (6XE0225B29036797) has a 600000 ms screen-off timeout; waking it well before that
# resets the countdown. The loop runs detached; every cycle appends one line to the log.
#
#   Start detached:  Start-Process pwsh -ArgumentList '-NoProfile','-File','<this file>' -WindowStyle Hidden
#   Stop:            Stop-Process -Id <pid>
param(
  [string]$Target = '6XE0225B29036797',
  [int]$IntervalSeconds = 500,
  [string]$LogFile = 'D:\APP\Deepseek\DSHHarmony\tools\phone-wake.log'
)

$ErrorActionPreference = 'Continue'
$HDC = 'D:\APP\Devecostudio26\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'

function Write-Log([string]$Message) {
  $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8
}

Write-Log "wake loop started (target=$Target interval=${IntervalSeconds}s pid=$PID)"

while ($true) {
  $ok = $false
  try {
    # power-shell wakeup turns the screen on; the uitest key event is the fallback for the
    # devices that ignore the power service command while the screen is dimmed.
    $out = & $HDC -t $Target shell 'power-shell wakeup' 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { $ok = $true }
    & $HDC -t $Target shell 'uitest uiInput keyEvent KEYCODE_WAKEUP' 2>&1 | Out-Null
    $state = & $HDC -t $Target shell 'hidumper -s PowerManagerService -a -s' 2>&1 | Out-String
    $current = if ($state -match 'Current State:\s*(\S+)') { $Matches[1] } else { 'unknown' }
    if ($ok) {
      Write-Log "wake ok  state=$current"
    } else {
      Write-Log "wake failed (hdc exit $LASTEXITCODE)  state=$current"
    }
  } catch {
    Write-Log "wake error: $($_.Exception.Message)"
  }
  Start-Sleep -Seconds $IntervalSeconds
}
