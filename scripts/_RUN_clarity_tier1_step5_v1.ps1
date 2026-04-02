param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source
$RuntimeRoot = "C:\ProgramData\Clarity"
$Principal = "single-tenant/operator/user/alec"
$Tenant = "single-tenant"
$ProducerInstance = ("{0}-standalone-1" -f $env:COMPUTERNAME)

$Bootstrap = Join-Path $RepoRoot "scripts\_bootstrap_clarity_standalone_v1.ps1"
$Open      = Join-Path $RepoRoot "scripts\display_session_open.ps1"
$Adapter   = Join-Path $RepoRoot "scripts\display_adapter_hyperv.ps1"
$Close     = Join-Path $RepoRoot "scripts\display_session_close.ps1"
$Replay    = Join-Path $RepoRoot "scripts\display_replay_view.ps1"

Write-Host "TIER1_STEP5: bootstrap" -ForegroundColor DarkGray
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Bootstrap -RepoRoot $RepoRoot | Out-Host

Write-Host "TIER1_STEP5: open_session" -ForegroundColor DarkGray
$openOut = @(& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Open -RuntimeRoot $RuntimeRoot -Tenant $Tenant -Principal $Principal -ProducerInstance $ProducerInstance -ContentRef "cas:sha256:deadbeef" -Adapter "hyperv" -DisplayMode "protected_review")

$sessionMatches = @(
  $openOut |
    ForEach-Object { $_.ToString().Trim() } |
    Where-Object { $_ -match "^[0-9a-f]{32}$" }
)
if($sessionMatches.Count -le 0){ throw "NO_SESSION_ID_FOUND" }
$sessionId = $sessionMatches[$sessionMatches.Count - 1]

Write-Host ("SESSION_ID=" + $sessionId) -ForegroundColor Yellow

Write-Host "TIER1_STEP5: hyperv_request" -ForegroundColor DarkGray
$adapterOut = @(& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Adapter -RuntimeRoot $RuntimeRoot -SessionId $sessionId)

$requestMatches = @(
  $adapterOut |
    ForEach-Object { $_.ToString().Trim() } |
    Where-Object { $_ -like "*.json" -and (Test-Path -LiteralPath $_ -PathType Leaf) }
)
$cmdMatches = @(
  $adapterOut |
    ForEach-Object { $_.ToString().Trim() } |
    Where-Object { $_ -like "*.cmd" -and (Test-Path -LiteralPath $_ -PathType Leaf) }
)

if($requestMatches.Count -le 0){ throw "MISSING_HYPERV_REQUEST_JSON" }
if($cmdMatches.Count -le 0){ throw "MISSING_HYPERV_LAUNCH_CMD" }

$requestPath = $requestMatches[$requestMatches.Count - 1]
$launchCmd   = $cmdMatches[$cmdMatches.Count - 1]

Write-Host ("REQUEST_JSON=" + $requestPath) -ForegroundColor Yellow
Write-Host ("LAUNCH_CMD=" + $launchCmd) -ForegroundColor Yellow

Write-Host "TIER1_STEP5: close_session" -ForegroundColor DarkGray
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Close -RuntimeRoot $RuntimeRoot -SessionId $sessionId | Out-Host

Write-Host "TIER1_STEP5: replay_view" -ForegroundColor DarkGray
$replayOut = @(& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Replay -RuntimeRoot $RuntimeRoot -RepoRoot $RepoRoot -SessionId $sessionId)

$reportMatches = @(
  $replayOut |
    ForEach-Object { $_.ToString().Trim() } |
    Where-Object { $_ -like "*.replay.json" -and (Test-Path -LiteralPath $_ -PathType Leaf) }
)
$timelineMatches = @(
  $replayOut |
    ForEach-Object { $_.ToString().Trim() } |
    Where-Object { $_ -like "*.timeline.txt" -and (Test-Path -LiteralPath $_ -PathType Leaf) }
)

if($reportMatches.Count -le 0){ throw "MISSING_REPLAY_REPORT" }
if($timelineMatches.Count -le 0){ throw "MISSING_REPLAY_TIMELINE" }

$reportPath   = $reportMatches[$reportMatches.Count - 1]
$timelinePath = $timelineMatches[$timelineMatches.Count - 1]

$reportObj = Get-Content -Raw -LiteralPath $reportPath -Encoding UTF8 | ConvertFrom-Json
if([string]$reportObj.session_id -ne $sessionId){ throw "REPLAY_SESSION_ID_MISMATCH" }
if([int]$reportObj.receipt_count -lt 3){ throw "REPLAY_RECEIPT_COUNT_TOO_LOW" }

Write-Host ("REPLAY_REPORT=" + $reportPath) -ForegroundColor Yellow
Write-Host ("REPLAY_TIMELINE=" + $timelinePath) -ForegroundColor Yellow
Write-Host "CLARITY_TIER1_STEP5_OK" -ForegroundColor Green
