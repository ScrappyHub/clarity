param(
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$SessionId,
  [Parameter(Mandatory=$true)][string]$ProfilePath,
  [Parameter(Mandatory=$false)][string]$SnapshotPath = ""
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
if(-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)){ throw ("MISSING_PROFILE: " + $ProfilePath) }

$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source
$Validator = Join-Path $PSScriptRoot "vm_profile_validate.ps1"
$validationArgs = @("-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",$Validator,"-RepoRoot",(Split-Path -Parent $PSScriptRoot),"-ProfilePath",$ProfilePath,"-Adapter","hyperv")
if($SnapshotPath){ $validationArgs += @("-SnapshotPath",$SnapshotPath) }
$validationOutput = @(& $PSExe @validationArgs)
$validationMatches = @($validationOutput | ForEach-Object { $line=$_.ToString().Trim(); if($line -like "*.vm_compatibility.json" -and (Test-Path -LiteralPath $line -PathType Leaf)){ $line } })
if($validationMatches.Count -eq 0){ throw "MISSING_VM_COMPATIBILITY_REPORT" }
$validationPath = $validationMatches[$validationMatches.Count - 1]
$validation = Get-Content -Raw -LiteralPath $validationPath -Encoding UTF8 | ConvertFrom-Json
if([string]$validation.decision -eq "deny"){ throw ("VM_PROFILE_DENIED: " + (($validation.deny_codes) -join ",")) }
$validationHash = Sha256HexFile $validationPath

$reqRoot = Join-Path $RuntimeRoot ("display\adapters\hyperv\requests\" + $SessionId)
EnsureDir $reqRoot

$requestPath = Join-Path $reqRoot "request.json"
$launchCmd   = Join-Path $reqRoot "launch.cmd"

$hypervAvailable = $false
if(Get-Command Get-VM -ErrorAction SilentlyContinue){ $hypervAvailable = $true }

$status = if([string]$validation.decision -eq "deferred"){ "deferred" } else { "requested" }
$detail = if($status -eq "deferred"){ "hyperv_request_deferred" } else { "hyperv_request_materialized" }
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
  profile_path = $ProfilePath
  profile_id = [string]$validation.profile_id
  profile_version = [string]$validation.profile_version
  profile_hash = [string]$validation.profile_hash
  configuration_hash = [string]$validation.configuration_hash
  profile_validation_path = $validationPath
  profile_validation_hash = $validationHash
  profile_decision = [string]$validation.decision
  snapshot_path = if($SnapshotPath){ $SnapshotPath } else { $null }
  snapshot_id = $validation.snapshot_id
  snapshot_hash = $validation.snapshot_hash
  snapshot_status = [string]$validation.snapshot_status
}

$requestHash = CL-RequestHash $obj
$obj["request_hash"] = $requestHash
$json = ($obj | ConvertTo-Json -Compress -Depth 6)
WriteUtf8NoBomLf $requestPath $json

$cmdLines = @(
  '@echo off',
  'REM Clarity Hyper-V launch stub',
  ('REM SessionId=' + $SessionId),
  ('REM RequestJson=' + $requestPath),
  ('REM ProfileId=' + [string]$validation.profile_id),
  ('REM ProfileHash=' + [string]$validation.profile_hash),
  ('echo CLARITY_HYPERV_REQUEST_READY ' + $SessionId)
)
WriteUtf8NoBomLf $launchCmd (($cmdLines -join "`n") + "`n")

[void](CL-AppendDisplayReceipt -RuntimeRoot $RuntimeRoot -ReceiptType "clarity.display.adapter.hyperv.requested.v1" -SessionId ([string]$session.session_id) -Tenant ([string]$session.tenant) -Principal ([string]$session.principal) -ContentRef ([string]$session.content_ref) -Adapter "hyperv" -Status $status -Detail ($detail + ";request_hash=" + $requestHash))

Write-Host ("HYPERV_ADAPTER_OK: " + $SessionId) -ForegroundColor Green
Write-Output $requestPath
Write-Output $launchCmd
Write-Output $validationPath
