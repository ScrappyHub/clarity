param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$Tenant,
  [Parameter(Mandatory=$true)][string]$Principal,
  [Parameter(Mandatory=$true)][string]$ProducerInstance,
  [Parameter(Mandatory=$false)][string[]]$TargetRoots,
  [Parameter(Mandatory=$false)][int]$MaxFiles = 5000,
  [Parameter(Mandatory=$false)][switch]$AllowDegraded
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\canon.ps1"

function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
function Invoke-PathOutput([string]$Path,[hashtable]$Arguments,[string]$Pattern){
  $output = @(& $Path @Arguments)
  $matches = @($output | ForEach-Object {
    $line = $_.ToString().Trim()
    $candidate = $line
    $separator = $line.IndexOf("=")
    if($separator -gt 0){ $candidate = $line.Substring($separator + 1).Trim() }
    if($candidate -like $Pattern -and (Test-Path -LiteralPath $candidate -PathType Leaf)){ $candidate }
  })
  if($matches.Count -eq 0){ throw ("MISSING_PHASE_OUTPUT: " + $Pattern) }
  return $matches[$matches.Count - 1]
}

if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){ throw ("MISSING_REPO_ROOT: " + $RepoRoot) }
EnsureDir $RuntimeRoot

$runId = [Guid]::NewGuid().ToString("N")
$reportDir = Join-Path $RepoRoot "reports\validator_runs"
EnsureDir $reportDir
$runPath = Join-Path $reportDir ($runId + ".run.json")

$preflightPath = Invoke-PathOutput (Join-Path $PSScriptRoot "validator_preflight.ps1") @{
  RuntimeRoot=$RuntimeRoot; RepoRoot=$RepoRoot; Tenant=$Tenant; Principal=$Principal; ProducerInstance=$ProducerInstance
} "*.preflight.json"

$scanArgs = @{ RepoRoot=$RepoRoot; MaxFiles=$MaxFiles }
if($TargetRoots -and $TargetRoots.Count -gt 0){ $scanArgs["TargetRoots"] = $TargetRoots }
$scanPath = Invoke-PathOutput (Join-Path $PSScriptRoot "validator_scan_targeted.ps1") $scanArgs "*.scan.json"

$isolationPath = Invoke-PathOutput (Join-Path $PSScriptRoot "validator_isolate_copy.ps1") @{
  RuntimeRoot=$RuntimeRoot; RepoRoot=$RepoRoot; ScanReportPath=$scanPath; Tenant=$Tenant; Principal=$Principal; ProducerInstance=$ProducerInstance
} "*.isolation.json"

$gateArgs = @{ RepoRoot=$RepoRoot; PreflightPath=$preflightPath; ScanPath=$scanPath; IsolationPath=$isolationPath }
if($AllowDegraded.IsPresent){ $gateArgs["AllowDegraded"] = $true }
$handoffPath = Invoke-PathOutput (Join-Path $PSScriptRoot "validator_handoff_gate.ps1") $gateArgs "*.handoff.json"

$preflight = Get-Content -Raw -LiteralPath $preflightPath -Encoding UTF8 | ConvertFrom-Json
$scan = Get-Content -Raw -LiteralPath $scanPath -Encoding UTF8 | ConvertFrom-Json
$isolation = Get-Content -Raw -LiteralPath $isolationPath -Encoding UTF8 | ConvertFrom-Json
$handoff = Get-Content -Raw -LiteralPath $handoffPath -Encoding UTF8 | ConvertFrom-Json

$obj = [ordered]@{
  schema = "clarity.validator_run.v1"
  run_id = $runId
  created_at_utc = UtcNow
  validator = "clarity"
  assurance_level = "A1_HOST_OBSERVED"
  tenant = $Tenant
  principal = $Principal
  producer_instance = $ProducerInstance
  phases = [ordered]@{
    preflight = [ordered]@{ path=$preflightPath; sha256=(Sha256HexFile $preflightPath); run_id=[string]$preflight.run_id; trust_tier=[string]$preflight.trust_tier }
    scan = [ordered]@{ path=$scanPath; sha256=(Sha256HexFile $scanPath); findings_path=[string]$scan.findings_path; findings_sha256=(Sha256HexFile ([string]$scan.findings_path)); run_id=[string]$scan.run_id; suspicious_count=[int]$scan.suspicious_count }
    isolation = [ordered]@{ path=$isolationPath; sha256=(Sha256HexFile $isolationPath); ledger_path=[string]$isolation.ledger_path; ledger_sha256=(Sha256HexFile ([string]$isolation.ledger_path)); run_id=[string]$isolation.run_id; isolated_count=[int]$isolation.isolated_count }
    handoff = [ordered]@{ path=$handoffPath; sha256=(Sha256HexFile $handoffPath); preflight_run_id=[string]$handoff.preflight_run_id; decision=[string]$handoff.decision; allowed=[bool]$handoff.allowed }
  }
  decision = [ordered]@{
    trust_tier = [string]$preflight.trust_tier
    handoff = [string]$handoff.decision
    allowed = [bool]$handoff.allowed
  }
}

WriteUtf8NoBomLf $runPath (($obj | ConvertTo-Json -Compress -Depth 10))
Write-Host ("VALIDATOR_RUN_OK: " + $runPath) -ForegroundColor Green
Write-Output $runPath
