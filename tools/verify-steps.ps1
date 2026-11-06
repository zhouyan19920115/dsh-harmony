# Walk through every interaction on the wide (triple fold) emulator and capture
# a screenshot for each one. After every step the foreground state and the app
# log are checked so a crash cannot slip through unnoticed.
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
  param($Layout, [string]$Text, [int]$MaxX = 99999, [int]$MinX = -1)
  $script:hit = $null
  function Walk($n) {
    if ($null -eq $n -or $null -ne $script:hit) { return }
    $a = $n.attributes
    if ($a.text -eq $Text -and $a.bounds -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
      $x1 = [int]$Matches[1]
      if ($x1 -le $MaxX -and $x1 -ge $MinX) { $script:hit = $a; return }
    }
    if ($n.children) { foreach ($c in $n.children) { Walk $c } }
  }
  $script:hit = $null
  if ($null -ne $Layout) { Walk $Layout }
  return $script:hit
}

function Show-Text {
  param($Layout, [int]$Max = 30, [int]$MinX = -1)
  $i = 0
  function Walk($n) {
    if ($null -eq $n -or $i -ge $Max) { return }
    $a = $n.attributes
    if ($a.text -and $a.bounds -match '\[(\d+),(\d+)\]' -and [int]$Matches[1] -ge $MinX) {
      Write-Output ("    '{0}' {1}" -f $a.text, $a.bounds)
      $script:i++
    }
    if ($n.children) { foreach ($c in $n.children) { Walk $c } }
  }
  $script:i = 0
  if ($null -ne $Layout) { Walk $Layout }
}

function Step {
  param([string]$Name, [string]$Shot)
  $fg = Foreground
  Write-Output ("  foreground={0}" -f $fg)
  Save-Screenshot -Path "$OutDir\$Shot" | Out-Null
  Write-Output ("  saved {0}" -f $Shot)
  if (-not $fg) { Write-Output "  *** APP NOT IN FOREGROUND after $Name ***" }
  return $fg
}

# ---------------------------------------------------------------- 1. new session
Write-Output "=== [1] 新会话 dialog (工作区 / 模式 / 权限) ==="
Wake-Screen
$lay = Get-Layout
$btn = Find-ByText -Layout $lay -Text '新会话'
if ($null -eq $btn) { throw '新会话 button not found' }
$c = Get-Center $btn.bounds
Write-Output ("  tap at {0},{1}" -f $c.X, $c.Y)
Invoke-Tap -X $c.X -Y $c.Y -SettleMs 2000 | Out-Null
Start-Sleep -Seconds 2
Step 'new-session dialog' '32-large-newsession-dialog.jpeg' | Out-Null
Write-Output '  dialog content:'
Show-Text -Layout (Get-Layout) -Max 40

# ------------------------------------------------------- 2. pick a mode + permission
Write-Output "`n=== [2] choose mode + permission ==="
$lay = Get-Layout
$mode = Find-ByText -Layout $lay -Text 'standard'
if ($null -ne $mode) {
  $c = Get-Center $mode.bounds
  Write-Output ("  tap mode 'standard' at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 1200 | Out-Null
  Start-Sleep -Seconds 1
}
$lay = Get-Layout
$perm = Find-ByText -Layout $lay -Text 'workspace-write'
if ($null -ne $perm) {
  $c = Get-Center $perm.bounds
  Write-Output ("  tap permission 'workspace-write' at {0},{1}" -f $c.X, $c.Y)
  Invoke-Tap -X $c.X -Y $c.Y -SettleMs 1200 | Out-Null
  Start-Sleep -Seconds 1
}
Step 'mode+permission' '33-large-newsession-mode-permission.jpeg' | Out-Null
Write-Output '  dialog now:'
Show-Text -Layout (Get-Layout) -Max 40
Write-Output 'done'
