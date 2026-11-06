# 用「内部测试 Profile」签一份 release 包并装到真机
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File tools\install-release-internal.ps1 -ProfileFile "certificate\xxx.p7b"
#
# 为什么需要这个:
#   HarmonyOS NEXT 的来源信任检查只放行「开发证书 + debug Profile」的包走 hdc 侧载。
#   实测 2x2 对照矩阵(同一 unsigned HAP / 同一 p12 / 同一 keyAlias, 只换证书与 Profile):
#     debug证书  + debug Profile   => install bundle successfully
#     debug证书  + release Profile => 9568322 not trusted app source
#     release证书 + debug Profile  => 9568322 not trusted app source
#     release证书 + release Profile => 9568322 not trusted app source
#   只有 AGC 的**内部测试 Profile**(带设备 UDID 授权)能让正式签名的包走侧载。
#   普通 app_gallery 发布 Profile 没有设备列表, 只能靠 AGC 邀请测试分发。
#
# 前置:
#   1) AGC -> 证书、APP ID 和 Profile -> 设备, 已登记本机 UDID
#   2) AGC 生成「内部测试 Profile」(.p7b), 下载后放到 certificate\ 下
#   3) 设备已连上 hdc
param(
  [Parameter(Mandatory = $true)][string]$ProfileFile,
  [string]$DevEco = 'D:\APP\Devecostudio26\DevEco Studio',
  [string]$Project = '',
  [string]$CertDir = '',
  [string]$Device = '6XE0225B29036797',
  [string]$Udid = '',
  [switch]$NoBuild,
  [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
# 注意: **不要在 param 默认值里用 $PSScriptRoot** —— 某些宿主下它会解析成空,
# 拼出来变成 "\..\harmony"(根相对路径) ⇒ Resolve-Path 报 D:\harmony 不存在。
# 一律挪到脚本体里算。
$ScriptRoot = $PSScriptRoot
if (-not $Project) { $Project = Join-Path $ScriptRoot '..\harmony' }
if (-not $CertDir) { $CertDir = Join-Path $ScriptRoot '..\certificate' }
$Project = (Resolve-Path $Project).Path
$CertDir = (Resolve-Path $CertDir).Path
if (-not (Test-Path $ProfileFile)) { throw "找不到 Profile: $ProfileFile" }
$ProfileFile = (Resolve-Path $ProfileFile).Path

$env:DEVECO_STUDIO_PATH = $DevEco
$env:DEVECO_SDK_HOME   = Join-Path $DevEco 'sdk'
$env:JAVA_HOME         = Join-Path $DevEco 'jbr'
$env:Path              = "$(Join-Path $DevEco 'tools\node');$(Join-Path $DevEco 'jbr\bin');$env:Path"

$node     = Join-Path $DevEco 'tools\node\node.exe'
$hvigor   = Join-Path $DevEco 'tools\hvigor\bin\hvigorw.js'
$java     = Join-Path $DevEco 'jbr\bin\java.exe'
$signTool = Join-Path $DevEco 'sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar'
$hdc      = Join-Path $DevEco 'sdk\default\openharmony\toolchains\hdc.exe'
$cert     = Join-Path $CertDir 'DSHHarmony.cer'
$p12      = Join-Path $CertDir 'DSHHarmony.p12'

# ---------------------------------------------------------------------------
# 1) 先验 Profile: 包名对不对、有没有这台设备
# ---------------------------------------------------------------------------
Write-Host "`n=== [1/5] 检查 Profile ===" -ForegroundColor Cyan
if (-not $Udid) {
  $Udid = (& $hdc -t $Device shell 'bm get --udid' 2>&1 | Out-String) -replace '.*udid of current device is\s*:?\s*', '' -replace '\s+', ''
  $Udid = $Udid.Trim()
}
Write-Host "  设备 UDID: $Udid"
$info = & python (Join-Path $PSScriptRoot 'p7b-info.py') $ProfileFile --udid $Udid 2>&1 | Out-String
Write-Host $info
if ($info -notmatch '包含目标设备 UDID\s+✓') {
  Write-Warning "这个 Profile 里没有本机 UDID —— 装上去大概率还是 9568322。确认是「内部测试 Profile」且已选了这台设备。"
}
if ($info -notmatch 'bundle-name\s+com\.dshyourname\.cn') {
  throw "这个 Profile 的包名不是 com.example.dshsync, 用错了"
}
if ($CheckOnly) {
  Write-Host "`n  -CheckOnly: 到此为止, 没动任何东西。" -ForegroundColor Yellow
  return
}

# ---------------------------------------------------------------------------
# 2) 出未签名包
# ---------------------------------------------------------------------------
$out = Join-Path $Project 'entry\build\default\outputs\default'
$unsigned = Join-Path $out 'entry-default-unsigned.hap'
Write-Host "=== [2/5] 未签名包 ===" -ForegroundColor Cyan
if ($NoBuild -and (Test-Path $unsigned)) {
  Write-Host "  复用已有的: $unsigned"
} else {
  Write-Host "  构建中..."
  Push-Location $Project
  try {
    & $node $hvigor clean --no-daemon
    & $node $hvigor assembleHap --mode module -p module=entry@default -p buildMode=release --no-daemon
    if ($LASTEXITCODE -ne 0) { throw "hvigor 构建失败 (exit $LASTEXITCODE)" }
  } finally {
    Pop-Location
  }
}
if (-not (Test-Path $unsigned)) { throw "找不到未签名包: $unsigned" }

# ---------------------------------------------------------------------------
# 3) 用 发布证书 + 这个 Profile 签
# ---------------------------------------------------------------------------
Write-Host "`n=== [3/5] 签名 ===" -ForegroundColor Cyan
$localHap = Join-Path $out 'entry-default-internal-signed.hap'
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  & $java -jar $signTool sign-app -keyAlias zy -signAlg SHA256withECDSA -mode localSign `
    -appCertFile  $cert `
    -profileFile  $ProfileFile `
    -keystoreFile $p12 `
    -keystorePwd 'YOUR_KEYSTORE_PASSWORD' -keyPwd 'YOUR_KEYSTORE_PASSWORD' `
    -inFile $unsigned -outFile $localHap -signCode 1
  & $java -jar $signTool verify-app -inFile $localHap `
    -outCertChain (Join-Path $env:TEMP 'chain-internal.cer') -outProfile (Join-Path $env:TEMP 'profile-internal.p7b')
} finally {
  $ErrorActionPreference = $prevEap
}
if (-not (Test-Path $localHap)) { throw "签名失败, 没产出 $localHap" }
Write-Host ("  产物: {0}  ({1:N0} 字节)" -f $localHap, (Get-Item $localHap).Length) -ForegroundColor Green

# ---------------------------------------------------------------------------
# 4) 装(发布链和调试链是不同身份, 必须先卸载)
# ---------------------------------------------------------------------------
Write-Host "`n=== [4/5] 安装 ===" -ForegroundColor Cyan
& $hdc -t $Device uninstall com.example.dshsync 2>&1 | Out-Null
Start-Sleep -Seconds 2
$res = (& $hdc -t $Device install $localHap 2>&1 | Out-String)
Write-Host ("  " + ($res -replace '\s+', ' ').Trim())
if ($res -notmatch 'install bundle successfully') {
  throw "安装失败。Profile 里没有本机 UDID 时就是这个结果(9568322)。回到 AGC 确认设备已登记且 Profile 是内部测试的。"
}
Start-Sleep -Seconds 3
& $hdc -t $Device shell 'aa start -a EntryAbility -b com.example.dshsync' 2>&1 | Out-Null

# ---------------------------------------------------------------------------
# 5) 重新配对(换签名 => 配对状态被清掉了)
# ---------------------------------------------------------------------------
Write-Host "`n=== [5/5] 重新配对 ===" -ForegroundColor Cyan
Start-Sleep -Seconds 5
& $hdc -t $Device shell 'uitest dumpLayout -p /data/local/tmp/ii.json >/dev/null 2>&1; cat /data/local/tmp/ii.json' 2>&1 |
  Out-String | Set-Content (Join-Path $env:TEMP 'ii.json') -Encoding UTF8
$raw = Get-Content (Join-Path $env:TEMP 'ii.json') -Raw
if ($raw -match 'Fail') {
  Start-Sleep -Seconds 2
  & $hdc -t $Device shell 'uitest dumpLayout -p /data/local/tmp/ii.json >/dev/null 2>&1; cat /data/local/tmp/ii.json' 2>&1 |
    Out-String | Set-Content (Join-Path $env:TEMP 'ii.json') -Encoding UTF8
  $raw = Get-Content (Join-Path $env:TEMP 'ii.json') -Raw
}
$rows = @()
if ($raw -and $raw -notmatch 'Fail') {
  $j = $raw | ConvertFrom-Json
  function Walk($n) {
    if ($null -eq $n) { return }
    $a = $n.attributes
    if ($a -and $a.text -and $a.text.Trim() -ne '') {
      $script:rows += [pscustomobject]@{ text = $a.text; bounds = $a.bounds }
    }
    if ($n.children) { foreach ($c in $n.children) { Walk $c } }
  }
  Walk $j
}
$btn = $rows | Where-Object { $_.text -eq '自动探测' } | Select-Object -First 1
if ($btn) {
  $m = [regex]::Match($btn.bounds, '\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]')
  $x = [int](([int]$m.Groups[1].Value + [int]$m.Groups[3].Value) / 2)
  $y = [int](([int]$m.Groups[2].Value + [int]$m.Groups[4].Value) / 2)
  & $hdc -t $Device shell "uitest uiInput click $x $y" 2>&1 | Out-Null
  Write-Host "  已点「自动探测」, 稍等它自动配对..."
  Start-Sleep -Seconds 12
} else {
  Write-Host "  当前页面没有「自动探测」按钮 —— 可能已经连上了"
}
& $hdc -t $Device shell 'snapshot_display -f /data/local/tmp/internal.jpeg' 2>&1 | Out-Null
& $hdc -t $Device file recv /data/local/tmp/internal.jpeg (Join-Path $PSScriptRoot 'dsh-internal-installed.jpeg') 2>&1 | Out-Null
Write-Host "`n  截图: tools\dsh-internal-installed.jpeg" -ForegroundColor Green
Write-Host "  产物: $localHap" -ForegroundColor Green
