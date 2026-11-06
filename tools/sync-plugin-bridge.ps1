param()
# 把仓库里的桥接源码同步进插件包（发布前执行）
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..").Path
$src = Join-Path $root 'bridge\src'
$dstRoot = Join-Path $root 'plugins\dsh-harmony-bridge\bridge'
if (-not (Test-Path $src)) { throw "找不到 bridge/src: $src" }
if (Test-Path $dstRoot) { Remove-Item $dstRoot -Recurse -Force }
New-Item -ItemType Directory -Path $dstRoot -Force | Out-Null
Copy-Item $src (Join-Path $dstRoot 'src') -Recurse -Force
Copy-Item (Join-Path $root 'bridge\package.json') (Join-Path $dstRoot 'package.json') -Force
$count = (Get-ChildItem $dstRoot -Recurse -File | Measure-Object).Count
Write-Host ("已同步 bridge/src -> plugins/dsh-harmony-bridge/bridge ({0} 个文件)" -f $count)
Write-Host "提醒: 桥接有改动时, 记得跑 tools\package-desktop.ps1 重新生成手机内置的桌面端 zip。"
