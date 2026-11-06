# Package the desktop side into one zip so the phone app can hand it to any computer.
#   powershell -ExecutionPolicy Bypass -File tools\package-desktop.ps1
#
# Two packages are produced:
#   dsh-harmony-desktop.zip      the sources, ~170 KB, the user needs Node.js 20+
#   dsh-harmony-desktop-exe.zip  the single file executables, the user needs nothing
#
# Both unpack into one folder ("DSH-Harmony-Desktop") with the same layout, so the user
# always does the same thing: double click the start script in it.
#
# The exe package is skipped with a hint when the executables have not been built yet
# (tools\build-desktop-exe.ps1), so this script never fails because of a missing exe.
#
# NOTE: this file is UTF-8 WITH a BOM, because it contains Chinese file names. A .ps1 without
# the BOM would be read as the system code page by PowerShell 5.1 and the names would break.
param(
  [string]$Out = "$PSScriptRoot\..\harmony\entry\src\main\resources\rawfile\dsh-harmony-desktop.zip",
  [string]$ExeOut = "$PSScriptRoot\..\harmony\deploy\dsh-harmony-desktop-exe.zip"
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..").Path
$out = [System.IO.Path]::GetFullPath($Out)
$exeOut = [System.IO.Path]::GetFullPath($ExeOut)

# The exe package is 42 MB. It must NOT go into the HAP: the app would carry 42 MB that
# nobody reads at startup (the phone hands over the *source* package, a few hundred KB), and
# .gitignore says so too. It belongs in harmony\deploy\ (the relay serves it from there).
# The default used to point into rawfile, which is how the HAP silently grew to 45 MB.
$rawfile = [System.IO.Path]::GetFullPath((Join-Path $root 'harmony\entry\src\main\resources\rawfile'))
if ($exeOut.StartsWith($rawfile + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw ("the exe package must not go into the rawfile ($exeOut) —— it would make the HAP 42 MB bigger.`n" +
         "  Put it in harmony\deploy\ instead (that is where the relay serves it from).")
}

# The name the user clicks. The batch file itself stays pure ASCII (cmd.exe breaks on Chinese
# text inside a batch file), only its name is Chinese.
$FolderName = 'DSH-Harmony-桌面端'
$StartName = '双击我-开始.cmd'

# A credential of this machine must never end up in the package: the account registry, the device
# registry, the bridge state (it holds the token), every push token file and every private key.
function Test-SecretName([string]$name) {
  $leaf = [System.IO.Path]::GetFileName($name)
  if ([string]::IsNullOrEmpty($leaf)) { return $false }
  if ($leaf -match '^(accounts|devices|bridge|credentials)\.json$') { return $true }
  if ($leaf -like '*.local.json') { return $true }
  if ($leaf -match '(?i)token') { return $true }
  if ($leaf -match '(?i)\.(pem|key|p12|pfx|jks|keystore)$') { return $true }
  if ($leaf -match '(?i)^\.env(\..+)?$') { return $true }
  return $false
}

function New-Stage {
  $stage = Join-Path ([System.IO.Path]::GetTempPath()) ("dsh-desktop-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $stage -Force | Out-Null
  # Everything lands in one folder, so the zip unpacks into a single directory.
  $package = Join-Path $stage $FolderName
  New-Item -ItemType Directory -Path $package -Force | Out-Null
  return $package
}
function Copy-Tree([string]$from, [string]$to) {
  if (-not (Test-Path $from)) { Write-Host "  skip (missing): $from"; return }
  New-Item -ItemType Directory -Path $to -Force | Out-Null
  $files = Get-ChildItem $from -Recurse -File | Where-Object {
    $_.FullName -notmatch '\\node_modules\\' -and $_.Extension -notin @('.log', '.jpeg', '.jpg', '.png')
  }
  $skipped = @()
  foreach ($f in $files) {
    # A credential of this machine never goes into the package.
    if (Test-SecretName $f.Name) { $skipped += $f.FullName; continue }
    $rel = $f.FullName.Substring($from.Length).TrimStart('\')
    $target = Join-Path $to $rel
    $dir = Split-Path $target
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item $f.FullName $target -Force
  }
  foreach ($item in $skipped) { Write-Host "  skipped (secret): $item" }
  Write-Host "  copied $($files.Count - $skipped.Count) files -> $(Split-Path $to -Leaf)"
}
function Copy-Launchers([string]$package) {
  # The launcher the user clicks. tools\desktop-start.cmd is the canonical one; the older
  # tools\start-desktop.cmd is used when it is the only one there.
  $start = Join-Path $root "tools\desktop-start.cmd"
  if (-not (Test-Path $start)) { $start = Join-Path $root "tools\start-desktop.cmd" }
  if (Test-Path $start) {
    # The batch file MUST have CRLF line endings: cmd.exe re-reads the file after `chcp` and
    # computes the offset in bytes, so a LF-only file makes it read the wrong tokens (the
    # arguments end up shifted - `--port 8899` ends up as %0). Any tool that rewrites the
    # file may normalize the endings, so they are put back here, right before the file goes
    # into the package ✓
    $launcherText = [System.IO.File]::ReadAllText($start)
    $launcherText = $launcherText -replace "`r`n", "`n"
    $launcherText = $launcherText -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $package $StartName), $launcherText, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  copied $StartName (CRLF)"
  }
  $installer = Join-Path $root "tools\install-desktop.ps1"
  if (Test-Path $installer) { Copy-Item $installer (Join-Path $package "install-desktop.ps1") -Force }
  Copy-Item (Join-Path $root "tools\desktop-README.txt") (Join-Path $package "README.txt") -Force
}
function Compress-Zip([string]$package, [string]$destination) {
  New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
  if (Test-Path $destination) { Remove-Item $destination -Force }
  # The folder itself is the entry, so the zip unpacks into "DSH-Harmony-Desktop\...".
  # (A wildcard path would archive the contents without the folder.)
  #
  # The entries are written by hand, with **forward slashes**. `Compress-Archive` writes the
  # entry names with Windows separators, and Windows happily unpacks that back again -- so the
  # defect is invisible on the machine that built the package. On macOS/Linux the same zip
  # unpacks into a flat pile of files instead of the folder tree, which breaks the very
  # "send the package to the computer" flow this file exists for. Same trap as the project
  # backup zip (see tools/backup-project.ps1).
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
  $base = (Split-Path $package -Parent).TrimEnd('\')
  $prefix = Split-Path $package -Leaf
  $fileStream = [System.IO.File]::Open($destination, [System.IO.FileMode]::Create)
  try {
    $archive = New-Object System.IO.Compression.ZipArchive($fileStream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
      foreach ($file in (Get-ChildItem $package -Recurse -File | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($package.Length + 1).Replace('\', '/')
        $entry = $archive.CreateEntry("$prefix/$relative", [System.IO.Compression.CompressionLevel]::Optimal)
        $entryStream = $entry.Open()
        try {
          $input = [System.IO.File]::OpenRead($file.FullName)
          try { $input.CopyTo($entryStream) } finally { $input.Dispose() }
        } finally { $entryStream.Dispose() }
      }
    } finally { $archive.Dispose() }
  } finally { $fileStream.Dispose() }
  $size = [math]::Round((Get-Item $destination).Length / 1KB, 1)
  Write-Host "  done: $destination ($size KB)"
}

# The package is handed to other people, so it must never carry a credential of this machine.
# The account registry, the device registry, the bridge state (it holds the token) and every
# private key are refused: the packaging fails and the zip is deleted.
function Assert-NoSecrets([string]$zip) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
  $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
  $bad = New-Object System.Collections.Generic.List[string]
  try {
    foreach ($entry in $archive.Entries) {
      $leaf = [System.IO.Path]::GetFileName($entry.FullName)
      if ([string]::IsNullOrEmpty($leaf)) { continue }
      if (Test-SecretName $leaf) { $bad.Add($entry.FullName) }
    }
  } finally {
    $archive.Dispose()
  }
  if ($bad.Count -gt 0) {
    Write-Host ""
    Write-Host "  SELF CHECK FAILED — the package carries secrets:" -ForegroundColor Red
    foreach ($item in $bad) { Write-Host "    $item" -ForegroundColor Red }
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Write-Host "  the zip was deleted. Add the file to .gitignore and to the copy filter." -ForegroundColor Red
    exit 1
  }
  Write-Host "  self check ok: no account registry, no device registry, no token file, no private key"
}

# ------------------------------------------------------------------ the sources
Write-Host "[1/4] bridge ..."
$stage = New-Stage
Copy-Tree (Join-Path $root "bridge") (Join-Path $stage "bridge")
Write-Host "[2/4] relay ..."
Copy-Tree (Join-Path $root "relay") (Join-Path $stage "relay")
Write-Host "[3/4] launcher scripts ..."
Copy-Launchers $stage
Write-Host "[4/4] zip (sources, needs Node.js) ..."
Compress-Zip $stage $out
Assert-NoSecrets $out
Remove-Item (Split-Path $stage -Parent) -Recurse -Force

# ------------------------------------------------------------------ the executables
Write-Host ""
Write-Host "standalone executables ..."
$bridgeExe = [System.IO.Path]::GetFullPath((Join-Path $root "dist\dsh-harmony-bridge.exe"))
$relayExe = [System.IO.Path]::GetFullPath((Join-Path $root "dist\dsh-harmony-relay.exe"))
if (-not (Test-Path $bridgeExe)) {
  Write-Host "  skip: $bridgeExe not found."
  Write-Host "        Build it first:  powershell -ExecutionPolicy Bypass -File tools\build-desktop-exe.ps1"
  Write-Host "        (the sources package above is complete and works with Node.js 20+)"
  exit 0
}

$stage = New-Stage
# The executables go next to the launcher, in the root of the package.
Copy-Item $bridgeExe (Join-Path $stage "dsh-harmony-bridge.exe") -Force
Write-Host "  copied dsh-harmony-bridge.exe ($([math]::Round((Get-Item $bridgeExe).Length / 1MB, 1)) MB)"
if (Test-Path $relayExe) {
  Copy-Item $relayExe (Join-Path $stage "dsh-harmony-relay.exe") -Force
  Write-Host "  copied dsh-harmony-relay.exe ($([math]::Round((Get-Item $relayExe).Length / 1MB, 1)) MB)"
} else {
  Write-Host "  skip: dsh-harmony-relay.exe not found (the cloud relay needs Node.js then)."
}

# The store scanner runs in a thread of its own, so the executable needs its sources on disk:
# inside the snapshot a thread cannot be started. The bridge looks for them next to the
# executable (worker\scan-worker.js) and falls back to a chunked scan if they are missing.
$workerStage = Join-Path $stage "worker"
New-Item -ItemType Directory -Path $workerStage -Force | Out-Null
foreach ($workerFile in @("scan-worker.js", "store.js", "config.js", "protocol.js")) {
  $workerSource = Join-Path $root "bridge\src\$workerFile"
  if (Test-Path $workerSource) {
    Copy-Item $workerSource (Join-Path $workerStage $workerFile) -Force
  }
}
Write-Host "  copied the store scanner (worker\scan-worker.js)"

Copy-Launchers $stage
Compress-Zip $stage $exeOut
Assert-NoSecrets $exeOut
Remove-Item (Split-Path $stage -Parent) -Recurse -Force
Write-Host ""
Write-Host "the exe package needs nothing installed; the sources package needs Node.js 20+."
