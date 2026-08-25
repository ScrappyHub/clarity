param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ProfilePath,
  [Parameter(Mandatory=$false)][ValidateSet("hyperv","windows_sandbox")][string]$Adapter = "",
  [Parameter(Mandatory=$false)][string]$SnapshotPath = "",
  [Parameter(Mandatory=$false)][string]$ReportRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\canon.ps1"

function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
function Add-Issue([System.Collections.Generic.List[string]]$List,[string]$Code){ [void]$List.Add($Code) }

if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){ throw ("MISSING_REPO_ROOT: " + $RepoRoot) }
if(-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)){ throw ("MISSING_PROFILE: " + $ProfilePath) }
if([string]::IsNullOrWhiteSpace($ReportRoot)){ $ReportRoot = Join-Path $RepoRoot "reports\vm_compatibility" }
EnsureDir $ReportRoot

$profile = Get-Content -Raw -LiteralPath $ProfilePath -Encoding UTF8 | ConvertFrom-Json
if([string]$profile.schema -ne "clarity.vm_profile.v1"){ throw "UNSUPPORTED_PROFILE_SCHEMA" }
$profileHash = Sha256HexTextNormalized (($profile | ConvertTo-Json -Compress -Depth 20))
$configurationHash = Sha256HexTextNormalized (($profile.configuration | ConvertTo-Json -Compress -Depth 20))

$deny = New-Object System.Collections.Generic.List[string]
$defer = New-Object System.Collections.Generic.List[string]
$adapterName = [string]$profile.adapter
if($Adapter -and $Adapter -ne $adapterName){ Add-Issue $deny "PROFILE_ADAPTER_MISMATCH" }
if([string]$profile.profile_id -match "REPLACE_WITH|PLACEHOLDER|TODO"){ Add-Issue $deny "PROFILE_ID_NOT_RELEASE_READY" }
if([string]$profile.guest.image_ref -match "REPLACE_WITH|PLACEHOLDER|TODO"){ Add-Issue $defer "GUEST_IMAGE_DIGEST_UNRESOLVED" }
if([int]$profile.resources.vcpu -lt 1){ Add-Issue $deny "INVALID_VCPU" }
if([int]$profile.resources.memory_mb -lt 512){ Add-Issue $deny "INVALID_MEMORY" }
if([string]$profile.configuration.networking -ne "disabled"){ Add-Issue $defer "NETWORKING_NOT_DISABLED" }
if([string]$profile.configuration.clipboard -ne "disabled"){ Add-Issue $defer "CLIPBOARD_NOT_DISABLED" }
if([string]$profile.isolation.host_filesystem -ne "none"){ Add-Issue $defer "HOST_FILESYSTEM_EXPOSURE" }

$hypervAvailable = [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)
$sandboxAvailable = Test-Path -LiteralPath (Join-Path $env:WINDIR "System32\WindowsSandbox.exe") -PathType Leaf
$secureBootState = "unknown"
try {
  if(Get-Command Confirm-SecureBootUEFI -ErrorAction SilentlyContinue){
    $secureBootState = if([bool](Confirm-SecureBootUEFI)){ "enabled" } else { "disabled" }
  }
} catch {}

if($adapterName -eq "hyperv" -and -not $hypervAvailable){ Add-Issue $defer "HYPERV_UNAVAILABLE" }
if($adapterName -eq "windows_sandbox" -and -not $sandboxAvailable){ Add-Issue $defer "WINDOWS_SANDBOX_UNAVAILABLE" }
if([bool]$profile.guest.secure_boot_required){
  if($secureBootState -eq "disabled"){ Add-Issue $deny "SECURE_BOOT_DISABLED" }
  elseif($secureBootState -eq "unknown"){ Add-Issue $defer "SECURE_BOOT_UNOBSERVED" }
}
if([string]$profile.guest.measurement_policy -eq "required"){ Add-Issue $defer "GUEST_MEASUREMENT_UNAVAILABLE" }

$snapshotStatus = "not_supplied"
$snapshotId = $null
$snapshotHash = $null
if($SnapshotPath){
  if(-not (Test-Path -LiteralPath $SnapshotPath -PathType Leaf)){ Add-Issue $deny "MISSING_SNAPSHOT_MANIFEST" }
  else {
    $snapshot = Get-Content -Raw -LiteralPath $SnapshotPath -Encoding UTF8 | ConvertFrom-Json
    if([string]$snapshot.schema -ne "clarity.vm_snapshot.v1"){ Add-Issue $deny "UNSUPPORTED_SNAPSHOT_SCHEMA" }
    $snapshotHash = Sha256HexTextNormalized (($snapshot | ConvertTo-Json -Compress -Depth 20))
    $snapshotId = [string]$snapshot.snapshot_id
    $snapshotStatus = "manifest_verified"
    if([string]$profile.snapshot_policy.mode -eq "forbidden"){ Add-Issue $deny "SNAPSHOT_FORBIDDEN_BY_PROFILE" }
    if([string]$snapshot.profile_id -ne [string]$profile.profile_id){ Add-Issue $deny "SNAPSHOT_PROFILE_ID_MISMATCH" }
    if([string]$snapshot.profile_hash -ne $profileHash){ Add-Issue $deny "SNAPSHOT_PROFILE_HASH_MISMATCH" }
    if([string]$snapshot.configuration_hash -ne $configurationHash){ Add-Issue $deny "SNAPSHOT_CONFIGURATION_HASH_MISMATCH" }
    $allowedStates = @($profile.snapshot_policy.allowed_states | ForEach-Object { [string]$_ })
    if($allowedStates -notcontains [string]$snapshot.state){ Add-Issue $deny "SNAPSHOT_STATE_NOT_ALLOWED" }
    if(-not [bool]$snapshot.available){ Add-Issue $defer "SNAPSHOT_UNAVAILABLE" }
    if([string]$snapshot.verification_scope -ne "content_verified"){ Add-Issue $defer "SNAPSHOT_CONTENT_NOT_VERIFIED" }
    else { Add-Issue $defer "SNAPSHOT_CONTENT_VERIFICATION_UNAVAILABLE" }
    if($deny.Count -eq 0 -and $defer.Count -eq 0){ $snapshotStatus = "compatible" }
  }
} elseif([string]$profile.snapshot_policy.mode -eq "required") {
  Add-Issue $deny "SNAPSHOT_REQUIRED"
}

$decision = "compatible"
if($deny.Count -gt 0){ $decision = "deny" }
elseif($defer.Count -gt 0){ $decision = "deferred" }

$runId = [Guid]::NewGuid().ToString("N")
$outPath = Join-Path $ReportRoot ($runId + ".vm_compatibility.json")
$report = [ordered]@{
  schema = "clarity.vm_compatibility.v1"
  run_id = $runId
  created_at_utc = UtcNow
  adapter = $adapterName
  profile_path = $ProfilePath
  profile_id = [string]$profile.profile_id
  profile_version = [string]$profile.version
  profile_hash = $profileHash
  configuration_hash = $configurationHash
  snapshot_path = if($SnapshotPath){ $SnapshotPath } else { $null }
  snapshot_id = $snapshotId
  snapshot_hash = $snapshotHash
  snapshot_status = $snapshotStatus
  decision = $decision
  assurance_level = "A1_HOST_OBSERVED"
  host_capabilities = [ordered]@{
    hyperv_available = $hypervAvailable
    windows_sandbox_available = $sandboxAvailable
    secure_boot_state = $secureBootState
    guest_measurement_status = "unavailable"
  }
  deny_codes = @($deny.ToArray())
  defer_codes = @($defer.ToArray())
}
WriteUtf8NoBomLf $outPath (($report | ConvertTo-Json -Compress -Depth 12))
Write-Host ("VM_PROFILE_VALIDATION_REPORT: " + $outPath) -ForegroundColor Yellow
Write-Output $outPath
Write-Host ("VM_PROFILE_VALIDATE_OK: decision=" + $decision) -ForegroundColor Green
