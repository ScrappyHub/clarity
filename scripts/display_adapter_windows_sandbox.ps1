param(
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$SessionId,
  [Parameter(Mandatory=$true)][string]$ProfilePath,
  [switch]$Launch
)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
. "$PSScriptRoot\lib\canon.ps1"
. "$PSScriptRoot\lib\clarity_display_common.ps1"
$sessionPath = CL-SessionPath $RuntimeRoot $SessionId
if(-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)){ throw ("MISSING_SESSION: " + $sessionPath) }
$session = Get-Content -Raw -LiteralPath $sessionPath -Encoding UTF8 | ConvertFrom-Json
if([string]$session.adapter -ne "windows_sandbox"){ throw "SESSION_ADAPTER_MISMATCH_NOT_WINDOWS_SANDBOX" }
if([string]$session.status -ne "open"){ throw "SESSION_NOT_OPEN" }
if(-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)){ throw ("MISSING_PROFILE: " + $ProfilePath) }
$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source
$Validator = Join-Path $PSScriptRoot "vm_profile_validate.ps1"
$validationOutput = @(& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Validator -RepoRoot (Split-Path -Parent $PSScriptRoot) -ProfilePath $ProfilePath -Adapter windows_sandbox)
$validationMatches = @($validationOutput | ForEach-Object { $line=$_.ToString().Trim(); if($line -like "*.vm_compatibility.json" -and (Test-Path -LiteralPath $line -PathType Leaf)){ $line } })
if($validationMatches.Count -eq 0){ throw "MISSING_VM_COMPATIBILITY_REPORT" }
$validationPath = $validationMatches[$validationMatches.Count - 1]
$validation = Get-Content -Raw -LiteralPath $validationPath -Encoding UTF8 | ConvertFrom-Json
if([string]$validation.decision -eq "deny"){ throw ("VM_PROFILE_DENIED: " + (($validation.deny_codes) -join ",")) }
$validationHash = Sha256HexFile $validationPath
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
  profile_path = $ProfilePath
  profile_id = [string]$validation.profile_id
  profile_version = [string]$validation.profile_version
  profile_hash = [string]$validation.profile_hash
  configuration_hash = [string]$validation.configuration_hash
  profile_validation_path = $validationPath
  profile_validation_hash = $validationHash
  profile_decision = [string]$validation.decision
  snapshot_path = $null
  snapshot_id = $validation.snapshot_id
  snapshot_hash = $validation.snapshot_hash
  snapshot_status = [string]$validation.snapshot_status
}
$requestPath = Join-Path $requestDir "request.json"
$requestHash = CL-RequestHash $reqObj
$reqObj["request_hash"] = $requestHash
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
      [void](CL-AppendDisplayReceipt -RuntimeRoot $RuntimeRoot -ReceiptType "clarity.display.adapter.windows_sandbox.launched.v1" -SessionId ([string]$session.session_id) -Tenant ([string]$session.tenant) -Principal ([string]$session.principal) -ContentRef ([string]$session.content_ref) -Adapter "windows_sandbox" -Status $status -Detail ($detail + ";request_hash=" + $requestHash))
    } catch {
      $detail = $_.Exception.Message
      $status = "launch_failed"
      [void](CL-AppendDisplayReceipt -RuntimeRoot $RuntimeRoot -ReceiptType "clarity.display.adapter.windows_sandbox.launch_failed.v1" -SessionId ([string]$session.session_id) -Tenant ([string]$session.tenant) -Principal ([string]$session.principal) -ContentRef ([string]$session.content_ref) -Adapter "windows_sandbox" -Status $status -Detail ($detail + ";request_hash=" + $requestHash))
      throw
    }
  } else {
    $detail = "windows_sandbox_not_available"
    $status = "launch_failed"
    [void](CL-AppendDisplayReceipt -RuntimeRoot $RuntimeRoot -ReceiptType "clarity.display.adapter.windows_sandbox.launch_failed.v1" -SessionId ([string]$session.session_id) -Tenant ([string]$session.tenant) -Principal ([string]$session.principal) -ContentRef ([string]$session.content_ref) -Adapter "windows_sandbox" -Status $status -Detail ($detail + ";request_hash=" + $requestHash))
    throw "WINDOWS_SANDBOX_NOT_AVAILABLE"
  }
} else {
  [void](CL-AppendDisplayReceipt -RuntimeRoot $RuntimeRoot -ReceiptType "clarity.display.adapter.windows_sandbox.requested.v1" -SessionId ([string]$session.session_id) -Tenant ([string]$session.tenant) -Principal ([string]$session.principal) -ContentRef ([string]$session.content_ref) -Adapter "windows_sandbox" -Status $status -Detail ($detail + ";request_hash=" + $requestHash))
}
Write-Host ("WINDOWS_SANDBOX_ADAPTER_OK: " + $SessionId) -ForegroundColor Green
Write-Output $requestPath
Write-Output $wsbPath
Write-Output $validationPath
