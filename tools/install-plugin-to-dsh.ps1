param()
# 把仓库里的 DSH 插件装进本机 DSH profile（幂等，可重复执行）。
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\install-plugin-to-dsh.ps1
#
# 做完这一步只差「重启 DSH」；重启前记得先停掉手动跑的桥接（否则 8787 端口会被占用）。
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot\..").Path
$src = Join-Path $root 'plugins\dsh-harmony-bridge'
$profile = Join-Path $env:USERPROFILE '.dsh\profiles\desktop'
if (-not (Test-Path $profile)) { throw "找不到 DSH profile: $profile" }

# 1) 插件文件
$dst = Join-Path $profile 'plugins\dsh-harmony-bridge'
New-Item -ItemType Directory -Force (Join-Path $profile 'plugins') | Out-Null
if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
Copy-Item $src $dst -Recurse -Force

# 2) node_modules 里放一个 junction，让 DSH 能按包名解析
$link = Join-Path $profile 'node_modules\dsh-harmony-bridge'
if (Test-Path $link) { cmd /c rmdir "$link" | Out-Null }
cmd /c mklink /J "$link" "$dst" | Out-Null

# 3) profile 的依赖清单
$pj = Join-Path $profile 'package.json'
$json = Get-Content $pj -Raw | ConvertFrom-Json
if (-not $json.dependencies.'dsh-harmony-bridge') {
  $json.dependencies | Add-Member -NotePropertyName 'dsh-harmony-bridge' -NotePropertyValue 'file:./plugins/dsh-harmony-bridge'
  $json | ConvertTo-Json -Depth 12 | Set-Content $pj -Encoding utf8
  Write-Host '已把 dsh-harmony-bridge 加入 profile dependencies'
}

# 4) cordis.patch.yml 里插入插件（去重）
$cfg = Join-Path $profile 'cordis.patch.yml'
$text = Get-Content $cfg -Raw
if ($text -notmatch 'dsh-harmony-bridge') {
  $text = $text.TrimEnd() + "`n`n- id: harmony-bridge`n  name: dsh-harmony-bridge`n  config:`n    port: 8787`n    host: 0.0.0.0`n    autoStart: true`n    verbose: false`n"
  Set-Content $cfg $text -Encoding utf8 -NoNewline
  Write-Host '已把 harmony-bridge 插入 cordis.patch.yml'
} else {
  Write-Host 'cordis.patch.yml 里已经有 harmony-bridge，跳过'
}

$version = (Get-Content (Join-Path $dst 'package.json') -Raw | ConvertFrom-Json).version
Write-Host ""
Write-Host ("插件已安装到: {0} (v{1})" -f $dst, $version) -ForegroundColor Green
Write-Host "下一步: 停掉手动跑的桥接 → 重启 DSH（插件会随 DSH 自动启动桥接）。"
Write-Host "也可以直接运行: powershell -File tools\switch-to-plugin.ps1 -StopManualBridge"
