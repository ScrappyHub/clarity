param(
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$SessionId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\lib\canon.ps1"
. "$PSScriptRoot\lib\clarity_display_common.ps1"

function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }

if(-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)){ throw ("MISSING_RUNTIME_ROOT: " + $RuntimeRoot) }
if($SessionId -notmatch "^[0-9a-f]{32}$"){ throw ("BAD_SESSION_ID: " + $SessionId) }

$sessionPath = Join-Path (Join-Path (Join-Path $RuntimeRoot "display\sessions") $SessionId) "session.json"
if(-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)){ throw ("MISSING_SESSION_JSON: " + $sessionPath) }

$session = Get-Content -Raw -LiteralPath $sessionPath -Encoding UTF8 | ConvertFrom-Json

if([string]$session.adapter -ne "hyperv"){ throw "SESSION_ADAPTER_MISMATCH_NOT_HYPERV" }
if([string]$session.status -ne "open"){ throw "SESSION_NOT_OPEN" }

$reqRoot = Join-Path $RuntimeRoot ("display\adapters\hyperv\requests\" + $SessionId)
EnsureDir $reqRoot

$requestPath = Join-Path $reqRoot "request.json"
$launchCmd   = Join-Path $reqRoot "launch.cmd"

$hypervAvailable = $false
if(Get-Command Get-VM -ErrorAction SilentlyContinue){ $hypervAvailable = $true }

$status = "requested"
$detail = "hyperv_request_materialized"
if(-not $hypervAvailable){ $detail = "hyperv_module_not_present_or_unavailable" }

$obj = [ordered]@{
  schema           = "clarity.display.hyperv.request.v1"
  created_at_utc   = UtcNow
  session_id       = [string]$session.session_id
  tenant           = [string]$session.tenant
  principal        = [string]$session.principal
  content_ref      = [string]$session.content_ref
  display_mode     = [string]$session.display_mode
  adapter          = "hyperv"
  hyperv_available = $hypervAvailable
  status           = $status
  detail           = $detail
}

$json = ($obj | ConvertTo-Json -Compress -Depth 6)
WriteUtf8NoBomLf $requestPath $json

$cmdLines = @(
  '@echo off',
  'REM Clarity Hyper-V launch stub',
  ('REM SessionId=' + $SessionId),
  ('REM RequestJson=' + $requestPath),
  ('echo CLARITY_HYPERV_REQUEST_READY ' + $SessionId)
)
WriteUtf8NoBomLf $launchCmd (($cmdLines -join "
") + "
")

[void](CL-AppendDisplayReceipt -RuntimeRoot $RuntimeRoot -ReceiptType "clarity.display.adapter.hyperv.requested.v1" -SessionId ([string]$session.session_id) -Tenant ([string]$session.tenant) -Principal ([string]$session.principal) -ContentRef ([string]$session.content_ref) -Adapter "hyperv" -Status $status -Detail $detail)

Write-Host ("HYPERV_ADAPTER_OK: " + $SessionId) -ForegroundColor Green
Write-Output $requestPath
Write-Output $launchCmd
