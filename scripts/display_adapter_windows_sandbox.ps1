param(
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$SessionId,
  [switch]$Launch
)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
. "$PSScriptRoot\lib\canon.ps1"
. "$PSScriptRoot\lib\clarity_display_common.ps1"
$sessionPath = CL-SessionPath $RuntimeRoot $SessionId
if(-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)){ throw ("MISSING_SESSION: " + $sessionPath) }
$session = Get-Content -Raw -LiteralPath $sessionPath -Encoding UTF8 | ConvertFrom-Json
$adapterRoot = Join-Path (Join-Path (Join-Path $RuntimeRoot "display\adapters") "windows_sandbox") "requests"
$requestDir = Join-Path $adapterRoot $SessionId
EnsureDir $requestDir
$reqObj = [ordered]@{
  schema = "clarity.display_adapter_request.v1"
  adapter = "windows_sandbox"
  session_id = [string]$session.session_id
  tenant = [string]$session.tenant
  principal = [string]$session.principal
  content_ref = [string]$session.content_ref
  display_mode = [string]$session.display_mode
  requested_at_utc = CL-UtcNow
}
$requestPath = Join-Path $requestDir "request.json"
[void](CL-WriteJsonFile $requestPath $reqObj)
$wsbText = @(
  "<Configuration>"
  "  <VGpu>Disable</VGpu>"
  "  <Networking>Disable</Networking>"
  "  <AudioInput>Disable</AudioInput>"
  "  <VideoInput>Disable</VideoInput>"
  "  <ProtectedClient>Enable</ProtectedClient>"
  "  <ClipboardRedirection>Disable</ClipboardRedirection>"
  "  <PrinterRedirection>Disable</PrinterRedirection>"
  "  <MemoryInMB>2048</MemoryInMB>"
  "</Configuration>"
) -join "`n"
$wsbPath = Join-Path $requestDir "clarity_display.wsb"
WriteUtf8NoBomLf $wsbPath $wsbText
$detail = "request_written"
$status = "requested"
$winSandboxExe = Join-Path $env:WINDIR "System32\WindowsSandbox.exe"
if($Launch){
  if(Test-Path -LiteralPath $winSandboxExe -PathType Leaf){
    try {
      Start-Process -FilePath $winSandboxExe -ArgumentList ("`"" + $wsbPath + "`"") | Out-Null
      $detail = "launch_started"
      $status = "launched"
      [void](CL-AppendDisplayReceipt -RuntimeRoot $RuntimeRoot -ReceiptType "clarity.display.adapter.windows_sandbox.launched.v1" -SessionId ([string]$session.session_id) -Tenant ([string]$session.tenant) -Principal ([string]$session.principal) -ContentRef ([string]$session.content_ref) -Adapter "windows_sandbox" -Status $status -Detail $detail)
    } catch {
      $detail = $_.Exception.Message
      $status = "launch_failed"
      [void](CL-AppendDisplayReceipt -RuntimeRoot $RuntimeRoot -ReceiptType "clarity.display.adapter.windows_sandbox.launch_failed.v1" -SessionId ([string]$session.session_id) -Tenant ([string]$session.tenant) -Principal ([string]$session.principal) -ContentRef ([string]$session.content_ref) -Adapter "windows_sandbox" -Status $status -Detail $detail)
      throw
    }
  } else {
    $detail = "windows_sandbox_not_available"
    $status = "launch_failed"
    [void](CL-AppendDisplayReceipt -RuntimeRoot $RuntimeRoot -ReceiptType "clarity.display.adapter.windows_sandbox.launch_failed.v1" -SessionId ([string]$session.session_id) -Tenant ([string]$session.tenant) -Principal ([string]$session.principal) -ContentRef ([string]$session.content_ref) -Adapter "windows_sandbox" -Status $status -Detail $detail)
    throw "WINDOWS_SANDBOX_NOT_AVAILABLE"
  }
} else {
  [void](CL-AppendDisplayReceipt -RuntimeRoot $RuntimeRoot -ReceiptType "clarity.display.adapter.windows_sandbox.requested.v1" -SessionId ([string]$session.session_id) -Tenant ([string]$session.tenant) -Principal ([string]$session.principal) -ContentRef ([string]$session.content_ref) -Adapter "windows_sandbox" -Status $status -Detail $detail)
}
Write-Host ("WINDOWS_SANDBOX_ADAPTER_OK: " + $SessionId) -ForegroundColor Green
Write-Output $requestPath
Write-Output $wsbPath
