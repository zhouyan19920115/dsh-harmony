<#
.SYNOPSIS
  Drive the DSH HarmonyOS app (com.dsh.harmony) on the local DevEco HarmonyOS emulator.

.DESCRIPTION
  Helper used to install, launch, drive and screenshot the already-built HAP.
  It does NOT modify any ArkTS source and does NOT touch bridge/.

  Verified environment (2026-10-22):
    hdc        : D:\APP\Devecostudio26\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe
    emulator   : D:\APP\Devecostudio26\DevEco Studio\tools\emulator\Emulator.exe
    hap        : D:\APP\Deepseek\DSHHarmony\harmony\entry\build\default\outputs\default\entry-default-unsigned.hap
    node       : D:\APP\Devecostudio26\DevEco Studio\tools\node\node.exe

  Emulator facts:
    - "Mate 90 Pro" instance was ALREADY RUNNING as 127.0.0.1:5555
    - image HarmonyOS 7.0.0 (26.0.0), os.apiVersion 26.0.0  -> satisfies compatibleSdkVersion 26
    - The UNSIGNED HAP installs fine on this image (no re-signing needed).

  IMPORTANT networking fact:
    The emulator is a QEMU guest with ip 10.0.2.15. 127.0.0.1 inside the emulator is the
    EMULATOR ITSELF, not the host PC. Use 10.0.2.2 (QEMU host alias) to reach a bridge
    running on the host. 10.0.2.2 and the host LAN IP (e.g. 192.168.1.10) are both routable.

.EXAMPLE
  .\harmony-emulator-drive.ps1 -Action status
  .\harmony-emulator-drive.ps1 -Action install
  .\harmony-emulator-drive.ps1 -Action launch
  .\harmony-emulator-drive.ps1 -Action shot -Name my-screenshot
  .\harmony-emulator-drive.ps1 -Action tap -X 344 -Y 1657
  .\harmony-emulator-drive.ps1 -Action type -Text "10.0.2.2"
  .\harmony-emulator-drive.ps1 -Action dumpLayout
#>
[CmdletBinding()]
param(
  [ValidateSet('status', 'install', 'uninstall', 'launch', 'stop', 'shot', 'tap', 'type', 'clear', 'dumpLayout', 'log')]
  [string]$Action = 'status',

  [string]$Name   = 'shot',
  [int]    $X     = 0,
  [int]    $Y     = 0,
  [string]$Text   = '',
  [int]    $Count = 12,
  [string]$Bundle = 'com.dsh.harmony'
)

$ErrorActionPreference = 'Stop'

$DevEco   = 'D:\APP\Devecostudio26\DevEco Studio'
$Hdc      = Join-Path $DevEco 'sdk\default\openharmony\toolchains\hdc.exe'
$Emulator = Join-Path $DevEco 'tools\emulator\Emulator.exe'
$Hap      = 'D:\APP\Deepseek\DSHHarmony\harmony\entry\build\default\outputs\default\entry-default-unsigned.hap'
$OutDir   = 'D:\APP\Deepseek\DSHHarmony\docs\screenshots'
$WorkDir  = 'D:\APP\Deepseek\DSHHarmony\tools'

# HarmonyOS key code for the Delete/Backspace key.
$KeyCodeDel = 2055

function Invoke-Hdc {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
  & $Hdc @Args
}

function Test-Target {
  $targets = & $Hdc list targets 2>$null
  return [bool]($targets -match '\S')
}

function Wait-Target {
  param([int]$TimeoutSec = 180)
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (Test-Target) { return $true }
    Start-Sleep -Seconds 2
  }
  return $false
}

function Get-Layout {
  # Dumps the UI tree and returns the parsed JSON.
  $remote = '/data/local/tmp/dsh-layout.json'
  $local  = Join-Path $WorkDir 'dsh-layout.json'
  & $Hdc shell "uitest dumpLayout -p $remote" | Out-Null
  & $Hdc file recv $remote $local | Out-Null
  if (-not (Test-Path $local)) { return $null }
  return (Get-Content $local -Raw -Encoding utf8 | ConvertFrom-Json)
}

function Show-Elements {
  param($Node)
  if ($null -eq $Node) { return }
  $a = $Node.attributes
  if ($a.type -in @('TextInput', 'Button') -or ($a.type -eq 'Text' -and $a.text)) {
    [pscustomobject]@{ Type = $a.type; Text = $a.text; Bounds = $a.bounds; Focused = $a.focused }
  }
  if ($Node.children) { foreach ($c in $Node.children) { Show-Elements $c } }
}

function Save-Screenshot {
  param([string]$BaseName)
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  $remote = '/data/local/tmp/dsh-shot.jpeg'
  $local  = Join-Path $OutDir "$BaseName.jpeg"
  & $Hdc shell "snapshot_display -f $remote" | Out-Null
  & $Hdc file recv $remote $local | Out-Null
  Write-Output "screenshot -> $local"
  return $local
}

switch ($Action) {

  'status' {
    Write-Output '--- hdc targets ---'
    & $Hdc list targets
    Write-Output '--- device info ---'
    & $Hdc shell 'param get const.product.software.version'
    & $Hdc shell 'param get const.ohos.apiversion'
    & $Hdc shell 'param get const.product.model'
    Write-Output '--- emulator instances ---'
    & $Emulator -list -details
  }

  'install' {
    if (-not (Test-Target)) {
      Write-Output 'no target; starting emulator "Mate 90 Pro" ...'
      Start-Process -FilePath $Emulator -ArgumentList '-start', 'Mate 90 Pro' -WindowStyle Hidden
      if (-not (Wait-Target)) { throw 'emulator did not appear in hdc list targets' }
    }
    & $Hdc install $Hap
  }

  'uninstall' { & $Hdc uninstall $Bundle }

  'launch' {
    & $Hdc shell "aa start -a EntryAbility -b $Bundle"
    Start-Sleep -Seconds 2
  }

  'stop' { & $Hdc shell "aa force-stop $Bundle" }

  'shot' { Save-Screenshot -BaseName $Name | Out-Null }

  'tap' {
    & $Hdc shell "uitest uiInput click $X $Y"
    Start-Sleep -Milliseconds 800
  }

  'type' {
    # Types into whatever TextInput currently holds focus.
    & $Hdc shell "uitest uiInput text $Text"
    Start-Sleep -Milliseconds 800
  }

  'clear' {
    # Sends $Count backspaces to the focused field.
    for ($i = 0; $i -lt $Count; $i++) { & $Hdc shell "uitest uiInput keyEvent $KeyCodeDel" | Out-Null }
    Start-Sleep -Milliseconds 400
  }

  'dumpLayout' {
    $json = Get-Layout
    Show-Elements $json | Format-Table -AutoSize | Out-String | Write-Output
  }

  'log' {
    & $Hdc shell "hilog -x | grep -i dsh | tail -100"
  }
}
