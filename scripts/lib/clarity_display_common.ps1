Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
. "$PSScriptRoot\canon.ps1"

function CL-UtcNow(){
  (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function CL-DisplayRoot([string]$RuntimeRoot){
  Join-Path $RuntimeRoot "display"
}

function CL-DisplaySessionsRoot([string]$RuntimeRoot){
  Join-Path (CL-DisplayRoot $RuntimeRoot) "sessions"
}

function CL-DisplayReceiptsPath([string]$RuntimeRoot){
  Join-Path (Join-Path (CL-DisplayRoot $RuntimeRoot) "receipts") "display_receipts.ndjson"
}

function CL-SessionDir([string]$RuntimeRoot,[string]$SessionId){
  Join-Path (CL-DisplaySessionsRoot $RuntimeRoot) $SessionId
}

function CL-SessionPath([string]$RuntimeRoot,[string]$SessionId){
  Join-Path (CL-SessionDir $RuntimeRoot $SessionId) "session.json"
}

function CL-EnsureDisplayLayout([string]$RuntimeRoot){
  EnsureDir (CL-DisplayRoot $RuntimeRoot)
  EnsureDir (CL-DisplaySessionsRoot $RuntimeRoot)
  EnsureDir (Join-Path (CL-DisplayRoot $RuntimeRoot) "receipts")
  EnsureDir (Join-Path (CL-DisplayRoot $RuntimeRoot) "adapters")
}

function CL-WriteJsonFile([string]$Path,[object]$Obj){
  $json = ($Obj | ConvertTo-Json -Compress -Depth 10)
  WriteUtf8NoBomLf $Path $json
  return $json
}

function CL-AppendDisplayReceipt(
  [string]$RuntimeRoot,
  [string]$ReceiptType,
  [string]$SessionId,
  [string]$Tenant,
  [string]$Principal,
  [string]$ContentRef,
  [string]$Adapter,
  [string]$Status,
  [string]$Detail
){
  CL-EnsureDisplayLayout $RuntimeRoot
  $receiptPath = CL-DisplayReceiptsPath $RuntimeRoot
  $obj = [ordered]@{
    schema = "clarity.display_receipt.v1"
    receipt_type = $ReceiptType
    created_at_utc = CL-UtcNow
    session_id = $SessionId
    tenant = $Tenant
    principal = $Principal
    content_ref = $ContentRef
    adapter = $Adapter
    status = $Status
    detail = $Detail
  }
  $noHash = ($obj | ConvertTo-Json -Compress -Depth 10)
  $receiptHash = Sha256HexTextNormalized $noHash
  $obj["receipt_hash"] = $receiptHash
  $line = ($obj | ConvertTo-Json -Compress -Depth 10)
  if(Test-Path -LiteralPath $receiptPath -PathType Leaf){
    $existing = Get-Content -Raw -LiteralPath $receiptPath -Encoding UTF8
  } else {
    $existing = ""
  }
  WriteUtf8NoBomLf $receiptPath ($existing + $line + "`n")
  return $receiptHash
}
