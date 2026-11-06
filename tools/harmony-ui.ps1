<#
.SYNOPSIS
  Robust UI-driving helpers for the DSH HarmonyOS app on the DevEco emulator.

.DESCRIPTION
  Locates elements by their `hint` / `text` in the uitest layout tree instead of
  hard-coded pixel coordinates, so the helpers survive layout changes between builds.

  Known emulator quirks handled here:
   * The screen sleeps (PowerManagerService -> INACTIVE). While asleep,
     `snapshot_display` returns a BLACK frame and injected touches/text are dropped.
     Always call `Wake-Screen` first.
   * `uitest uiInput text` is unreliable for long strings -> type in small chunks.
   * The Back key exits the app when the soft keyboard is already closed.
   * `uitest` sometimes fails with "ExecuteCommand need connect-key?" -> just retry.
#>
param()

$script:Hdc      = 'D:\APP\Devecostudio26\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
$script:WorkDir  = 'D:\APP\Deepseek\DSHHarmony\tools'
$script:LayoutLocal = Join-Path $script:WorkDir 'dsh-layout.json'
# Which emulator to talk to. Several instances can be connected at once, so every
# command has to name its target explicitly.
$script:Target   = '127.0.0.1:5555'

function Invoke-Hdc {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$HdcArgs)
  & $script:Hdc -t $script:Target @HdcArgs
}

function Wake-Screen {
  <# Keeps the emulator display on; without this, input is silently dropped. #>
  Invoke-Hdc shell 'power-shell setmode 602' | Out-Null
  Invoke-Hdc shell 'power-shell wakeup' | Out-Null
  Start-Sleep -Milliseconds 400
}

function Get-Layout {
  <# One hdc round-trip: dump the tree and cat it back. Doing it as two calls
     (dumpLayout + file recv) doubled the cost of the whole test. #>
  for ($try = 1; $try -le 3; $try++) {
    $json = Invoke-Hdc shell 'uitest dumpLayout -p /data/local/tmp/dsh-layout.json >/dev/null 2>&1; cat /data/local/tmp/dsh-layout.json'
    if (-not $json) { Start-Sleep -Milliseconds 400; continue }
    $text = ($json -join "`n")
    if (-not $text.Trim()) { Start-Sleep -Milliseconds 400; continue }
    try { return ($text | ConvertFrom-Json) } catch { Start-Sleep -Milliseconds 400 }
  }
  return $null
}

function Get-Element {
  <# Finds a node by exact `text` or by `hint`. Returns the node whose bounds contain the match. #>
  param(
    $Layout,
    [string]$Text,
    [string]$Hint,
    [string]$Type
  )
  if ($null -eq $Layout) { return $null }
  $found = $null
  function Walk($n) {
    if ($null -eq $n -or $null -ne $script:found) { return }
    $a = $n.attributes
    $hit = $false
    if ($Text  -and $a.text  -eq $Text)  { $hit = $true }
    if ($Hint  -and $a.hint  -eq $Hint)  { $hit = $true }
    if ($hit -and $Type -and $a.type -ne $Type) { $hit = $false }
    if ($hit) { $script:found = $a; return }
    if ($n.children) { foreach ($c in $n.children) { Walk $c } }
  }
  $script:found = $null
  Walk $Layout
  return $script:found
}

function Get-Center {
  param([Parameter(Mandatory)]$Bounds)
  # Bounds look like "[x1,y1][x2,y2]"
  if ($Bounds -notmatch '\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]') { return $null }
  $x = ([int]$Matches[1] + [int]$Matches[3]) / 2
  $y = ([int]$Matches[2] + [int]$Matches[4]) / 2
  return [pscustomobject]@{ X = [int]$x; Y = [int]$y }
}

function Find-Below {
  <# First node of a type whose top edge is at or below MinY. Handy to pick the
     status line or the first list row without depending on the exact wording. #>
  param($Layout, [string]$Type = 'Text', [int]$MinY = 0)
  $script:hit = $null
  function Walk($n) {
    if ($null -eq $n -or $null -ne $script:hit) { return }
    $a = $n.attributes
    if ($a.type -eq $Type -and $a.bounds -match '\[(-?\d+),(-?\d+)\]' -and [int]$Matches[2] -ge $MinY) {
      $script:hit = $a
      return
    }
    if ($n.children) { foreach ($c in $n.children) { Walk $c } }
  }
  $script:hit = $null
  if ($null -ne $Layout) { Walk $Layout }
  return $script:hit
}

function Invoke-Tap {
  param([Parameter(Mandatory)][int]$X, [Parameter(Mandatory)][int]$Y, [int]$SettleMs = 800)
  $r = Invoke-Hdc shell "uitest uiInput click $X $Y"
  if ("$r" -match 'need connect-key') {          # transient uitest daemon hiccup
    Start-Sleep -Milliseconds 500
    $r = Invoke-Hdc shell "uitest uiInput click $X $Y"
  }
  Start-Sleep -Milliseconds $SettleMs
  return "$r".Trim()
}

function Invoke-Type {
  <# Types into the focused field. Long strings are split into chunks. #>
  param([Parameter(Mandatory)][string]$Value, [int]$Chunk = 6, [int]$SettleMs = 450)
  for ($i = 0; $i -lt $Value.Length; $i += $Chunk) {
    $len = [Math]::Min($Chunk, $Value.Length - $i)
    $part = $Value.Substring($i, $len)
    $r = Invoke-Hdc shell "uitest uiInput text $part"
    if ("$r" -match 'need connect-key') { Start-Sleep -Milliseconds 500; Invoke-Hdc shell "uitest uiInput text $part" | Out-Null }
    Start-Sleep -Milliseconds $SettleMs
  }
}

function Clear-Field {
  <# Backspace delivery is lossy, so send them in batches of three (uitest accepts
     up to three key codes per call) and from a device-side loop where possible. #>
  param([int]$Count = 16)
  $sent = 0
  while ($sent -lt $Count) {
    $batch = [Math]::Min(3, $Count - $sent)
    $keys = @()
    for ($k = 0; $k -lt $batch; $k++) { $keys += '2055' }
    Invoke-Hdc shell "uitest uiInput keyEvent $($keys -join ' ')" | Out-Null
    $sent += $batch
  }
  Start-Sleep -Milliseconds 300
}

function Set-Field {
  <# Focuses the field identified by text/hint, clears it, and types the new value. #>
  param(
    [Parameter(Mandatory)]$Layout,
    [string]$Text,
    [string]$Hint,
    [Parameter(Mandatory)][string]$Value,
    [int]$Chunk = 6
  )
  $el = Get-Element -Layout $Layout -Text $Text -Hint $Hint
  if ($null -eq $el) { throw "field not found (text='$Text' hint='$Hint')" }
  $c = Get-Center $el.bounds
  Invoke-Tap -X $c.X -Y $c.Y | Out-Null

  # The click must actually move the caret into THIS field. If it did not, the
  # backspaces below would be delivered to whatever field still had focus and
  # would silently wipe it. Verify focus, retry the tap if needed.
  $cur = Get-Element -Layout (Get-Layout) -Text $Text -Hint $Hint
  if (-not $cur.focused) {
    Invoke-Tap -X $c.X -Y $c.Y -SettleMs 1200 | Out-Null
    $cur = Get-Element -Layout (Get-Layout) -Text $Text -Hint $Hint
  }
  if (-not $cur.focused) { throw "could not focus field (text='$Text' hint='$Hint')" }

  # Delete exactly as many characters as the field holds - never a fixed count,
  # otherwise the surplus backspaces land in a neighbouring field.
  $have = if ($cur.text) { $cur.text.Length } else { 0 }
  if ($have -gt 0) { Clear-Field -Count $have }
  Invoke-Type -Value $Value -Chunk $Chunk
  return (Get-Layout) | ForEach-Object { Get-Element -Layout $_ -Text $Text -Hint $Hint }
}

function Get-Nth {
  <# Nth node of a given type, in tree order. Index-based lookup avoids all
     string/encoding fragility with Chinese hints. #>
  param(
    $Layout,
    [string]$Type,
    [int]$Index = 0,
    [int]$MinY = 0
  )
  if ($null -eq $Layout) { return $null }
  $hits = @()
  function Walk($n) {
    if ($null -eq $n) { return }
    $a = $n.attributes
    if ($a.type -eq $Type -and $a.bounds -match '\[(-?\d+),(-?\d+)\]' -and [int]$Matches[2] -ge $MinY) {
      $script:hits += $a
    }
    if ($n.children) { foreach ($c in $n.children) { Walk $c } }
  }
  $script:hits = @()
  Walk $Layout
  if ($script:hits.Count -gt $Index) { return $script:hits[$Index] }
  return $null
}

function Set-NthField {
  <# Focus the Nth field of a type, clear exactly its own characters, type a value,
     and verify the result. Retries if the caret did not land in the field.

     -Method 'text'       : chunked `uitest uiInput text` (appends at the caret).
     -Method 'inputText'  : one-shot `uitest uiInput inputText x y value`.
       The secure keyboard opened for PASSWORD fields drops most of the characters
       sent through `uiInput text`, but accepts `inputText` in a single shot.
     -Masked              : the field is a password; the layout reports '*' instead of
       the real text, so the expected value is a mask of the same length. #>
  param(
    [Parameter(Mandatory)][string]$Type,
    [Parameter(Mandatory)][int]$Index,
    [Parameter(Mandatory)][string]$Value,
    [int]$Chunk = 6,
    [int]$Attempts = 3,
    [ValidateSet('text', 'inputText')][string]$Method = 'text',
    [switch]$Masked
  )
  $expected = if ($Masked) { ('*' * $Value.Length) } else { $Value }
  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    $lay = Get-Layout
    $el = Get-Nth -Layout $lay -Type $Type -Index $Index
    if ($null -eq $el) { throw "no $Type #$Index found" }
    $c = Get-Center $el.bounds
    Invoke-Tap -X $c.X -Y $c.Y | Out-Null
    $cur = Get-Nth -Layout (Get-Layout) -Type $Type -Index $Index
    if (-not $cur.focused) {
      Invoke-Tap -X $c.X -Y $c.Y -SettleMs 1200 | Out-Null
      $cur = Get-Nth -Layout (Get-Layout) -Type $Type -Index $Index
    }
    if (-not $cur.focused) { Write-Host "    (attempt ${attempt}: focus not acquired)"; continue }
    # Backspace delivery is lossy, so keep pressing until the field is really empty.
    for ($round = 0; $round -lt 5; $round++) {
      $cur = Get-Nth -Layout (Get-Layout) -Type $Type -Index $Index
      if ($null -eq $cur -or -not $cur.text -or $cur.text.Length -eq 0) { break }
      Clear-Field -Count 30
    }
    if ($Method -eq 'inputText') {
      Invoke-Hdc shell "uitest uiInput inputText $($c.X) $($c.Y) $Value" | Out-Null
      Start-Sleep -Milliseconds 700
    } else {
      Invoke-Type -Value $Value -Chunk $Chunk
    }
    $after = Get-Nth -Layout (Get-Layout) -Type $Type -Index $Index
    # A password field reports a mask whose exact glyph differs from '*', so for
    # masked fields the length is the only reliable signal. The real value is
    # proven functionally by the bridge answering the health call.
    $ok = if ($Masked) { $after.text.Length -eq $Value.Length } else { $after.text -eq $expected }
    if ($ok) { return $after.text }
    Write-Host "    (attempt ${attempt}: got len $($after.text.Length), expected $Value.Length) - retrying"
  }
  $final = Get-Nth -Layout (Get-Layout) -Type $Type -Index $Index
  return $final.text
}

function Test-AppForeground {
  $out = Invoke-Hdc shell 'aa dump -a'
  $i = 0
  foreach ($l in $out) {
    if ("$l" -match 'bundle name \[com\.dsh\.harmony\]') {
      $i++
      if ($i -ge 2) { return $true }   # 2nd occurrence is the app-state line
    }
  }
  return ($out -join "`n") -match 'bundle name \[com\.dsh\.harmony\][\s\S]{0,200}?app state #FOREGROUND'
}

function Dismiss-Keyboard {
  <# The soft keyboard (and the secure keyboard opened for password fields) is a
     separate window that covers the lower half of the screen. While it is up the
     buttons underneath are filtered out of the merged uitest tree, so they cannot
     be located or tapped. This closes it and returns the requested element once it
     becomes reachable again.

     -NeedText : text of the element we want to reach (used as the "is it visible yet" probe). #>
  param(
    [string]$NeedText,
    [int]$Tries = 6
  )
  for ($i = 1; $i -le $Tries; $i++) {
    $lay = Get-Layout
    $el = if ($NeedText) { Get-Element -Layout $lay -Text $NeedText } else { $null }
    if ($el) { return $el }
    # 1) tap a neutral area of the app (the page title) to drop focus
    Invoke-Tap -X 250 -Y 280 -SettleMs 900 | Out-Null
    $lay = Get-Layout
    $el = if ($NeedText) { Get-Element -Layout $lay -Text $NeedText } else { $null }
    if ($el) { return $el }
    # 2) Back closes the keyboard; guard against it leaving the app
    Invoke-Hdc shell 'uitest uiInput keyEvent Back' | Out-Null
    Start-Sleep -Milliseconds 900
    if (-not (Test-AppForeground)) {
      Invoke-Hdc shell 'aa start -a EntryAbility -b com.dsh.harmony' | Out-Null
      Start-Sleep -Seconds 3
    }
  }
  return $null
}

function Get-FieldValue {
  param([Parameter(Mandatory)]$Layout, [string]$Text, [string]$Hint)
  $el = Get-Element -Layout $Layout -Text $Text -Hint $Hint
  if ($null -eq $el) { return $null }
  return $el.text
}

function Save-Screenshot {
  param([Parameter(Mandatory)][string]$Path)
  $dir = Split-Path $Path -Parent
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $remote = '/data/local/tmp/dsh-shot.jpeg'
  Invoke-Hdc shell "snapshot_display -f $remote" | Out-Null
  Invoke-Hdc file recv $remote $Path | Out-Null
  return $Path
}

function Get-AppPid {
  $line = Invoke-Hdc shell 'ps -ef | grep dsh.harmony'
  foreach ($l in $line) { if ($l -match '^\S+\s+(\d+)\s+\S+.*com\.dsh\.harmony') { return $Matches[1] } }
  return $null
}
