param(
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$TargetPath,
  [Parameter(Mandatory=$true)][string]$Tenant,
  [Parameter(Mandatory=$true)][string]$Principal,
  [Parameter(Mandatory=$true)][string]$ProducerInstance,
  [Parameter(Mandatory=$false)][string]$ObjectSha256 = "",
  [Parameter(Mandatory=$false)][ValidateSet("ReportOnly","Marker")][string]$Mode = "",
  [Parameter(Mandatory=$false)][string]$RulesPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\canon.ps1"

function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
function HasProp($obj,[string]$name){ if($null -eq $obj){ return $false }; return [bool]($obj.PSObject.Properties.Name -contains $name) }

if(-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)){ throw ("MISSING_RUNTIME_ROOT: " + $RuntimeRoot) }
if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){ throw ("MISSING_REPO_ROOT: " + $RepoRoot) }
if(-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)){ throw ("MISSING_BLOCK_TARGET: " + $TargetPath) }

# Policy from rules (BOM tolerant).
if([string]::IsNullOrWhiteSpace($RulesPath)){ $RulesPath = Join-Path $RepoRoot "clarity_rules.json" }
$criticalPrefixes = @()
$allowedRoots = @()
$defaultMode = "ReportOnly"
if(Test-Path -LiteralPath $RulesPath -PathType Leaf){
  $rules = ((ReadUtf8Text $RulesPath).TrimStart([char]0xFEFF)) | ConvertFrom-Json
  if(HasProp $rules "scan" -and (HasProp $rules.scan "critical_prefixes")){ $criticalPrefixes = @($rules.scan.critical_prefixes | ForEach-Object { [string]$_ }) }
  if(HasProp $rules "quarantine"){
    if(HasProp $rules.quarantine "allowed_block_roots"){ $allowedRoots = @($rules.quarantine.allowed_block_roots | ForEach-Object { [string]$_ }) }
    if(HasProp $rules.quarantine "default_mode"){ $defaultMode = [string]$rules.quarantine.default_mode }
  }
}
if([string]::IsNullOrWhiteSpace($Mode)){ $Mode = $defaultMode }
if($Mode -ne "ReportOnly" -and $Mode -ne "Marker"){ $Mode = "ReportOnly" }

$targetFull = [IO.Path]::GetFullPath($TargetPath)

# Boot-critical gate: never write near a critical target. Record intent only.
$isCritical = $false
foreach($cp in $criticalPrefixes){
  $cpn = ([IO.Path]::GetFullPath($cp)).TrimEnd('\') + '\'
  if(($targetFull + '\').StartsWith($cpn,[StringComparison]::OrdinalIgnoreCase)){ $isCritical = $true; break }
}

$targetHashBefore = Sha256HexFile $targetFull
$decision = ""
$reason = ""
$markerPath = $null

if($isCritical){
  $decision = "blocked_logical"
  $reason = "CRITICAL_FILE_LOGICAL_BLOCK_ONLY"
}
elseif($Mode -eq "ReportOnly"){
  $decision = "block_reported"
  $reason = "REPORT_ONLY"
}
else {
  # Marker mode: the target must sit inside an allowed block root.
  $withinAllowed = $false
  foreach($ar in $allowedRoots){
    $arn = ([IO.Path]::GetFullPath($ar)).TrimEnd('\') + '\'
    if(($targetFull + '\').StartsWith($arn,[StringComparison]::OrdinalIgnoreCase)){ $withinAllowed = $true; break }
  }
  if(-not $withinAllowed){ throw ("BLOCK_PATH_NOT_ALLOWED: " + $targetFull) }
  $markerPath = $targetFull + ".clarity_blocked.json"
  $marker = [ordered]@{
    schema = "clarity.isolation_block_marker.v1"
    blocked_at_utc = UtcNow
    target_path = $targetFull
    object_sha256 = if($ObjectSha256){ $ObjectSha256.ToLowerInvariant() } else { $null }
    tenant = $Tenant
    principal = $Principal
    producer_instance = $ProducerInstance
  }
  WriteUtf8NoBomLf $markerPath (($marker | ConvertTo-Json -Compress -Depth 6))
  $decision = "blocked_marker"
  $reason = "EXECUTION_BLOCK_MARKER_WRITTEN"
}

# The original target is never modified or deleted by a block action.
$targetHashAfter = Sha256HexFile $targetFull
if($targetHashBefore -ne $targetHashAfter){ throw "BLOCK_MUTATED_TARGET" }

# Append-only, hash-chained block ledger.
$vaultRoot  = Join-Path $RuntimeRoot "vault"
$ledgerDir  = Join-Path $vaultRoot "ledger"
$ledgerPath = Join-Path $ledgerDir "block.ndjson"
EnsureDir $ledgerDir
$existingRaw = ""
$prevLogHash = "GENESIS"
$seq = 1
if(Test-Path -LiteralPath $ledgerPath -PathType Leaf){
  $existingRaw = ReadUtf8Text $ledgerPath
  $existingLines = @((Get-Content -LiteralPath $ledgerPath -Encoding UTF8) | Where-Object { $_ -and $_.Trim() -ne "" })
  if($existingLines.Count -gt 0){
    $last = $existingLines[$existingLines.Count - 1] | ConvertFrom-Json
    $prevLogHash = [string]$last.log_hash
    $seq = [int]$last.seq + 1
  }
}
$lineObj = [ordered]@{
  schema = "clarity.isolation_block_ledger.v1"
  seq = $seq
  created_at_utc = UtcNow
  event_type = "clarity.isolation.execution_block.v1"
  tenant = $Tenant
  principal = $Principal
  producer_instance = $ProducerInstance
  target_path = $targetFull
  object_sha256 = if($ObjectSha256){ $ObjectSha256.ToLowerInvariant() } else { $null }
  mode = $Mode
  decision = $decision
  critical = $isCritical
  reason_code = $reason
  prev_log_hash = $prevLogHash
}
$lineJsonNoHash = ($lineObj | ConvertTo-Json -Compress -Depth 6)
$logHash = Sha256HexTextNormalized $lineJsonNoHash
$lineObj["log_hash"] = $logHash
$lineJson = ($lineObj | ConvertTo-Json -Compress -Depth 6)
WriteUtf8NoBomLf $ledgerPath ($existingRaw + $lineJson + "`n")

# Report artifact.
$reportDir = Join-Path $RepoRoot "reports\validator_isolation_block"
EnsureDir $reportDir
$runId = [Guid]::NewGuid().ToString("N")
$outPath = Join-Path $reportDir ($runId + ".block.json")
$report = [ordered]@{
  schema = "clarity.isolation_block.v1"
  run_id = $runId
  created_at_utc = UtcNow
  tenant = $Tenant
  principal = $Principal
  producer_instance = $ProducerInstance
  target_path = $targetFull
  object_sha256 = if($ObjectSha256){ $ObjectSha256.ToLowerInvariant() } else { $null }
  mode = $Mode
  decision = $decision
  critical = $isCritical
  marker_path = $markerPath
  reason_code = $reason
  ledger_path = $ledgerPath
}
WriteUtf8NoBomLf $outPath (($report | ConvertTo-Json -Compress -Depth 6))
Write-Host ("VALIDATOR_ISOLATION_BLOCK_OK: " + $outPath) -ForegroundColor Green
Write-Output ("BLOCK_REPORT=" + $outPath)
Write-Output "CLARITY_ISOLATION_BLOCK_OK"
