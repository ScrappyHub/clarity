param(
  [Parameter(Mandatory=$true)][string]$RunPath,
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$Principal,
  [Parameter(Mandatory=$false)][string]$KeyBase = "",
  [Parameter(Mandatory=$false)][string]$Namespace = "clarity.validator_run.v1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\canon.ps1"

function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }

if(-not (Test-Path -LiteralPath $RunPath -PathType Leaf)){ throw ("MISSING_RUN: " + $RunPath) }
if(-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)){ throw ("MISSING_RUNTIME_ROOT: " + $RuntimeRoot) }
if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){ throw ("MISSING_REPO_ROOT: " + $RepoRoot) }

$run = Get-Content -Raw -LiteralPath $RunPath -Encoding UTF8 | ConvertFrom-Json
if([string]$run.schema -ne "clarity.validator_run.v1"){ throw "UNSUPPORTED_RUN_SCHEMA" }

if([string]::IsNullOrWhiteSpace($KeyBase)){ $KeyBase = Join-Path $RuntimeRoot "keys\clarity_dev_ed25519" }
if(-not (Test-Path -LiteralPath $KeyBase -PathType Leaf)){ throw ("MISSING_SIGNING_KEY: " + $KeyBase) }

$p = $run.phases
$items = @(
  [ordered]@{ name = "report.json";             src = $RunPath;                              expect = $null },
  [ordered]@{ name = "preflight.json";           src = [string]$p.preflight.path;             expect = [string]$p.preflight.sha256 },
  [ordered]@{ name = "scan.json";                src = [string]$p.scan.path;                  expect = [string]$p.scan.sha256 },
  [ordered]@{ name = "scan_findings.ndjson";     src = [string]$p.scan.findings_path;         expect = [string]$p.scan.findings_sha256 },
  [ordered]@{ name = "isolation.json";           src = [string]$p.isolation.path;             expect = [string]$p.isolation.sha256 },
  [ordered]@{ name = "isolation_ledger.ndjson";  src = [string]$p.isolation.ledger_path;      expect = [string]$p.isolation.ledger_sha256 },
  [ordered]@{ name = "handoff_decision.json";    src = [string]$p.handoff.path;               expect = [string]$p.handoff.sha256 }
)

$sealDir = Join-Path $RepoRoot ("reports\validator_seals\" + [string]$run.run_id)
EnsureDir $sealDir

$sumLines = New-Object System.Collections.Generic.List[string]
$fileEntries = New-Object System.Collections.Generic.List[object]
foreach($it in $items){
  if(-not (Test-Path -LiteralPath $it.src -PathType Leaf)){ throw ("MISSING_SEAL_SOURCE: " + $it.name) }
  if($it.expect){
    $srcHash = Sha256HexFile $it.src
    if($srcHash -ne $it.expect){ throw ("SEAL_SOURCE_HASH_MISMATCH: " + $it.name) }
  }
  $dest = Join-Path $sealDir $it.name
  Copy-Item -LiteralPath $it.src -Destination $dest -Force
  $h = Sha256HexFile $dest
  [void]$sumLines.Add(($h + "  " + $it.name))
  [void]$fileEntries.Add([ordered]@{ name = $it.name; sha256 = $h })
}

$sumPath = Join-Path $sealDir "sha256sums.txt"
$sumText = (($sumLines.ToArray()) -join "`n") + "`n"
WriteUtf8NoBomLf $sumPath $sumText

# Detached Ed25519 signature over the sums manifest (same mechanism as packets).
$signArg = ("-Y sign -f `"" + $KeyBase + "`" -n " + $Namespace + " -I `"" + $Principal + "`" `"" + $sumPath + "`"")
$sp = Start-Process -FilePath "ssh-keygen.exe" -ArgumentList $signArg -Wait -PassThru -NoNewWindow
if($sp.ExitCode -ne 0){ throw ("SEAL_SIGN_FAILED exit=" + $sp.ExitCode) }
$producedSig = $sumPath + ".sig"
if(-not (Test-Path -LiteralPath $producedSig -PathType Leaf)){ throw "SEAL_SIGNATURE_NOT_PRODUCED" }
$sigPath = Join-Path $sealDir "signature.sig"
Move-Item -LiteralPath $producedSig -Destination $sigPath -Force

$seal = [ordered]@{
  schema = "clarity.validator_seal.v1"
  run_id = [string]$run.run_id
  created_at_utc = UtcNow
  principal = $Principal
  namespace = $Namespace
  key_id = "clarity-dev-ed25519"
  sha256sums_sha256 = (Sha256HexFile $sumPath)
  files = @($fileEntries.ToArray())
  sig_ref = "signature.sig"
}
$sealPath = Join-Path $sealDir "seal.json"
WriteUtf8NoBomLf $sealPath (($seal | ConvertTo-Json -Depth 6))

Write-Host ("VALIDATOR_SEAL_OK: " + $sealDir) -ForegroundColor Green
Write-Output ("SEAL_DIR=" + $sealDir)
Write-Output "CLARITY_VALIDATOR_SEAL_OK"
