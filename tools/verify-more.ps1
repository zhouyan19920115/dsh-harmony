# Second create with a proper title, then the remaining interactions.
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
function Dump-Text {
  param($Layout, [int]$Max = 26, [int]$MinX = -1)
  $i = 0
  function Walk($n) {
    if ($null -eq $n -or $i -ge $Max) { return }
    $a = $n.attributes
    if ($a.text -and $a.bounds -match '\[(\d+),(\d+)\]' -and [int]$Matches[1] -ge $MinX) {
      Write-Output ("      '{0}'" -f $a.text)
      $script:i++
    }
    if ($n.children) { foreach ($c in $n.children) { Walk $c } }
  }
  $script:i = 0
  if ($null -ne $Layout) { Walk $Layout }
}

# ------------------------------------------------- 1. create with a real title
Write-Output "=== [1] open dialog, set the title properly, create ==="
Wake-Screen
$lay = Get-Layout
$btn = Find-ByText -Layout $lay -Text '新会话'
$c = Get-Center $btn.bounds
Invoke-Tap -X $c.X -Y $c.Y -SettleMs 2000 | Out-Null
Start-Sleep -Seconds 2

$lay = Get-Layout
$inputs = @()
function CollectInputs($n) {
  if ($null -eq $n) { return }
  $a = $n.attributes
  if ($a.type -eq 'TextInput' -or $a.type -eq 'TextArea') { $script:inputs += $a }
  if ($n.children) { foreach ($c in $n.children) { CollectInputs $c } }
}
$script:inputs = @(); CollectInputs $lay
$title = $script:inputs[$script:inputs.Count - 1]
# tap the LEFT part of the title input: the right part overlaps the composer
# of the detail pane behind the dialog, which is where the text went last time.
$b = $title.bounds
if ($b -notmatch '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') { throw 'bad title bounds' }
$tx = [int]$Matches[1] + 60
$ty = [int]$Matches[2] + 20
Write-Output ("  tap title at {0},{1} (input {2})" -f $tx, $ty, $script:inputs.Count)
Invoke-Tap -X $tx -Y $ty -SettleMs 1200 | Out-Null
Invoke-Type -Value 'large-verify-session' -Chunk 6
Start-Sleep -Milliseconds 900
$lay = Get-Layout
$script:inputs = @(); CollectInputs $lay
$title = $script:inputs[$script:inputs.Count - 1]
Write-Output ("  title field now = '{0}'" -f $title.text)

$lay = Get-Layout
$create = Find-ByText -Layout $lay -Text '创建'
$c = Get-Center $create.bounds
Write-Output ("  tap 创建 at {0},{1}" -f $c.X, $c.Y)
Invoke-Tap -X $c.X -Y $c.Y -SettleMs 3000 | Out-Null
Start-Sleep -Seconds 6
Shot '35-large-created-session.jpeg' 'after 创建' | Out-Null
$lay = Get-Layout
$found = Find-ByText -Layout $lay -Text 'large-verify-session'
Write-Output ("  new session in list: {0}" -f $(if ($found) { "YES $($found.bounds)" } else { 'NO' }))

# ------------------------------------------------------------- 2. the + panel
Write-Output "`n=== [2] + panel (指令/技能/文件) ==="
Wake-Screen
$lay = Get-Layout
$plus = Find-ByText -Layout $lay -Text '+' -MinX 1250
if ($null -ne $plus) {
  $c = Get-Center $plus.bounds
  Write-Output ("  tap + at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 2000 | Out-Null
  Start-Sleep -Seconds 2
  Shot '36-large-plus-panel.jpeg' '+ panel' | Out-Null
  Write-Output '  panel content:'
  Dump-Text -Layout (Get-Layout) -Max 20 -MinX 1250
  # close it again
  Wake-Screen
  $lay = Get-Layout
  $close = Find-ByText -Layout $lay -Text '关闭' -MinX 1250
  if ($null -ne $close) { $c = Get-Center $close.bounds; Invoke-Tap -X $c.X -Y $c.Y -SettleMs 1200 | Out-Null }
} else { Write-Output '  + not found' }

# ---------------------------------------------------------- 3. model picker
Write-Output "`n=== [3] model picker ==="
Wake-Screen
$lay = Get-Layout
$model = Find-ByText -Layout $lay -Text 'MiniMax-M3.1-Flash' -MinX 1250
if ($null -ne $model) {
  $c = Get-Center $model.bounds
  Write-Output ("  tap model at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 2000 | Out-Null
  Start-Sleep -Seconds 2
  Shot '37-large-model-picker.jpeg' 'model picker' | Out-Null
  Dump-Text -Layout (Get-Layout) -Max 14 -MinX 1250
} else { Write-Output '  model label not found' }
Write-Output 'done'
