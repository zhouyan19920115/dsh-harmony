param()
# 校验已安装的 DSH 插件：client 模块声明完整、能按包名解析、能被 __ModuleLoader__ 执行。
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify-plugin-client.ps1
#
# 失败会打印原因；退出码非 0。
$ErrorActionPreference = 'Stop'
$profileDir = Join-Path $env:USERPROFILE '.dsh\profiles\desktop'
$pkgDir = Join-Path $profileDir 'plugins\dsh-harmony-bridge'
if (-not (Test-Path $pkgDir)) { throw "插件没装: $pkgDir" }

$pkg = [System.IO.File]::ReadAllText((Join-Path $pkgDir 'package.json')) | ConvertFrom-Json
$problems = @()
if (-not $pkg.dsh.client) { $problems += 'package.json 缺少 dsh.client 声明' }
if (-not $pkg.exports.'./client') { $problems += 'package.json exports 缺少 "./client"' }
$clientPath = Join-Path $pkgDir ($pkg.exports.'./client' -replace '^\./', '')
if (-not (Test-Path $clientPath)) { $problems += "client 文件不存在: $clientPath" }
if (-not (Test-Path (Join-Path $pkgDir 'lib\client.js'))) { $problems += 'lib/client.js 缺失' }
if ($problems.Count -gt 0) {
  Write-Host '插件 client 声明有问题:' -ForegroundColor Red
  $problems | ForEach-Object { Write-Host " - $_" }
  exit 1
}
Write-Host ("package.json OK: version={0}, client={1}" -f $pkg.version, $pkg.exports.'./client') -ForegroundColor Green

# 在 profile 里按包名解析并执行 client 模块（模拟 DSH 的加载方式）
$script = @'
globalThis.window = { __ModuleLoader__: { load(def) { globalThis.__loaded = def; } } };
globalThis.document = { getElementById: () => null, createElement: () => ({}), head: { appendChild() {} } };
await import('dsh-harmony-bridge/client');
const def = globalThis.__loaded;
if (!def) throw new Error('module did not call __ModuleLoader__.load');
const fakeReact = { createElement: () => null, useState: (v) => [v, () => {}], useEffect: () => {} };
const mod = def.factory((name) => (name === 'react' ? fakeReact : {}));
if (typeof mod.apply !== 'function') throw new Error('client module has no apply()');
console.log('client module OK, name=' + mod.name);
'@
$tmp = Join-Path $profileDir '_verify-client.mjs'
Set-Content -Path $tmp -Value $script -Encoding utf8
Push-Location $profileDir
try {
  & 'D:\APP\Node\node.exe' $tmp
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
  Pop-Location
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}
Write-Host '全部通过。若 DSH 已经启动过旧版本，重启一次 DSH 即可看到「打开桥接设置」按钮。' -ForegroundColor Green
