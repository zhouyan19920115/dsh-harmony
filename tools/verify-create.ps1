# Create a real session from the dialog, then walk the remaining interactions.
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
function Find-Nth {
  param($Layout, [string]$Type, [int]$Index = 0)
  $script:nth = $null
  $script:n = 0
  function Walk($n) {
    if ($null -eq $n -or $null -ne $script:nth) { return }
    $a = $n.attributes
    if ($a.type -eq $Type) {
      if ($script:n -eq $Index) { $script:nth = $a; return }
      $script:n++
    }
    if ($n.children) { foreach ($c in $n.children) { Walk $c } }
  }
  $script:nth = $null; $script:n = 0
  if ($null -ne $Layout) { Walk $Layout }
  return $script:nth
}
function Shot {
  param([string]$Name, [string]$Label)
  $fg = Foreground
  Save-Screenshot -Path "$OutDir\$Name" | Out-Null
  Write-Output ("  {0}: fg={1} -> {2}" -f $Label, $fg, $Name)
  if (-not $fg) { Write-Output "  *** APP LEFT FOREGROUND at $Label ***" }
  return $fg
}

# ---------------------------------------------------- 1. create a real session
Write-Output "=== [1] fill title and 创建 ==="
Wake-Screen
$lay = Get-Layout
$inputs = @()
function CollectInputs($n) {
  if ($null -eq $n) { return }
  $a = $n.attributes
  if ($a.type -eq 'TextInput' -or $a.type -eq 'TextArea') { $script:inputs += $a }
  if ($n.children) { foreach ($c in $n.children) { CollectInputs $c } }
}
$script:inputs = @(); CollectInputs $lay
Write-Output ("  inputs found: {0}" -f $script:inputs.Count)
for ($i = 0; $i -lt $script:inputs.Count; $i++) {
  Write-Output ("    #{0} '{1}' hint='{2}' {3}" -f $i, $script:inputs[$i].text, $script:inputs[$i].hint, $script:inputs[$i].bounds)
}
# the title input is the last one
if ($script:inputs.Count -gt 0) {
  $title = $script:inputs[$script:inputs.Count - 1]
  $c = Get-Center $title.bounds
  Write-Output ("  tap title field at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 1200 | Out-Null
  Invoke-Type -Value 'large-verify-session' -Chunk 6
  Start-Sleep -Milliseconds 800
  Shot '34-large-newsession-title.jpeg' 'title typed' | Out-Null
}

Wake-Screen
$lay = Get-Layout
$create = Find-ByText -Layout $lay -Text '创建'
if ($null -eq $create) { throw '创建 button not found' }
$c = Get-Center $create.bounds
Write-Output ("  tap 创建 at {0},{1}" -f $c.X, $c.Y)
Invoke-Hdc shell 'hilog -r' | Out-Null
Invoke-Tap -X $c.X -Y $c.Y -SettleMs 3000 | Out-Null
Start-Sleep -Seconds 6
Shot '35-large-created-session.jpeg' 'after 创建' | Out-Null

Write-Output '  is the new session in the list?'
$lay = Get-Layout
$found = Find-ByText -Layout $lay -Text 'large-verify-session'
Write-Output ("    found: {0}" -f $(if ($found) { "YES $($found.bounds)" } else { 'NO' }))
if ($null -eq $found) {
  function ShowLeft($n) {
    if ($null -eq $n) { return }
    $a = $n.attributes
    if ($a.text -and $a.bounds -match '\[(\d+),(\d+)\]' -and [int]$Matches[1] -lt 1250) { Write-Output ("      '{0}'" -f $a.text) }
    if ($n.children) { foreach ($c in $n.children) { ShowLeft $c } }
  }
  ShowLeft $lay
}

Write-Output "`n=== [2] app log after create ==="
Invoke-Hdc shell "hilog -x | grep -iE 'DshHarmony|dshyourname|fatal|js_fault|forEach|ArkUI:.*rror' | tail -25" | ForEach-Object { Write-Output "  $_" }
Write-Output 'done'
