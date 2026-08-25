param(
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$SessionId
)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
. "$PSScriptRoot\lib\canon.ps1"
. "$PSScriptRoot\lib\clarity_display_common.ps1"
if(-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)){ throw ("MISSING_RUNTIME_ROOT: " + $RuntimeRoot) }
$sessionPath = CL-SessionPath $RuntimeRoot $SessionId
if(-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)){ throw ("MISSING_SESSION: " + $sessionPath) }
$obj = Get-Content -Raw -LiteralPath $sessionPath -Encoding UTF8 | ConvertFrom-Json
if([string]$obj.status -ne "open"){ throw "SESSION_NOT_OPEN" }
$obj.closed_at_utc = CL-UtcNow
$obj.status = "closed"
[void](CL-WriteJsonFile $sessionPath $obj)
$receiptHash = CL-AppendDisplayReceipt -RuntimeRoot $RuntimeRoot -ReceiptType "clarity.display.session.closed.v1" -SessionId ([string]$obj.session_id) -Tenant ([string]$obj.tenant) -Principal ([string]$obj.principal) -ContentRef ([string]$obj.content_ref) -Adapter ([string]$obj.adapter) -Status "closed" -Detail "session_closed"
Write-Host ("DISPLAY_SESSION_CLOSE_OK: " + $SessionId) -ForegroundColor Green
Write-Output $receiptHash
