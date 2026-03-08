param(
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$Tenant,
  [Parameter(Mandatory=$true)][string]$Principal,
  [Parameter(Mandatory=$true)][string]$ProducerInstance,
  [Parameter(Mandatory=$true)][string]$ContentRef,
  [Parameter(Mandatory=$true)][string]$Adapter,
  [Parameter(Mandatory=$true)][string]$DisplayMode
)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
. "$PSScriptRoot\lib\canon.ps1"
. "$PSScriptRoot\lib\clarity_display_common.ps1"
if(-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)){ throw ("MISSING_RUNTIME_ROOT: " + $RuntimeRoot) }
CL-EnsureDisplayLayout $RuntimeRoot
$sessionId = [Guid]::NewGuid().ToString("N")
$sessionObj = [ordered]@{
  schema = "clarity.display_session.v1"
  session_id = $sessionId
  tenant = $Tenant
  principal = $Principal
  producer_instance = $ProducerInstance
  content_ref = $ContentRef
  adapter = $Adapter
  display_mode = $DisplayMode
  opened_at_utc = CL-UtcNow
  closed_at_utc = $null
  status = "open"
  meta = $null
}
$sessionDir = CL-SessionDir $RuntimeRoot $sessionId
EnsureDir $sessionDir
$sessionPath = CL-SessionPath $RuntimeRoot $sessionId
[void](CL-WriteJsonFile $sessionPath $sessionObj)
$receiptHash = CL-AppendDisplayReceipt -RuntimeRoot $RuntimeRoot -ReceiptType "clarity.display.session.opened.v1" -SessionId $sessionId -Tenant $Tenant -Principal $Principal -ContentRef $ContentRef -Adapter $Adapter -Status "open" -Detail $DisplayMode
Write-Host ("DISPLAY_SESSION_OPEN_OK: " + $sessionId) -ForegroundColor Green
Write-Output $sessionId
Write-Output $receiptHash
