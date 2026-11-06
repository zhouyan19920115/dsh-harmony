# Model picker, 轨迹 tab, queue box, settings page.
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
  param($Layout, [int]$Max = 18)
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

# ---------------------------------------------------------- 1. model picker
Write-Output "=== [1] model picker ==="
Wake-Screen
$lay = Get-Layout
$m = Find-ByText -Layout $lay -Text 'MiniMax-M3.1-Flash' -MinX 1250
if ($null -ne $m) {
  $c = Get-Center $m.bounds
  Write-Output ("  tap at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 2500 | Out-Null
  Start-Sleep -Seconds 2
  Shot '37-large-model-picker.jpeg' 'model picker' | Out-Null
  Dump-Right -Layout (Get-Layout) -Max 16
  # close it (tap the model label again)
  Wake-Screen
  $lay = Get-Layout
  $m2 = Find-ByText -Layout $lay -Text 'MiniMax-M3.1-Flash' -MinX 1250
  if ($null -ne $m2) { $c = Get-Center $m2.bounds; Invoke-Tap -X $c.X -Y $c.Y -SettleMs 1200 | Out-Null }
} else { Write-Output '  model label not found' }

# ------------------------------------------------------------ 2. 轨迹 tab
Write-Output "`n=== [2] 轨迹 tab ==="
Wake-Screen
$lay = Get-Layout
$tab = Find-ByText -Layout $lay -Text '轨迹' -MinX 1250
if ($null -ne $tab) {
  $c = Get-Center $tab.bounds
  Write-Output ("  tap 轨迹 at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 2000 | Out-Null
  Start-Sleep -Seconds 2
  Shot '38-large-trace-tab.jpeg' '轨迹 tab' | Out-Null
  Dump-Right -Layout (Get-Layout) -Max 10
  # back to 对话
  Wake-Screen
  $lay = Get-Layout
  $t2 = Find-ByText -Layout $lay -Text '对话' -MinX 1250
  if ($null -ne $t2) { $c = Get-Center $t2.bounds; Invoke-Tap -X $c.X -Y $c.Y -SettleMs 1200 | Out-Null }
}

# ------------------------------------------------------ 3. a session with a queue
Write-Output "`n=== [3] open a running session (queue box) ==="
Wake-Screen
$lay = Get-Layout
$row = Find-ByText -Layout $lay -Text '看板任务子Agent执行' -MaxX 1250
if ($null -ne $row) {
  $c = Get-Center $row.bounds
  Write-Output ("  tap row at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 3000 | Out-Null
  Start-Sleep -Seconds 4
  Shot '39-large-running-session.jpeg' 'running session' | Out-Null
  Dump-Right -Layout (Get-Layout) -Max 16
} else { Write-Output '  running row not found' }

# ------------------------------------------------------------- 4. settings
Write-Output "`n=== [4] 设置 page ==="
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
    if ($null -eq $n -or $i -ge 22) { return }
    $a = $n.attributes
    if ($a.text) { Write-Output ("      '{0}' {1}" -f $a.text, $a.bounds); $script:i++ }
    if ($n.children) { foreach ($c in $n.children) { W $c } }
  }
  $script:i = 0; W $lay
} else { Write-Output '  设置 not found' }
Write-Output 'done'
