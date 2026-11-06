<#
.SYNOPSIS
    给真机装 DSH Harmony: 配签名 -> 编译 -> 用 hdc 装到设备。

.DESCRIPTION
    模拟器可以装未签名的 HAP, **真机不行** —— 真机只接受用证书签过的包。
    签名材料来自华为开发者服务的「自动签名」(DevEco Studio: 文件 > 项目结构 > 签名配置,
    或者 设备管理器里的「自动签名」), 一共三个文件:

        *.p12   密钥库(里面是私钥, 有密码)
        *.cer   证书
        *.p7b   描述文件(里面写着这个包名能用哪些设备)

    脚本会把它们写进 harmony/build-profile.json5 的 signingConfigs, 然后编译, 然后
    用 hdc 装到指定设备。

.PARAMETER P12
    密钥库(.p12)的路径。

.PARAMETER Cer
    证书(.cer)的路径。

.PARAMETER P7b
    描述文件(.p7b)的路径。

.PARAMETER StorePassword
    密钥库密码。

.PARAMETER KeyPassword
    私钥密码(一般是同一个)。

.PARAMETER Alias
    密钥库里的别名(默认 "debugKey")。

.PARAMETER Device
    hdc list targets 里看到的设备号(默认用第一台不是 127.0.0.1 的设备)。

.PARAMETER Install
    编译完之后是否直接 hdc install。

.EXAMPLE
    tools\sign-and-install.ps1 -P12 D:\keys\my.p12 -Cer D:\keys\my.cer -P7b D:\keys\my.p7b `
        -StorePassword 123456 -KeyPassword 123456 -Install
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$P12,
  [Parameter(Mandatory = $true)][string]$Cer,
  [Parameter(Mandatory = $true)][string]$P7b,
  [Parameter(Mandatory = $true)][string]$StorePassword,
  [string]$KeyPassword,
  [string]$Alias = 'debugKey',
  [string]$Device,
  [switch]$Install
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$harmony = Join-Path $root 'harmony'
$profile = Join-Path $harmony 'build-profile.json5'
$ide = if ($env:DEVECO_STUDIO_PATH) { $env:DEVECO_STUDIO_PATH } else { 'D:\APP\Devecostudio26\DevEco Studio' }
$hdc = Join-Path $ide 'sdk\default\openharmony\toolchains\hdc.exe'

foreach ($f in @($P12, $Cer, $P7b)) {
  if (-not (Test-Path $f)) { throw "找不到签名文件: $f" }
}
if (-not $KeyPassword) { $KeyPassword = $StorePassword }

# ---- 1) 把签名配置写进 build-profile.json5 -------------------------------------------
Copy-Item $profile "$profile.bak" -Force
$json5 = Get-Content $profile -Raw -Encoding UTF8
$escaped = {
  param($value)
  $value -replace '\\', '\\\\' -replace '"', '\"'
}
$block = @"
    "signingConfigs": [
      {
        "name": "default",
        "material": {
          "storeFile": "$(& $escaped ((Resolve-Path $P12).Path))",
          "storePassword": "YOUR_ENCRYPTED_PWD",
          "keyAlias": "$(& $escaped $Alias)",
          "keyPassword": "YOUR_ENCRYPTED_PWD",
          "signAlg": "SHA256withECDSA",
          "storeFileType": "pkcs12",
          "profile": "$(& $escaped ((Resolve-Path $P7b).Path))",
          "certpath": "$(& $escaped ((Resolve-Path $Cer).Path))"
        }
      }
    ],
"@
$json5 = $json5 -replace '(?s)("signingConfigs"\s*:\s*)\[\]', ('$1' + $block)
[System.IO.File]::WriteAllText($profile, $json5, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "已写入签名配置 -> $profile (原文件备份在 $profile.bak)"

# ---- 2) 编译 --------------------------------------------------------------------------
$env:DEVECO_STUDIO_PATH = $ide
$env:DEVECO_SDK_HOME = Join-Path $ide 'sdk'
$env:JAVA_HOME = Join-Path $ide 'jbr'
$env:Path = "$ide\tools\node;$ide\jbr\bin;$env:Path"
Push-Location $harmony
try {
  & (Join-Path $ide 'tools\node\node.exe') (Join-Path $ide 'tools\hvigor\bin\hvigorw.js') `
    assembleHap --mode module -p module=entry@default -p buildMode=debug --no-daemon
  if ($LASTEXITCODE -ne 0) { throw '编译失败' }
} finally {
  Pop-Location
}
$hap = Join-Path $harmony 'entry\build\default\outputs\default\entry-default-unsigned.hap'
if (-not (Test-Path $hap)) { throw "没有找到 HAP: $hap" }
Write-Host "编译完成: $hap"

# ---- 3) 装到设备 ----------------------------------------------------------------------
if ($Install) {
  if (-not $Device) {
    $targets = & $hdc list targets 2>&1 | Where-Object { $_ -match '\S' -and $_ -notmatch '^\[' }
    $Device = ($targets | Where-Object { $_ -notmatch '^127\.0\.0\.1' } | Select-Object -First 1)
    if (-not $Device) { throw "没有找到真机。请用 USB 连上并开启「开发者选项 > USB 调试」, 或者用 -Device 指定设备号。" }
  }
  Write-Host "安装到设备 $Device ..."
  & $hdc -t $Device install -r $hap
  if ($LASTEXITCODE -ne 0) { throw '安装失败' }
  Write-Host "装好了。在手机上打开「DSH 助手」, 填桌面端地址与令牌即可。"
}
