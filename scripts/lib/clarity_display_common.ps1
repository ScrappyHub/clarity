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

function CL-ReceiptCanonicalObject([object]$Receipt){
  [ordered]@{
    schema = [string]$Receipt.schema
    receipt_type = [string]$Receipt.receipt_type
    created_at_utc = [string]$Receipt.created_at_utc
    session_id = [string]$Receipt.session_id
    tenant = [string]$Receipt.tenant
    principal = [string]$Receipt.principal
    content_ref = [string]$Receipt.content_ref
    adapter = [string]$Receipt.adapter
    status = if($null -eq $Receipt.status){ $null } else { [string]$Receipt.status }
    detail = if($null -eq $Receipt.detail){ $null } else { [string]$Receipt.detail }
    prev_receipt_hash = [string]$Receipt.prev_receipt_hash
  }
}

function CL-ReceiptHash([object]$Receipt){
  $canonical = CL-ReceiptCanonicalObject $Receipt
  Sha256HexTextNormalized (($canonical | ConvertTo-Json -Compress -Depth 10))
}

function CL-VerifyDisplayReceipt([object]$Receipt){
  if([string]::IsNullOrWhiteSpace([string]$Receipt.receipt_hash)){ throw "RECEIPT_HASH_MISSING" }
  if([string]::IsNullOrWhiteSpace([string]$Receipt.prev_receipt_hash)){ throw "RECEIPT_PREV_HASH_MISSING" }
  $expected = CL-ReceiptHash $Receipt
  if($expected -ne [string]$Receipt.receipt_hash){ throw ("RECEIPT_HASH_MISMATCH: " + [string]$Receipt.receipt_type) }
  return $true
}

function CL-RequestHash([object]$Request){
  $canonical = [ordered]@{}
  if($Request -is [System.Collections.IDictionary]){
    foreach($key in $Request.Keys){
      if([string]$key -ne "request_hash"){ $canonical[[string]$key] = $Request[$key] }
    }
  } else {
    foreach($property in $Request.PSObject.Properties){
      if([string]$property.Name -ne "request_hash"){ $canonical[$property.Name] = $property.Value }
    }
  }
  Sha256HexTextNormalized (($canonical | ConvertTo-Json -Compress -Depth 10))
}

function CL-VerifyAdapterRequest([string]$RuntimeRoot,[object]$Session){
  $adapter = [string]$Session.adapter
  if(($adapter -ne "windows_sandbox") -and ($adapter -ne "hyperv")){ throw "UNSUPPORTED_DISPLAY_ADAPTER" }
  $requestPath = Join-Path (Join-Path (Join-Path (Join-Path $RuntimeRoot "display\adapters") $adapter) "requests") ([string]$Session.session_id)
  $requestPath = Join-Path $requestPath "request.json"
  if(-not (Test-Path -LiteralPath $requestPath -PathType Leaf)){ throw "MISSING_ADAPTER_REQUEST" }
  $request = Get-Content -Raw -LiteralPath $requestPath -Encoding UTF8 | ConvertFrom-Json
  if([string]$request.session_id -ne [string]$Session.session_id){ throw "ADAPTER_REQUEST_SESSION_MISMATCH" }
  if([string]$request.adapter -ne $adapter){ throw "ADAPTER_REQUEST_TYPE_MISMATCH" }
  if([string]$request.content_ref -ne [string]$Session.content_ref){ throw "ADAPTER_REQUEST_CONTENT_MISMATCH" }
  if([string]::IsNullOrWhiteSpace([string]$request.profile_id)){ throw "ADAPTER_REQUEST_PROFILE_MISSING" }
  if([string]::IsNullOrWhiteSpace([string]$request.profile_hash)){ throw "ADAPTER_REQUEST_PROFILE_HASH_MISSING" }
  $validationPath = [string]$request.profile_validation_path
  if(-not (Test-Path -LiteralPath $validationPath -PathType Leaf)){ throw "MISSING_PROFILE_VALIDATION_REPORT" }
  if((Sha256HexFile $validationPath) -ne [string]$request.profile_validation_hash){ throw "PROFILE_VALIDATION_REPORT_HASH_MISMATCH" }
  $validation = Get-Content -Raw -LiteralPath $validationPath -Encoding UTF8 | ConvertFrom-Json
  if([string]$validation.profile_id -ne [string]$request.profile_id){ throw "PROFILE_VALIDATION_ID_MISMATCH" }
  if([string]$validation.profile_hash -ne [string]$request.profile_hash){ throw "PROFILE_VALIDATION_HASH_MISMATCH" }
  if([string]$validation.decision -eq "deny"){ throw "PROFILE_VALIDATION_DENIED" }
  $expected = CL-RequestHash $request
  if($expected -ne [string]$request.request_hash){ throw "ADAPTER_REQUEST_HASH_MISMATCH" }
  return $request
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
  if(Test-Path -LiteralPath $receiptPath -PathType Leaf){
    $existingLines = @((Get-Content -LiteralPath $receiptPath -Encoding UTF8) | Where-Object { $_ -and $_.Trim() -ne "" })
    if($existingLines.Count -gt 0){
      $lastReceipt = $existingLines[$existingLines.Count - 1] | ConvertFrom-Json
      [void](CL-VerifyDisplayReceipt $lastReceipt)
      $obj["prev_receipt_hash"] = [string]$lastReceipt.receipt_hash
    } else {
      $obj["prev_receipt_hash"] = "GENESIS"
    }
  } else {
    $obj["prev_receipt_hash"] = "GENESIS"
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
