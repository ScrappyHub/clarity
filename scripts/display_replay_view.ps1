param(
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$SessionId
)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
. "$PSScriptRoot\lib\canon.ps1"
. "$PSScriptRoot\lib\clarity_display_common.ps1"

if(-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)){ throw ("MISSING_RUNTIME_ROOT: " + $RuntimeRoot) }
if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){ throw ("MISSING_REPO_ROOT: " + $RepoRoot) }

$sessionPath = CL-SessionPath $RuntimeRoot $SessionId
if(-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)){ throw ("MISSING_SESSION: " + $sessionPath) }
$session = Get-Content -Raw -LiteralPath $sessionPath -Encoding UTF8 | ConvertFrom-Json

$receiptPath = CL-DisplayReceiptsPath $RuntimeRoot
if(-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)){ throw ("MISSING_DISPLAY_RECEIPTS: " + $receiptPath) }
$allReceiptLines = @((Get-Content -LiteralPath $receiptPath -Encoding UTF8) | Where-Object { $_ -and $_.Trim() -ne "" })
$allReceipts = New-Object System.Collections.Generic.List[object]
$globalExpectedPrev = "GENESIS"
foreach($line in $allReceiptLines){
  $globalReceipt = $line | ConvertFrom-Json
  [void](CL-VerifyDisplayReceipt $globalReceipt)
  if([string]$globalReceipt.prev_receipt_hash -ne $globalExpectedPrev){ throw "GLOBAL_RECEIPT_CHAIN_MISMATCH" }
  $globalExpectedPrev = [string]$globalReceipt.receipt_hash
  [void]$allReceipts.Add($globalReceipt)
}
$receipts = New-Object System.Collections.Generic.List[object]
foreach($obj in $allReceipts){
  if([string]$obj.session_id -eq $SessionId){ [void]$receipts.Add($obj) }
}
if($receipts.Count -le 0){ throw "NO_RECEIPTS_FOR_SESSION" }

$receiptIndex = 0
foreach($r in $receipts){
  [void](CL-VerifyDisplayReceipt $r)
  if([string]$r.session_id -ne [string]$session.session_id){ throw "RECEIPT_SESSION_ID_MISMATCH" }
  if([string]$r.adapter -ne [string]$session.adapter){ throw "RECEIPT_ADAPTER_MISMATCH" }
  if($receiptIndex -eq 0 -and [string]$r.receipt_type -ne "clarity.display.session.opened.v1"){ throw "SESSION_OPEN_RECEIPT_NOT_FIRST" }
  $receiptIndex++
}
if([string]$session.status -ne "closed"){ throw "SESSION_NOT_CLOSED_FOR_REPLAY" }
if([string]$receipts[$receipts.Count - 1].receipt_type -ne "clarity.display.session.closed.v1"){ throw "SESSION_CLOSE_RECEIPT_NOT_LAST" }
$adapterRequest = CL-VerifyAdapterRequest -RuntimeRoot $RuntimeRoot -Session $session
$requestReceipts = @($receipts | Where-Object { [string]$_.receipt_type -like "clarity.display.adapter.*.requested.v1" })
if($requestReceipts.Count -ne 1){ throw "ADAPTER_REQUEST_RECEIPT_COUNT_INVALID" }
if(([string]$requestReceipts[0].detail) -notmatch ("request_hash=" + [regex]::Escape([string]$adapterRequest.request_hash))){ throw "ADAPTER_REQUEST_RECEIPT_HASH_MISMATCH" }

$reportDir = Join-Path $RepoRoot "reports\display_replay"
EnsureDir $reportDir
$reportPath = Join-Path $reportDir ($SessionId + ".replay.json")
$timelinePath = Join-Path $reportDir ($SessionId + ".timeline.txt")

$timeline = New-Object System.Collections.Generic.List[string]
$normalizedReceipts = New-Object System.Collections.Generic.List[object]
foreach($r in $receipts){
  [void]$timeline.Add(([string]$r.created_at_utc + " | " + [string]$r.receipt_type + " | " + [string]$r.status + " | " + [string]$r.detail))
  [void]$normalizedReceipts.Add([ordered]@{
    created_at_utc = [string]$r.created_at_utc
    receipt_type = [string]$r.receipt_type
    status = [string]$r.status
    detail = [string]$r.detail
    receipt_hash = [string]$r.receipt_hash
  })
}

$reportObj = [ordered]@{
  schema = "clarity.display_replay_report.v1"
  session_id = [string]$session.session_id
  tenant = [string]$session.tenant
  principal = [string]$session.principal
  content_ref = [string]$session.content_ref
  adapter = [string]$session.adapter
  display_mode = [string]$session.display_mode
  opened_at_utc = [string]$session.opened_at_utc
  closed_at_utc = [string]$session.closed_at_utc
  status = [string]$session.status
  receipt_count = [int]$normalizedReceipts.Count
  receipts = $normalizedReceipts
}

$reportJson = ($reportObj | ConvertTo-Json -Compress -Depth 10)
WriteUtf8NoBomLf $reportPath $reportJson
WriteUtf8NoBomLf $timelinePath (($timeline.ToArray() -join "`n") + "`n")

Write-Host ("DISPLAY_REPLAY_OK: " + $SessionId) -ForegroundColor Green
Write-Output $reportPath
Write-Output $timelinePath
