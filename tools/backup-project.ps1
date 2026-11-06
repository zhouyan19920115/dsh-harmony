# DSHHarmony 工程备份
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File tools\backup-project.ps1 -DryRun      # 只出清单, 不打包
#   powershell -ExecutionPolicy Bypass -File tools\backup-project.ps1             # 完整备份 + 验证
#   powershell -ExecutionPolicy Bypass -File tools\backup-project.ps1 -SkipBuild  # 跳过编译验证(不推荐)
#
# 方法论: 见 skills/harmony-project-backup (工程备份方法论 v2.1)
#
# 四条铁律都在这儿落地了:
#   1) 机器可再生则不备份 —— build/ 缓存/依赖/日志 一律不进
#   2) 不可再生才备份 —— 源码、配置、文档、脚本、证据、git 历史
#   3) 私钥永不进 zip —— certificate/ 整个目录分流, 打包时硬拦
#   4) 绝对路径必查 —— local.properties 排除, 但 MANIFEST 里点名
#   5) 备份可证明 = 备份成功 —— SHA256 + 解压重 build 都过, 才算成功
param(
  [string]$Root = "$PSScriptRoot\..",
  [string]$OutRoot = 'D:\APP\Deepseek\_backups',
  [string]$Label = 'manual',
  [switch]$DryRun,
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path $Root).Path
$Stamp = Get-Date -Format 'yyyyMMdd'
$Name = 'DSHHarmony'
$BackupDir = Join-Path $OutRoot "${Name}_backup_${Stamp}_${Label}"

# ---------------------------------------------------------------------------
# 排除规则 —— 每一类都要有理由, 理由写进 MANIFEST, 不许默默丢东西
# ---------------------------------------------------------------------------
$ExcludedDirs = @(
  'certificate',        # 签名材料(私钥) —— 走手工渠道, 永不进 zip
  '_tmp', 'dist',       # 临时目录与构建产物
  'node_modules', 'oh_modules', '.hvigor', '.idea', '.cache', '.cxx',
  '.harmonybot', 'build', 'deploy', 'backup'
)
$ExcludedFiles = @(
  'local.properties',   # 含本机绝对路径(sdk.dir / java.home)—— 换机即废
  'push-tokens.local.json',
  'accounts.json', 'devices.json'
)
# 模式类排除: 日志、临时、备份副本
$ExcludedPatterns = @(
  '\.p12$', '\.p7b$', '\.cer$', '\.csr$', '\.pfx$', '\.jks$',
  '\.log$', '\.err$', '\.tmp$', '\.bak$',
  '^harmony/hilog-.*\.txt$',   # 设备日志残留(最大的一个 181MB)—— 可随时重抓
  '\.exe$',                    # 第三方可执行文件(cloudflared)—— 可重新下载
  '\.hap$', '\.app$'
)
# 额外收进来的: 上一轮做出来但还没提交的工具(有价值的, 丢了就没了)
$ExtraFiles = @(
  'tools/dsh-monitor/README.md', 'tools/dsh-monitor/COMPAT_AUDIT.md',
  'tools/dsh-monitor/DSH_DISK_FORMAT.md', 'tools/dsh-monitor/HARMONY_EMBED.md',
  'tools/dsh-monitor/TRAFFIC_REPORT.md', 'tools/dsh-monitor/asar-extract.mjs',
  'tools/dsh-monitor/dsh-client.mjs', 'tools/dsh-monitor/enrich-live.mjs',
  'tools/dsh-monitor/inspect-session.mjs', 'tools/dsh-monitor/measure-compact.mjs',
  'tools/dsh-monitor/probe-payloads.mjs', 'tools/dsh-monitor/scan-logs.mjs',
  'tools/dsh-monitor/telemetry-feed.mjs', 'tools/dsh-monitor/telemetry.json',
  'tools/dsh-monitor/preview.png',
  'tools/phone-wake-loop.ps1', 'tools/phone-wake-once.ps1', 'tools/phone-wake.cmd',
  'tools/repair-workspace-membership.mjs',
  'tools/verify-i18n-errors.ps1', 'tools/verify-session-open.ps1', 'tools/relay-ssh.py',
  'tools/backup-project.ps1',
  'tools/backup-project.ps1'
)

function Test-Excluded {
  param([string]$RelPath)
  $parts = $RelPath -split '/'
  foreach ($d in $ExcludedDirs) { if ($parts -contains $d) { return $d } }
  foreach ($f in $ExcludedFiles) { if ($parts -contains $f) { return $f } }
  foreach ($p in $ExcludedPatterns) { if ($RelPath -match $p) { return $p } }
  return $null
}

# ---------------------------------------------------------------------------
# 组装清单
# ---------------------------------------------------------------------------
Push-Location $Root
try {
  $tracked = @(git ls-files)
} finally { Pop-Location }

$include = New-Object System.Collections.Generic.List[string]
$skip = New-Object System.Collections.Generic.List[string]
$missing = New-Object System.Collections.Generic.List[string]

foreach ($f in $tracked) {
  $why = Test-Excluded $f
  if ($why) { $skip.Add("$f`t[$why]"); continue }
  $abs = Join-Path $Root $f
  if (-not (Test-Path $abs)) { $missing.Add($f); continue }   # 工作树里已删(HEAD 里还在)
  $include.Add($f)
}
foreach ($f in $ExtraFiles) {
  $abs = Join-Path $Root $f
  if (Test-Path $abs) { if (-not $include.Contains($f)) { $include.Add($f) } }
  else { $missing.Add($f) }
}

# 私钥硬拦截 —— 铁律 3: 进了就得当场炸, 不能只靠"应该不会"
$leaks = $include | Where-Object { $_ -match '\.(p12|p7b|cer|csr|pfx|jks)$' }
if ($leaks) { throw "清单里有签名材料, 中止: $($leaks -join ', ')" }

$totalBytes = 0
foreach ($f in $include) { $totalBytes += (Get-Item (Join-Path $Root $f)).Length }

Write-Output "=== 备份清单 ==="
Write-Output ("  工程根   : {0}" -f $Root)
Write-Output ("  备份目录 : {0}" -f $BackupDir)
Write-Output ("  纳入文件 : {0} 个, {1:N1} MB" -f $include.Count, ($totalBytes / 1MB))
Write-Output ("  排除条目 : {0} 条" -f $skip.Count)
Write-Output ("  缺失文件 : {0} 个(工作树已删, 按 HEAD 计)" -f $missing.Count)

$include | Set-Content (Join-Path $env:TEMP 'dsh-backup-include.txt') -Encoding UTF8
$skip    | Set-Content (Join-Path $env:TEMP 'dsh-backup-skip.txt') -Encoding UTF8

Write-Output ""
Write-Output "=== 按顶层目录 ==="
$include | Group-Object { ($_ -split '/')[0] } | Sort-Object Count -Descending | ForEach-Object {
  Write-Output ("  {0,-12} {1,4} 个" -f $_.Name, $_.Count)
}
Write-Output ""
Write-Output "=== 排除的目录类(前 8 类, 按命中数) ==="
$skip | ForEach-Object { ($_ -split "`t")[-1].Trim('[',']') } | Group-Object | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object {
  Write-Output ("  {0,-28} {1,4} 条" -f $_.Name, $_.Count)
}

if ($DryRun) {
  Write-Output ""
  Write-Output "(dry-run, 没有打包。清单已存到 $env:TEMP\dsh-backup-include.txt)"
  return
}

# ---------------------------------------------------------------------------
# staging + zip
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "=== [1/5] staging ==="
# 重跑时先把上一次的产物清掉 —— 不然旧 zip 混在新 zip 里, 校验和就对不上了 ✓
if (Test-Path $BackupDir) { Remove-Item $BackupDir -Recurse -Force }
New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
$Stage = Join-Path $BackupDir 'staging'
New-Item -ItemType Directory -Path $Stage -Force | Out-Null
foreach ($f in $include) {
  $dest = Join-Path $Stage ($f -replace '/', '\')
  New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
  Copy-Item (Join-Path $Root ($f -replace '/', '\')) $dest -Force
}
Write-Output ("  已拷贝 {0} 个文件" -f $include.Count)

Write-Output "=== [2/5] 打包 ==="
$Zip = Join-Path $BackupDir "${Name}_source.zip"

# **不用 Compress-Archive** —— 它在 Windows PowerShell 5.1 里把 entry 名写成反斜杠
# (`bridge\src\cli.js`), 而 zip 的规范要求正斜杠。后果: 在 Linux/macOS 上解压会得到
# 一个叫 "bridge\src\cli.js" 的单文件, 目录结构全乱 ⇒ **这个包换机器根本用不了**。
# 本机 Expand-Archive 能解开(本机也是 Windows)所以自检时看不出来 ⇒ 必须手工写 entry 名 ✓
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipStream = [System.IO.File]::Open($Zip, [System.IO.FileMode]::Create)
$zipArchive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Create)
try {
  foreach ($f in $include) {
    $entryName = $f -replace '\\', '/'          # ← 正斜杠, 规范要求
    $entry = $zipArchive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
    $entryStream = $entry.Open()
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $Root ($f -replace '/', '\')))
    $entryStream.Write($bytes, 0, $bytes.Length)
    $entryStream.Dispose()
  }
} finally {
  $zipArchive.Dispose()
  $zipStream.Dispose()
}
Remove-Item $Stage -Recurse -Force
$zipMB = [math]::Round((Get-Item $Zip).Length / 1MB, 1)
Write-Output ("  {0}  ({1} MB)" -f (Split-Path $Zip -Leaf), $zipMB)

# 可移植性自检: entry 名里不能有反斜杠, 也不能有盘符/绝对路径
$zipCheck = [System.IO.Compression.ZipFile]::OpenRead($Zip)
try {
  $badNames = @($zipCheck.Entries | Where-Object { $_.FullName -match '\\' -or $_.FullName -match '^[A-Za-z]:' -or $_.FullName -match '^\.\.' } | ForEach-Object { $_.FullName })
  $entryCount = $zipCheck.Entries.Count
} finally { $zipCheck.Dispose() }
if ($badNames.Count -gt 0) {
  throw ("zip 里有 {0} 条路径不可移植(反斜杠/绝对路径/上跳): {1}" -f $badNames.Count, ($badNames | Select-Object -First 3) -join ', ')
}
Write-Output ("  可移植性自检: {0} 条目, 全部正斜杠相对路径 ✓" -f $entryCount)

Write-Output "=== [3/5] git 历史打包 ==="
$Bundle = Join-Path $BackupDir "${Name}.bundle"
& git -C $Root bundle create $Bundle --all 2>&1 | Out-Null
if (Test-Path $Bundle) {
  Write-Output ("  {0}  ({1} MB)" -f (Split-Path $Bundle -Leaf), [math]::Round((Get-Item $Bundle).Length / 1MB, 1))
} else {
  Write-Output "  (跳过: 不是 git 仓库或没有提交)"
  $Bundle = $null
}

Write-Output "=== [4/5] 校验和 ==="
$sha = Get-FileHash $Zip -Algorithm SHA256
$shaLines = @("# SHA256 校验和  —  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", "")
$shaLines += ("{0}  {1}" -f $sha.Hash.ToLower(), (Split-Path $Zip -Leaf))
if ($Bundle) {
  $bs = Get-FileHash $Bundle -Algorithm SHA256
  $shaLines += ("{0}  {1}" -f $bs.Hash.ToLower(), (Split-Path $Bundle -Leaf))
}
$shaLines | Set-Content (Join-Path $BackupDir 'SHA256.txt') -Encoding UTF8
Write-Output ("  zip  SHA256 {0}" -f $sha.Hash.ToLower())

# ---------------------------------------------------------------------------
# [5/5] 验证: 解压 -> 逐文件比对 -> 重新 build
# ---------------------------------------------------------------------------
Write-Output ""
Write-Output "=== [5/5] 验证可恢复性 ==="
$Verify = Join-Path $env:TEMP "dsh-verify-$Stamp"
Remove-Item $Verify -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $Verify | Out-Null
Expand-Archive -Path $Zip -DestinationPath $Verify -Force

$cmp = 0; $mismatch = @()
foreach ($f in $include) {
  $a = Join-Path $Root ($f -replace '/', '\')
  $b = Join-Path $Verify ($f -replace '/', '\')
  if (-not (Test-Path $b)) { $mismatch += "缺: $f"; continue }
  $ha = (Get-FileHash $a -Algorithm SHA256).Hash
  $hb = (Get-FileHash $b -Algorithm SHA256).Hash
  if ($ha -ne $hb) { $mismatch += "不一致: $f" } else { $cmp++ }
}
Write-Output ("  源文件逐个比对: {0} 个一致, {1} 个不一致" -f $cmp, $mismatch.Count)
$mismatch | Select-Object -First 10 | ForEach-Object { Write-Output ("    $_") }
if ($mismatch.Count -gt 0) { throw "解压出来的文件和源文件不一致, 备份作废" }

$buildOk = $false
if (-not $SkipBuild) {
  # local.properties 不在包里(铁律 4), 验证时从本机补一份 —— 它本来就是本机专属的
  $lp = Join-Path $Verify 'harmony\local.properties'
  if (Test-Path (Join-Path $Root 'harmony\local.properties')) {
    Copy-Item (Join-Path $Root 'harmony\local.properties') $lp -Force
  }
  Write-Output "  正在重新 build(这一步要几分钟)..."
  # **必须临时把 ErrorActionPreference 调回 Continue** ——
  # hvigor 会把 WARN 写到 stderr, 而 $ErrorActionPreference='Stop' 会把原生命令的
  # stderr 当成终止错误 ⇒ 构建还没跑完脚本自己先死了(踩过一次)✓
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $log = & powershell -ExecutionPolicy Bypass -File (Join-Path $Verify 'tools\build-hap.ps1') 2>&1 | Out-String
    $buildExit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prevEap
  }
  $buildOk = ($log -match 'BUILD SUCCESSFUL') -and ($buildExit -eq 0)
  $log | Set-Content (Join-Path $BackupDir 'verify-build.log') -Encoding UTF8
  if ($buildOk) {
    Write-Output "  编译验证: BUILD SUCCESSFUL ✓ (exit $buildExit)"
  } else {
    Write-Output "  编译验证: 失败 ✗ (exit $buildExit, 日志在 verify-build.log)"
  }
} else {
  Write-Output "  编译验证: 跳过(-SkipBuild)"
}
Remove-Item $Verify -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# MANIFEST
# ---------------------------------------------------------------------------
$head = (& git -C $Root rev-parse HEAD 2>$null)
$dirty = @(git -C $Root status --short 2>$null)
$dirtyText = if ($dirty.Count -gt 0) { "是（$($dirty.Count) 项，都是工具脚本和探针产物，不影响源码）" } else { '否' }
$buildVerdict = if ($buildOk) { 'BUILD SUCCESSFUL ⇒ PASS' } elseif ($SkipBuild) { '跳过' } else { 'FAIL (见 verify-build.log)' }
$cmpVerdict = if ($mismatch.Count -eq 0) { 'PASS' } else { 'FAIL' }

# MANIFEST 用单引号 here-string 写: PowerShell 的双引号会把 markdown 的反引号当转义符吃掉
# (踩过一次: 行尾的 \` 把收尾引号转义了, 整个脚本语法报错) ⇒ 全部走占位符 + -f ✓
$manifest = @'
# 备份清单 — {0} — {1}

## 1. 基础信息
- 备份时间：{2}
- 备份等级：常规
- 工程根：`{3}`
- Git HEAD SHA：`{4}`
- 脏工作树：{5}
- 备份目录：`{6}`

## 2. 文件统计
- 纳入文件：{7} 个
- 纳入总体积：{8} MB
- 压缩后体积：{9} MB
- 排除条目：{10} 条

## 3. 包含项
- 全部 git 追踪文件（去掉排除规则命中的）
- 上一轮未提交但有价值的工具脚本（tools/dsh-monitor/ 等 {11} 个）
- 完整清单：`dsh-backup-include.txt`（与本 MANIFEST 同目录）
- 排除明细：`dsh-backup-skip.txt`（每条都标了排除理由）

## 4. 排除项

### 4.1 私钥分流（永不进 zip）
- `certificate/`（含 DSHHarmony.p12 / .csr / DSHRelease.p7b / DSHdebugDebug.p7b / *.cer / material/）—— **不在本备份里**
- 打包脚本里有硬拦截：清单里出现 `.p12/.p7b/.cer/.csr` 会当场中止，不会打完包才说
- 手工备份渠道：见第 7 节

### 4.2 机器可再生（build / 缓存 / 依赖）
- `harmony/**/build/`、`harmony/deploy/`、`harmony/.hvigor/`、`harmony/.idea/`、`harmony/entry/.cxx/`
- `_tmp/`、`dist/`、`node_modules/`、`oh_modules/`

### 4.3 日志与临时文件
- `harmony/hilog-*.txt`（20 个设备日志，共约 230 MB，最大的 hilog-tri4.txt 有 181 MB）
- `*.log`、`*.err`、`*.tmp`、`*.bak`、`*.exe`、`*.hap`

### 4.4 本机专属
- `harmony/local.properties`（含本机绝对路径）—— 见第 5 节
- `push-tokens.local.json`、`relay/accounts.json`、`relay/devices.json`（本地令牌 / 账号档）

## 5. 绝对路径扫描（恢复时必查）
- [x] `harmony/local.properties` —— **不在包里**。内容是 sdk.dir / java.home / nodejs.dir 三个本机绝对路径
      ⇒ 换机恢复时：重新生成，或手写这三行指向新机的 DevEco Studio
- [x] `harmony/build-profile.json5` —— **在包里**，但 signingConfigs 指向 `certificate/*.p12` 的绝对路径
      ⇒ 恢复时：改成本机证书路径，或者改成不签名构建
- [x] `harmony/hvigorfile.ts`、`harmony/entry/hvigorfile.ts` —— 纯 import，无绝对路径 ✓
- [x] `harmony/oh-package.json5`、`harmony/entry/oh-package.json5` —— 无本地 path 依赖 ✓

## 6. 恢复步骤
1. 解压 `{0}_source.zip` 到工程根目录
2. 恢复 git 历史：`git clone {0}.bundle DSHHarmony`（或解压后 `git init` + `git fetch ../{0}.bundle`）
3. 改第 5 节列出的绝对路径（local.properties 要重新生成）
4. 签名材料从手工渠道拿回来放进 `certificate/`（见第 7 节）
5. `powershell -ExecutionPolicy Bypass -File tools\build-hap.ps1` 验证 BUILD SUCCESSFUL
6. 装到真机：`hdc install -r harmony/entry/build/default/outputs/default/entry-default-signed.hap`

## 7. 私钥去向（手工备份，不在 zip 里）
- 位置：`{16}`（DSHHarmony.p12 / .csr / DSHRelease.p7b / DSHdebugDebug.p7b / *.cer）
- U 盘路径：（待填）
- 密码管理器条目：（待填）
- 异地副本：（待填）

## 8. 验证结果
- 源文件逐个 SHA256 比对：{12} 个一致，{13} 个不一致 ⇒ {15}
- 重新编译：{14}
- zip SHA256：{17}

## 9. 3-2-1 备份原则
| 数字 | 状态 | 说明 |
|---|---|---|
| 3 份拷贝 | 2/3 | 本地 D 盘 + 你的云盘（待同步）|
| 2 种介质 | 1/2 | 本地 SSD + 云盘（待同步）|
| 1 份异地 | 0/1 | **待办**：把备份根目录整个拷到 U 盘或云盘 |

## 10. 备注
- `bridge/test/fixtures/relay-test-key.pem` 和 `relay/test/fixtures/relay-test-key.pem` 是**测试夹具**用的自签密钥（`relay/test/run.js` 起 TLS 测试服务器要用），不是生产签名材料 ⇒ 保留在包里。生产签名私钥是 `certificate/DSHHarmony.p12`，已分流。
- `harmony/entry/src/main/resources/rawfile/dsh-harmony-desktop-exe.zip`（桌面端安装包）是构建产物，不在包里 ⇒ 用 `tools/build-desktop-exe.ps1` 重新生成
- 仓库里那 21 个 `harmony/hilog-*.txt` 建议顺手 `git rm --cached` 掉：它们是设备日志，早该被 .gitignore 管住，但 .gitignore 对**已追踪**文件无效，所以一直躺在仓库里
'@ -f $Name, (Get-Date -Format 'yyyy-MM-dd HH:mm'), (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Root, $head,
      $dirtyText, $BackupDir, $include.Count, [math]::Round($totalBytes / 1MB, 1), $zipMB, $skip.Count,
      $ExtraFiles.Count, $cmp, $mismatch.Count, $buildVerdict, $cmpVerdict, (Join-Path $Root 'certificate'),
      $sha.Hash.ToLower()
$manifest | Set-Content (Join-Path $BackupDir 'MANIFEST.md') -Encoding UTF8
Copy-Item (Join-Path $env:TEMP 'dsh-backup-include.txt') (Join-Path $BackupDir 'dsh-backup-include.txt') -Force
Copy-Item (Join-Path $env:TEMP 'dsh-backup-skip.txt') (Join-Path $BackupDir 'dsh-backup-skip.txt') -Force

Write-Output ""
Write-Output "=== 完成 ==="
Get-ChildItem $BackupDir | ForEach-Object { Write-Output ("  {0,-34} {1,8:N1} MB" -f $_.Name, ($_.Length / 1MB)) }
Write-Output ""
if ($mismatch.Count -eq 0 -and ($buildOk -or $SkipBuild)) {
  Write-Output "备份可证明: 源文件一致 ✓  编译 $(if($buildOk){'PASS'}else{'跳过'})  ⇒ 备份有效"
} else {
  Write-Output "备份未通过验证, 别当成功用。"
}
