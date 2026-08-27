param(
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ObjectSha256,
  [Parameter(Mandatory=$true)][string]$DestinationPath,
  [Parameter(Mandatory=$true)][string]$Tenant,
  [Parameter(Mandatory=$true)][string]$Principal,
  [Parameter(Mandatory=$true)][string]$ProducerInstance,
  [Parameter(Mandatory=$false)][string]$RulesPath = "",
  [switch]$Authorize,
  [switch]$AllowCritical,
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\canon.ps1"

function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
function HasProp($obj,[string]$name){ if($null -eq $obj){ return $false }; return [bool]($obj.PSObject.Properties.Name -contains $name) }

if(-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)){ throw ("MISSING_RUNTIME_ROOT: " + $RuntimeRoot) }
if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){ throw ("MISSING_REPO_ROOT: " + $RepoRoot) }

$sha = $ObjectSha256.ToLowerInvariant()
if($sha -notmatch '^[0-9a-f]{64}$'){ throw "INVALID_OBJECT_SHA256" }

# Authorization is checked before touching anything.
if(-not $Authorize.IsPresent){ throw "UNAUTHORIZED_RESTORE" }

# Locate the vault object.
$vaultRoot   = Join-Path $RuntimeRoot "vault"
$objectsRoot = Join-Path $vaultRoot "objects\sha256"
$objDir      = Join-Path (Join-Path $objectsRoot $sha.Substring(0,2)) $sha
$contentPath = Join-Path $objDir "content.bin"
if(-not (Test-Path -LiteralPath $contentPath -PathType Leaf)){ throw ("MISSING_VAULT_OBJECT: " + $sha) }

# Object identity verification — the stored content must still hash to its address.
$objectActual = Sha256HexFile $contentPath
if($objectActual -ne $sha){ throw "ISOLATION_OBJECT_CORRUPT" }

# Policy from rules (BOM tolerant).
if([string]::IsNullOrWhiteSpace($RulesPath)){ $RulesPath = Join-Path $RepoRoot "clarity_rules.json" }
$criticalPrefixes = @()
$allowedRoots = @()
if(Test-Path -LiteralPath $RulesPath -PathType Leaf){
  $rules = ((ReadUtf8Text $RulesPath).TrimStart([char]0xFEFF)) | ConvertFrom-Json
  if(HasProp $rules "scan" -and (HasProp $rules.scan "critical_prefixes")){ $criticalPrefixes = @($rules.scan.critical_prefixes | ForEach-Object { [string]$_ }) }
  if(HasProp $rules "quarantine" -and (HasProp $rules.quarantine "allowed_block_roots")){ $allowedRoots = @($rules.quarantine.allowed_block_roots | ForEach-Object { [string]$_ }) }
}

$destFull = [IO.Path]::GetFullPath($DestinationPath)

# Critical-file safety gate: never restore over a boot-critical prefix without an explicit override.
$isCritical = $false
foreach($cp in $criticalPrefixes){
  $cpn = ([IO.Path]::GetFullPath($cp)).TrimEnd('\') + '\'
  if(($destFull + '\').StartsWith($cpn,[StringComparison]::OrdinalIgnoreCase)){ $isCritical = $true; break }
}
if($isCritical -and -not $AllowCritical.IsPresent){ throw "RESTORE_TO_CRITICAL_DENIED" }

# Destination must be inside an allowed restore root (a critical override bypasses this).
$withinAllowed = $false
foreach($ar in $allowedRoots){
  $arn = ([IO.Path]::GetFullPath($ar)).TrimEnd('\') + '\'
  if(($destFull + '\').StartsWith($arn,[StringComparison]::OrdinalIgnoreCase)){ $withinAllowed = $true; break }
}
if(-not $withinAllowed -and -not ($isCritical -and $AllowCritical.IsPresent)){ throw "RESTORE_DESTINATION_NOT_ALLOWED" }

# Target-state validation.
$decision = "restored"
if(Test-Path -LiteralPath $destFull -PathType Leaf){
  $existing = Sha256HexFile $destFull
  if($existing -eq $sha){
    $decision = "restored_idempotent"
  } elseif(-not $Force.IsPresent){
    throw "RESTORE_TARGET_EXISTS"
  }
}

# Copy vault content to destination (temp then move), verifying the copy hash.
if($decision -ne "restored_idempotent"){
  $destDir = Split-Path -Parent $destFull
  if($destDir){ EnsureDir $destDir }
  $tmp = $destFull + "." + [Guid]::NewGuid().ToString("N") + ".tmp"
  Copy-Item -LiteralPath $contentPath -Destination $tmp -Force
  $restoredHash = Sha256HexFile $tmp
  if($restoredHash -ne $sha){
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    throw "RESTORE_HASH_MISMATCH"
  }
  Move-Item -LiteralPath $tmp -Destination $destFull -Force
} else {
  $restoredHash = $sha
}

# The vault object is preserved (copy, not move) — evidence is never destroyed by restore.
if(-not (Test-Path -LiteralPath $contentPath -PathType Leaf)){ throw "VAULT_OBJECT_LOST_DURING_RESTORE" }

# Append-only, hash-chained restore ledger.
$ledgerDir  = Join-Path $vaultRoot "ledger"
$ledgerPath = Join-Path $ledgerDir "restore.ndjson"
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
  schema = "clarity.isolation_restore_ledger.v1"
  seq = $seq
  created_at_utc = UtcNow
  event_type = "clarity.isolation.object.restored.v1"
  tenant = $Tenant
  principal = $Principal
  producer_instance = $ProducerInstance
  object_sha256 = $sha
  destination_path = $destFull
  decision = $decision
  critical_override = [bool]$AllowCritical.IsPresent
  prev_log_hash = $prevLogHash
}
$lineJsonNoHash = ($lineObj | ConvertTo-Json -Compress -Depth 6)
$logHash = Sha256HexTextNormalized $lineJsonNoHash
$lineObj["log_hash"] = $logHash
$lineJson = ($lineObj | ConvertTo-Json -Compress -Depth 6)
WriteUtf8NoBomLf $ledgerPath ($existingRaw + $lineJson + "`n")

# Report artifact.
$reportDir = Join-Path $RepoRoot "reports\validator_isolation_restore"
EnsureDir $reportDir
$runId = [Guid]::NewGuid().ToString("N")
$outPath = Join-Path $reportDir ($runId + ".restore.json")
$report = [ordered]@{
  schema = "clarity.isolation_restore.v1"
  run_id = $runId
  created_at_utc = UtcNow
  tenant = $Tenant
  principal = $Principal
  producer_instance = $ProducerInstance
  object_sha256 = $sha
  destination_path = $destFull
  restored_hash = $restoredHash
  authorized = $true
  decision = $decision
  critical_override = [bool]$AllowCritical.IsPresent
  ledger_path = $ledgerPath
}
WriteUtf8NoBomLf $outPath (($report | ConvertTo-Json -Compress -Depth 6))
Write-Host ("VALIDATOR_ISOLATION_RESTORE_OK: " + $outPath) -ForegroundColor Green
Write-Output ("RESTORE_REPORT=" + $outPath)
Write-Output "CLARITY_ISOLATION_RESTORE_OK"
