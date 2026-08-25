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
$Profile = Join-Path $RepoRoot "vm_profiles\protected_review_sandbox.v1.json"
$Close = Join-Path $RepoRoot "scripts\display_session_close.ps1"
Write-Host "TIER1_STEP2: bootstrap" -ForegroundColor DarkGray
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Bootstrap -RepoRoot $RepoRoot | Out-Host
Write-Host "TIER1_STEP2: open_session" -ForegroundColor DarkGray
$openOut = @(& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Open -RuntimeRoot $RuntimeRoot -Tenant $Tenant -Principal $Principal -ProducerInstance $ProducerInstance -ContentRef "cas:sha256:deadbeef" -Adapter "windows_sandbox" -DisplayMode "protected_review")
$sessionId = @($openOut | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -match "^[0-9a-f]{32}$" })[-1]
if(-not $sessionId){ throw "NO_SESSION_ID_FOUND" }
Write-Host ("SESSION_ID=" + $sessionId) -ForegroundColor Yellow
Write-Host "TIER1_STEP2: sandbox_request" -ForegroundColor DarkGray
$adapterOut = @(& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Adapter -RuntimeRoot $RuntimeRoot -SessionId $sessionId -ProfilePath $Profile)
$requestPath = @($adapterOut | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -like "*.json" })[-1]
$wsbPath = @($adapterOut | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -like "*.wsb" })[-1]
if(-not (Test-Path -LiteralPath $requestPath -PathType Leaf)){ throw "MISSING_ADAPTER_REQUEST_JSON" }
if(-not (Test-Path -LiteralPath $wsbPath -PathType Leaf)){ throw "MISSING_WSB_FILE" }
Write-Host ("REQUEST_JSON=" + $requestPath) -ForegroundColor Yellow
Write-Host ("WSB_PATH=" + $wsbPath) -ForegroundColor Yellow
Write-Host "TIER1_STEP2: close_session" -ForegroundColor DarkGray
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Close -RuntimeRoot $RuntimeRoot -SessionId $sessionId | Out-Host
$sessionPath = Join-Path (Join-Path (Join-Path $RuntimeRoot "display\sessions") $sessionId) "session.json"
if(-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)){ throw "MISSING_SESSION_JSON" }
$sessionObj = Get-Content -Raw -LiteralPath $sessionPath -Encoding UTF8 | ConvertFrom-Json
if([string]$sessionObj.status -ne "closed"){ throw "SESSION_NOT_CLOSED" }
$receiptPath = Join-Path $RuntimeRoot "display\receipts\display_receipts.ndjson"
if(-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)){ throw "MISSING_DISPLAY_RECEIPTS" }
$receiptLines = @((Get-Content -LiteralPath $receiptPath -Encoding UTF8) | Where-Object { $_ -and $_.Trim() -ne "" })
if($receiptLines.Count -lt 3){ throw "DISPLAY_RECEIPTS_TOO_SHORT" }
Write-Host "CLARITY_TIER1_STEP2_OK" -ForegroundColor Green
