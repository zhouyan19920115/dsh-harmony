<#
.SYNOPSIS
  Tap a control on the HarmonyOS phone by its text, instead of by hand.

.DESCRIPTION
  Tapping by coordinates is the thing that keeps going wrong: the layout moves,
  the soft keyboard pushes the button off the screen, and a blind BACK press
  navigates away. This script taps by NAME and takes the coordinates from a
  fresh, settled layout right before the tap.

  What it handles:
    * the soft keyboard is open -> it is closed first (only when a text field
      really has the focus, so BACK never navigates away by accident)
    * the layout changed since the last dump -> the layout is dumped again and
      the coordinates are computed again
    * the same text appears several times -> -Index picks the n-th one
    * the tap did not do anything -> it is retried (new dump, new coordinates),
      up to -Attempts times
    * every tap prints the target and the coordinates BEFORE it happens

.EXAMPLE
  .\ui-tap.ps1 -Text 'zidong-tance'
  Taps the first node whose text is exactly 'zidong-tance'. The Chinese words of
  the app can be typed straight into the console (the console hands them over
  as Unicode, so they arrive intact) - copy them from the phone screen.

.EXAMPLE
  .\ui-tap.ps1 -Contains 'hui hua' -Index 2
  Taps the second node whose text contains 'hui hua'.

.EXAMPLE
  .\ui-tap.ps1 -Text 'lian jie' -Type Button -Attempts 5
  Only looks at buttons, and retries five times.

.NOTES
  The source of this file is ASCII on purpose. Windows PowerShell 5.1 reads a
  .ps1 file without BOM as ANSI (GBK on this machine) and would mangle Chinese
  literals. Chinese text that comes FROM the phone is fine: the dump is read
  as UTF-8. The -Text / -Contains arguments are passed by the caller and are
  therefore not affected by this either.
#>

param(
    # Exact text of the control to tap.
    [string]$Text,
    # Substring of the control to tap (use this when you only know part of it).
    [string]$Contains,
    # Only look at controls of this type, e.g. Button, Text, TextInput.
    [string]$Type,
    # Which one to take when several controls match (1 based).
    [int]$Index = 1,
    # How many times a tap may be retried when nothing happened.
    [int]$Attempts = 3,
    # Do not close the soft keyboard first.
    [switch]$NoKeyboardDismiss,
    # Print the nodes of the screen instead of tapping.
    [switch]$List,
    # Seconds to wait after the tap.
    [int]$SettleMs = 900,
    [string]$HdcPath,
    [string]$Target
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'phone-probe.ps1')

function Show-DshNodeList {
    param($Nodes, [string]$Filter, [int]$Limit = 40)
    $shown = 0
    foreach ($n in $Nodes) {
        if (-not $n.Text) { continue }
        if ($Filter -and -not $n.Text.Contains($Filter)) { continue }
        Write-Host ("  {0,-9} {1}  @({2},{3})  [{4},{5}][{6},{7}]" -f $n.Type, $n.Text, $n.CenterX, $n.CenterY, $n.Left, $n.Top, $n.Right, $n.Bottom)
        $shown++
        if ($shown -ge $Limit) { break }
    }
    if ($shown -eq 0) { Write-Host '  (nothing matched)' }
}

try {
    Enter-DshPhone -HdcPath $HdcPath -Target $Target | Out-Null
    $nodes = Wait-DshLayoutStable -HdcPath $HdcPath -Target $Target

    if (Test-DshLocked -Nodes $nodes) {
        throw 'the phone is locked (face or fingerprint). Unlock it once, then run this again.'
    }

    if ($List) {
        Write-Host '--- nodes on screen ---'
        Show-DshNodeList -Nodes $nodes -Filter $Contains
        exit 0
    }

    if (-not $Text -and -not $Contains) {
        Write-Host '--- nodes on screen ---'
        Show-DshNodeList -Nodes $nodes
        throw 'give me -Text (exact) or -Contains (substring) to tap'
    }

    $tap = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if (-not $NoKeyboardDismiss) {
            $hidden = Hide-DshKeyboard -HdcPath $HdcPath -Target $Target -Nodes $nodes
            if ($hidden) {
                $nodes = Wait-DshLayoutStable -HdcPath $HdcPath -Target $Target
            }
        }

        $tap = Find-DshNode -Nodes $nodes -Text $Text -Contains $Contains -Type $Type -Index $Index
        if ($null -eq $tap) {
            Write-Host "[tap] attempt $attempt/$Attempts : no match for (text='$Text' contains='$Contains' type='$Type' index=$Index)"
            Write-Host '--- what is on screen ---'
            Show-DshNodeList -Nodes $nodes -Filter $Contains
            Start-Sleep -Milliseconds 600
            $nodes = Wait-DshLayoutStable -HdcPath $HdcPath -Target $Target
            continue
        }

        $before = Get-DshLayoutTextSignature -Nodes $nodes
        Write-Host ("[tap] target: {0} '{1}' at ({2},{3})  [{4},{5}][{6},{7}]  attempt {8}/{9}" -f `
                $tap.Type, $tap.Text, $tap.CenterX, $tap.CenterY, $tap.Left, $tap.Top, $tap.Right, $tap.Bottom, $attempt, $Attempts)

        Invoke-DshHdc -Arguments @('shell', "uitest uiInput click $($tap.CenterX) $($tap.CenterY)") -HdcPath $HdcPath -Target $Target -AllowFail | Out-Null
        Start-Sleep -Milliseconds $SettleMs

        # Did anything happen? If the screen looks exactly the same, the tap
        # probably missed (the layout moved) -> dump again and try again.
        $after = Wait-DshLayoutStable -HdcPath $HdcPath -Target $Target
        $afterSig = Get-DshLayoutTextSignature -Nodes $after
        if ($afterSig -ne $before) {
            Write-Host "[tap] done: the screen changed"
            $nodes = $after
            exit 0
        }
        Write-Host "[tap] attempt $attempt/$Attempts : the screen did not change, retrying"
        $nodes = $after
    }

    throw "could not tap (text='$Text' contains='$Contains' type='$Type' index=$Index) after $Attempts attempts"
}
catch {
    Write-Error $_
    exit 1
}
