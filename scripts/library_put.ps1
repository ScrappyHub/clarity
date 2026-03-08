param(
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$InputPath,
  [Parameter(Mandatory=$true)][string]$Tenant,
  [Parameter(Mandatory=$true)][string]$Principal,
  [Parameter(Mandatory=$true)][string]$ProducerInstance,
  [switch]$Sealed
)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
. "$PSScriptRoot\lib\canon.ps1"
function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
if(-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)){ throw ("MISSING_RUNTIME_ROOT: " + $RuntimeRoot) }
if(-not (Test-Path -LiteralPath $InputPath -PathType Leaf)){ throw ("MISSING_INPUT: " + $InputPath) }
$ledgerDir = Join-Path $RuntimeRoot "library\ledger"
$objectsRoot = Join-Path $RuntimeRoot "library\objects\sha256"
EnsureDir $ledgerDir
EnsureDir $objectsRoot
$objHash = Sha256HexFile $InputPath
$prefix = $objHash.Substring(0,2)
$objDir = Join-Path (Join-Path $objectsRoot $prefix) $objHash
EnsureDir $objDir
$contentPath = Join-Path $objDir "content.bin"
Copy-Item -LiteralPath $InputPath -Destination $contentPath -Force
$contentRef = ("cas:sha256:" + $objHash)
$metaObj = [ordered]@{
  schema = "clarity.library_object_meta.v1"
  object_sha256 = $objHash
  content_ref = $contentRef
  stored_name = (Split-Path -Leaf $InputPath)
  stored_bytes = [int](Get-Item -LiteralPath $contentPath).Length
  sealed = [bool]$Sealed
  tenant = $Tenant
  principal = $Principal
  producer_instance = $ProducerInstance
  stored_at_utc = UtcNow
}
$metaJson = ($metaObj | ConvertTo-Json -Compress)
WriteUtf8NoBomLf (Join-Path $objDir "meta.json") $metaJson
$ledgerPath = Join-Path $ledgerDir "library.ndjson"
$prevLogHash = "GENESIS"
$seq = 1
if(Test-Path -LiteralPath $ledgerPath -PathType Leaf){
  $existing = @((Get-Content -LiteralPath $ledgerPath -Encoding UTF8) | Where-Object { $_ -and $_.Trim() -ne "" })
  if($existing.Count -gt 0){
    $last = $existing[$existing.Count - 1] | ConvertFrom-Json
    $prevLogHash = [string]$last.log_hash
    $seq = [int]$last.seq + 1
  }
}
$eventType = "clarity.library.object.added.v1"
if($Sealed){ $eventType = "clarity.library.object.sealed.v1" }
$lineObj = [ordered]@{
  schema = "clarity.library_ledger.v1"
  seq = $seq
  created_at_utc = UtcNow
  event_type = $eventType
  object_sha256 = $objHash
  content_ref = $contentRef
  content_path = ("library/objects/sha256/" + $prefix + "/" + $objHash + "/content.bin")
  sealed = [bool]$Sealed
  tenant = $Tenant
  principal = $Principal
  producer_instance = $ProducerInstance
  prev_log_hash = $prevLogHash
}
$lineJsonNoHash = ($lineObj | ConvertTo-Json -Compress)
$logHash = Sha256HexTextNormalized $lineJsonNoHash
$lineObj["log_hash"] = $logHash
$lineJson = ($lineObj | ConvertTo-Json -Compress)
if(Test-Path -LiteralPath $ledgerPath -PathType Leaf){
  $existingRaw = Get-Content -Raw -LiteralPath $ledgerPath -Encoding UTF8
} else {
  $existingRaw = ""
}
WriteUtf8NoBomLf $ledgerPath ($existingRaw + $lineJson + "`n")
Write-Host ("LIBRARY_PUT_OK: " + $contentRef) -ForegroundColor Green
Write-Output $contentRef
