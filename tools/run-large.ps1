# Drive the DSH app on the triple-fold emulator (wide screen) and capture the
# two-column layout.
$ErrorActionPreference = 'Stop'

$Target = '127.0.0.1:5555'
$OutDir = 'D:\APP\Deepseek\DSHHarmony\docs\screenshots'
$Host_ = '192.168.1.10:8790'

$bridgeJson = 'C:\Users\YourName\.dsh-harmony-bridge\bridge.json'
$state = Get-Content $bridgeJson -Raw -Encoding utf8 | ConvertFrom-Json
$Token = $state.token
Write-Output ("token length = {0}" -f $Token.Length)

. 'D:\APP\Deepseek\DSHHarmony\tools\harmony-ui.ps1'
$script:Target = $Target

# Sanity: this must be the triple fold (3184x2232), not the phone.
$display = (Invoke-Hdc shell "hidumper -s DisplayManagerService -a '-a'" | Select-String -Pattern 'width: \d+ height' | Select-Object -First 1)
Write-Output ("  target {0} display: {1}" -f $Target, $display)
if ("$display" -notmatch 'width: 3184 height: 2232') { throw "target $Target is not the unfolded triple fold" }

function Show-Text {
  param($Layout, [int]$Max = 40)
  $i = 0
  function Walk($n) {
    if ($null -eq $n -or $i -ge $Max) { return }
    $a = $n.attributes
    if ($a.type -eq 'Text' -and $a.text) { Write-Output ("    '{0}'" -f $a.text); $script:i++ }
    if ($n.children) { foreach ($c in $n.children) { Walk $c } }
  }
  $script:i = 0
  Walk $Layout
}

Write-Output "`n=== [1] fill the form ==="
Wake-Screen
$a = Set-NthField -Type 'TextInput' -Index 0 -Value $Host_ -Chunk 5
Write-Output "  address = '$a'"
$t = Set-NthField -Type 'TextInput' -Index 1 -Value $Token -Method 'inputText' -Masked
Write-Output ("  token   = {0} chars" -f $(if ($t) { $t.Length } else { 0 }))
if ($a -ne $Host_) { throw "address not filled: '$a'" }
if (-not $t -or $t.Length -ne $Token.Length) { throw "token not filled" }

Write-Output "`n=== [2] 测试连接 ==="
Wake-Screen
$btn = Dismiss-Keyboard -NeedText '测试连接'
if ($null -eq $btn) { throw '测试连接 not reachable' }
$c = Get-Center $btn.bounds
Write-Output ("  tap at {0},{1}" -f $c.X, $c.Y)
Invoke-Tap -X $c.X -Y $c.Y -SettleMs 2500 | Out-Null
Start-Sleep -Seconds 3
Save-Screenshot -Path "$OutDir\20-large-connectpage.jpeg" | Out-Null
$lay = Get-Layout
$status = Find-Below -Layout $lay -Type 'Text' -MinY 1000
Write-Output "  status: '$($status.text)'"

Write-Output "`n=== [3] 连接 -> session list (two columns) ==="
Wake-Screen
$btn = Dismiss-Keyboard -NeedText '连接'
if ($null -eq $btn) { throw '连接 not reachable' }
$c = Get-Center $btn.bounds
Write-Output ("  tap at {0},{1}" -f $c.X, $c.Y)
Invoke-Tap -X $c.X -Y $c.Y -SettleMs 3000 | Out-Null
Start-Sleep -Seconds 8
Save-Screenshot -Path "$OutDir\21-large-sessionlist.jpeg" | Out-Null
Write-Output '  visible text:'
Show-Text -Layout (Get-Layout) -Max 26

Write-Output "`n=== [4] open the first session (right pane) ==="
Wake-Screen
$lay = Get-Layout
$first = Find-Below -Layout $lay -Type 'Text' -MinY 500
if ($null -eq $first) { throw 'no session row found' }
$c = Get-Center $first.bounds
Write-Output ("  tap '{0}' at {1},{2}" -f $first.text, $c.X, $c.Y)
Invoke-Tap -X $c.X -Y $c.Y -SettleMs 3000 | Out-Null
Start-Sleep -Seconds 6
Save-Screenshot -Path "$OutDir\ui-large.jpeg" | Out-Null
Write-Output '  visible text:'
Show-Text -Layout (Get-Layout) -Max 30

Write-Output "`n=== [5] breakpoint log ==="
Invoke-Hdc shell "hilog -x | grep -i 'DshHarmony' | grep -i '断点' | tail -5" | ForEach-Object { Write-Output "  $_" }
Write-Output 'done'
