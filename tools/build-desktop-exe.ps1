# Builds the single-file Windows executables of the desktop side.
#
#   tools\build-desktop-exe.ps1                 -> dist\dsh-harmony-bridge.exe + dist\dsh-harmony-relay.exe
#   tools\build-desktop-exe.ps1 -NoCompress     -> the same, without the gzip compression
#   tools\build-desktop-exe.ps1 -Target node24-win-x64
#   tools\build-desktop-exe.ps1 -Only bridge    -> just the bridge
#
# The point of this file: a user who has nothing installed can unzip the package and double
# click the exe. No Node.js, no npm, no PATH.
#
# It needs the packaging tool "pkg". The original pkg (5.8.1) only knows CommonJS and Node 18,
# and this project is ESM and needs the zstd APIs of Node 22+, so the maintained fork is used:
#
#   npm i -g @yao-pkg/pkg
#
# Two executables are built:
#   dsh-harmony-bridge.exe  the LAN bridge the phone talks to
#   dsh-harmony-relay.exe   the cloud relay (only needed for access from outside the WiFi)
#
[CmdletBinding()]
param(
  # Not called $Target: PowerShell treats variable names case-insensitively, and the loop
  # variable of the build loop would overwrite it.
  [string]$NodeTarget = 'node22-win-x64',
  [switch]$NoCompress,
  # Not called $Output: PowerShell treats that name case-insensitively as the automatic
  # $Output variable, and assigning to it breaks the script.
  [string]$ExePath = '',
  [ValidateSet('bridge', 'relay', 'both')]
  [string]$Only = 'both'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if ($ExePath -eq '') { $ExePath = Join-Path $root 'dist\dsh-harmony-bridge.exe' }
$dist = Split-Path -Parent $ExePath
New-Item -ItemType Directory -Force -Path $dist | Out-Null

Write-Host 'DSH Harmony - building the standalone executable' -ForegroundColor Cyan
Write-Host '===================================================='
Write-Host ''

# ------------------------------------------------------------------ the tool
$pkg = Get-Command pkg -ErrorAction SilentlyContinue
if ($null -eq $pkg) {
  Write-Host '  [!] The packaging tool "pkg" is not installed.' -ForegroundColor Yellow
  Write-Host ''
  Write-Host '      Install it once with:'
  Write-Host '        npm i -g @yao-pkg/pkg'
  Write-Host ''
  Write-Host '      (The maintained fork is required: the original pkg 5.8.1 only supports'
  Write-Host '       CommonJS and Node 18, this project is ESM and needs Node 22+ for zstd.)'
  Write-Host ''
  exit 2
}
$pkgVersion = (& pkg --version 2>$null)
Write-Host "  [1/4] packaging tool: pkg $pkgVersion"

# ------------------------------------------------------------------ the inputs
$targets = @()
if ($Only -eq 'bridge' -or $Only -eq 'both') {
  $targets += @{ Name = 'dsh-harmony-bridge.exe'; Entry = 'bridge\src\cli.js' }
}
if ($Only -eq 'relay' -or $Only -eq 'both') {
  $targets += @{ Name = 'dsh-harmony-relay.exe'; Entry = 'relay\src\cli.js' }
}
foreach ($target in $targets) {
  if (-not (Test-Path (Join-Path $root $target.Entry))) {
    Write-Host "  [!] $($target.Entry) not found." -ForegroundColor Yellow
    exit 2
  }
}
Write-Host "  [2/4] entry points   : $(($targets | ForEach-Object { $_.Entry }) -join ', ')"

# ------------------------------------------------------------------ the builds
$compress = -not $NoCompress
Write-Host '  [3/4] building ...'
foreach ($item in $targets) {
  $out = Join-Path $dist $item.Name
  $pkgArgs = @((Join-Path $root $item.Entry), '--targets', $NodeTarget, '--output', $out)
  if ($compress) { $pkgArgs += @('--compress', 'GZip') }
  Write-Host "        pkg $($item.Entry) -> $($item.Name)"
  & pkg @pkgArgs
  if ($LASTEXITCODE -ne 0) {
    Write-Host "  [!] pkg failed for $($item.Entry)." -ForegroundColor Red
    exit 1
  }
}

# ------------------------------------------------------------------ the proof
# The hard requirement: the exe must run on a machine without Node.js. So the check runs with
# a PATH that contains no node.exe at all.
Write-Host '  [4/4] verifying: running every exe with an empty PATH ...'
$oldPath = $env:Path
try {
  $env:Path = "$env:SystemRoot\System32;$env:SystemRoot"
  foreach ($item in $targets) {
    $exe = Join-Path $dist $item.Name
    $helpText = & $exe --help 2>&1 | Out-String
    $code = $LASTEXITCODE
    $expected = if ($item.Name -like '*bridge*') { 'Usage: dsh-harmony-bridge' } else { 'Usage: dsh-harmony-relay' }
    if ($code -ne 0 -or $helpText -notmatch [regex]::Escape($expected)) {
      Write-Host "  [!] $($item.Name) did not print its usage without Node.js in the PATH." -ForegroundColor Red
      Write-Host $helpText
      exit 1
    }
    $size = [math]::Round((Get-Item $exe).Length / 1MB, 1)
    Write-Host "        ok: $($item.Name) ($size MB)"
  }
} finally {
  $env:Path = $oldPath
}

Write-Host ''
Write-Host '  done.' -ForegroundColor Green
Write-Host '  The executables carry their own Node.js runtime: the user needs nothing installed.'
Write-Host ''
Write-Host '  Next: tools\package-desktop.ps1 puts them into the zip for the phone app.'
