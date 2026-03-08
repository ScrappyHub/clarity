param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source
$RuntimeRoot = "C:\ProgramData\Clarity"
$Principal = "single-tenant/operator/user/alec"
$Tenant = "single-tenant"
$ProducerInstance = ("{0}-standalone-1" -f $env:COMPUTERNAME)
$Bootstrap = Join-Path $RepoRoot "scripts\_bootstrap_clarity_standalone_v1.ps1"
$Open = Join-Path $RepoRoot "scripts\display_session_open.ps1"
$Adapter = Join-Path $RepoRoot "scripts\display_adapter_windows_sandbox.ps1"
$Close = Join-Path $RepoRoot "scripts\display_session_close.ps1"
$Replay = Join-Path $RepoRoot "scripts\display_replay_view.ps1"
Write-Host "TIER1_STEP3: bootstrap" -ForegroundColor DarkGray
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Bootstrap -RepoRoot $RepoRoot | Out-Host
Write-Host "TIER1_STEP3: open_session" -ForegroundColor DarkGray
$openOut = @(& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Open -RuntimeRoot $RuntimeRoot -Tenant $Tenant -Principal $Principal -ProducerInstance $ProducerInstance -ContentRef "cas:sha256:deadbeef" -Adapter "windows_sandbox" -DisplayMode "protected_review")
$sessionId = @($openOut | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -match "^[0-9a-f]{32}$" })[-1]
if(-not $sessionId){ throw "NO_SESSION_ID_FOUND" }
Write-Host ("SESSION_ID=" + $sessionId) -ForegroundColor Yellow
Write-Host "TIER1_STEP3: sandbox_request" -ForegroundColor DarkGray
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Adapter -RuntimeRoot $RuntimeRoot -SessionId $sessionId | Out-Host
Write-Host "TIER1_STEP3: close_session" -ForegroundColor DarkGray
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Close -RuntimeRoot $RuntimeRoot -SessionId $sessionId | Out-Host
Write-Host "TIER1_STEP3: replay_view" -ForegroundColor DarkGray
$replayOut = @(& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Replay -RuntimeRoot $RuntimeRoot -RepoRoot $RepoRoot -SessionId $sessionId)
$reportPath = @($replayOut | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -like "*.replay.json" })[-1]
$timelinePath = @($replayOut | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -like "*.timeline.txt" })[-1]
if(-not (Test-Path -LiteralPath $reportPath -PathType Leaf)){ throw "MISSING_REPLAY_REPORT" }
if(-not (Test-Path -LiteralPath $timelinePath -PathType Leaf)){ throw "MISSING_REPLAY_TIMELINE" }
$reportObj = Get-Content -Raw -LiteralPath $reportPath -Encoding UTF8 | ConvertFrom-Json
if([string]$reportObj.session_id -ne $sessionId){ throw "REPLAY_SESSION_ID_MISMATCH" }
if([int]$reportObj.receipt_count -lt 3){ throw "REPLAY_RECEIPT_COUNT_TOO_LOW" }
Write-Host ("REPLAY_REPORT=" + $reportPath) -ForegroundColor Yellow
Write-Host ("REPLAY_TIMELINE=" + $timelinePath) -ForegroundColor Yellow
Write-Host "CLARITY_TIER1_STEP3_OK" -ForegroundColor Green
