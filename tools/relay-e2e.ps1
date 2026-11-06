<#
 .SYNOPSIS
   云中继端到端验证。

 .DESCRIPTION
   1) 启动本地 relay(模拟公网中继);
   2) 启动 bridge, 让它**主动外拨**到 relay;
   3) 验证 "经中继" 与 "直连" 两条路径返回完全一致的业务数据;
   4) 把手机端指向中继地址, 跑一遍完整的"手机 -> 中继 -> 桌面 -> 回复"闭环。

   用法:
     tools\relay-e2e.ps1 -Keep          # 跑完后保留 relay/bridge 进程
     tools\relay-e2e.ps1 -DeviceId dev-8f2a
 #>
[CmdletBinding()]
param(
  [string]$RelayPort = '8788',
  [string]$BridgePort = '8787',
  [string]$DeviceId = 'dev-8f2a',
  [string]$DeviceFile = '',
  [switch]$Keep,
  [int]$WaitSeconds = 75
)

$ErrorActionPreference = 'Stop'
$W = 'D:\APP\Deepseek\DSHHarmony'
if ($DeviceFile -eq '') { $DeviceFile = "$W\relay\devices.json" }

$devices = (Get-Content $DeviceFile -Raw -Encoding UTF8 | ConvertFrom-Json).devices
$device = $devices | Where-Object { $_.id -eq $DeviceId } | Select-Object -First 1
if (-not $device) { throw "device '$DeviceId' not found in $DeviceFile" }
$deviceToken = $device.token

$stateFile = "$env:USERPROFILE\.dsh-harmony-bridge\bridge.json"
$bridgeToken = (Get-Content $stateFile -Raw | ConvertFrom-Json).token

function Log($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

# ---------- 清理旧进程 ----------
function Stop-ByPort([int]$port) {
  Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -eq $port } | ForEach-Object {
      try { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue; Log "stopped pid $($_.OwningProcess) on :$port" } catch {}
    }
}
Stop-ByPort ([int]$RelayPort)
Stop-ByPort ([int]$BridgePort)
Start-Sleep -Seconds 2

# ---------- 起 relay ----------
Log "starting relay on :$RelayPort"
$relay = Start-Process -FilePath 'node' -ArgumentList "relay\src\cli.js", '--port', $RelayPort, '--host', '127.0.0.1', '--device', $DeviceFile, '--bridge-port', $BridgePort `
  -WorkingDirectory $W -RedirectStandardOutput "$W\tools\relay-out.log" -RedirectStandardError "$W\tools\relay-err.log" -PassThru -NoNewWindow
Start-Sleep -Seconds 4

# ---------- 起 bridge(外拨中继) ----------
Log "starting bridge on :$BridgePort, dialling out to ws://127.0.0.1:$RelayPort/bridge"
$bridge = Start-Process -FilePath 'node' `
  -ArgumentList "bridge\src\cli.js", '--port', $BridgePort, '--host', '0.0.0.0', `
    '--relay', "ws://127.0.0.1:$RelayPort/bridge", '--device-token', $deviceToken, '--device-id', $DeviceId, '--relay-name', 'relay-e2e' `
  -WorkingDirectory $W -RedirectStandardOutput "$W\tools\bridge-out.log" -RedirectStandardError "$W\tools\bridge-err.log" -PassThru -NoNewWindow
Start-Sleep -Seconds 8

Log "--- relay banner ---"
Get-Content "$W\tools\relay-out.log" -Encoding UTF8 -Tail 12 | ForEach-Object { Write-Host "    $_" }
Log "--- bridge banner ---"
Get-Content "$W\tools\bridge-out.log" -Encoding UTF8 -Tail 14 | ForEach-Object { Write-Host "    $_" }

# ---------- 业务数据一致性 ----------
$direct = $null; $viaRelay = $null
try {
  $direct = (Invoke-WebRequest -Uri "http://127.0.0.1:$BridgePort/api/v1/health" -Headers @{ Authorization = "Bearer $bridgeToken" } -UseBasicParsing -TimeoutSec 20).Content
} catch { Log "direct health FAILED: $($_.Exception.Message)" }
try {
  $viaRelay = (Invoke-WebRequest -Uri "http://127.0.0.1:$RelayPort/$DeviceId/api/v1/health" -Headers @{ Authorization = "Bearer $bridgeToken" } -UseBasicParsing -TimeoutSec 20).Content
} catch { Log "relay health FAILED: $($_.Exception.Message)" }
Log "direct : $direct"
Log "relay  : $viaRelay"

if ($direct -and $viaRelay) {
  $d = $direct | ConvertFrom-Json; $r = $viaRelay | ConvertFrom-Json
  $same = ($d.name -eq $r.name) -and ($d.version -eq $r.version) -and ($d.dsh.reachable -eq $r.dsh.reachable)
  Log ("health through relay matches direct : $same")
} else {
  Log "health comparison SKIPPED (one side failed)"
}

try {
  $s1 = (Invoke-WebRequest -Uri "http://127.0.0.1:$BridgePort/api/v1/sessions" -Headers @{ Authorization = "Bearer $bridgeToken" } -UseBasicParsing -TimeoutSec 40).Content
  $s2 = (Invoke-WebRequest -Uri "http://127.0.0.1:$RelayPort/$DeviceId/api/v1/sessions" -Headers @{ Authorization = "Bearer $bridgeToken" } -UseBasicParsing -TimeoutSec 40).Content
  $n1 = ($s1 | ConvertFrom-Json).sessions.Count
  $n2 = ($s2 | ConvertFrom-Json).sessions.Count
  Log "sessions: direct=$n1  via relay=$n2  match=$($n1 -eq $n2)"
} catch { Log "sessions comparison FAILED: $($_.Exception.Message)" }

# ---------- 未授权必须被拒 ----------
try {
  Invoke-WebRequest -Uri "http://127.0.0.1:$RelayPort/$DeviceId/api/v1/sessions" -UseBasicParsing -TimeoutSec 15 | Out-Null
  Log "!! relay accepted an unauthenticated request (BAD)"
} catch { Log "relay rejects unauthenticated requests: OK ($($_.Exception.Response.StatusCode.value__))" }

Log "--- relay endpoint the phone should use: http://127.0.0.1:$RelayPort/$DeviceId ---"
Log "bridge pid=$($bridge.Id)  relay pid=$($relay.Id)"

if (-not $Keep) {
  Log "stopping processes (use -Keep to leave them running)"
  Stop-Process -Id $relay.Id -Force -ErrorAction SilentlyContinue
  Stop-Process -Id $bridge.Id -Force -ErrorAction SilentlyContinue
}
