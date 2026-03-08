param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dir {
  param([Parameter(Mandatory=$true)][string]$Path)
  if([string]::IsNullOrWhiteSpace($Path)){ throw "ENSURE_DIR_EMPTY" }
  if(-not (Test-Path -LiteralPath $Path -PathType Container)){
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Write-Utf8NoBomLf {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Text
  )
  $dir = Split-Path -Parent $Path
  if($dir){ Ensure-Dir $dir }
  $lf = $Text.Replace("`r`n","`n").Replace("`r","`n")
  if(-not $lf.EndsWith("`n")){ $lf += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllBytes($Path,$enc.GetBytes($lf))
}

function Parse-GatePs1 {
  param([Parameter(Mandatory=$true)][string]$Path)
  $tok = $null
  $err = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err)
  $errs = @(@($err))
  if($errs.Count -gt 0){
    $msg = ($errs | ForEach-Object { $_.ToString() }) -join "`n"
    throw ("PARSEGATE_FAIL: " + $Path + "`n" + $msg)
  }
}

function Write-Script {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Text
  )
  Write-Utf8NoBomLf -Path $Path -Text $Text
  Parse-GatePs1 -Path $Path
}

$ScriptsDir = Join-Path $RepoRoot "scripts"
Ensure-Dir $ScriptsDir

$PreflightPath = Join-Path $ScriptsDir "validator_preflight.ps1"
$GatePath      = Join-Path $ScriptsDir "validator_handoff_gate.ps1"
$RunnerPath    = Join-Path $ScriptsDir "_RUN_clarity_tier1_step4_v1.ps1"

$preflight = @'
param(
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$Tenant,
  [Parameter(Mandatory=$true)][string]$Principal,
  [Parameter(Mandatory=$true)][string]$ProducerInstance
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\canon.ps1"

function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }

if(-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)){ throw ("MISSING_RUNTIME_ROOT: " + $RuntimeRoot) }
if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){ throw ("MISSING_REPO_ROOT: " + $RepoRoot) }

$reportDir = Join-Path $RepoRoot "reports\validator_preflight"
EnsureDir $reportDir

$runId   = [Guid]::NewGuid().ToString("N")
$outPath = Join-Path $reportDir ($runId + ".preflight.json")

$reqPaths = @(
  (Join-Path $RepoRoot "scripts\_bootstrap_clarity_standalone_v1.ps1"),
  (Join-Path $RepoRoot "scripts\make_packet.ps1"),
  (Join-Path $RepoRoot "scripts\verify_packet.ps1"),
  (Join-Path $RepoRoot "scripts\pledge_local.ps1"),
  (Join-Path $RepoRoot "scripts\library_put.ps1"),
  (Join-Path $RepoRoot "scripts\library_get.ps1"),
  (Join-Path $RepoRoot "scripts\display_session_open.ps1"),
  (Join-Path $RepoRoot "scripts\display_session_close.ps1"),
  (Join-Path $RepoRoot "scripts\display_replay_view.ps1"),
  (Join-Path $RepoRoot "scripts\display_adapter_windows_sandbox.ps1")
)

$missing = New-Object System.Collections.Generic.List[string]
foreach($p in $reqPaths){
  if(-not (Test-Path -LiteralPath $p -PathType Leaf)){
    [void]$missing.Add($p)
  }
}

$keyBase         = Join-Path $RuntimeRoot "keys\clarity_dev_ed25519"
$pubPath         = $keyBase + ".pub"
$allowed         = Join-Path $RuntimeRoot "keys\allowed_signers"
$outbox          = Join-Path $RuntimeRoot "outbox"
$pledges         = Join-Path $RuntimeRoot "pledges\pledges.ndjson"
$libraryLedger   = Join-Path $RuntimeRoot "library\ledger\library.ndjson"
$displayReceipts = Join-Path $RuntimeRoot "display\receipts\display_receipts.ndjson"
$sandboxExe      = Join-Path $env:WINDIR "System32\WindowsSandbox.exe"

$sandboxAvailable = (Test-Path -LiteralPath $sandboxExe -PathType Leaf)

$deviceName  = $env:COMPUTERNAME
$osCaption   = ""
$osVersion   = ""
$biosVersion = ""

try {
  $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
  $osCaption = [string]$os.Caption
  $osVersion = [string]$os.Version
} catch {}

try {
  $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
  $biosVersion = [string](@($bios.SMBIOSBIOSVersion)[0])
} catch {}

$tpmPresent = $false
$tpmReady   = $false
try {
  if(Get-Command Get-Tpm -ErrorAction SilentlyContinue){
    $tpm = Get-Tpm
    $tpmPresent = [bool]$tpm.TpmPresent
    $tpmReady   = [bool]$tpm.TpmReady
  }
} catch {}

$requiredRuntimeOk =
  (Test-Path -LiteralPath $keyBase -PathType Leaf) -and
  (Test-Path -LiteralPath $pubPath -PathType Leaf) -and
  (Test-Path -LiteralPath $allowed -PathType Leaf) -and
  (Test-Path -LiteralPath $outbox -PathType Container)

$trustTier   = "FAIL"
$reasonCodes = New-Object System.Collections.Generic.List[string]

if($missing.Count -gt 0){ [void]$reasonCodes.Add("MISSING_REQUIRED_SCRIPTS") }
if(-not $requiredRuntimeOk){ [void]$reasonCodes.Add("RUNTIME_NOT_READY") }
if(-not $tpmPresent){ [void]$reasonCodes.Add("TPM_ABSENT_OR_UNREADABLE") }

if(($missing.Count -eq 0) -and $requiredRuntimeOk){
  if($tpmPresent -and $tpmReady){
    $trustTier = "FULL"
  } else {
    $trustTier = "DEGRADED"
  }
}

$buildHashes = [ordered]@{}
foreach($p in $reqPaths){
  if(Test-Path -LiteralPath $p -PathType Leaf){
    $buildHashes[(Split-Path -Leaf $p)] = (Sha256HexFile $p)
  }
}

$obj = [ordered]@{
  schema = "clarity.validator_preflight.v1"
  run_id = $runId
  created_at_utc = UtcNow
  validator = "clarity"
  mode = "hosted_validator_shell"
  tenant = $Tenant
  principal = $Principal
  producer_instance = $ProducerInstance
  trust_tier = $trustTier
  reason_codes = @($reasonCodes.ToArray())
  device = [ordered]@{
    computer_name = $deviceName
    os_caption = $osCaption
    os_version = $osVersion
    bios_version = $biosVersion
  }
  capabilities = [ordered]@{
    tpm_present = $tpmPresent
    tpm_ready = $tpmReady
    windows_sandbox_available = $sandboxAvailable
  }
  runtime = [ordered]@{
    runtime_root = $RuntimeRoot
    key_present = (Test-Path -LiteralPath $keyBase -PathType Leaf)
    pub_present = (Test-Path -LiteralPath $pubPath -PathType Leaf)
    allowed_signers_present = (Test-Path -LiteralPath $allowed -PathType Leaf)
    outbox_present = (Test-Path -LiteralPath $outbox -PathType Container)
    pledges_present = (Test-Path -LiteralPath $pledges -PathType Leaf)
    library_ledger_present = (Test-Path -LiteralPath $libraryLedger -PathType Leaf)
    display_receipts_present = (Test-Path -LiteralPath $displayReceipts -PathType Leaf)
  }
  build_hashes = $buildHashes
  missing_required_scripts = @($missing.ToArray())
}

$json = ($obj | ConvertTo-Json -Compress -Depth 8)
WriteUtf8NoBomLf $outPath $json
Write-Host ("VALIDATOR_PREFLIGHT_OK: " + $outPath) -ForegroundColor Green
Write-Output $outPath
