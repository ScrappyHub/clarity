param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$PreflightPath,
  [Parameter(Mandatory=$false)][string]$ScanPath = "",
  [Parameter(Mandatory=$false)][string]$IsolationPath = "",
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
$scan = $null
$isolation = $null
if(($ScanPath -and -not $IsolationPath) -or ($IsolationPath -and -not $ScanPath)){ throw "SCAN_AND_ISOLATION_MUST_BE_PAIRED" }
if($ScanPath){
  if(-not (Test-Path -LiteralPath $ScanPath -PathType Leaf)){ throw ("MISSING_SCAN: " + $ScanPath) }
  if(-not (Test-Path -LiteralPath $IsolationPath -PathType Leaf)){ throw ("MISSING_ISOLATION: " + $IsolationPath) }
  $scan = Get-Content -Raw -LiteralPath $ScanPath -Encoding UTF8 | ConvertFrom-Json
  $isolation = Get-Content -Raw -LiteralPath $IsolationPath -Encoding UTF8 | ConvertFrom-Json
}

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

if($scan){
  if(-not [bool]$scan.scan_complete){ $decision = "deny"; $allowed = $false; $reason = "SCAN_INCOMPLETE" }
  elseif([int]$scan.suspicious_count -gt 0){ $decision = "deny"; $allowed = $false; $reason = "SUSPICIOUS_FINDINGS_PRESENT" }
  elseif([int]$isolation.isolated_count -ne 0){ $decision = "deny"; $allowed = $false; $reason = "UNEXPECTED_ISOLATION_COUNT" }
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
  scan_path = if($scan){ $ScanPath } else { $null }
  scan_run_id = if($scan){ [string]$scan.run_id } else { $null }
  scan_complete = if($scan){ [bool]$scan.scan_complete } else { $null }
  suspicious_count = if($scan){ [int]$scan.suspicious_count } else { $null }
  isolation_path = if($isolation){ $IsolationPath } else { $null }
  isolation_run_id = if($isolation){ [string]$isolation.run_id } else { $null }
  isolated_count = if($isolation){ [int]$isolation.isolated_count } else { $null }
}

$json = ($obj | ConvertTo-Json -Compress -Depth 6)
WriteUtf8NoBomLf $outPath $json
Write-Host ("VALIDATOR_HANDOFF_GATE_OK: " + $outPath) -ForegroundColor Green
Write-Output $outPath
