param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$PreflightPath,
  [switch]$AllowDegraded
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\canon.ps1"

function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }

if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){ throw ("MISSING_REPO_ROOT: " + $RepoRoot) }
if(-not (Test-Path -LiteralPath $PreflightPath -PathType Leaf)){ throw ("MISSING_PREFLIGHT: " + $PreflightPath) }

$reportDir = Join-Path $RepoRoot "reports\validator_handoff"
EnsureDir $reportDir

$outPath = Join-Path $reportDir (([Guid]::NewGuid().ToString("N")) + ".handoff.json")
$pre = Get-Content -Raw -LiteralPath $PreflightPath -Encoding UTF8 | ConvertFrom-Json

$decision = "deny"
$allowed  = $false
$reason   = "TRUST_FAIL"

if([string]$pre.trust_tier -eq "FULL"){
  $decision = "normal"
  $allowed  = $true
  $reason   = "FULL_TRUST"
}
elseif([string]$pre.trust_tier -eq "DEGRADED"){
  if($AllowDegraded.IsPresent){
    $decision = "restricted"
    $allowed  = $true
    $reason   = "DEGRADED_ALLOWED"
  } else {
    $decision = "deny"
    $allowed  = $false
    $reason   = "DEGRADED_REQUIRES_EXPLICIT_ALLOW"
  }
}

$obj = [ordered]@{
  schema = "clarity.validator_handoff_decision.v1"
  created_at_utc = UtcNow
  preflight_path = $PreflightPath
  preflight_run_id = [string]$pre.run_id
  trust_tier = [string]$pre.trust_tier
  decision = $decision
  allowed = $allowed
  reason_code = $reason
}

$json = ($obj | ConvertTo-Json -Compress -Depth 6)
WriteUtf8NoBomLf $outPath $json
Write-Host ("VALIDATOR_HANDOFF_GATE_OK: " + $outPath) -ForegroundColor Green
Write-Output $outPath
