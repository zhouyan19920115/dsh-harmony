# Settings page, queue box, and a stress pass looking for the crash the lead saw.
$ErrorActionPreference = 'Stop'
$Target = '127.0.0.1:5555'
$OutDir = 'D:\APP\Deepseek\DSHHarmony\docs\screenshots'
. 'D:\APP\Deepseek\DSHHarmony\tools\harmony-ui.ps1'
$script:Target = $Target

function Foreground {
  $out = Invoke-Hdc shell 'aa dump -a'
  return (($out -join "`n")) -match 'bundle name \[com\.dshyourname\.cn\][\s\S]{0,400}?app state #FOREGROUND'
}
function Find-ByText {
  param($Layout, [string]$Text, [int]$MinX = -1, [int]$MaxX = 99999)
  $script:hit = $null
  function Walk($n) {
    if ($null -eq $n -or $null -ne $script:hit) { return }
    $a = $n.attributes
    if ($a.text -eq $Text -and $a.bounds -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
      $x1 = [int]$Matches[1]
      if ($x1 -ge $MinX -and $x1 -le $MaxX) { $script:hit = $a; return }
    }
    if ($n.children) { foreach ($c in $n.children) { Walk $c } }
  }
  $script:hit = $null
  if ($null -ne $Layout) { Walk $Layout }
  return $script:hit
}
function Shot {
  param([string]$Name, [string]$Label)
  $fg = Foreground
  Save-Screenshot -Path "$OutDir\$Name" | Out-Null
  Write-Output ("  {0}: fg={1} -> {2}" -f $Label, $fg, $Name)
  if (-not $fg) { Write-Output "  *** APP LEFT FOREGROUND at $Label ***" }
  return $fg
}
function Dump-Right {
  param($Layout, [int]$Max = 16)
  $i = 0
  function Walk($n) {
    if ($null -eq $n -or $i -ge $Max) { return }
    $a = $n.attributes
    if ($a.text -and $a.bounds -match '\[(\d+),(\d+)\]' -and [int]$Matches[1] -ge 1250) {
      Write-Output ("      '{0}' {1}" -f $a.text, $a.bounds)
      $script:i++
    }
    if ($n.children) { foreach ($c in $n.children) { Walk $c } }
  }
  $script:i = 0
  if ($null -ne $Layout) { Walk $Layout }
}

# ------------------------------------------------------------ 1. settings page
Write-Output "=== [1] 设置 page ==="
Wake-Screen
$lay = Get-Layout
$s = Find-ByText -Layout $lay -Text '设置'
if ($null -ne $s) {
  $c = Get-Center $s.bounds
  Write-Output ("  tap 设置 at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 2500 | Out-Null
  Start-Sleep -Seconds 3
  Shot '40-large-settings-page.jpeg' 'settings page' | Out-Null
  $lay = Get-Layout
  $i = 0
  function W($n) {
    if ($null -eq $n -or $i -ge 20) { return }
    $a = $n.attributes
    if ($a.text) { Write-Output ("      '{0}' {1}" -f $a.text, $a.bounds); $script:i++ }
    if ($n.children) { foreach ($c in $n.children) { W $c } }
  }
  $script:i = 0; W $lay
  # go back
  Wake-Screen
  Invoke-Hdc shell 'uitest uiInput keyEvent Back' | Out-Null
  Start-Sleep -Seconds 2
} else { Write-Output '  设置 not found' }

# --------------------------------------------------------- 2. queue box
Write-Output "`n=== [2] queue box on a running session ==="
Wake-Screen
$lay = Get-Layout
$row = Find-ByText -Layout $lay -Text '看板任务子Agent执行' -MaxX 1250
if ($null -ne $row) {
  $c = Get-Center $row.bounds
  Write-Output ("  tap row at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 3000 | Out-Null
  Start-Sleep -Seconds 5
  Shot '39-large-running-session.jpeg' 'running session' | Out-Null
  Dump-Right -Layout (Get-Layout) -Max 18
  # the queue chip sits in the composer toolbar
  $lay = Get-Layout
  foreach ($t in @('队列', '排队', '任务队列')) {
    $q = Find-ByText -Layout $lay -Text $t -MinX 1250
    if ($null -ne $q) {
      $c = Get-Center $q.bounds
      Write-Output ("  tap queue chip '{0}' at {1},{2}" -f $t, $c.X, $c.Y)
      Invoke-Tap -X $c.X -Y $c.Y -SettleMs 2000 | Out-Null
      Start-Sleep -Seconds 2
      Shot '41-large-queue-box.jpeg' 'queue box' | Out-Null
      Dump-Right -Layout (Get-Layout) -Max 16
      break
    }
  }
} else { Write-Output '  running row not found' }

# --------------------------------------------------------- 3. stress the tree
Write-Output "`n=== [3] stress: open/expand many rows quickly ==="
Invoke-Hdc shell 'hilog -r' | Out-Null
$lost = 0
for ($i = 0; $i -lt 12; $i++) {
  Wake-Screen
  $lay = Get-Layout
  if ($null -eq $lay) { Write-Output "  [$i] layout dump returned null"; continue }
  $arrows = @()
  function CollectArrows($n) {
    if ($null -eq $n) { return }
    $a = $n.attributes
    if (($a.text -eq '▸' -or $a.text -eq '▾') -and $a.bounds -match '\[(\d+),(\d+)\]') {
      if ([int]$Matches[1] -lt 1250) { $script:arrows += $a }
    }
    if ($n.children) { foreach ($c in $n.children) { CollectArrows $c } }
  }
  $script:arrows = @(); CollectArrows $lay
  if ($script:arrows.Count -eq 0) { Write-Output "  [$i] no arrows"; continue }
  $a = $script:arrows[$i % $script:arrows.Count]
  $c = Get-Center $a.bounds
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 400 | Out-Null
  $fg = Foreground
  if (-not $fg) { $lost++; Write-Output "  [$i] *** LOST FOREGROUND after tapping arrow at $($c.X),$($c.Y) ***" }
}
Write-Output ("  foreground lost {0} times in 12 taps" -f $lost)
Shot '42-large-after-stress.jpeg' 'after stress' | Out-Null

Write-Output "`n=== [4] crash scan ==="
Invoke-Hdc shell "hilog -x | grep -iE 'cppcrash|FatalSignal|js_fault|JS_CRASH|FatalError|AppFreeze|forEach.*rror|ACE.*ERROR' | tail -20" | ForEach-Object { Write-Output "  $_" }
Write-Output ("  app alive: {0}" -f ((Invoke-Hdc shell 'ps -A | grep dshyourname') -join ' '))
Write-Output 'done'
