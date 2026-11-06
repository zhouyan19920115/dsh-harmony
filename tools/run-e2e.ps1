<#
.SYNOPSIS
  Full end-to-end test of the DSH HarmonyOS app against the live desktop bridge.

.DESCRIPTION
  Runs as ONE continuous script on purpose: the emulator display sleeps aggressively
  (PowerManagerService -> INACTIVE). While it sleeps, `snapshot_display` returns a
  BLACK frame and injected touches are dropped. Splitting the flow across shell
  invocations leaves gaps where the screen sleeps, so every step wakes the screen
  first and the whole flow runs without gaps.

  Flow: ConnectPage -> fill host/port/token -> 测试连接 -> 连接 -> session list
        -> first session -> composer -> 发送 -> wait for the desktop agent reply.
#>
[CmdletBinding()]
param(
  [string]$Host_ = '192.168.1.10',
  [int]$Port = 8790,
  [string]$Bridge = 'D:\APP\Deepseek\DSHHarmony\bridge',
  [string]$OutDir = 'D:\APP\Deepseek\DSHHarmony\docs\screenshots',
  [int]$ReplyWaitSec = 35
)

$ErrorActionPreference = 'Stop'
. "D:\APP\Deepseek\DSHHarmony\tools\harmony-ui.ps1"

$Node = 'D:\APP\Devecostudio26\DevEco Studio\tools\node\node.exe'
$Token = (& $Node -e "console.log(JSON.parse(require('fs').readFileSync('C:/Users/YourName/.dsh-harmony-bridge/bridge.json','utf8')).token)").Trim()
Write-Output "token length = $($Token.Length)"

# --- make sure the bridge we are pointed at is actually up ---------------
function Test-Bridge {
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/v1/health" `
         -Headers @{ Authorization = "Bearer $Token" } -UseBasicParsing -TimeoutSec 8
    Write-Output "bridge health: $($r.Content)"
    return $true
  } catch {
    Write-Output "bridge NOT reachable on $Port : $($_.Exception.Message)"
    return $false
  }
}
if (-not (Test-Bridge)) {
  Write-Output 'starting bridge ...'
  Start-Process -FilePath $Node -ArgumentList 'src/cli.js', '--port', $Port `
    -WorkingDirectory $Bridge -WindowStyle Hidden `
    -RedirectStandardOutput "$OutDir\bridge-$Port.log" -RedirectStandardError "$OutDir\bridge-$Port.err"
  Start-Sleep -Seconds 4
  if (-not (Test-Bridge)) { throw "bridge did not come up on $Port" }
}

function Find-Below {
  <# First node of the given type whose bounds start below $MinY (list entries). #>
  param($Layout, [string]$Type, [int]$MinY)
  $hit = $null
  function Walk($n) {
    if ($null -eq $n -or $null -ne $script:hit) { return }
    $a = $n.attributes
    if ($a.type -eq $Type -and $a.bounds -match '\[(-?\d+),(-?\d+)\]' -and [int]$Matches[2] -ge $MinY) {
      $script:hit = $a; return
    }
    if ($n.children) { foreach ($c in $n.children) { Walk $c } }
  }
  $script:hit = $null
  if ($null -ne $Layout) { Walk $Layout }
  return $script:hit
}

function Show-Text {
  param($Layout, [int]$Max = 40)
  $i = 0
  function Walk($n) {
    if ($null -eq $n -or $i -ge $Max) { return }
    $a = $n.attributes
    if ($a.type -eq 'Text' -and $a.text) { Write-Output ("    '{0}'" -f $a.text); $script:i++ }
    if ($n.children) { foreach ($c in $n.children) { Walk $c } }
  }
  $script:i = 0
  Walk $Layout
}

# ============================ 1. ConnectPage =============================
Wake-Screen
Write-Output "`n=== [1] reset app to ConnectPage ==="
Invoke-Hdc shell 'aa force-stop com.dsh.harmony' | Out-Null
Invoke-Hdc shell 'bm clean -d -n com.dsh.harmony' | Out-Null
Start-Sleep -Seconds 2
Invoke-Hdc shell 'aa start -a EntryAbility -b com.dsh.harmony' | Out-Null
Start-Sleep -Seconds 4
Wake-Screen

$lay = Get-Layout
$hostHint = '例如 192.168.1.10(模拟器填 10.0.2.2)'
Write-Output "=== [2] fill form (host=$Host_ port=$Port) ==="

function Set-Verified {
  <# Fill a field and confirm the value landed; retry once if it did not. #>
  param([string]$Text, [string]$Hint, [string]$Value, [int]$Chunk = 6, [int]$Attempts = 3)
  for ($i = 1; $i -le $Attempts; $i++) {
    $l = Get-Layout
    Set-Field -Layout $l -Text $Text -Hint $Hint -Value $Value -Chunk $Chunk | Out-Null
    $l2 = Get-Layout
    $got = Get-FieldValue -Layout $l2 -Text $Text -Hint $Hint
    if ($got -eq $Value) { return $got }
    Write-Output "    (attempt $i got '$got') - retrying"
  }
  return (Get-FieldValue -Layout (Get-Layout) -Text $Text -Hint $Hint)
}

$h = Set-Verified -Hint $hostHint -Value $Host_ -Chunk 5
Write-Output "  host  = '$h'"
$p = Set-Verified -Hint '8787' -Value "$Port" -Chunk 4
Write-Output "  port  = '$p'"
$t = Set-Verified -Hint '桌面端启动时打印的令牌' -Value $Token -Chunk 8
Write-Output "  token = $(if($t){$t.Length}else{0}) chars (expected $($Token.Length))"
if ($h -ne $Host_ -or $p -ne "$Port" -or -not $t -or $t.Length -ne $Token.Length) {
  throw "form not filled correctly: host='$h' port='$p' tokenLen=$(if($t){$t.Length}else{0})"
}

# ============================ 3. 测试连接 ================================
Wake-Screen
$btn = Dismiss-Keyboard -NeedText '测试连接'
if ($null -eq $btn) { throw '测试连接 button not reachable (keyboard still covering it)' }
$c = Get-Center $btn.bounds
Write-Output "`n=== [3] tap 测试连接 at $($c.X),$($c.Y) ==="
Invoke-Hdc shell 'hilog -r' | Out-Null
Invoke-Tap -X $c.X -Y $c.Y -SettleMs 2000 | Out-Null
Start-Sleep -Seconds 2
Save-Screenshot -Path "$OutDir\15-test-connection-8790.jpeg" | Out-Null
$lay = Get-Layout
$status = Find-Below -Layout $lay -Type 'Text' -MinY 1400
Write-Output "  status line: '$($status.text)'"
Write-Output '  netstat:'
Invoke-Hdc shell "netstat -an 2>/dev/null | grep $Port" | ForEach-Object { Write-Output "    $_" }

# ============================ 4. 连接 ===================================
Wake-Screen
$btn = Dismiss-Keyboard -NeedText '连接'
if ($null -eq $btn) { throw '连接 button not reachable (keyboard still covering it)' }
$c = Get-Center $btn.bounds
Write-Output "`n=== [4] tap 连接 at $($c.X),$($c.Y) ==="
Invoke-Tap -X $c.X -Y $c.Y -SettleMs 2500 | Out-Null
Start-Sleep -Seconds 6
Save-Screenshot -Path "$OutDir\16-sessionlist.jpeg" | Out-Null
$lay = Get-Layout
Write-Output '  session list:'
Show-Text -Layout $lay -Max 14

# ======================= 5. open the first session =======================
Wake-Screen
$lay = Get-Layout
$first = Find-Below -Layout $lay -Type 'Text' -MinY 400
if ($null -eq $first) { throw 'no session entry found in the list' }
$c = Get-Center $first.bounds
Write-Output "`n=== [5] tap first session '$($first.text)' at $($c.X),$($c.Y) ==="
Invoke-Tap -X $c.X -Y $c.Y -SettleMs 2500 | Out-Null
Start-Sleep -Seconds 4
Save-Screenshot -Path "$OutDir\17-session-transcript.jpeg" | Out-Null
$lay = Get-Layout
Write-Output '  transcript:'
Show-Text -Layout $lay -Max 30

# ======================= 6. compose + send ==============================
# The composer on the session page is a TextArea (not a TextInput).
Wake-Screen
$lay = Get-Layout
$composer = Find-Below -Layout $lay -Type 'TextArea' -MinY 1800
if ($null -eq $composer) { throw 'composer TextArea not found' }
$c = Get-Center $composer.bounds
Write-Output "`n=== [6] focus composer at $($c.X),$($c.Y) ==="
Invoke-Tap -X $c.X -Y $c.Y -SettleMs 1200 | Out-Null

$promptZh = '请只回复三个字：已收到'
$promptEn = 'reply with exactly: OK-HARMONY'
Invoke-Type -Value $promptZh -Chunk 4
Start-Sleep -Milliseconds 800
$composer = Find-Below -Layout (Get-Layout) -Type 'TextArea' -MinY 1800
$typed = $composer.text
Write-Output "  typed (zh attempt): '$typed'"
if ($typed -notmatch '已收到') {
  Write-Output '  chinese did not land -> clearing and using ASCII'
  for ($i = 0; $i -lt 40; $i++) { Invoke-Hdc shell 'uitest uiInput keyEvent 2055' | Out-Null }
  Start-Sleep -Milliseconds 500
  Invoke-Hdc shell "uitest uiInput inputText $($c.X) $($c.Y) $promptEn" | Out-Null
  Start-Sleep -Milliseconds 800
  $composer = Find-Below -Layout (Get-Layout) -Type 'TextArea' -MinY 1800
  Write-Output "  typed (ascii): '$($composer.text)'"
}
Save-Screenshot -Path "$OutDir\18-composer-typed.jpeg" | Out-Null

$lay = Get-Layout
$send = Dismiss-Keyboard -NeedText '发送'
if ($null -eq $send) { throw '发送 button not reachable' }
$c = Get-Center $send.bounds
Write-Output "  tap 发送 at $($c.X),$($c.Y)"
Invoke-Hdc shell 'hilog -r' | Out-Null
Invoke-Tap -X $c.X -Y $c.Y -SettleMs 2000 | Out-Null

Write-Output "`n=== [7] waiting ${ReplyWaitSec}s for the desktop agent reply ==="
for ($i = 0; $i -lt $ReplyWaitSec; $i += 5) {
  Start-Sleep -Seconds 5
  Wake-Screen
  $lay = Get-Layout
  $hit = Find-Below -Layout $lay -Type 'Text' -MinY 200
  Write-Output ("  t+{0}s" -f ($i + 5))
}
Save-Screenshot -Path "$OutDir\19-reply.jpeg" | Out-Null
$lay = Get-Layout
Write-Output '  final transcript:'
Show-Text -Layout $lay -Max 40

Write-Output "`n=== app log (DshHarmony tag) ==="
$pid_ = Get-AppPid
Write-Output "app pid = $pid_"
Invoke-Hdc shell "hilog -x | grep ' $pid_ ' | grep -iE 'DshHarmony|RespCode|errCode|websocket|error' | tail -30" | ForEach-Object { Write-Output "  $_" }
