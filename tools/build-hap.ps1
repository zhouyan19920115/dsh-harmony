# 构建鸿蒙端 HAP 包
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File tools\build-hap.ps1
#   powershell -ExecutionPolicy Bypass -File tools\build-hap.ps1 -Mode release
#   powershell -ExecutionPolicy Bypass -File tools\build-hap.ps1 -LocalInstall
#
# -LocalInstall: 额外用**调试证书 + debug Profile** 重签一份出来装自己手机。
#   为什么要这一步: build-profile.json5 里挂的是**发布**材料, 而 HarmonyOS NEXT 的
#   来源信任检查只放行「开发证书 + debug Profile」的包侧载 —— 发布签名的包 hdc install
#   会报 9568322 not trusted app source (实测 2×2 矩阵: 换证书或换 Profile 任一边都不行)。
#   所以**发布包给你上传 AGC, 本地这份给你自己装**, 两者代码完全一样。
#
# 依赖: DevEco Studio 26 (默认在 D:\APP\Devecostudio26\DevEco Studio)
param(
  [string]$DevEco = 'D:\APP\Devecostudio26\DevEco Studio',
  [string]$Mode = 'debug',
  [string]$Project = '',
  [switch]$LocalInstall,
  [string]$CertDir = ''
)

$ErrorActionPreference = 'Stop'
# 注意: **不要在 param 默认值里用 $PSScriptRoot** —— 某些宿主下它会解析成空,
# 拼出来变成 "\..\harmony"(根相对路径) ⇒ Resolve-Path 报 "D:\harmony 不存在"。
# 一律挪到脚本体里算。
$ScriptRoot = $PSScriptRoot
if (-not $Project) { $Project = Join-Path $ScriptRoot '..\harmony' }
if (-not $CertDir) { $CertDir = Join-Path $ScriptRoot '..\certificate' }
$Project = (Resolve-Path $Project).Path
$CertDir = (Resolve-Path $CertDir).Path

$env:DEVECO_STUDIO_PATH = $DevEco
$env:DEVECO_SDK_HOME   = Join-Path $DevEco 'sdk'
$env:JAVA_HOME         = Join-Path $DevEco 'jbr'
$env:Path              = "$(Join-Path $DevEco 'tools\node');$(Join-Path $DevEco 'jbr\bin');$env:Path"

$node  = Join-Path $DevEco 'tools\node\node.exe'
$hvigor = Join-Path $DevEco 'tools\hvigor\bin\hvigorw.js'
$java   = Join-Path $DevEco 'jbr\bin\java.exe'
$signTool = Join-Path $DevEco 'sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar'

Write-Host "[build] 项目: $Project" -ForegroundColor Cyan
Write-Host "[build] 模式: $Mode" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 发布签名自检(在构建**之前** —— 不对就别白等 4 分钟)
#
# DevEco Studio 管签名配置, 它会**把 harmony\build-profile.json5 的 material 换回自己那份
# 默认调试证书**(keyAlias=debugKey, 证书在 ~/.ohos/config/ 下)。那时候构建出来的
# "release 包"其实是调试签名的, 上传 AGC 会被拒(profile 类型对不上), 而且本地根本看不出来。
# ---------------------------------------------------------------------------
$profilePath = Join-Path $Project 'build-profile.json5'
$material = ''
if (Test-Path $profilePath) { $material = Get-Content $profilePath -Raw -Encoding UTF8 }
$isReleaseMaterial = ($material -match 'DSHHarmony\.cer') -and ($material -match 'DSHRelease\.p7b')
if (-not $isReleaseMaterial) {
  # 不再拦: 发布包是拿 unsigned 包自己签的(见下面), 签什么材料跟这个文件无关。
  # 这里只提醒一句 —— 这个文件是 DevEco 管的, 它随时会改。
  Write-Warning "[build] build-profile.json5 里的签名材料不是发布那套(DevEco 改过了)。不影响: 发布包用发布证书自己签。"
}

Push-Location $Project
try {
  & $node $hvigor clean --no-daemon
  & $node $hvigor assembleHap --mode module -p module=entry@default -p buildMode=$Mode --no-daemon
  if ($LASTEXITCODE -ne 0) { throw "hvigor 构建失败 (exit $LASTEXITCODE)" }
} finally {
  Pop-Location
}

$out = Join-Path $Project "entry\build\default\outputs\default"
Write-Host "`n[build] 产物目录: $out" -ForegroundColor Green
Get-ChildItem $out -Filter *.hap | ForEach-Object {
  Write-Host ("[build] {0}  ({1:N0} 字节)" -f $_.FullName, $_.Length) -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 发布包: 自己签, 不靠 hvigor 签
#
# DevEco Studio 会把 harmony\build-profile.json5 里的签名材料换成它自己那份调试证书 ——
# 哪怕是**在构建进行中**换的(构建前查一遍不够, 它是在 hvigor 读配置之前改的)。结果就是
# "release 包"其实是调试签名的, 上传 AGC 会被拒(profile type 对不上), 而本地看不出来。
#
# 所以: 拿 hvigor 签出来的 **unsigned** 包, 用发布证书 + 发布 Profile 自己签一遍,
# 签完 verify-app 确认 profile type 确实是 release —— 结果不再取决于 DevEco 什么时候动配置 ✓
# ---------------------------------------------------------------------------
$unsigned = Join-Path $out 'entry-default-unsigned.hap'
if ($Mode -eq 'release') {
  $releaseHap = Join-Path $out 'entry-default-signed.hap'
  if (-not (Test-Path $unsigned)) { throw "找不到未签名包: $unsigned" }
  Write-Host "`n[build] 用发布证书重签(DevEco 会改 build-profile.json5 的材料, 不靠它签)..." -ForegroundColor Cyan
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $java -jar $signTool sign-app -keyAlias zy -signAlg SHA256withECDSA -mode localSign `
      -appCertFile  (Join-Path $CertDir 'DSHHarmony.cer') `
      -profileFile  (Join-Path $CertDir 'DSHRelease.p7b') `
      -keystoreFile (Join-Path $CertDir 'DSHHarmony.p12') `
      -keystorePwd 'YOUR_KEYSTORE_PASSWORD' -keyPwd 'YOUR_KEYSTORE_PASSWORD' `
      -inFile $unsigned -outFile $releaseHap -signCode 1
  } finally {
    $ErrorActionPreference = $prevEap
  }
  if (-not (Test-Path $releaseHap)) { throw "发布重签失败, 没产出 $releaseHap" }
  Write-Host ("[build] 发布包: {0}  ({1:N0} 字节)" -f $releaseHap, (Get-Item $releaseHap).Length) -ForegroundColor Green

  # ---------------------------------------------------------------------------
  # 发布 profile 里写死了版本号。上传 AGC 时 profile 的版本必须和 App 一样, 否则
  # 报 7017「Profile 版本不符」—— 本地签名不校验这个, 所以这里主动查一遍。
  # (不匹配也不拦着: 本地装机自测照样能装, 只是上传前必须去 AGC 换一份 profile。)
  # ---------------------------------------------------------------------------
  $prevEap2 = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $profileText = & $java -jar $signTool verify-profile -inFile (Join-Path $CertDir 'DSHRelease.p7b') 2>&1 | Out-String
  } finally {
    $ErrorActionPreference = $prevEap2
  }
  $profileName = ''
  $profileCode = ''
  if ($profileText -match '"version-name"\s*:\s*"([^"]+)"') { $profileName = $Matches[1] }
  if ($profileText -match '"version-code"\s*:\s*(\d+)') { $profileCode = $Matches[1] }
  $appJson = Get-Content (Join-Path $Project 'AppScope\app.json5') -Raw
  $appName = ''
  $appCode = ''
  if ($appJson -match '"versionName"\s*:\s*"([^"]+)"') { $appName = $Matches[1] }
  if ($appJson -match '"versionCode"\s*:\s*(\d+)') { $appCode = $Matches[1] }
  if ($profileName -ne '' -and $appName -ne '' -and ($profileName -ne $appName -or $profileCode -ne $appCode)) {
    Write-Warning ("[build] App 是 {0} (code {1}), 但发布 profile 是 {2} (code {3}) —— " -f $appName, $appCode, $profileName, $profileCode)
    Write-Warning "         本地装没问题, 但**上传 AGC 会报 7017 Profile 版本不符**。"
    Write-Warning "         要上传的话: 去 AGC 按新版本重新生成一份 profile, 下载后替换 certificate\DSHRelease.p7b。"
  } else {
    Write-Host ("[build] 版本对得上: App {0} (code {1}) = profile {2} (code {3})" -f $appName, $appCode, $profileName, $profileCode) -ForegroundColor Cyan
  }
}

# ---------------------------------------------------------------------------
# 验签: profile type 必须跟模式对上。release 包必须是 release, 调试包是 debug ——
# 签错了就在这里停住, 别把一个错签名的包交出去。
# ---------------------------------------------------------------------------
$signedHap = Join-Path $out 'entry-default-signed.hap'
if (Test-Path $signedHap) {
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $verify = & $java -jar $signTool verify-app -inFile $signedHap `
      -outCertChain (Join-Path $env:TEMP 'dsh-verify-chain.cer') `
      -outProfile (Join-Path $env:TEMP 'dsh-verify-profile.p7b') 2>&1 | Out-String
  } finally {
    $ErrorActionPreference = $prevEap
  }
  $type = 'unknown'
  if ($verify -match 'profile type is:\s*(\S+)') { $type = $Matches[1] }
  Write-Host "[build] 验签: profile type = $type" -ForegroundColor Cyan
  if ($Mode -eq 'release' -and $type -ne 'release') {
    throw ("这个包的 profile type 是 '$type', 不是 release —— 别拿它去上传 AGC。`n" +
           "  (DevEco 又把签名材料换了?  查: git checkout -- harmony/build-profile.json5)")
  }
  if ($Mode -eq 'debug' -and $type -ne 'debug') {
    Write-Warning "[build] 这个包的 profile type 是 '$type'(不是 debug)。"
  }
}

if ($LocalInstall) {
  $unsigned = Join-Path $out 'entry-default-unsigned.hap'
  $localHap = Join-Path $out 'entry-default-local-signed.hap'
  if (-not (Test-Path $unsigned)) { throw "找不到未签名包: $unsigned" }
  Write-Host "`n[build] 用调试证书重签一份(装自己手机用)..." -ForegroundColor Cyan
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $java -jar $signTool sign-app -keyAlias zy -signAlg SHA256withECDSA -mode localSign `
      -appCertFile  (Join-Path $CertDir 'DSHHarmony-debug.cer') `
      -profileFile  (Join-Path $CertDir 'DSHdebugDebug.p7b') `
      -keystoreFile (Join-Path $CertDir 'DSHHarmony.p12') `
      -keystorePwd 'YOUR_KEYSTORE_PASSWORD' -keyPwd 'YOUR_KEYSTORE_PASSWORD' `
      -inFile $unsigned -outFile $localHap -signCode 1
  } finally {
    $ErrorActionPreference = $prevEap
  }
  if (-not (Test-Path $localHap)) { throw "重签失败, 没产出 $localHap" }
  Write-Host ("[build] 本地安装用: {0}  ({1:N0} 字节)" -f $localHap, (Get-Item $localHap).Length) -ForegroundColor Green
  Write-Host "[build] 装: hdc install `"$localHap`"" -ForegroundColor Yellow
}
