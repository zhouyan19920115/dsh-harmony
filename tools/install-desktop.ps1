# DSH Harmony · 桌面端安装 / 启动脚本(更完整的那条路)
#
#   powershell -ExecutionPolicy Bypass -File tools\install-desktop.ps1
#
# 不想敲命令就直接双击 tools\start-desktop.cmd。
# 这个脚本多做几件事: 端口占用检测、防火墙规则、输出写日志、可选拉起云中继。
#
# 这个文件同时也是「中文文案」的唯一出处: start-desktop.cmd 是纯 ASCII 的(原因见那边的
# 注释), 它靠 -Message 参数让本脚本把中文提示打出来。
#
# ---------------------------------------------------------------------------
# 为什么这个文件没有 param() 块, 也没有 comment-based help:
# Windows PowerShell 5.1 会把 "-?" 抢走当成 powershell.exe 自己的帮助参数, 脚本根本
# 不会执行(而且什么都不打印)。没有 param() 块时 "-?" 才会原样落进 $args, 于是这里
# 自己解析、自己打印帮助。$args 的解析见下面的参数解析部分。
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

function Show-Help {
  Write-Host ''
  Write-Host '  DSH Harmony · 桌面端安装 / 启动脚本 (install-desktop.ps1)'
  Write-Host '  ============================================================'
  Write-Host ''
  Write-Host '  用法:'
  Write-Host '    powershell -ExecutionPolicy Bypass -File tools\install-desktop.ps1 [选项]'
  Write-Host ''
  Write-Host '  选项:'
  Write-Host '    -Port <端口>          桥接服务端口 (默认 8787)'
  Write-Host '    -Host <地址>          监听地址 (默认 0.0.0.0; 手机要能连就别改成 127.0.0.1)'
  Write-Host '    -Relay                顺便把云中继也拉起来 (远程用)'
  Write-Host '    -RelayPort <端口>     云中继端口 (默认 8788)'
  Write-Host '    -RelayUrl <url>       云中继地址 (默认 ws://127.0.0.1:<RelayPort>/bridge)'
  Write-Host '    -Account <id>         中继账号 id (默认从 relay\accounts.json 读)'
  Write-Host '    -AccountToken <hex>   中继账号令牌 (默认从 relay\accounts.json 读)'
  Write-Host '    -DeviceId <id>        本机设备号 (默认从注册表读)'
  Write-Host '    -DeviceName <名字>    本机设备名 (默认取电脑名)'
  Write-Host '    -DshUrl <url>         桌面端 DSH 地址 (默认自动探测, 平时不用填)'
  Write-Host '    -NoFirewall           不检查也不添加防火墙规则'
  Write-Host '    -DryRun               只做检查, 不启动'
  Write-Host '    -Message <种类>       只打印一段中文提示然后退出: banner / nonode / portbusy'
  Write-Host '                         (start-desktop.cmd 内部用, 一般不用手敲)'
  Write-Host '    -?  -h  --help        显示这份帮助'
  Write-Host ''
  Write-Host '  例子:'
  Write-Host '    # 最常见: 默认端口, 手机和电脑同一个 WiFi'
  Write-Host '    powershell -ExecutionPolicy Bypass -File tools\install-desktop.ps1'
  Write-Host ''
  Write-Host '    # 端口被占了, 换一个'
  Write-Host '    powershell -ExecutionPolicy Bypass -File tools\install-desktop.ps1 -Port 8899'
  Write-Host ''
  Write-Host '    # 远程(手机不在同一个 WiFi): 连云中继一起起'
  Write-Host '    powershell -ExecutionPolicy Bypass -File tools\install-desktop.ps1 -Relay'
  Write-Host ''
  exit 0
}

# --------------------------------------------------------------------- 中文文案
# 这里集中放所有给用户看的中文。start-desktop.cmd 本身是纯 ASCII 的, 由它调用本函数。
function Show-Message([string]$kind, [string]$port = '8787', [int]$processId = 0) {
  switch ($kind) {
    'nonode' {
      Write-Host ''
      Write-Host '  [!] 没有找到 Node.js。'
      Write-Host ''
      Write-Host '      这个项目需要 Node.js 20 或更高版本。它是零依赖的(只用 Node 自带模块,'
      Write-Host '      不需要 npm install), 装完 Node 就能跑。'
      Write-Host ''
      Write-Host '      官方下载(选 LTS 就行): https://nodejs.org/en/download'
      Write-Host ''
      Write-Host '      装完之后重新双击 tools\start-desktop.cmd。'
      Write-Host ''
    }
    'portbusy' {
      Write-Host ''
      Write-Host "  [!] 端口 $port 已经被别的程序占用了。"
      Write-Host ''
      Write-Host '      关掉占用它的程序, 或者换一个端口:'
      Write-Host '        tools\start-desktop.cmd --port 8899'
      Write-Host ''
    }
    'background' {
      Write-Host ''
      Write-Host '  [✓] 桌面端已在后台运行(没有窗口, 关掉这个窗口也不会停 ✓)。'
      Write-Host ''
      Write-Host '      手机怎么连:'
      Write-Host '        1) 手机和电脑连同一个 WiFi'
      Write-Host '        2) 打开 App -> 连接页 -> 点「自动发现」'
      Write-Host '        3) 选你的这台电脑 -> 自动配对(不用手输令牌)'
      Write-Host ''
      Write-Host '      要手动填地址(地址/令牌/二维码都在日志里):'
      Write-Host '        logs\bridge-daemon.log'
      Write-Host ''
      Write-Host '      要停掉它:'
      Write-Host '        双击我-开始.cmd --stop'
      Write-Host ''
    }
    'stopped' {
      Write-Host ''
      Write-Host '  [✓] 桌面端已停止。'
      Write-Host ''
    }
    'notrunning' {
      Write-Host ''
      Write-Host '  [i] 桌面端没有在运行(端口上没有桥接)。'
      Write-Host ''
      Write-Host '      要启动它: 双击「双击我-开始.cmd」'
      Write-Host ''
    }
    'running' {
      Write-Host ''
      Write-Host "  [✓] 桌面端正在运行(端口 $port, 进程 $processId)。"
      Write-Host ''
      Write-Host '      要停掉它: 双击我-开始.cmd --stop'
      Write-Host ''
    }
    'installed' {
      Write-Host ''
      Write-Host '  [✓] 已经注册成开机自启的服务(登录时自动在后台起来, 没有窗口 ✓)。'
      Write-Host ''
      Write-Host '      它现在就在后台跑着, 关掉这个窗口也没关系 ✓'
      Write-Host ''
      Write-Host '      要取消注册: 双击我-开始.cmd --uninstall'
      Write-Host ''
    }
    'uninstalled' {
      Write-Host ''
      Write-Host '  [✓] 开机自启已取消(服务本身还在跑, 要停: 双击我-开始.cmd --stop)。'
      Write-Host ''
    }
    'installed' {
      Write-Host ''
      Write-Host '  [✓] 已经注册成开机自启的服务(登录时自动在后台起来, 没有窗口 ✓)。'
      Write-Host ''
      Write-Host '      现在就在后台运行了, 关掉这个窗口也没关系 ✓'
      Write-Host ''
      Write-Host '      要取消注册: 双击我-开始.cmd --uninstall'
      Write-Host ''
    }
    'uninstalled' {
      Write-Host ''
      Write-Host '  [✓] 开机自启已取消(服务本身还在跑, 要停: 双击我-开始.cmd --stop)。'
      Write-Host ''
    }
    default {
      Write-Host ''
      Write-Host '  手机怎么连:'
      Write-Host '    1) 手机和电脑连同一个 WiFi'
      Write-Host '    2) 打开 App -> 连接页 -> 点「自动发现」'
      Write-Host '    3) 选你的这台电脑 -> 自动配对(不用手输令牌)'
      Write-Host ''
      Write-Host '  [!] 手机连不上? 多半是防火墙挡住了 node.exe 的入站。以管理员身份运行:'
      Write-Host "        netsh advfirewall firewall add rule name=`"DSH Harmony Bridge`" dir=in action=allow protocol=TCP localport=$port profile=private"
      Write-Host ''
    }
  }
}

# --------------------------------------------------------------------- 参数解析
# 没有 param() 块: 这样 "-?" 才会落到 $args 里(见文件头的说明)。
$options = @{
  Port         = 8787
  Host         = '0.0.0.0'
  Relay        = $false
  RelayPort    = 8788
  RelayUrl     = ''
  Account      = ''
  AccountToken = ''
  DeviceId     = ''
  DeviceName   = ''
  DshUrl       = ''
  NoFirewall   = $false
  DryRun       = $false
  Message      = ''
  SelfSigned   = $false
  CertDir      = ''
  CertName     = ''
  CertHosts    = ''
  InstallNode  = $false
  StartHidden  = $false
  Script       = ''
  StopBridge   = $false
  StatusBridge = $false
  InstallRun   = $false
  UninstallRun = $false
  Launcher     = ''
  Pass         = @()
}

$argList = @($args)
for ($i = 0; $i -lt $argList.Count; $i++) {
  $arg = [string]$argList[$i]
  $key = $arg.ToLowerInvariant()
  # "--port" 与 "-Port" 都认
  $key = $key -replace '^--', '-'
  switch ($key) {
    '-?'             { Show-Help }
    '/?'             { Show-Help }
    '--?'            { Show-Help }
    '-h'             { Show-Help }
    '--help'         { Show-Help }
    '-help'          { Show-Help }
    '-relay'         { $options.Relay = $true; break }
    '-dryrun'        { $options.DryRun = $true; break }
    '-nofirewall'    { $options.NoFirewall = $true; break }
    '-port'          { $i++; $options.Port = [int]$argList[$i]; break }
    '-host'          { $i++; $options.Host = [string]$argList[$i]; break }
    '-relayport'     { $i++; $options.RelayPort = [int]$argList[$i]; break }
    '-relayurl'      { $i++; $options.RelayUrl = [string]$argList[$i]; break }
    '-account'       { $i++; $options.Account = [string]$argList[$i]; break }
    '-accounttoken'  { $i++; $options.AccountToken = [string]$argList[$i]; break }
    '-account-token' { $i++; $options.AccountToken = [string]$argList[$i]; break }
    '-deviceid'      { $i++; $options.DeviceId = [string]$argList[$i]; break }
    '-device-id'     { $i++; $options.DeviceId = [string]$argList[$i]; break }
    '-devicename'    { $i++; $options.DeviceName = [string]$argList[$i]; break }
    '-device-name'   { $i++; $options.DeviceName = [string]$argList[$i]; break }
    '-dshurl'        { $i++; $options.DshUrl = [string]$argList[$i]; break }
    '-dsh-url'       { $i++; $options.DshUrl = [string]$argList[$i]; break }
    '-message'       { $i++; $options.Message = [string]$argList[$i]; break }
    default {
      if ($arg.StartsWith('-')) { throw "未知参数: $arg  (加 -? 看帮助)" }
      $options.Pass += $arg
    }
  }
}

# --------------------------------------------------------------------- 只打印提示
if ($options.Message -ne '') {
  Show-Message $options.Message $options.Port
  exit 0
}

# --------------------------------------------------------------------- 自签证书
# DER 编码助手: 把 RSA 参数写成 PKCS#1 的 PEM。
# Windows PowerShell 5.1(.NET Framework)没有 ExportPkcs8PrivateKey / ExportRSAPrivateKey,
# 所以这里手写最小 DER 编码器: SEQUENCE { INTEGER ... }。
function New-DerLength([int]$length) {
  $out = New-Object System.Collections.Generic.List[byte]
  if ($length -lt 0x80) { $out.Add([byte]$length); return ,$out.ToArray() }
  $tmp = New-Object System.Collections.Generic.List[byte]
  $v = $length
  while ($v -gt 0) { $tmp.Insert(0, [byte]($v -band 0xFF)); $v = $v -shr 8 }
  $out.Add([byte](0x80 -bor $tmp.Count))
  $out.AddRange($tmp)
  return ,$out.ToArray()
}
function New-DerInteger([byte[]]$value) {
  $start = 0
  while ($start -lt ($value.Length - 1) -and $value[$start] -eq 0) { $start++ }
  $body = New-Object System.Collections.Generic.List[byte]
  for ($i = $start; $i -lt $value.Length; $i++) { $body.Add($value[$i]) }
  if ($body.Count -gt 0 -and ($body[0] -band 0x80) -ne 0) { $body.Insert(0, 0) }
  $out = New-Object System.Collections.Generic.List[byte]
  $out.Add(0x02)
  $out.AddRange((New-DerLength $body.Count))
  $out.AddRange($body)
  return ,$out.ToArray()
}
function New-DerSequence([byte[]]$content) {
  $out = New-Object System.Collections.Generic.List[byte]
  $out.Add(0x30)
  $out.AddRange((New-DerLength $content.Length))
  $out.AddRange($content)
  return ,$out.ToArray()
}
function Export-RsaPrivateKeyPem([System.Security.Cryptography.RSA]$rsa) {
  $prm = $rsa.ExportParameters($true)
  $content = New-Object System.Collections.Generic.List[byte]
  $content.AddRange((New-DerInteger ([byte[]]@(0))))
  foreach ($name in @('Modulus', 'Exponent', 'D', 'P', 'Q', 'DP', 'DQ', 'InverseQ')) {
    $content.AddRange((New-DerInteger $prm.$name))
  }
  $der = New-DerSequence $content.ToArray()
  return ("-----BEGIN RSA PRIVATE KEY-----`r`n" +
    [Convert]::ToBase64String($der, 'InsertLineBreaks') + "`r`n-----END RSA PRIVATE KEY-----`r`n")
}

# 中继的 TLS 证书。桌桥 -> 中继这一段必须加密(评审 P0), 所以启动器默认用 wss。
# 证书用 .NET 的 CertificateRequest 现场签一张(不需要 openssl, 不需要联网):
#   * SAN 里写上中继域名和公网 IP;
#   * 手机端第一次连接时弹窗让用户核对 SHA256 指纹(就是这里打印的那个)。
function New-RelayCertificate([string]$dir, [string]$commonName, [string]$hostList) {
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $certPath = Join-Path $dir 'relay-cert.pem'
  $keyPath  = Join-Path $dir 'relay-key.pem'
  $metaPath = Join-Path $dir 'relay-cert.txt'
  $names = @($hostList -split '[,;\s]+' | Where-Object { $_ -ne '' })
  if ($names.Count -eq 0) { $names = @('localhost', '127.0.0.1') }

  $reuse = $false
  if ((Test-Path $certPath) -and (Test-Path $keyPath) -and (Test-Path $metaPath)) {
    $meta = Get-Content $metaPath -Raw -ErrorAction SilentlyContinue
    if ($meta -and ($meta -match [regex]::Escape($commonName))) { $reuse = $true }
  }
  if (-not $reuse) {
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest(
      "CN=$commonName", $rsa,
      [System.Security.Cryptography.HashAlgorithmName]::SHA256,
      [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $san = New-Object System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder
    foreach ($n in $names) {
      if ($n -match '^\d{1,3}(\.\d{1,3}){3}$') {
        [void]$san.AddIpAddress([System.Net.IPAddress]::Parse($n))
      } else {
        [void]$san.AddDnsName($n)
      }
    }
    $req.CertificateExtensions.Add($san.Build())
    $req.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension($false, $false, 0, $true)))
    $req.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509KeyUsageExtension(
      ([System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor
       [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment), $true)))
    $oids = New-Object System.Security.Cryptography.OidCollection
    [void]$oids.Add((New-Object System.Security.Cryptography.Oid('1.3.6.1.5.5.7.3.1')))
    $req.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension($oids, $false)))
    $notBefore = [DateTimeOffset]::UtcNow.AddDays(-1)
    $notAfter = [DateTimeOffset]::UtcNow.AddYears(2)
    $cert = $req.CreateSelfSigned($notBefore, $notAfter)

    $der = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $certPem = "-----BEGIN CERTIFICATE-----`r`n" +
      [Convert]::ToBase64String($der, 'InsertLineBreaks') + "`r`n-----END CERTIFICATE-----`r`n"
    [System.IO.File]::WriteAllText($certPath, $certPem, [System.Text.Encoding]::ASCII)
    $keyPem = Export-RsaPrivateKeyPem $rsa
    [System.IO.File]::WriteAllText($keyPath, $keyPem, [System.Text.Encoding]::ASCII)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fingerprint = -join ($sha.ComputeHash($der) | ForEach-Object { $_.ToString('x2') })
  } else {
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certPath)
    $der = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fingerprint = -join ($sha.ComputeHash($der) | ForEach-Object { $_.ToString('x2') })
  }
  Set-Content -Path $metaPath -Value ("commonName=$commonName`nhosts=$($names -join ',')`nfingerprint=$fingerprint`n") -Encoding ASCII
  Write-Output "CERT=$certPath"
  Write-Output "KEY=$keyPath"
  Write-Output "FINGERPRINT=$fingerprint"
}

if ($options.SelfSigned) {
  $certDir = $options.CertDir
  if ($certDir -eq '') { $certDir = Join-Path $env:LOCALAPPDATA 'dsh-harmony\relay-tls' }
  $certName = $options.CertName
  if ($certName -eq '') { $certName = 'dsh-harmony-relay' }
  $certHosts = $options.CertHosts
  if ($certHosts -eq '') { $certHosts = 'localhost,127.0.0.1' }
  New-RelayCertificate $certDir $certName $certHosts
  exit 0
}

# --------------------------------------------------------------------- 定位仓库
$root = Split-Path -Parent $PSScriptRoot
$bridgeCli = Join-Path $root 'bridge\src\cli.js'
$relayCli = Join-Path $root 'relay\src\cli.js'

# --------------------------------------------------------------------- 装 Node
# 这台电脑上没装 Node.js 时, 启动器会调这里(命令行是 -InstallNode)。
#
# 装的是 **zip 版**: 免管理员、免改系统 PATH、不写注册表 —— 解压到 <根目录>\runtime\ 里,
# 启动器把它加进 PATH 用。删掉 runtime\ 这个目录就等于没装过 ✓
function Install-NodeRuntime([string]$base) {
  $runtime = Join-Path $base 'runtime'
  $nodeExe = Join-Path $runtime 'node.exe'
  if (Test-Path $nodeExe) {
    Write-Host '  [i] 这个包里已经带了一份 Node.js(runtime\node.exe), 直接用。'
    return $nodeExe
  }
  Write-Host ''
  Write-Host '  [i] 这台电脑上还没有 Node.js, 现在下载一个(要联网, 等一会儿)。'
  Write-Host ''
  $index = $null
  try {
    $index = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 90
  } catch {
    Write-Host '  [!] 连不上 nodejs.org, 自动装不了。'
    Write-Host '      手动装也行(选 LTS): https://nodejs.org/en/download'
    return $null
  }
  $release = $null
  foreach ($item in @($index)) {
    if ($item.lts -ne $false) { $release = $item; break }
  }
  if ($null -eq $release) { $release = @($index)[0] }
  if ($null -eq $release) {
    Write-Host '  [!] 拿不到 Node.js 的版本列表。'
    return $null
  }
  $version = [string]$release.version
  $url = "https://nodejs.org/dist/$version/node-$version-win-x64.zip"
  Write-Host "      版本: $version"
  Write-Host "      下载: $url"
  $tmp = Join-Path $env:TEMP "node-$version-win-x64.zip"
  $tmpDir = Join-Path $env:TEMP "node-$version-unpack"
  try {
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 900
    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
    Expand-Archive -LiteralPath $tmp -DestinationPath $tmpDir -Force
    $inner = Get-ChildItem $tmpDir -Directory | Select-Object -First 1
    if ($null -eq $inner) { throw '解压出来的目录是空的' }
    if (Test-Path $runtime) { Remove-Item $runtime -Recurse -Force }
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    Get-ChildItem -LiteralPath $inner.FullName -Force | ForEach-Object {
      Move-Item -LiteralPath $_.FullName -Destination $runtime -Force
    }
  } catch {
    Write-Host "  [!] 下载或解压失败: $($_.Exception.Message)"
    return $null
  } finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (-not (Test-Path $nodeExe)) {
    Write-Host '  [!] 装完了但没找到 runtime\node.exe。'
    return $null
  }
  Write-Host ''
  Write-Host '  [ok] Node.js 装好了: runtime\node.exe'
  return $nodeExe
}

if ($options.InstallNode) {
  $installed = Install-NodeRuntime $root
  if ($null -eq $installed) { exit 1 }
  Write-Output $installed
  exit 0
}
$relayAccounts = Join-Path $root 'relay\accounts.json'
$logDir = Join-Path $root 'logs'
Set-Location $root

function Say([string]$text) { Write-Host $text }
function Step([string]$text) { Write-Host "  $text" -ForegroundColor Cyan }

Say ''
Say '  DSH Harmony · 桌面端安装 / 启动'
Say '  ============================================================'
Say ''

# --------------------------------------------------------------------- Node
$node = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $node) {
  Show-Message 'nonode'
  exit 1
}
$nodeVersion = (& node -v) 2>$null
$nodeMajor = 0
if ($nodeVersion -match 'v(\d+)\.') { $nodeMajor = [int]$Matches[1] }
if ($nodeMajor -lt 20) {
  Say "  [!] Node.js 版本太老($nodeVersion), 这个项目需要 20 或更高版本。"
  Say ''
  Say '      官方下载(选 LTS 就行): https://nodejs.org/en/download'
  Say ''
  exit 1
}
Step "[1/5] Node.js $nodeVersion"

if (-not (Test-Path $bridgeCli)) {
  Say ''
  Say "  [!] 找不到 $bridgeCli"
  Say '      确认你复制的是整个仓库: bridge\ 和 relay\ 都要在。'
  Say ''
  exit 1
}
Step '[2/5] 代码齐全 (bridge\ + relay\)'

# --------------------------------------------------------------------- 端口
function Test-PortBusy([int]$port) {
  try {
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($null -ne $conn) { return @($conn) }
  } catch {
    # 老系统没有 Get-NetTCPConnection, 退回 netstat。
    $lines = & netstat -ano 2>$null | Select-String -Pattern (":" + $port + "\s+.*LISTENING")
    if ($null -ne $lines) { return @($lines) }
  }
  return @()
}

$busy = Test-PortBusy $options.Port
if ($busy.Count -gt 0) {
  Say ''
  Say "  [!] 端口 $($options.Port) 已经被别的程序占用了。"
  foreach ($entry in $busy) {
    $owner = ''
    try { $owner = (Get-Process -Id $entry.OwningProcess -ErrorAction SilentlyContinue).ProcessName } catch { }
    if ($owner) { Say "        占用者: $owner (PID $($entry.OwningProcess))" }
  }
  Say ''
  Say '        关掉占用它的程序, 或者换一个端口:'
  Say "          powershell -ExecutionPolicy Bypass -File tools\install-desktop.ps1 -Port 8899"
  Say ''
  exit 1
}
Step "[3/5] 端口 $($options.Port) 空闲"

# --------------------------------------------------------------------- 防火墙
$firewallName = 'DSH Harmony Bridge'
if (-not $options.NoFirewall) {
  $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
  $rule = Get-NetFirewallRule -DisplayName $firewallName -ErrorAction SilentlyContinue
  if ($null -eq $rule) {
    $nodeAllowed = $false
    try {
      $nodeAllowed = $null -ne (Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
        Where-Object { $_.Program -like '*node.exe' })
    } catch { }
    if ($nodeAllowed) {
      Step "[4/5] 防火墙: node.exe 已经放行过了"
    } elseif ($isAdmin) {
      New-NetFirewallRule -DisplayName $firewallName -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort $options.Port -Profile Private -ErrorAction SilentlyContinue | Out-Null
      Step "[4/5] 防火墙: 已加规则「$firewallName」(专用网络, TCP $($options.Port))"
    } else {
      Step "[4/5] 防火墙: 没有放行规则, 而当前不是管理员, 没法自动加"
      Say ''
      Say '        以管理员身份打开 PowerShell, 跑一次这条:'
      Say "          netsh advfirewall firewall add rule name=`"$firewallName`" dir=in action=allow protocol=TCP localport=$($options.Port) profile=private"
      Say ''
      Say '        (手机连不上的时候, 大概率就是这一条挡着)'
    }
  } else {
    Step "[4/5] 防火墙: 规则「$firewallName」已经在"
  }
} else {
  Step '[4/5] 防火墙: 按要求跳过'
}

# --------------------------------------------------------------------- 中继
$relayProcess = $null
$bridgeExtra = @()

function Get-RelayAccount {
  # 从注册表里挑一个账号 + 一台桌面设备。令牌只在本机, 不外传。
  if (-not (Test-Path $relayAccounts)) { return $null }
  try {
    $registry = Get-Content -Raw -LiteralPath $relayAccounts | ConvertFrom-Json
  } catch {
    return $null
  }
  $accounts = @($registry.accounts)
  if ($accounts.Count -eq 0) { return $null }
  $account = $accounts | Where-Object { @($_.devices).Count -gt 0 } | Select-Object -First 1
  if ($null -eq $account) { $account = $accounts[0] }
  $device = @($account.devices) | Where-Object { $_.role -eq 'desktop' } | Select-Object -First 1
  if ($null -eq $device) { $device = @($account.devices) | Select-Object -First 1 }
  if ($null -eq $device) { return $null }
  return [pscustomobject]@{
    AccountId = [string]$account.id
    AccountToken = [string]$account.token
    DeviceId = [string]$device.id
    DeviceToken = [string]$device.token
  }
}

if ($options.Relay) {
  if (-not (Test-Path $relayCli)) {
    Say ''
    Say "  [!] 找不到 $relayCli, 云中继没法启动。"
    Say '      局域网直连不需要中继, 去掉 -Relay 就能继续。'
    Say ''
    exit 1
  }
  if (-not (Test-Path $relayAccounts)) {
    Say '  [*] 还没有中继账号, 自动建一个(令牌是本机随机生成的, 不上传任何地方)'
    & node $relayCli --account-create --account-name '我的账号' --device-id dev-desktop --device-name $env:COMPUTERNAME | Out-Host
  }
  $account = Get-RelayAccount
  if ($null -eq $account) {
    Say ''
    Say '  [!] 中继注册表里没有可用的设备, 桥接服务先不带中继启动。'
    Say "      建一个账号: node relay\src\cli.js --account-create --device-id dev-desktop --device-name `"$env:COMPUTERNAME`""
    Say ''
  } else {
    $accountId = if ($options.Account) { $options.Account } else { $account.AccountId }
    $accountToken = if ($options.AccountToken) { $options.AccountToken } else { $account.AccountToken }
    $deviceId = if ($options.DeviceId) { $options.DeviceId } else { $account.DeviceId }
    $deviceToken = $account.DeviceToken
    $relayUrl = if ($options.RelayUrl) { $options.RelayUrl } else { "ws://127.0.0.1:$($options.RelayPort)/bridge" }
    $bridgeExtra += @('--relay', $relayUrl, '--device-token', $deviceToken, '--device-id', $deviceId,
      '--account', $accountId, '--account-token', $accountToken)
    if ($options.DeviceName) { $bridgeExtra += @('--relay-name', $options.DeviceName) }
    Step "[5/5] 云中继: 账号 $accountId / 设备 $deviceId -> $relayUrl"
  }
} else {
  Step '[5/5] 云中继: 没启动(远程访问才需要它; 加 -Relay 一起起)'
}

# --------------------------------------------------------------------- 日志
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bridgeLog = Join-Path $logDir "bridge-$stamp.log"

Show-Message 'banner' $options.Port
Say "  日志: $bridgeLog"
Say ''

if ($options.DryRun) {
  Say '  --dry-run: 检查完毕, 不启动服务。'
  exit 0
}

# --------------------------------------------------------------------- 中继进程
if ($options.Relay -and (Test-Path $relayCli) -and $bridgeExtra.Count -gt 0) {
  $relayLog = Join-Path $logDir "relay-$stamp.log"
  $relayArgs = @($relayCli, '--port', "$($options.RelayPort)", '--bridge-port', "$($options.Port)")
  $relayProcess = Start-Process -FilePath 'node' -ArgumentList $relayArgs -WorkingDirectory $root `
    -RedirectStandardOutput $relayLog -RedirectStandardError "$relayLog.err" -WindowStyle Hidden -PassThru
  Start-Sleep -Seconds 2
  Say "  云中继在后台跑着 (PID $($relayProcess.Id)), 日志: $relayLog"
  Say ''
}

# --------------------------------------------------------------------- 启动桥接
$bridgeArgs = @($bridgeCli, '--port', "$($options.Port)", '--host', $options.Host)
if ($options.DshUrl) { $bridgeArgs += @('--dsh-url', $options.DshUrl) }
$bridgeArgs += $bridgeExtra
$bridgeArgs += $options.Pass

Say '  ------------------------------------------------------------'
Say '  下面是桥接服务的输出: 局域网地址 / 令牌 / 配对码 / 二维码'
Say '  ------------------------------------------------------------'
Say ''

try {
  & node @bridgeArgs 2>&1 | Tee-Object -FilePath $bridgeLog
  $exitCode = $LASTEXITCODE
} finally {
  if ($null -ne $relayProcess) {
    Stop-Process -Id $relayProcess.Id -Force -ErrorAction SilentlyContinue
  }
}

Say ''
Say "  桥接服务已停止(退出码 $exitCode), 日志在 $bridgeLog"
exit $exitCode
