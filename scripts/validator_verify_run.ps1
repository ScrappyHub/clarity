param(
  [Parameter(Mandatory=$true)][string]$RunPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\canon.ps1"

if(-not (Test-Path -LiteralPath $RunPath -PathType Leaf)){ throw ("MISSING_RUN: " + $RunPath) }
$run = Get-Content -Raw -LiteralPath $RunPath -Encoding UTF8 | ConvertFrom-Json
if([string]$run.schema -ne "clarity.validator_run.v1"){ throw "UNSUPPORTED_RUN_SCHEMA" }

function Assert-Hash([string]$Path,[string]$Expected,[string]$Label){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ throw ("MISSING_ARTIFACT: " + $Label) }
  $actual = Sha256HexFile $Path
  if($actual -ne $Expected){ throw ("ARTIFACT_HASH_MISMATCH: " + $Label) }
}

$p = $run.phases
Assert-Hash ([string]$p.preflight.path) ([string]$p.preflight.sha256) "preflight"
Assert-Hash ([string]$p.scan.path) ([string]$p.scan.sha256) "scan"
Assert-Hash ([string]$p.scan.findings_path) ([string]$p.scan.findings_sha256) "findings"
Assert-Hash ([string]$p.isolation.path) ([string]$p.isolation.sha256) "isolation"
Assert-Hash ([string]$p.isolation.ledger_path) ([string]$p.isolation.ledger_sha256) "isolation_ledger"
Assert-Hash ([string]$p.handoff.path) ([string]$p.handoff.sha256) "handoff"
if($p.PSObject.Properties.Name -contains "handoff_target"){
  Assert-Hash ([string]$p.handoff_target.path) ([string]$p.handoff_target.sha256) "handoff_target"
}

$scan = Get-Content -Raw -LiteralPath ([string]$p.scan.path) -Encoding UTF8 | ConvertFrom-Json
$preflight = Get-Content -Raw -LiteralPath ([string]$p.preflight.path) -Encoding UTF8 | ConvertFrom-Json
$isolation = Get-Content -Raw -LiteralPath ([string]$p.isolation.path) -Encoding UTF8 | ConvertFrom-Json
$handoff = Get-Content -Raw -LiteralPath ([string]$p.handoff.path) -Encoding UTF8 | ConvertFrom-Json
if([string]$preflight.trust_tier -ne [string]$p.preflight.trust_tier){ throw "PREFLIGHT_TRUST_TIER_MISMATCH" }
if([string]$scan.run_id -ne [string]$p.scan.run_id){ throw "SCAN_RUN_ID_MISMATCH" }
if([int]$scan.suspicious_count -ne [int]$p.scan.suspicious_count){ throw "SCAN_COUNT_MISMATCH" }
if([string]$isolation.run_id -ne [string]$p.isolation.run_id){ throw "ISOLATION_RUN_ID_MISMATCH" }
if([int]$isolation.isolated_count -ne [int]$p.isolation.isolated_count){ throw "ISOLATION_COUNT_MISMATCH" }
if([string]$handoff.preflight_run_id -ne [string]$p.preflight.run_id){ throw "HANDOFF_PREFLIGHT_RUN_ID_MISMATCH" }
if([string]$handoff.decision -ne [string]$p.handoff.decision){ throw "HANDOFF_DECISION_MISMATCH" }
if([bool]$handoff.allowed -ne [bool]$p.handoff.allowed){ throw "HANDOFF_ALLOWED_MISMATCH" }
if([string]$run.decision.trust_tier -ne [string]$preflight.trust_tier){ throw "RUN_DECISION_TRUST_MISMATCH" }
if([string]$run.decision.handoff -ne [string]$handoff.decision){ throw "RUN_DECISION_HANDOFF_MISMATCH" }
if([bool]$run.decision.allowed -ne [bool]$handoff.allowed){ throw "RUN_DECISION_ALLOWED_MISMATCH" }
if($p.PSObject.Properties.Name -contains "handoff_target"){
  $htv = Get-Content -Raw -LiteralPath ([string]$p.handoff_target.path) -Encoding UTF8 | ConvertFrom-Json
  if([string]$htv.verdict -ne [string]$p.handoff_target.verdict){ throw "HANDOFF_TARGET_VERDICT_MISMATCH" }
  if([bool]$htv.allowed -ne [bool]$p.handoff_target.allowed){ throw "HANDOFF_TARGET_ALLOWED_MISMATCH" }
  if((-not [bool]$htv.allowed) -and [bool]$run.decision.allowed){ throw "HANDOFF_TARGET_DENY_NOT_ENFORCED" }
}

Write-Host ("VALIDATOR_RUN_VERIFY_OK: " + $RunPath) -ForegroundColor Green
Write-Output $RunPath
