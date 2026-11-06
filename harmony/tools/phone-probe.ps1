<#
.SYNOPSIS
  Shared probe helpers for driving ONE HarmonyOS real phone over HDC.

.DESCRIPTION
  Driving the phone by hand keeps hitting the same four problems, so they are
  fixed here once:

    1. the screen locks itself after ~30 seconds   -> Wake-DshPhone
    2. dumpLayout sometimes returns the PREVIOUS
       screen (stale layout)                        -> Wait-DshLayoutStable
    3. the soft keyboard pushes the wanted button
       off the screen                              -> Test-DshKeyboardOpen
                                                       + hide the keyboard
    4. a tap lands on the wrong element because
       the layout moved                            -> tap by node bounds,
                                                       taken from a fresh dump

  Functions:
    Get-DshHdcPath            locate hdc.exe
    Get-DshPhoneTarget        the serial of the phone (env DSH_PHONE_TARGET)
    Invoke-DshHdc            run one hdc command, return its output text
    Connect-DshPhone          make sure hdc knows the phone (tconn + list)
    Get-DshPowerState         AWAKE / SUSPEND
    Wake-DshPhone             wake the screen up
    Unlock-DshPhone           swipe up (this phone has no PIN)
    Get-DshLayout             dump + parse -> node objects
    Get-DshLayoutSignature    short hash of a layout (to detect "no change")
    Wait-DshLayoutStable      poll until N consecutive dumps are identical
    Test-DshKeyboardOpen      is a text field focused right now?
    Hide-DshKeyboard          close the soft keyboard (only if it is open)
    Find-DshNode              find nodes by text / substring / type
    Get-DshHilog              hilog tail, optionally filtered
    Save-DshScreenshot        snapshot_display + file recv -> local path
    Get-DshAppDataPath        on-device path of the app sandbox (haps/entry)

.NOTES
  * The source of this file is ASCII on purpose. Windows PowerShell 5.1 reads
    a .ps1 file that has no BOM as ANSI (GBK on this machine), which would
    mangle Chinese literals. Chinese that comes FROM the device is fine: the
    dump is read as UTF-8.
  * The dump is parsed with a regex, not ConvertFrom-Json: the dump is ~120 KB
    and ConvertFrom-Json needs ~4 s on PS 5.1 while the regex needs ~0.6 s.
    If the regex finds no attributes at all, we fall back to ConvertFrom-Json.

.EXAMPLE
  . "$PSScriptRoot\phone-probe.ps1"
  Connect-DshPhone
  $nodes = Wait-DshLayoutStable
  $nodes | Where-Object { $_.Text -like '*zidong*' } | Format-Table Type, Text, CenterX, CenterY

.EXAMPLE
  .\phone-probe.ps1 -Action stable -Filter 'zidong'
  The Chinese words of the app can be passed straight from the console (the
  console hands them over as Unicode, so they arrive intact). Copy them from
  the phone screen, for example the four characters of the "discover" button.
  .\phone-probe.ps1 -Action screenshot -Path D:\tmp\shot.jpeg
#>

param(
    [ValidateSet('wake', 'dump', 'stable', 'hilog', 'screenshot', 'prefs')]
    [string]$Action = 'dump',
    [string]$HdcPath,
    [string]$Target,
    [string]$Filter,
    [string]$Path,
    [int]$Lines = 60
)

Set-StrictMode -Version 2.0

# ---------------------------------------------------------------- constants --

$script:DshDefaultHdc = 'D:\APP\Devecostudio26\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
$script:DshDefaultTarget = '192.168.1.20:40663'
$script:DshBundle = 'com.example.dshsync'
$script:DshRemoteTmp = '/data/local/tmp'
$script:DshDumpSeq = 0
$script:DshShotSeq = 0
$script:DshResolvedTarget = ''

# ------------------------------------------------------------------- basics --

function Get-DshHdcPath {
    <#
    .SYNOPSIS
      Locate hdc.exe. Parameter wins, then $env:DSH_HDC, then the known path.
    #>
    param([string]$HdcPath)
    if ($HdcPath) { return $HdcPath }
    if ($env:DSH_HDC -and (Test-Path -LiteralPath $env:DSH_HDC)) { return $env:DSH_HDC }
    if (Test-Path -LiteralPath $script:DshDefaultHdc) { return $script:DshDefaultHdc }
    throw "hdc.exe not found. Pass -HdcPath or set `$env:DSH_HDC."
}

function Get-DshPhoneTarget {
    <#
    .SYNOPSIS
      Serial of the phone. Parameter wins, then the resolved one, then the env var.
    #>
    param([string]$Target)
    if ($Target) { return $Target }
    if ($script:DshResolvedTarget) { return $script:DshResolvedTarget }
    if ($env:DSH_PHONE_TARGET) { return $env:DSH_PHONE_TARGET }
    return $script:DshDefaultTarget
}

function Get-DshUsbTarget {
    <#
    .SYNOPSIS
      A USB attached device that has our app installed (empty when there is none).
    .DESCRIPTION
      Devices that look like "ip:port" (the emulator, the phone over WiFi) are
      skipped: only real USB serials are considered.
    #>
    param([string]$HdcPath, [string]$Bundle)
    if (-not $Bundle) { $Bundle = $script:DshBundle }
    $hdc = Get-DshHdcPath -HdcPath $HdcPath
    $devices = (& $hdc list targets 2>&1 | ForEach-Object { $_.ToString().Trim() }) | Where-Object { $_ }
    foreach ($d in $devices) {
        if ($d -match '^\d+\.\d+\.\d+\.\d+:\d+$') { continue }
        $out = (& $hdc -t $d shell "bm dump -n $Bundle 2>&1 | head -c 200" 2>&1 | ForEach-Object { $_.ToString() }) -join ''
        if ($out -match [regex]::Escape($Bundle)) { return $d }
    }
    return $null
}

function Invoke-DshHdc {
    <#
    .SYNOPSIS
      Run one hdc command against the phone and return its output as text.
    .DESCRIPTION
      $Arguments is passed to hdc as a list, so no quoting surprises.
      Output of stdout and stderr is merged; $LASTEXITCODE keeps hdc's code.
    #>
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$HdcPath,
        [string]$Target,
        [switch]$AllowFail
    )
    $hdc = Get-DshHdcPath -HdcPath $HdcPath
    if (-not $Target) { $Target = Get-DshPhoneTarget }
    $full = @()
    if ($Target) { $full += @('-t', $Target) }
    $full += $Arguments
    $out = & $hdc @full 2>&1
    $text = ($out | ForEach-Object { $_.ToString() }) -join "`n"
    if (-not $AllowFail -and $LASTEXITCODE -ne 0) {
        throw ("hdc {0} failed ({1}): {2}" -f ($Arguments -join ' '), $LASTEXITCODE, $text.Trim())
    }
    return $text
}

function Test-DshDevice {
    <#
    .SYNOPSIS
      Can we really talk to this device? (dump the layout and look at the file)
    #>
    param([string]$HdcPath, [string]$Device)
    if (-not $Device) { return $false }
    $remote = "$script:DshRemoteTmp/dsh_probe.json"
    Invoke-DshHdc -Arguments @('shell', "uitest dumpLayout -p $remote") -HdcPath $HdcPath -Target $Device -AllowFail | Out-Null
    $out = Invoke-DshHdc -Arguments @('shell', "ls $remote 2>/dev/null") -HdcPath $HdcPath -Target $Device -AllowFail
    Invoke-DshHdc -Arguments @('shell', "rm -f $remote") -HdcPath $HdcPath -Target $Device -AllowFail | Out-Null
    return ($out -match 'dsh_probe.json')
}

function Connect-DshPhone {
    <#
    .SYNOPSIS
      Make sure hdc can talk to the phone, and remember which device that is.
    .DESCRIPTION
      The phone can be reached over WiFi (192.168.1.20:40663) and over USB.
      The WiFi link now and then only half works, so every candidate is tested
      with a real dump and the first one that answers is used.
    #>
    param(
        [string]$HdcPath,
        [string]$Target,
        [int]$Attempts = 3
    )
    $hdc = Get-DshHdcPath -HdcPath $HdcPath
    $ser = Get-DshPhoneTarget -Target $Target

    for ($i = 1; $i -le $Attempts; $i++) {
        $targets = (& $hdc list targets 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
        if ($targets -match [regex]::Escape($ser)) {
            $script:DshResolvedTarget = $ser
            break
        }
        Write-Host "[probe] tconn $ser (attempt $i/$Attempts)"
        & $hdc tconn $ser 2>&1 | Out-Null
        Start-Sleep -Milliseconds 1200
    }

    # Candidates: the requested one, then the USB devices that have the app.
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($ser) { $candidates.Add($ser) }
    $usb = Get-DshUsbTarget -HdcPath $HdcPath
    if ($usb -and -not $candidates.Contains($usb)) { $candidates.Add($usb) }
    $script:DshCandidates = @($candidates)

    foreach ($c in $candidates) {
        if (Test-DshDevice -HdcPath $HdcPath -Device $c) {
            if ($c -ne $script:DshResolvedTarget) {
                Write-Host "[probe] using $c"
            }
            $script:DshResolvedTarget = $c
            return $c
        }
        Write-Host "[probe] $c does not answer, trying the next one"
    }

    $targets = (& $hdc list targets 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
    throw "no phone answers. hdc list targets said:`n$targets"
}

# ------------------------------------------------------------ screen state --

function Get-DshPowerState {
    <#
    .SYNOPSIS
      AWAKE or SUSPEND (from PowerManagerService).
    #>
    param([string]$HdcPath, [string]$Target)
    $text = Invoke-DshHdc -Arguments @('shell', 'hidumper -s PowerManagerService -a -s') -HdcPath $HdcPath -Target $Target -AllowFail
    if ($text -match 'Current State:\s*([A-Z_]+)') { return $Matches[1] }
    return 'UNKNOWN'
}

function Test-DshScreenOn {
    <#
    .SYNOPSIS
      True when the screen is on: uitest can only dump a layout of a lit screen.
    #>
    param([string]$HdcPath, [string]$Target)
    try {
        $null = Get-DshLayout -HdcPath $HdcPath -Target $Target
        return $true
    }
    catch {
        return $false
    }
}

function Wake-DshPhone {
    <#
    .SYNOPSIS
      Turn the screen on when it is off. Does nothing when the screen is already on.
    .DESCRIPTION
      The only key uitest accepts for that is "Power", and Power TOGGLES the
      screen, so the power state is checked first. On this phone the screen
      switches itself off after ~30 seconds, hence this runs before every
      script step.
    #>
    param([string]$HdcPath, [string]$Target, [int]$Attempts = 3)
    for ($i = 1; $i -le $Attempts; $i++) {
        $state = Get-DshPowerState -HdcPath $HdcPath -Target $Target
        if ($state -eq 'AWAKE') { return $true }
        if ($state -eq 'UNKNOWN') {
            # The power state cannot be read (some connections do not answer
            # hidumper). Ask the screen itself: if a dump works, it is on.
            if (Test-DshScreenOn -HdcPath $HdcPath -Target $Target) { return $true }
        }
        Write-Host "[probe] the screen is $state, waking it up"
        Invoke-DshHdc -Arguments @('shell', 'uitest uiInput keyEvent Power') -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
        Start-Sleep -Milliseconds 2500
    }
    return ((Get-DshPowerState -HdcPath $HdcPath -Target $Target) -eq 'AWAKE')
}

function Unlock-DshPhone {
    <#
    .SYNOPSIS
      Swipe up to leave the lock screen. This phone has no PIN, so a swipe is enough.
    #>
    param([string]$HdcPath, [string]$Target)
    Invoke-DshHdc -Arguments @('shell', 'uitest uiInput swipe 640 2400 640 500 300') -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
    Start-Sleep -Milliseconds 800
    return $true
}

# ------------------------------------------------------------------ layout --

function ConvertFrom-DshDump {
    <#
    .SYNOPSIS
      Parse the JSON of a uitest dumpLayout into node objects.
    .DESCRIPTION
      Each node becomes a PSCustomObject with Type, Text, Left, Top, Right,
      Bottom, CenterX, CenterY, Clickable, Focused, Visible, Enabled, Hash.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if (-not $raw -or $raw.Trim().Length -lt 10) {
        Write-Host '[probe] the dump file is empty'
        return @()
    }

    $attrRx = [regex]'"attributes":\{([^{}]*)\}'
    $fieldRx = [regex]'"([a-zA-Z]+)":"((?:[^"\\]|\\.)*)"'
    $boundsRx = [regex]'\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]'

    $nodes = New-Object System.Collections.Generic.List[object]
    $seen = $false
    foreach ($m in $attrRx.Matches($raw)) {
        $seen = $true
        $fields = @{}
        foreach ($f in $fieldRx.Matches($m.Groups[1].Value)) {
            $fields[$f.Groups[1].Value] = $f.Groups[2].Value
        }
        $text = ''
        if ($fields.ContainsKey('text')) {
            $text = $fields['text'] -replace '\\"', '"' -replace '\\\\', '\'
        }
        $left = 0; $top = 0; $right = 0; $bottom = 0
        if ($fields.ContainsKey('bounds')) {
            $b = $boundsRx.Match($fields['bounds'])
            if ($b.Success) {
                $left = [int]$b.Groups[1].Value
                $top = [int]$b.Groups[2].Value
                $right = [int]$b.Groups[3].Value
                $bottom = [int]$b.Groups[4].Value
            }
        }
        $type = ''
        if ($fields.ContainsKey('type')) { $type = $fields['type'] }
        $nodes.Add([pscustomobject]@{
                Type      = $type
                Text      = $text
                Left      = $left
                Top       = $top
                Right     = $right
                Bottom    = $bottom
                CenterX   = [int](($left + $right) / 2)
                CenterY   = [int](($top + $bottom) / 2)
                Clickable = ($fields['clickable'] -eq 'true')
                Focused   = ($fields['focused'] -eq 'true')
                Visible   = ($fields['visible'] -ne 'false')
                Enabled   = ($fields['enabled'] -ne 'false')
                Hash      = $fields['hashcode']
            })
    }

    if (-not $seen) {
        # The dump format changed: fall back to the slow but general parser.
        Write-Host '[probe] regex found no attributes, falling back to ConvertFrom-Json'
        $json = $raw | ConvertFrom-Json
        $stack = New-Object System.Collections.Stack
        $stack.Push($json)
        while ($stack.Count -gt 0) {
            $n = $stack.Pop()
            if ($null -eq $n) { continue }
            $a = $n.attributes
            if ($null -ne $a) {
                $text = ''
                if ($null -ne $a.text) { $text = [string]$a.text }
                $bounds = ''
                if ($null -ne $a.bounds) { $bounds = [string]$a.bounds }
                $b = $boundsRx.Match($bounds)
                $left = 0; $top = 0; $right = 0; $bottom = 0
                if ($b.Success) {
                    $left = [int]$b.Groups[1].Value
                    $top = [int]$b.Groups[2].Value
                    $right = [int]$b.Groups[3].Value
                    $bottom = [int]$b.Groups[4].Value
                }
                $type = ''
                if ($null -ne $a.type) { $type = [string]$a.type }
                $nodes.Add([pscustomobject]@{
                        Type      = $type
                        Text      = $text
                        Left      = $left
                        Top       = $top
                        Right     = $right
                        Bottom    = $bottom
                        CenterX   = [int](($left + $right) / 2)
                        CenterY   = [int](($top + $bottom) / 2)
                        Clickable = ([string]$a.clickable -eq 'true')
                        Focused   = ([string]$a.focused -eq 'true')
                        Visible   = ([string]$a.visible -ne 'false')
                        Enabled   = ([string]$a.enabled -ne 'false')
                        Hash      = [string]$a.hashcode
                    })
            }
            if ($null -ne $n.children) {
                foreach ($c in $n.children) { $stack.Push($c) }
            }
        }
    }
    return $nodes
}

function Enter-DshPhone {
    <#
    .SYNOPSIS
      Get the phone into a usable state: connected, screen on, lock screen gone.
    .DESCRIPTION
      The screen switches itself off after ~30 seconds, so every script run
      starts here. The lock screen is left by a swipe up; on this phone there
      is no PIN, so the swipe is enough. The swipe is only sent when the
      layout does not look like the app (that is how a locked screen is
      recognised: the app markers are missing).
    #>
    param(
        [string]$HdcPath,
        [string]$Target,
        [switch]$NoUnlock
    )
    Connect-DshPhone -HdcPath $HdcPath -Target $Target | Out-Null
    if (-not (Test-DshScreenOn -HdcPath $HdcPath -Target $Target)) {
        Wake-DshPhone -HdcPath $HdcPath -Target $Target | Out-Null
    }
    if ($NoUnlock) { return $true }
    $nodes = @()
    try {
        $nodes = Get-DshLayout -HdcPath $HdcPath -Target $Target
    }
    catch {
        # The screen was off and did not come back: try to wake it once more.
        Write-Host "[probe] dump failed ($($_.Exception.Message)), trying to wake the phone again"
        Wake-DshPhone -HdcPath $HdcPath -Target $Target -Attempts 3 | Out-Null
        Start-Sleep -Milliseconds 800
        $nodes = Get-DshLayout -HdcPath $HdcPath -Target $Target
    }
    if (-not (Test-DshAppVisible -Nodes $nodes)) {
        # Something is on top of the app: a locked screen or the shade that a
        # swipe opened. Close the shade with BACK first (BACK does nothing on
        # the lock screen), then swipe up for the lock screen.
        Write-Host '[probe] the app is not visible, closing what is on top of it'
        Invoke-DshHdc -Arguments @('shell', 'uitest uiInput keyEvent Back') -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
        Start-Sleep -Milliseconds 900
        $nodes = Get-DshLayout -HdcPath $HdcPath -Target $Target
        if (Test-DshLocked -Nodes $nodes) {
            Write-Host '[probe] the lock screen is in the way, swiping up'
            Unlock-DshPhone -HdcPath $HdcPath -Target $Target
            $nodes = Get-DshLayout -HdcPath $HdcPath -Target $Target
        }
        if (-not (Test-DshAppVisible -Nodes $nodes)) {
            Write-Host '[probe] still not visible, swiping up (lock screen?)'
            Unlock-DshPhone -HdcPath $HdcPath -Target $Target
            $nodes = Get-DshLayout -HdcPath $HdcPath -Target $Target
        }
    }
    if (Test-DshLocked -Nodes $nodes) {
        Write-Host '[probe] WARNING: the phone is locked (face or fingerprint). Unlock it once, then run again.'
    }
    if (-not (Test-DshAppVisible -Nodes $nodes)) {
        Write-Host '[probe] WARNING: the app still does not look visible, maybe the screen is locked'
    }
    return $true
}

function Test-DshLocked {
    <#
    .SYNOPSIS
      True when the lock screen is in front of everything else.
    .DESCRIPTION
      The phone locks itself, and on this phone the lock is a face or a
      fingerprint: a script cannot open it. So the tools have to know that
      state, say so, and wait for a person instead of tapping blindly.
      The markers are the lock screen's own words (do not disturb, calls and
      notifications are muted, not recognised - tap here to retry, enter the
      password), kept base64 so this file stays ASCII.
    #>
    param([Parameter(Mandatory = $true)]$Nodes)
    $blob = '5YWN5omT5omwfOadpeeUteWSjOmAmuefpeW3sumdmemfs3zmnKror4bliKvmiJDlip986L6T5YWl5a+G56CBfOivt+i+k+WFpeWvhueggQ=='
    $markers = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($blob)).Split('|')
    foreach ($n in $Nodes) {
        if (-not $n.Text) { continue }
        foreach ($m in $markers) {
            if ($n.Text.Contains($m)) { return $true }
        }
    }
    return $false
}

function Test-DshAppVisible {
    <#
    .SYNOPSIS
      True when the layout looks like our app (not the lock screen, not a launcher).
    .DESCRIPTION
      The markers are the app's own words: hui hua (session list title), lian jie
      (connect button), zhuo mian du di zhi (desktop address label), fang wen yin
      yong (token label), DSH (brand), gong zuo qu (workspace), xin hui hua (new
      session button). They are kept base64 encoded so this file stays pure ASCII
      and therefore readable by Windows PowerShell 5.1 without a BOM.
    #>
    param([Parameter(Mandatory = $true)]$Nodes)
    $blob = '5Lya6K+dfOi/nuaOpXzmoYzpnaLnq6/lnLDlnYB86K6/6Zeu5Luk54mMfERTSHzlt6XkvZzljLp85paw5Lya6K+d'
    $markers = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($blob)).Split('|')
    foreach ($n in $Nodes) {
        if (-not $n.Text) { continue }
        foreach ($m in $markers) {
            if ($n.Text.Contains($m)) { return $true }
        }
    }
    return $false
}

function Ensure-DshApp {
    <#
    .SYNOPSIS
      Make sure our app is the one on the screen, and return its layout.
    .DESCRIPTION
      The phone is often in use by a person, who walks away from the app. This
      starts the app again when it is not in front.
    #>
    param(
        [string]$HdcPath,
        [string]$Target,
        [string]$Bundle,
        [int]$Attempts = 2
    )
    if (-not $Bundle) { $Bundle = $script:DshBundle }
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            # The screen of an idle phone goes dark, and then nothing works.
            Enter-DshPhone -HdcPath $HdcPath -Target $Target | Out-Null
            $nodes = @(Get-DshLayout -HdcPath $HdcPath -Target $Target)
            if ($nodes.Count -gt 0 -and (Test-DshAppVisible -Nodes $nodes)) { return $nodes }
        }
        catch {
            # no layout yet: the wake inside Enter-DshPhone will fix it next round
        }
        Write-Host '[probe] starting the app'
        Invoke-DshHdc -Arguments @('shell', "aa start -a EntryAbility -b $Bundle") -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
        Start-Sleep -Seconds 3
    }
    return @(Get-DshLayout -HdcPath $HdcPath -Target $Target)
}

function Get-DshLayout {
    <#
    .SYNOPSIS
      One dumpLayout from the phone, parsed into node objects.
    #>
    param(
        [string]$HdcPath,
        [string]$Target,
        [switch]$KeepFile,
        [string]$LocalPath
    )
    $script:DshDumpSeq = $script:DshDumpSeq + 1
    $remote = "$script:DshRemoteTmp/dsh_layout_$($script:DshDumpSeq).json"
    if (-not $LocalPath) {
        $LocalPath = Join-Path ([System.IO.Path]::GetTempPath()) "dsh_layout_$($script:DshDumpSeq).json"
    }
    Invoke-DshHdc -Arguments @('shell', "uitest dumpLayout -p $remote") -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
    Invoke-DshHdc -Arguments @('file', 'recv', $remote, $LocalPath) -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
    if (-not (Test-Path -LiteralPath $LocalPath)) {
        throw "dumpLayout produced nothing (no $LocalPath). Is the screen on? Try -Action wake."
    }
    $nodes = ConvertFrom-DshDump -Path $LocalPath
    if (-not $KeepFile) {
        Remove-Item -LiteralPath $LocalPath -Force -ErrorAction SilentlyContinue
    }
    return $nodes
}

function Get-DshLayoutSignature {
    <#
    .SYNOPSIS
      Short hash of the STRUCTURE of a layout (types and places).
    .DESCRIPTION
      The text is left out on purpose: the app keeps a status line alive
      ("scanning...", "connection failed...") and that text changes all the
      time. The structure of the screen is what says "this is the same screen".
    #>
    param([Parameter(Mandatory = $true)]$Nodes)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($n in $Nodes) {
        $lines.Add("$($n.Type)|$($n.Left),$($n.Top),$($n.Right),$($n.Bottom)")
    }
    $text = ($lines -join "`n")
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $hash = $md5.ComputeHash($bytes)
    $md5.Dispose()
    return [System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, 16)
}

function Get-DshLayoutTextSignature {
    <#
    .SYNOPSIS
      Short hash of a layout WITH its texts. Used to see that a tap did
      something (a label changed), not only that the screen moved.
    #>
    param([Parameter(Mandatory = $true)]$Nodes)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($n in $Nodes) {
        $lines.Add("$($n.Type)|$($n.Text)|$($n.Left),$($n.Top),$($n.Right),$($n.Bottom)")
    }
    $text = ($lines -join "`n")
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $hash = $md5.ComputeHash($bytes)
    $md5.Dispose()
    return [System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, 16)
}

function Wait-DshLayoutStable {
    <#
    .SYNOPSIS
      Poll dumpLayout until the layout stops changing (N dumps in a row equal).
    .DESCRIPTION
      This is the fix for "dumpLayout gave me the previous screen": the layout
      is only trusted once two consecutive dumps are byte-for-byte the same.
    .PARAMETER StableCount
      How many identical dumps in a row are needed.
    .PARAMETER TimeoutSec
      Give up after this many seconds (returns the last dump anyway).
    #>
    param(
        [string]$HdcPath,
        [string]$Target,
        [int]$StableCount = 2,
        [int]$TimeoutSec = 20,
        [int]$IntervalMs = 700
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastSig = ''
    $stable = 0
    $nodes = @()
    while ((Get-Date) -lt $deadline) {
        try {
            $nodes = Get-DshLayout -HdcPath $HdcPath -Target $Target
        }
        catch {
            # The screen can go dark between two dumps. Wake it and try again.
            Write-Host "[probe] dump failed ($($_.Exception.Message)), waking the phone"
            Wake-DshPhone -HdcPath $HdcPath -Target $Target -Attempts 2 | Out-Null
            Start-Sleep -Milliseconds 800
            continue
        }
        $sig = Get-DshLayoutSignature -Nodes $nodes
        if ($sig -eq $lastSig) {
            $stable++
            if ($stable -ge ($StableCount - 1)) {
                Write-Host "[probe] layout stable ($sig)"
                return $nodes
            }
        }
        else {
            $stable = 0
        }
        $lastSig = $sig
        Start-Sleep -Milliseconds $IntervalMs
    }
    Write-Host "[probe] WARNING: layout did not settle within $TimeoutSec s, using the last dump"
    return $nodes
}

# ---------------------------------------------------------------- keyboard --

function Test-DshKeyboardOpen {
    <#
    .SYNOPSIS
      True when a text field has focus, i.e. the soft keyboard is probably up.
    #>
    param([Parameter(Mandatory = $true)]$Nodes)
    foreach ($n in $Nodes) {
        if ($n.Focused -and ($n.Type -eq 'TextInput' -or $n.Type -eq 'TextArea')) { return $true }
    }
    return $false
}

function Hide-DshKeyboard {
    <#
    .SYNOPSIS
      Close the soft keyboard, but only when it is really open.
    .DESCRIPTION
      A blind BACK press would navigate away from the current page, so the
      keyboard is only closed when a text field actually has the focus.
    #>
    param([string]$HdcPath, [string]$Target, $Nodes)
    if ($null -eq $Nodes) { $Nodes = Get-DshLayout -HdcPath $HdcPath -Target $Target }
    if (-not (Test-DshKeyboardOpen -Nodes $Nodes)) { return $false }
    Write-Host '[probe] hiding the soft keyboard'
    Invoke-DshHdc -Arguments @('shell', 'uitest uiInput keyEvent Back') -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
    Start-Sleep -Milliseconds 700
    return $true
}

# ------------------------------------------------------------------ search --

function Find-DshNode {
    <#
    .SYNOPSIS
      Find nodes by exact text, substring, type and/or index.
    .DESCRIPTION
      -Text      exact match (the whole text)
      -Contains  substring match
      -Type      node type, e.g. Button / Text / TextInput
      -Index     1-based pick when several nodes match (default 1)
    #>
    param(
        [Parameter(Mandatory = $true)]$Nodes,
        [string]$Text,
        [string]$Contains,
        [string]$Type,
        [int]$Index = 1,
        [switch]$All
    )
    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($n in $Nodes) {
        if ($Text -and $n.Text -ne $Text) { continue }
        if ($Contains -and -not $n.Text.Contains($Contains)) { continue }
        if ($Type -and $n.Type -ne $Type) { continue }
        $hits.Add($n)
    }
    if ($All) { return $hits }
    if ($hits.Count -eq 0) { return $null }
    if ($Index -lt 1) { $Index = 1 }
    if ($Index -gt $hits.Count) { return $null }
    return $hits[$Index - 1]
}

function Get-DshNodeTexts {
    <#
    .SYNOPSIS
      All visible texts of a layout (for error messages).
    #>
    param([Parameter(Mandatory = $true)]$Nodes, [int]$Limit = 40)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($n in $Nodes) {
        if ($n.Text -and $n.Visible) {
            $out.Add("$($n.Type):$($n.Text)")
            if ($out.Count -ge $Limit) { break }
        }
    }
    return $out
}

# ------------------------------------------------------------- log / shots --

function Get-DshHilog {
    <#
    .SYNOPSIS
      Tail of the device log (optionally filtered by a grep pattern).
    #>
    param(
        [string]$HdcPath,
        [string]$Target,
        [string]$Filter,
        [int]$Lines = 60
    )
    $cmd = 'hilog -x'
    if ($Filter) { $cmd = "hilog -x | grep '$Filter'" }
    $cmd = "$cmd | tail -n $Lines"
    return Invoke-DshHdc -Arguments @('shell', $cmd) -HdcPath $HdcPath -Target $Target -AllowFail
}

function Save-DshScreenshot {
    <#
    .SYNOPSIS
      Take a screenshot and pull it to the PC. Returns the local path.
    #>
    param(
        [string]$HdcPath,
        [string]$Target,
        [string]$Path
    )
    $script:DshShotSeq = $script:DshShotSeq + 1
    $remote = "$script:DshRemoteTmp/dsh_shot_$($script:DshShotSeq).jpeg"
    if (-not $Path) {
        $Path = Join-Path ([System.IO.Path]::GetTempPath()) "dsh_shot_$($script:DshShotSeq).jpeg"
    }
    Invoke-DshHdc -Arguments @('shell', "snapshot_display -f $remote") -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
    Invoke-DshHdc -Arguments @('file', 'recv', $remote, $Path) -HdcPath $HdcPath -Target $Target | Out-Null
    Invoke-DshHdc -Arguments @('shell', "rm -f $remote") -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
    Write-Host "[probe] screenshot -> $Path"
    return $Path
}

function Get-DshAppDataPath {
    <#
    .SYNOPSIS
      On-device path of the app sandbox root (haps/entry).
    #>
    param([string]$Bundle)
    if (-not $Bundle) { $Bundle = $script:DshBundle }
    return "/data/app/el2/100/base/$Bundle/haps/entry"
}

function Get-DshPreferencesText {
    <#
    .SYNOPSIS
      Content of an app preferences file (plain text), '' when unreadable.
    .DESCRIPTION
      Every connection to the phone is not equal: over WiFi the shell can read
      the app data, over USB it cannot. So all known devices are tried.
    #>
    param(
        [string]$HdcPath,
        [string]$Target,
        [string]$Name = 'dsh_harmony_bridge',
        [string]$Bundle
    )
    $path = "$(Get-DshAppDataPath -Bundle $Bundle)/preferences/$Name"
    $devices = @()
    if ($Target) { $devices += $Target }
    foreach ($c in $script:DshCandidates) { if ($devices -notcontains $c) { $devices += $c } }
    foreach ($d in $devices) {
        $text = Invoke-DshHdc -Arguments @('shell', "cat '$path' 2>/dev/null") -HdcPath $HdcPath -Target $d -AllowFail
        if ($text) { return $text.Trim() }
    }
    return ''
}

# -------------------------------------------------------------------- CLI ---

function Invoke-DshProbeCli {
    param(
        [string]$Action = 'dump',
        [string]$HdcPath,
        [string]$Target,
        [string]$Filter,
        [string]$Path,
        [int]$Lines = 60
    )
    switch ($Action) {
        'wake' {
            Connect-DshPhone -HdcPath $HdcPath -Target $Target | Out-Null
            Wake-DshPhone -HdcPath $HdcPath -Target $Target
            Unlock-DshPhone -HdcPath $HdcPath -Target $Target
            'awake'
        }
        'dump' {
            Enter-DshPhone -HdcPath $HdcPath -Target $Target | Out-Null
            $nodes = Wait-DshLayoutStable -HdcPath $HdcPath -Target $Target
            foreach ($n in $nodes) {
                if (-not $n.Text) { continue }
                if ($Filter -and -not $n.Text.Contains($Filter)) { continue }
                "$($n.Type)`t$($n.Text)`t$($n.CenterX)`t$($n.CenterY)`t$($n.Right)`t$($n.Bottom)"
            }
        }
        'stable' {
            Enter-DshPhone -HdcPath $HdcPath -Target $Target | Out-Null
            $nodes = Wait-DshLayoutStable -HdcPath $HdcPath -Target $Target
            "nodes=$($nodes.Count) signature=$(Get-DshLayoutSignature -Nodes $nodes)"
        }
        'hilog' {
            Connect-DshPhone -HdcPath $HdcPath -Target $Target | Out-Null
            Get-DshHilog -HdcPath $HdcPath -Target $Target -Filter $Filter -Lines $Lines
        }
        'screenshot' {
            Connect-DshPhone -HdcPath $HdcPath -Target $Target | Out-Null
            Save-DshScreenshot -HdcPath $HdcPath -Target $Target -Path $Path
        }
        'prefs' {
            Connect-DshPhone -HdcPath $HdcPath -Target $Target | Out-Null
            Get-DshPreferencesText -HdcPath $HdcPath -Target $Target
        }
        default {
            throw "unknown action '$Action'. Use wake|dump|stable|hilog|screenshot|prefs."
        }
    }
}

# Run the CLI only when this file is executed, not when it is dot-sourced.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-DshProbeCli -Action $Action -HdcPath $HdcPath -Target $Target -Filter $Filter -Path $Path -Lines $Lines
    }
    catch {
        Write-Error $_
        exit 1
    }
}
