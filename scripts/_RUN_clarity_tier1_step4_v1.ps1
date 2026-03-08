param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source
$RuntimeRoot = "C:\ProgramData\Clarity"
$Principal = "single-tenant/operator/user/alec"
$Tenant = "single-tenant"
$ProducerInstance = ("{0}-standalone-1" -f $env:COMPUTERNAME)

$Bootstrap = Join-Path $RepoRoot "scripts\_bootstrap_clarity_standalone_v1.ps1"
$Preflight = Join-Path $RepoRoot "scripts\validator_preflight.ps1"
$Gate = Join-Path $RepoRoot "scripts\validator_handoff_gate.ps1"

Write-Host "TIER1_STEP4: bootstrap" -ForegroundColor DarkGray
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Bootstrap -RepoRoot $RepoRoot | Out-Host

Write-Host "TIER1_STEP4: validator_preflight" -ForegroundColor DarkGray
$preOut = @(
  & $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Preflight `
    -RuntimeRoot $RuntimeRoot `
    -RepoRoot $RepoRoot `
    -Tenant $Tenant `
    -Principal $Principal `
    -ProducerInstance $ProducerInstance
)
$preMatches = @(
  $preOut |
    ForEach-Object { $_.ToString().Trim() } |
    Where-Object { $_ -like "*.preflight.json" -and (Test-Path -LiteralPath $_ -PathType Leaf) }
)
if($preMatches.Count -le 0){ throw "MISSING_PREFLIGHT_REPORT" }
$prePath = $preMatches[$preMatches.Count - 1]

$preObj = Get-Content -Raw -LiteralPath $prePath -Encoding UTF8 | ConvertFrom-Json
Write-Host ("PREFLIGHT_PATH=" + $prePath) -ForegroundColor Yellow
Write-Host ("TRUST_TIER=" + [string]$preObj.trust_tier) -ForegroundColor Yellow

Write-Host "TIER1_STEP4: handoff_gate" -ForegroundColor DarkGray
$gateOut = @(
  & $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Gate `
    -RepoRoot $RepoRoot `
    -PreflightPath $prePath `
    -AllowDegraded
)
$gateMatches = @(
  $gateOut |
    ForEach-Object { $_.ToString().Trim() } |
    Where-Object { $_ -like "*.handoff.json" -and (Test-Path -LiteralPath $_ -PathType Leaf) }
)
if($gateMatches.Count -le 0){ throw "MISSING_HANDOFF_REPORT" }
$gatePath = $gateMatches[$gateMatches.Count - 1]

$gateObj = Get-Content -Raw -LiteralPath $gatePath -Encoding UTF8 | ConvertFrom-Json

if([string]$gateObj.preflight_run_id -ne [string]$preObj.run_id){
  throw "HANDOFF_PREFLIGHT_RUN_ID_MISMATCH"
}
if(([string]$preObj.trust_tier -eq "FAIL") -and [bool]$gateObj.allowed){
  throw "FAIL_TRUST_MUST_NOT_ALLOW"
}

Write-Host ("HANDOFF_PATH=" + $gatePath) -ForegroundColor Yellow
Write-Host ("HANDOFF_DECISION=" + [string]$gateObj.decision) -ForegroundColor Yellow
Write-Host "CLARITY_TIER1_STEP4_OK" -ForegroundColor Green
