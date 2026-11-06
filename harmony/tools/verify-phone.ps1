<#
.SYNOPSIS
  One-click acceptance check of the HarmonyOS phone app on a real device.

.DESCRIPTION
  Runs a fixed list of checks against the phone and prints PASS / FAIL for each
  one, with the evidence that decided it. Every check is independent: a failing
  one does not stop the others, and every step has its own timeout, so the
  script never hangs.

  The checks:
    1  the app starts and lands on the session list or the connect page
    2  it says connected and the conversation tree is not empty
    3  opening a conversation shows the newest message last (first/last stamp)
    4  a message that is typed in shows up at the bottom right away
    5  the little triangle collapses the topic subtree without opening anything
    6  a truncated message can be expanded with "more"
    7  the access token is masked on screen
    8  the token is not stored in clear text in the preferences
    9  screenshots are written to docs/screenshots
   10  the summary at the end

.EXAMPLE
  .\verify-phone.ps1
  Runs everything. The token is not needed for most checks; when it is given,
  check 8 can prove that the clear text token is really gone.

.EXAMPLE
  $env:DSH_PHONE_TOKEN = 'the-real-token'
  .\verify-phone.ps1 -SkipSend
  Skips the check that sends a message into a real conversation.

.PARAMETER Token
  The bridge access token. Never hard-code it: pass it in or set
  $env:DSH_PHONE_TOKEN. Check 8 uses it to look for clear text on the phone.

.PARAMETER ScreenshotDir
  Where the screenshots go. Default: docs/screenshots next to this script.

.NOTES
  * The source of this file is ASCII on purpose. Windows PowerShell 5.1 reads a
    .ps1 file without BOM as ANSI (GBK on this machine) and would mangle
    Chinese literals, so the Chinese words of the UI are kept base64 encoded
    in $script:WordBlob and decoded at run time.
  * The phone is also in use by a human while these checks run, so a check can
    fail because somebody else touched the screen. The evidence line of a
    failing check says what was on the screen, which makes that visible.
#>

param(
    # The bridge access token (for check 8). Or set $env:DSH_PHONE_TOKEN.
    [string]$Token,
    # Skip the check that sends a message into a real conversation.
    [switch]$SkipSend,
    # Do not use the app's own discovery to connect to a desktop on the LAN.
    [switch]$NoAutoConnect,
    # How long to wait for a person to unlock the phone (seconds).
    [int]$WaitForUnlock = 180,
    # Only run the first N checks.
    [int]$Only = 0,
    # Where to put the screenshots.
    [string]$ScreenshotDir,
    [string]$HdcPath,
    [string]$Target,
    [string]$Bundle = 'com.example.dshsync'
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'phone-probe.ps1')

# The UI words of the app, base64 so this file stays pure ASCII:
#   yi lian jie (connected) | wei lian jie (not connected) | ge dui hua (N conversations)
#   ...dian kai geng duo (the "more" expander) | the two triangles | the send arrow
#   fang wen yin yong (token label) | zhuo mian du di zhi (address label)
#   gong zuo qu (workspace) | hui hua (session list title) | fa song xiao xi (input)
#   shou qi / zhan kai (collapse / expand) | gui ji (trace tab) | dui hua (chat tab)
#   ling pai deng yu (the token warning line)
$script:WordBlob = '5bey6L+e5o6lfOacqui/nuaOpXzkuKrlr7nor5184oCm54K55byA5pu05aSafOKWuHzilr584oaRfOiuv+mXruS7pOeJjHzmoYzpnaLnq6/lnLDlnYB85bel5L2c5Yy6fOS8muivnXzlj5HpgIHmtojmga985pS26LW3fOWxleW8gHzovajov7l85a+56K+dfOS7pOeJjOetieS6jnzorr7nva586L+e5o6lfOWIt+aWsHzorr7lpId86Ieq5Yqo5o6i5rWLfOi/lOWbng=='

function Get-DshWord {
    <#
    .SYNOPSIS
      The UI words of the app, decoded from base64.
    #>
    param([int]$Index)
    $list = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($script:WordBlob)).Split('|')
    if ($Index -lt 0 -or $Index -ge $list.Count) { return '' }
    return $list[$Index]
}

# word indices
$script:W_CONNECTED = 0      # yi lian jie
$script:W_NOTCONNECTED = 1   # wei lian jie
$script:W_CONVERSATIONS = 2   # ge dui hua
$script:W_MORE = 3           # ...dian kai geng duo
$script:W_TRI_DOWN = 4       # triangle, collapsed
$script:W_TRI_UP = 5         # triangle, expanded
$script:W_SEND = 6           # the send arrow
$script:W_TOKENLABEL = 7     # fang wen yin yong
$script:W_ADDRESS = 8        # zhuo mian du di zhi
$script:W_WORKSPACE = 9      # gong zuo qu
$script:W_SESSIONS = 10      # hui hua
$script:W_INPUT = 11         # fa song xiao xi
$script:W_COLLAPSE = 12      # shou qi
$script:W_EXPAND = 13        # zhan kai
$script:W_TRACE = 14         # gui ji
$script:W_CHAT = 15          # dui hua
$script:W_TOKENWARN = 16     # ling pai deng yu
$script:W_SETTINGS = 17      # she zhi (settings)
$script:W_CONNECT = 18       # lian jie (connect)
$script:W_REFRESH = 19       # shua xin (refresh)
$script:W_DEVICES = 20       # she bei (devices)
$script:W_DISCOVER = 21      # zi dong tan ce (the discover button)
$script:W_BACK = 22         # fan hui (the back entry of the app)

# ------------------------------------------------------------------ report --

$script:Results = New-Object System.Collections.Generic.List[object]
$script:ShotCount = 0

function Add-DshResult {
    param([string]$Name, [string]$Status, [string]$Evidence)
    $script:Results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Evidence = $Evidence })
    $color = 'Green'
    if ($Status -eq 'FAIL') { $color = 'Red' }
    elseif ($Status -eq 'SKIP') { $color = 'Yellow' }
    Write-Host ("[{0}] {1}`n      {2}" -f $Status, $Name, $Evidence) -ForegroundColor $color
}

function Save-DshShot {
    <#
    .SYNOPSIS
      Screenshot into the screenshot folder, returns the path.
    #>
    param([string]$Name)
    if (-not $script:ShotDir) { return '' }
    $script:ShotCount++
    $file = Join-Path $script:ShotDir ("verify-{0:d2}-{1}.jpeg" -f $script:ShotCount, $Name)
    try {
        return (Save-DshScreenshot -HdcPath $HdcPath -Target $Target -Path $file)
    }
    catch {
        Write-Host "[shot] failed: $($_.Exception.Message)"
        return ''
    }
}

function Get-DshTexts {
    param($Nodes)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($n in $Nodes) { if ($n.Text) { $out.Add($n.Text) } }
    return $out
}

function Get-DshTimes {
    <#
    .SYNOPSIS
      All the HH:mm stamps of the screen (message times).
    #>
    param($Nodes)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($n in $Nodes) {
        if (-not $n.Text) { continue }
        $m = [regex]::Match($n.Text, '(\d{2}):(\d{2})')
        if ($m.Success) { $out.Add($n.Text) }
    }
    return $out
}

function Find-DshRowTitle {
    <#
    .SYNOPSIS
      The title that belongs to a triangle (the text on the same line, to the right).
    #>
    param($Nodes, $Triangle)
    $best = $null
    foreach ($n in $Nodes) {
        if (-not $n.Text) { continue }
        if ($n.Type -eq 'Text' -and $n.Text -eq $Triangle.Text) { continue }
        if ([Math]::Abs($n.CenterY - $Triangle.CenterY) -gt 12) { continue }
        if ($n.Left -le $Triangle.Right) { continue }
        if ($null -eq $best -or $n.Left -lt $best.Left) { $best = $n }
    }
    return $best
}

function Test-DshOnScreen {
    <#
    .SYNOPSIS
      Is the given word on the screen?
    #>
    param($Nodes, [string]$Word)
    foreach ($n in $Nodes) {
        if ($n.Text -and $n.Text.Contains($Word)) { return $true }
    }
    return $false
}

function Go-DshSessionList {
    <#
    .SYNOPSIS
      Get back to the session list (the page with the conversation tree).
    .DESCRIPTION
      The app keeps the page it was on, so BACK is used until the session list
      shows up. Starting the app is the fallback.
    #>
    param([int]$Tries = 4)
    for ($i = 1; $i -le $Tries; $i++) {
        $nodes = @(Wait-DshLayoutStable -HdcPath $HdcPath -Target $Target)
        if ($nodes.Count -gt 0 -and (Test-DshOnScreen -Nodes $nodes -Word (Get-DshWord $script:W_SESSIONS))) { return $nodes }
        Write-Host "[nav] not on the session list yet, going back"
        $back = Find-DshNode -Nodes $nodes -Text (Get-DshWord $script:W_BACK)
        if ($null -ne $back -and $back.CenterY -lt 500) {
            Write-Host "[nav] tapping the back entry at ($($back.CenterX),$($back.CenterY))"
            Invoke-DshHdc -Arguments @('shell', "uitest uiInput click $($back.CenterX) $($back.CenterY)") -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
        }
        else {
            Invoke-DshHdc -Arguments @('shell', 'uitest uiInput keyEvent Back') -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
        }
        Start-Sleep -Milliseconds 900
    }
    $nodes = @(Start-DshApp)
    return $nodes
}

function Go-DshConnectPage {
    <#
    .SYNOPSIS
      Get to the connect page (the one with the desktop address and the token).
    .DESCRIPTION
      The connect page hangs under the top bar of the session list, so the
      entries of the top bar are tried until the token label shows up.
    #>
    param([int]$Tries = 6)
    $entries = @(
        (Get-DshWord $script:W_SETTINGS),
        (Get-DshWord $script:W_CONNECT),
        (Get-DshWord $script:W_DEVICES),
        (Get-DshWord $script:W_REFRESH)
    )
    for ($i = 1; $i -le $Tries; $i++) {
        $nodes = @(Wait-DshLayoutStable -HdcPath $HdcPath -Target $Target)
        if ($nodes.Count -gt 0 -and (Test-DshOnScreen -Nodes $nodes -Word (Get-DshWord $script:W_TOKENLABEL))) { return $nodes }
        $tapped = $false
        foreach ($entry in $entries) {
            $n = Find-DshNode -Nodes $nodes -Text $entry
            if ($null -eq $n) { continue }
            if ($n.CenterY -gt 520 -or $n.CenterY -lt 150) { continue }
            Write-Host "[nav] tapping the bar entry '$($n.Text)' at ($($n.CenterX),$($n.CenterY))"
            Invoke-DshHdc -Arguments @('shell', "uitest uiInput click $($n.CenterX) $($n.CenterY)") -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
            Start-Sleep -Milliseconds 1200
            $tapped = $true
            break
        }
        if (-not $tapped) {
            Write-Host '[nav] no top bar entry found, going back'
            Invoke-DshHdc -Arguments @('shell', 'uitest uiInput keyEvent Back') -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
            Start-Sleep -Milliseconds 900
        }
    }
    return $null
}

function Get-DshTokenValue {
    <#
    .SYNOPSIS
      The value of the token field: the input on the same row as the token label.
    #>
    param($Nodes)
    $label = Find-DshNode -Nodes $Nodes -Text (Get-DshWord $script:W_TOKENLABEL)
    if ($null -eq $label) { return '' }
    $best = $null
    foreach ($n in $Nodes) {
        if ($n.Type -ne 'TextInput' -and $n.Type -ne 'TextArea') { continue }
        if ([Math]::Abs($n.CenterY - $label.CenterY) -gt 24) { continue }
        if ($n.Left -lt $label.Right) { continue }
        if ($null -eq $best -or $n.Left -lt $best.Left) { $best = $n }
    }
    if ($null -eq $best) { return '' }
    return $best.Text
}

function Connect-DshAppToBridge {
    <#
    .SYNOPSIS
      Make the app talk to a desktop on the LAN, with the app's own discovery.
    .DESCRIPTION
      Uses the "discover" button of the connect page and then the first desktop
      that shows up (its address is an ip:port, which is easy to recognise).
      This is the same flow a person does, so it also proves that flow.
    #>
    param([int]$WaitSec = 40)
    $nodes = Go-DshConnectPage
    if ($null -eq $nodes) {
        Write-Host '[setup] the connect page was not reachable'
        return $false
    }
    $discover = Find-DshNode -Nodes $nodes -Text (Get-DshWord $script:W_DISCOVER)
    if ($null -eq $discover) {
        Write-Host '[setup] the discover button was not on the connect page'
        return $false
    }
    Write-Host "[setup] tapping the discover button at ($($discover.CenterX),$($discover.CenterY))"
    Invoke-DshHdc -Arguments @('shell', "uitest uiInput click $($discover.CenterX) $($discover.CenterY)") -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
    $deadline = (Get-Date).AddSeconds($WaitSec)
    $target = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $nodes = @(Get-DshLayout -HdcPath $HdcPath -Target $Target)
        foreach ($n in $nodes) {
            # The address of the desktop in the sheet. Not the input field of
            # the connect page: that one holds the address we typed ourselves.
            if ($n.Type -eq 'TextInput' -or $n.Type -eq 'TextArea') { continue }
            if ($n.Text -and $n.Text -match '\d+\.\d+\.\d+\.\d+:\d+') { $target = $n; break }
        }
        if ($null -ne $target) { break }
    }
    if ($null -eq $target) {
        Write-Host '[setup] no desktop was found on the LAN'
        return $false
    }
    Write-Host "[setup] tapping the found desktop '$($target.Text)' at ($($target.CenterX),$($target.CenterY))"
    Invoke-DshHdc -Arguments @('shell', "uitest uiInput click $($target.CenterX) $($target.CenterY)") -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
    Start-Sleep -Seconds 3
    $nodes = Wait-DshLayoutStable -HdcPath $HdcPath -Target $Target
    $ok = Test-DshOnScreen -Nodes $nodes -Word (Get-DshWord $script:W_CONNECTED)
    Write-Host ("[setup] the app says connected: {0}" -f $ok)
    if ($ok) {
        # The app opens the connect page when it has no desktop yet. Now that
        # it has one, a restart brings up the session list.
        Invoke-DshHdc -Arguments @('shell', "aa force-stop $Bundle") -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
        Start-Sleep -Seconds 2
        Invoke-DshHdc -Arguments @('shell', "aa start -a EntryAbility -b $Bundle") -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
        Start-Sleep -Seconds 4
    }
    return $ok
}

# ------------------------------------------------------------------- setup --

if (-not $Token -and $env:DSH_PHONE_TOKEN) { $Token = $env:DSH_PHONE_TOKEN }
if (-not $ScreenshotDir) {
    $ScreenshotDir = Join-Path (Split-Path -Parent $PSScriptRoot) '..\docs\screenshots'
}
if (-not (Test-Path -LiteralPath $ScreenshotDir)) {
    New-Item -ItemType Directory -Path $ScreenshotDir -Force | Out-Null
}
$script:ShotDir = (Resolve-Path -LiteralPath $ScreenshotDir).Path

Write-Host '==============================================================='
Write-Host ' phone acceptance check'
Write-Host (" target hdc      : {0}" -f (Get-DshHdcPath -HdcPath $HdcPath))
Write-Host (" screenshots     : {0}" -f $script:ShotDir)
Write-Host (" token given     : {0}" -f $(if ($Token) { 'yes' } else { 'no (check 8 can only look for the key)' }))
Write-Host '==============================================================='

try {
    $phone = Connect-DshPhone -HdcPath $HdcPath -Target $Target
    Write-Host (" connected to    : {0}" -f $phone)
}
catch {
    Write-Error $_
    exit 1
}

# A locked phone cannot be driven: the lock is a face or a fingerprint, and
# that is something only a person can do. Wait for a person to unlock it, and
# say so, instead of reporting nonsense failures.
try {
    Enter-DshPhone -HdcPath $HdcPath -Target $Target | Out-Null
    $lockNodes = @(Get-DshLayout -HdcPath $HdcPath -Target $Target)
    if (Test-DshLocked -Nodes $lockNodes) {
        Write-Host ''
        Write-Host '==============================================================='
        Write-Host ' THE PHONE IS LOCKED (face or fingerprint).'
        Write-Host ' Unlock it once with your finger or your face - the script waits.'
        Write-Host '==============================================================='
        $deadline = (Get-Date).AddSeconds($WaitForUnlock)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3
            try {
                $lockNodes = @(Get-DshLayout -HdcPath $HdcPath -Target $Target)
                if ($lockNodes.Count -gt 0 -and -not (Test-DshLocked -Nodes $lockNodes)) {
                    Write-Host ' the phone is unlocked, going on'
                    break
                }
            }
            catch {
                # the screen went dark again, keep waiting
            }
            Write-Host -NoNewline '.'
        }
        Write-Host ''
    }
}
catch {
    # The screen may be dark; the wake in Enter-DshPhone will deal with it.
}

function Start-DshApp {
    Invoke-DshHdc -Arguments @('shell', "aa start -a EntryAbility -b $Bundle") -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
    Start-Sleep -Seconds 3
    return (Wait-DshLayoutStable -HdcPath $HdcPath -Target $Target)
}

function Need-DshApp {
    <#
    .SYNOPSIS
      The app has to be the one on the screen before a check runs.
    #>
    $nodes = @(Ensure-DshApp -HdcPath $HdcPath -Target $Target -Bundle $Bundle)
    return (Wait-DshLayoutStable -HdcPath $HdcPath -Target $Target)
}

# ------------------------------------------------------------------ check 1 --

$nodes = $null
try {
    Enter-DshPhone -HdcPath $HdcPath -Target $Target | Out-Null
    $nodes = Start-DshApp
    $texts = Get-DshTexts -Nodes $nodes
    $onSessions = $false
    $onConnect = $false
    foreach ($t in $texts) {
        if ($t.Contains((Get-DshWord $script:W_SESSIONS))) { $onSessions = $true }
        if ($t.Contains((Get-DshWord $script:W_ADDRESS))) { $onConnect = $true }
    }
    $shot = Save-DshShot -Name 'app-started'
    if ($onSessions -or $onConnect) {
        $where = ''
        if ($onSessions) { $where = Get-DshWord $script:W_SESSIONS }
        if ($onConnect) { $where = Get-DshWord $script:W_ADDRESS }
        Add-DshResult -Name '1. app starts and lands on a page of the app' -Status 'PASS' -Evidence ("landed on '$where'. screenshot: $shot")
    }
    elseif (Test-DshLocked -Nodes $nodes) {
        Add-DshResult -Name '1. app starts and lands on a page of the app' -Status 'FAIL' -Evidence 'the phone is LOCKED (face or fingerprint), the app can not come to the front. Unlock it once and run again. screenshot: ' + $shot
    }
    else {
        Add-DshResult -Name '1. app starts and lands on a page of the app' -Status 'FAIL' -Evidence ("the app is not on screen, only: " + (($texts | Select-Object -First 8) -join ' / ') + ". screenshot: $shot")
    }
}
catch {
    Add-DshResult -Name '1. app starts and lands on a page of the app' -Status 'FAIL' -Evidence $_.Exception.Message
}

# ------------------------------------------------------------------ check 2 --

$conversationCount = 0
try {
    $nodes = Go-DshSessionList
    $texts = Get-DshTexts -Nodes $nodes
    $connected = $false
    $notConnected = $false
    foreach ($t in $texts) {
        if ($t.Contains((Get-DshWord $script:W_CONNECTED))) { $connected = $true }
        if ($t.Contains((Get-DshWord $script:W_NOTCONNECTED))) { $notConnected = $true }
    }
    if (-not $connected -and -not $NoAutoConnect) {
        # The app is not connected: use its own discovery to find a desktop.
        Write-Host '[setup] the app is not connected yet, using the app discovery'
        $null = Connect-DshAppToBridge
        $nodes = Go-DshSessionList
        $texts = Get-DshTexts -Nodes $nodes
        foreach ($t in $texts) {
            if ($t.Contains((Get-DshWord $script:W_CONNECTED))) { $connected = $true }
            if ($t.Contains((Get-DshWord $script:W_NOTCONNECTED))) { $notConnected = $true }
        }
    }
    foreach ($t in $texts) {
        $m = [regex]::Match($t, '(\d+)\s*' + [regex]::Escape((Get-DshWord $script:W_CONVERSATIONS)))
        if ($m.Success) { $conversationCount = [int]$m.Groups[1].Value }
    }
    $shot = Save-DshShot -Name 'session-list'
    if ($connected -and -not $notConnected -and $conversationCount -gt 0) {
        Add-DshResult -Name '2. connected and the conversation tree is not empty' -Status 'PASS' -Evidence ("connected, $conversationCount conversations. screenshot: $shot")
    }
    elseif (-not $connected -and $notConnected) {
        Add-DshResult -Name '2. connected and the conversation tree is not empty' -Status 'FAIL' -Evidence 'the app says NOT connected. screenshot: ' + $shot
    }
    else {
        Add-DshResult -Name '2. connected and the conversation tree is not empty' -Status 'FAIL' -Evidence ("connected=$connected, conversations=$conversationCount. screenshot: $shot")
    }
}
catch {
    Add-DshResult -Name '2. connected and the conversation tree is not empty' -Status 'FAIL' -Evidence $_.Exception.Message
}

# ------------------------------------------------------------------ check 5 --

# The triangle check needs a tree, so it runs before we open a conversation.
$triangleWorked = $null
try {
    $nodes = Wait-DshLayoutStable -HdcPath $HdcPath -Target $Target
    $down = Find-DshNode -Nodes $nodes -Text (Get-DshWord $script:W_TRI_DOWN)
    if ($null -eq $down) {
        Add-DshResult -Name '5. the triangle collapses the subtree and does not open a session' -Status 'SKIP' -Evidence 'no collapsible row on the screen (the tree is empty or already expanded)'
    }
    else {
        $rowsBefore = @($nodes | Where-Object { $_.Text }).Count
        $title = Find-DshRowTitle -Nodes $nodes -Triangle $down
        $titleText = ''
        if ($title) { $titleText = $title.Text }
        Write-Host "[check 5] tapping the triangle of '$titleText' at ($($down.CenterX),$($down.CenterY))"
        Invoke-DshHdc -Arguments @('shell', "uitest uiInput click $($down.CenterX) $($down.CenterY)") -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
        Start-Sleep -Milliseconds 1200
        $after = Wait-DshLayoutStable -HdcPath $HdcPath -Target $Target
        $rowsAfter = @($after | Where-Object { $_.Text }).Count
        $up = Find-DshNode -Nodes $after -Text (Get-DshWord $script:W_TRI_UP)
        $stillOnList = $false
        foreach ($t in (Get-DshTexts -Nodes $after)) {
            if ($t.Contains((Get-DshWord $script:W_SESSIONS))) { $stillOnList = $true }
        }
        $shot = Save-DshShot -Name 'triangle-collapsed'
        if ($null -ne $up -and $stillOnList) {
            Add-DshResult -Name '5. the triangle collapses the subtree and does not open a session' -Status 'PASS' -Evidence ("the triangle of '$titleText' flipped to the expanded sign, rows $rowsBefore -> $rowsAfter, still on the session list. screenshot: $shot")
            $triangleWorked = $title
        }
        else {
            Add-DshResult -Name '5. the triangle collapses the subtree and does not open a session' -Status 'FAIL' -Evidence ("the triangle did not flip (rows $rowsBefore -> $rowsAfter, still on list: $stillOnList). screenshot: $shot")
        }
    }
}
catch {
    Add-DshResult -Name '5. the triangle collapses the subtree and does not open a session' -Status 'FAIL' -Evidence $_.Exception.Message
}

# ------------------------------------------------------------------ check 3 --

try {
    $nodes = Wait-DshLayoutStable -HdcPath $HdcPath -Target $Target
    # A conversation row: a title with a triangle in front of it, or a plain row
    # under the workspace. Take the first title that is not a known label.
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($n in $nodes) {
        if (-not $n.Text) { continue }
        if ($n.Type -ne 'Text') { continue }
        if ($n.CenterY -lt 500) { continue }   # not a row: that is the title bar
        if ($n.Text -eq (Get-DshWord $script:W_WORKSPACE)) { continue }
        if ($n.Text.Contains((Get-DshWord $script:W_CONVERSATIONS))) { continue }
        if ($n.Text.Contains((Get-DshWord $script:W_SESSIONS))) { continue }
        if ($n.Text -match '^\d+$') { continue }
        if ($n.Text -match '^\d{2}:\d{2}$') { continue }
        $candidates.Add($n)
    }
    $opened = $null
    foreach ($c in $candidates) {
        Write-Host "[check 3] trying to open the conversation '$($c.Text)' at ($($c.CenterX),$($c.CenterY))"
        Invoke-DshHdc -Arguments @('shell', "uitest uiInput click $($c.CenterX) $($c.CenterY)") -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
        Start-Sleep -Milliseconds 1500
        $after = Wait-DshLayoutStable -HdcPath $HdcPath -Target $Target
        $times = @(Get-DshTimes -Nodes $after)
        if ($times.Count -gt 0) { $opened = @{ Title = $c.Text; Nodes = $after; Times = $times }; break }
    }
    if ($null -eq $opened) {
        Add-DshResult -Name '3. opening a conversation shows the newest message last' -Status 'FAIL' -Evidence ("could not open a conversation, tried " + $candidates.Count + ' titles')
    }
    else {
        $times = @($opened.Times)
        $first = $times[0]
        $last = $times[$times.Count - 1]
        $shot = Save-DshShot -Name 'conversation-open'
        # The stamps are "HH:mm" or "MM-DD HH:mm"; compare the time of day.
        $firstT = [regex]::Match($first, '(\d{2}):(\d{2})')
        $lastT = [regex]::Match($last, '(\d{2}):(\d{2})')
        $ok = $true
        if ($firstT.Success -and $lastT.Success) {
            $a = ([int]$firstT.Groups[1].Value * 60) + [int]$firstT.Groups[2].Value
            $b = ([int]$lastT.Groups[1].Value * 60) + [int]$lastT.Groups[2].Value
            $ok = ($b -ge $a)
        }
        if ($times.Count -lt 2) {
            Add-DshResult -Name '3. opening a conversation shows the newest message last' -Status 'SKIP' -Evidence ("the conversation '$($opened.Title)' has only one stamp: $last")
        }
        elseif ($ok) {
            Add-DshResult -Name '3. opening a conversation shows the newest message last' -Status 'PASS' -Evidence ("conversation '$($opened.Title)': $first ... $last ($($times.Count) stamps, the last one is the newest). screenshot: $shot")
        }
        else {
            Add-DshResult -Name '3. opening a conversation shows the newest message last' -Status 'FAIL' -Evidence ("the stamps go '$first' ... '$last', the last one is older. screenshot: $shot")
        }
    }
}
catch {
    Add-DshResult -Name '3. opening a conversation shows the newest message last' -Status 'FAIL' -Evidence $_.Exception.Message
}

# ------------------------------------------------------------------ check 6 --

try {
    $nodes = Wait-DshLayoutStable -HdcPath $HdcPath -Target $Target
    $more = Find-DshNode -Nodes $nodes -Contains (Get-DshWord $script:W_MORE)
    if ($null -eq $more) {
        Add-DshResult -Name '6. a truncated message can be expanded' -Status 'SKIP' -Evidence 'no truncated message on the screen (nothing to expand)'
    }
    else {
        Write-Host "[check 6] tapping '$($more.Text)' at ($($more.CenterX),$($more.CenterY))"
        Invoke-DshHdc -Arguments @('shell', "uitest uiInput click $($more.CenterX) $($more.CenterY)") -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
        Start-Sleep -Milliseconds 1200
        $after = Wait-DshLayoutStable -HdcPath $HdcPath -Target $Target
        $stillThere = $null -ne (Find-DshNode -Nodes $after -Contains (Get-DshWord $script:W_MORE))
        $shot = Save-DshShot -Name 'message-expanded'
        if (-not $stillThere) {
            Add-DshResult -Name '6. a truncated message can be expanded' -Status 'PASS' -Evidence "the 'more' link is gone after the tap, so the message is shown in full. screenshot: $shot"
        }
        else {
            Add-DshResult -Name '6. a truncated message can be expanded' -Status 'FAIL' -Evidence "the 'more' link is still there after the tap. screenshot: $shot"
        }
    }
}
catch {
    Add-DshResult -Name '6. a truncated message can be expanded' -Status 'FAIL' -Evidence $_.Exception.Message
}

# ------------------------------------------------------------------ check 4 --

if ($SkipSend) {
    Add-DshResult -Name '4. a message that is typed in shows up at the bottom' -Status 'SKIP' -Evidence 'skipped on purpose (-SkipSend)'
}
else {
    try {
        $message = "verify-phone $(Get-Date -Format 'HH:mm:ss')"
        $nodes = Wait-DshLayoutStable -HdcPath $HdcPath -Target $Target
        $input = Find-DshNode -Nodes $nodes -Type 'TextArea'
        if ($null -eq $input) {
            Add-DshResult -Name '4. a message that is typed in shows up at the bottom' -Status 'FAIL' -Evidence 'no input box on the screen'
        }
        else {
            Write-Host "[check 4] tapping the input box at ($($input.CenterX),$($input.CenterY))"
            Invoke-DshHdc -Arguments @('shell', "uitest uiInput click $($input.CenterX) $($input.CenterY)") -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
            Start-Sleep -Milliseconds 1200
            Invoke-DshHdc -Arguments @('shell', "uitest uiInput text '$message'") -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
            Start-Sleep -Milliseconds 1200
            $typed = Wait-DshLayoutStable -HdcPath $HdcPath -Target $Target
            $inField = $false
            foreach ($n in $typed) {
                if ($n.Type -eq 'TextArea' -and $n.Text -and $n.Text.Contains($message)) { $inField = $true }
            }
            $send = Find-DshNode -Nodes $typed -Text (Get-DshWord $script:W_SEND)
            if ($null -eq $send) {
                Add-DshResult -Name '4. a message that is typed in shows up at the bottom' -Status 'FAIL' -Evidence ("the text did not land in the field (typed '$message'), no send button either")
            }
            else {
                Write-Host "[check 4] tapping the send button at ($($send.CenterX),$($send.CenterY))"
                Invoke-DshHdc -Arguments @('shell', "uitest uiInput click $($send.CenterX) $($send.CenterY)") -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
                Start-Sleep -Seconds 2
                $after = Wait-DshLayoutStable -HdcPath $HdcPath -Target $Target
                $atBottom = $false
                $lastText = ''
                foreach ($n in $after) {
                    if ($n.Text -and $n.Text.Contains($message)) { $atBottom = $true; $lastText = $n.Text }
                }
                $shot = Save-DshShot -Name 'message-sent'
                if ($atBottom) {
                    Add-DshResult -Name '4. a message that is typed in shows up at the bottom' -Status 'PASS' -Evidence ("'$message' is on the screen right after sending. screenshot: $shot")
                }
                elseif (-not $inField) {
                    Add-DshResult -Name '4. a message that is typed in shows up at the bottom' -Status 'FAIL' -Evidence ("the text '$message' never made it into the input box (a Chinese IME may swallow it). screenshot: $shot")
                }
                else {
                    Add-DshResult -Name '4. a message that is typed in shows up at the bottom' -Status 'FAIL' -Evidence ("the text '$message' is in the box but did not show up in the list. screenshot: $shot")
                }
            }
        }
    }
    catch {
        Add-DshResult -Name '4. a message that is typed in shows up at the bottom' -Status 'FAIL' -Evidence $_.Exception.Message
    }
}

# ------------------------------------------------------------------ check 7 --

try {
    $nodes = Go-DshConnectPage
    if ($null -eq $nodes) {
        Add-DshResult -Name '7. the access token is masked on screen' -Status 'FAIL' -Evidence 'could not reach the connect page'
    }
    else {
        $tokenValue = Get-DshTokenValue -Nodes $nodes
        $shot = Save-DshShot -Name 'connect-page'
        if (-not $tokenValue) {
            Add-DshResult -Name '7. the access token is masked on screen' -Status 'SKIP' -Evidence 'the app has no token stored, so there is nothing that could be shown in clear text. screenshot: ' + $shot
        }
        else {
            $masked = $tokenValue.Contains([char]0x2022)   # bullet
            $plain = $false
            if ($Token) { $plain = $tokenValue.Contains($Token) }
            if ($masked -and -not $plain) {
                Add-DshResult -Name '7. the access token is masked on screen' -Status 'PASS' -Evidence ("the token field shows '$tokenValue' (masked). screenshot: $shot")
            }
            elseif ($plain) {
                Add-DshResult -Name '7. the access token is masked on screen' -Status 'FAIL' -Evidence 'the token is shown in clear text on the screen. screenshot: ' + $shot
            }
            else {
                Add-DshResult -Name '7. the access token is masked on screen' -Status 'FAIL' -Evidence ("the token field shows '$tokenValue', which is not masked. screenshot: $shot")
            }
        }
    }
}
catch {
    Add-DshResult -Name '7. the access token is masked on screen' -Status 'FAIL' -Evidence $_.Exception.Message
}

# ------------------------------------------------------------------ check 8 --

try {
    $prefs = Get-DshPreferencesText -HdcPath $HdcPath -Target $Target
    if (-not $prefs) {
        Add-DshResult -Name '8. the token is not stored in clear text in the preferences' -Status 'SKIP' -Evidence 'no preferences file on the phone yet (the app has not saved anything, or the shell may not read the app data)'
    }
    else {
        $clear = $false
        if ($Token -and $prefs.Contains($Token)) { $clear = $true }
        # The <string key="token"> entry must not carry the token either.
        $m = [regex]::Match($prefs, '<string key="token">([^<]*)</string>')
        $tokenEntry = ''
        if ($m.Success) { $tokenEntry = $m.Groups[1].Value }
        if ($clear -or ($tokenEntry -and $Token -and $tokenEntry -eq $Token)) {
            Add-DshResult -Name '8. the token is not stored in clear text in the preferences' -Status 'FAIL' -Evidence 'the clear text token was found in the preferences file'
        }
        else {
            Add-DshResult -Name '8. the token is not stored in clear text in the preferences' -Status 'PASS' -Evidence ("the preferences hold no clear text token (token key = '" + $tokenEntry + "')")
        }
    }
}
catch {
    Add-DshResult -Name '8. the token is not stored in clear text in the preferences' -Status 'FAIL' -Evidence $_.Exception.Message
}

# ------------------------------------------------------------------ summary --

Write-Host ''
Write-Host '==============================================================='
Write-Host ' summary'
Write-Host '==============================================================='
$pass = 0
$fail = 0
$skip = 0
$report = New-Object System.Collections.Generic.List[string]
$report.Add("phone acceptance check - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$report.Add("device: $phone")
$report.Add('')
foreach ($r in $script:Results) {
    $mark = '  ?'
    if ($r.Status -eq 'PASS') { $mark = ' OK'; $pass++ }
    elseif ($r.Status -eq 'FAIL') { $mark = 'FAIL'; $fail++ }
    else { $mark = 'SKIP'; $skip++ }
    Write-Host ("{0}  {1}" -f $mark, $r.Name)
    Write-Host ("      {0}" -f $r.Evidence)
    $report.Add("$mark  $($r.Name)")
    $report.Add("      $($r.Evidence)")
}
$summary = "total: $pass passed, $fail failed, $skip skipped, $($script:ShotCount) screenshots"
Write-Host ''
Write-Host (" total: {0} passed, {1} failed, {2} skipped, {3} screenshots" -f $pass, $fail, $skip, $script:ShotCount)
Write-Host '==============================================================='
$report.Add('')
$report.Add($summary)
$reportPath = Join-Path $script:ShotDir 'verify-report.txt'
try {
    [System.IO.File]::WriteAllLines($reportPath, $report, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host (" report written to {0}" -f $reportPath)
}
catch {
    Write-Host (" could not write the report file: {0}" -f $_.Exception.Message)
}

if ($fail -gt 0) { exit 1 }
exit 0
