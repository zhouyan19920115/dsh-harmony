# Verify the two-level session tree on the triple fold and catch any crash.
$ErrorActionPreference = 'Stop'
$Target = '127.0.0.1:5555'
$OutDir = 'D:\APP\Deepseek\DSHHarmony\docs\screenshots'
. 'D:\APP\Deepseek\DSHHarmony\tools\harmony-ui.ps1'
$script:Target = $Target

function Foreground {
  $out = Invoke-Hdc shell 'aa dump -a'
  $joined = ($out -join "`n")
  return $joined -match 'bundle name \[com\.dshyourname\.cn\][\s\S]{0,400}?app state #FOREGROUND'
}

function Dump-Tree {
  param($Layout)
  function Walk($n) {
    if ($null -eq $n) { return }
    $a = $n.attributes
    if ($a.text -and $a.bounds -match '\[(\d+),(\d+)\]' -and [int]$Matches[1] -lt 1250) {
      Write-Output ("    '{0}' {1}" -f $a.text, $a.bounds)
    }
    if ($n.children) { foreach ($c in $n.children) { Walk $c } }
  }
  Walk $Layout
}

Write-Output "=== [1] collapsed tree ==="
Wake-Screen
Save-Screenshot -Path "$OutDir\30-large-tree-collapsed.jpeg" | Out-Null
Dump-Tree (Get-Layout) | Select-Object -First 18

Write-Output "`n=== [2] expand a conversation that has topics ==="
Invoke-Hdc shell 'hilog -r' | Out-Null
$lay = Get-Layout
$arrow = $null
function FindArrow($n) {
  if ($null -eq $n -or $null -ne $script:arrow) { return }
  $a = $n.attributes
  if ($a.text -eq '▸' -and $a.bounds -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]' -and [int]$Matches[2] -gt 450 -and [int]$Matches[2] -lt 700) {
    $script:arrow = $a
    return
  }
  if ($n.children) { foreach ($c in $n.children) { FindArrow $c } }
}
$script:arrow = $null
FindArrow $lay
if ($null -eq $arrow) { throw 'no expand arrow found' }
$c = Get-Center $arrow.bounds
Write-Output ("  tap arrow at {0},{1}" -f $c.X, $c.Y)
Invoke-Tap -X $c.X -Y $c.Y -SettleMs 2500 | Out-Null
Start-Sleep -Seconds 3

Write-Output "  foreground now: $(Foreground)"
Save-Screenshot -Path "$OutDir\31-large-tree-expanded.jpeg" | Out-Null
Write-Output '  tree after expand:'
Dump-Tree (Get-Layout) | Select-Object -First 26

Write-Output "`n=== [3] crash / error log ==="
$log = Invoke-Hdc shell "hilog -x | grep -iE 'DshHarmony|fatal|js_fault|Error|forEach|ArkUI' | tail -60"
$log | ForEach-Object { Write-Output "  $_" }
Write-Output 'done'
