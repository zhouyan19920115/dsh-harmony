param(
  [Parameter(Mandatory = $true)][string]$SessionId,
  [Parameter(Mandatory = $true)][string]$Question,
  [string[]]$Options = @(),
  [int]$TimeoutSec = 600
)
# 手机可答的提问: 桥接 hold 住这个请求, 等手机在卡片上回答后返回答案。
$state = Get-Content "$env:USERPROFILE\.dsh-harmony-bridge\bridge.json" -Raw | ConvertFrom-Json
$headers = @{ Authorization = "Bearer $($state.token)"; 'Content-Type' = 'application/json' }
$opts = @()
foreach ($o in $Options) { $opts += @{ label = $o } }
$body = @{
  sessionId = $SessionId
  timeoutMs = $TimeoutSec * 1000
  questions = @(@{ id = 'q1'; question = $Question; options = $opts })
} | ConvertTo-Json -Depth 6
$resp = Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:8787/api/v1/ask' -Headers $headers -Body $body -TimeoutSec ($TimeoutSec + 30)
$resp | ConvertTo-Json -Depth 6
