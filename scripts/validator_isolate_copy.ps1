param(
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ScanReportPath,
  [Parameter(Mandatory=$true)][string]$Tenant,
  [Parameter(Mandatory=$true)][string]$Principal,
  [Parameter(Mandatory=$true)][string]$ProducerInstance
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\canon.ps1"
function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
if(-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)){ throw ("MISSING_RUNTIME_ROOT: " + $RuntimeRoot) }
if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){ throw ("MISSING_REPO_ROOT: " + $RepoRoot) }
if(-not (Test-Path -LiteralPath $ScanReportPath -PathType Leaf)){ throw ("MISSING_SCAN_REPORT: " + $ScanReportPath) }
$scan = Get-Content -Raw -LiteralPath $ScanReportPath -Encoding UTF8 | ConvertFrom-Json
$findingsPath = [string]$scan.findings_path
if(-not (Test-Path -LiteralPath $findingsPath -PathType Leaf)){ throw ("MISSING_FINDINGS_PATH: " + $findingsPath) }
$scanDir = ([IO.Path]::GetFullPath((Split-Path -Parent $ScanReportPath))).TrimEnd('\') + '\'
$findingsFullPath = [IO.Path]::GetFullPath($findingsPath)
if(-not $findingsFullPath.StartsWith($scanDir,[StringComparison]::OrdinalIgnoreCase)){ throw "FINDINGS_OUTSIDE_SCAN_REPORT_ROOT" }
$allowedRoots = @($scan.scanned_targets | ForEach-Object { ([IO.Path]::GetFullPath([string]$_)).TrimEnd('\') + '\' })
$vaultRoot = Join-Path $RuntimeRoot "vault"
$objectsRoot = Join-Path $vaultRoot "objects\sha256"
$ledgerDir = Join-Path $vaultRoot "ledger"
$ledgerPath = Join-Path $ledgerDir "vault.ndjson"
$reportDir = Join-Path $RepoRoot "reports\validator_isolation"
EnsureDir $objectsRoot
EnsureDir $ledgerDir
EnsureDir $reportDir
$existingRaw = ""
$prevLogHash = "GENESIS"
$seq = 1
if(Test-Path -LiteralPath $ledgerPath -PathType Leaf){
  $existingRaw = Get-Content -Raw -LiteralPath $ledgerPath -Encoding UTF8
  $existingLines = @((Get-Content -LiteralPath $ledgerPath -Encoding UTF8) | Where-Object { $_ -and $_.Trim() -ne "" })
  if($existingLines.Count -gt 0){
    $last = $existingLines[$existingLines.Count - 1] | ConvertFrom-Json
    $prevLogHash = [string]$last.log_hash
    $seq = [int]$last.seq + 1
  }
}
$isolatedCount = 0
$findingLines = @((Get-Content -LiteralPath $findingsPath -Encoding UTF8) | Where-Object { $_ -and $_.Trim() -ne "" })
if($findingLines.Count -ne [int]$scan.suspicious_count){ throw "SCAN_FINDING_COUNT_MISMATCH" }
foreach($line in @(@($findingLines))){
  $f = $line | ConvertFrom-Json
  if(([string]$f.severity -ne "suspicious") -and ([string]$f.severity -ne "critical")){ continue }
  $src = [string]$f.target_path
  $srcFullPath = [IO.Path]::GetFullPath($src)
  $withinScanRoot = $false
  foreach($root in $allowedRoots){
    if($srcFullPath.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){ $withinScanRoot = $true; break }
  }
  if(-not $withinScanRoot){ throw ("FINDING_OUTSIDE_SCANNED_TARGETS: " + $src) }
  if(-not (Test-Path -LiteralPath $srcFullPath -PathType Leaf)){ throw ("MISSING_FINDING_SOURCE: " + $src) }
  $sourceItem = Get-Item -LiteralPath $srcFullPath -Force
  if(($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){ throw ("REPARSE_POINT_SOURCE_REJECTED: " + $src) }
  $src = $srcFullPath
  $shaBefore = Sha256HexFile $src
  $sha = $shaBefore
  $prefix = $sha.Substring(0,2)
  $objDir = Join-Path (Join-Path $objectsRoot $prefix) $sha
  EnsureDir $objDir
  $contentPath = Join-Path $objDir "content.bin"
  $contentTmpPath = Join-Path $objDir ("content." + [Guid]::NewGuid().ToString("N") + ".tmp")
  $metaPath = Join-Path $objDir "meta.json"
  Copy-Item -LiteralPath $src -Destination $contentTmpPath -Force
  $shaAfter = Sha256HexFile $src
  $storedHash = Sha256HexFile $contentTmpPath
  if(($shaBefore -ne $shaAfter) -or ($storedHash -ne $shaBefore)){
    Remove-Item -LiteralPath $contentTmpPath -Force -ErrorAction SilentlyContinue
    throw ("ISOLATION_SOURCE_CHANGED_DURING_COPY: " + $src)
  }
  if(Test-Path -LiteralPath $contentPath -PathType Leaf){
    if((Sha256HexFile $contentPath) -ne $shaBefore){
      Remove-Item -LiteralPath $contentTmpPath -Force -ErrorAction SilentlyContinue
      throw ("ISOLATION_EXISTING_OBJECT_HASH_MISMATCH: " + $contentPath)
    }
    Remove-Item -LiteralPath $contentTmpPath -Force
  } else {
    Move-Item -LiteralPath $contentTmpPath -Destination $contentPath -Force
  }
  $meta = [ordered]@{
    schema = "clarity.isolation_object_meta.v1"
    isolated_at_utc = UtcNow
    tenant = $Tenant
    principal = $Principal
    producer_instance = $ProducerInstance
    source_path = $src
    source_reason_code = [string]$f.reason_code
    source_severity = [string]$f.severity
    object_sha256 = $sha
    stored_bytes = [int](Get-Item -LiteralPath $contentPath).Length
  }
  WriteUtf8NoBomLf $metaPath (($meta | ConvertTo-Json -Compress -Depth 6))
  $lineObj = [ordered]@{
    schema = "clarity.isolation_ledger.v1"
    seq = $seq
    created_at_utc = UtcNow
    event_type = "clarity.isolation.object.copied.v1"
    tenant = $Tenant
    principal = $Principal
    producer_instance = $ProducerInstance
    source_path = $src
    reason_code = [string]$f.reason_code
    object_sha256 = $sha
    content_path = ("vault/objects/sha256/" + $prefix + "/" + $sha + "/content.bin")
    prev_log_hash = $prevLogHash
  }
  $lineJsonNoHash = ($lineObj | ConvertTo-Json -Compress -Depth 6)
  $logHash = Sha256HexTextNormalized $lineJsonNoHash
  $lineObj["log_hash"] = $logHash
  $lineJson = ($lineObj | ConvertTo-Json -Compress -Depth 6)
  $existingRaw = $existingRaw + $lineJson + "`n"
  $prevLogHash = $logHash
  $seq = $seq + 1
  $isolatedCount = $isolatedCount + 1
}
WriteUtf8NoBomLf $ledgerPath $existingRaw
$outPath = Join-Path $reportDir (([string]$scan.run_id) + ".isolation.json")
$report = [ordered]@{
  schema = "clarity.isolation_report.v1"
  run_id = [string]$scan.run_id
  created_at_utc = UtcNow
  tenant = $Tenant
  principal = $Principal
  producer_instance = $ProducerInstance
  isolated_count = [int]$isolatedCount
  ledger_path = $ledgerPath
}
WriteUtf8NoBomLf $outPath (($report | ConvertTo-Json -Compress -Depth 6))
Write-Host ("VALIDATOR_ISOLATE_COPY_OK: " + $outPath) -ForegroundColor Green
Write-Output $outPath
