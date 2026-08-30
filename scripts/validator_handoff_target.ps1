param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$TargetPath,
  [Parameter(Mandatory=$true)][string]$BaselinePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\canon.ps1"

function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
function HasProp($obj,[string]$name){ if($null -eq $obj){ return $false }; return [bool]($obj.PSObject.Properties.Name -contains $name) }

if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){ throw ("MISSING_REPO_ROOT: " + $RepoRoot) }
if(-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)){ throw ("MISSING_HANDOFF_TARGET: " + $TargetPath) }
if(-not (Test-Path -LiteralPath $BaselinePath -PathType Leaf)){ throw ("MISSING_BASELINE: " + $BaselinePath) }

$targetFull = [IO.Path]::GetFullPath($TargetPath)

# Verification must not mutate the target — hash before and after.
$hashBefore = Sha256HexFile $targetFull

# Signature evidence (host-observed Authenticode; not a measured-boot quote).
$sigStatus = "unknown"
$signer = $null
try {
  $sig = Get-AuthenticodeSignature -LiteralPath $targetFull -ErrorAction Stop
  $sigStatus = [string]$sig.Status
  if($null -ne $sig.SignerCertificate){ $signer = [string]$sig.SignerCertificate.Subject }
} catch { $sigStatus = "unavailable" }

$baselineRaw = (ReadUtf8Text $BaselinePath).TrimStart([char]0xFEFF)
$baseline = $baselineRaw | ConvertFrom-Json
if([string]$baseline.schema -ne "clarity.baseline.v1"){ throw "UNSUPPORTED_BASELINE_SCHEMA" }
$baselineHash = Sha256HexTextNormalized $baselineRaw
$entries = @()
if(HasProp $baseline "entries"){ $entries = @($baseline.entries) }

$entry = $null
foreach($e in $entries){
  if(([IO.Path]::GetFullPath([string]$e.path)).ToLowerInvariant() -eq $targetFull.ToLowerInvariant()){ $entry = $e; break }
}

$expected = $null
$verdict = ""
$reason = ""

if($null -eq $entry){
  $verdict = "HANDOFF_TARGET_UNKNOWN"; $reason = "BASELINE_UNKNOWN"
}
else {
  $expected = ([string]$entry.sha256).ToLowerInvariant()
  $revoked = (HasProp $entry "revoked") -and [bool]$entry.revoked
  $policy = if(HasProp $entry "policy"){ [string]$entry.policy } else { "" }
  $requireSigned = (HasProp $entry "require_signed") -and [bool]$entry.require_signed
  $expectedSigner = if(HasProp $entry "signer"){ [string]$entry.signer } else { "" }

  if($revoked){
    $verdict = "HANDOFF_TARGET_REVOKED"; $reason = "BASELINE_REVOKED"
  }
  elseif($policy -eq "deny"){
    $verdict = "HANDOFF_TARGET_POLICY_DENIED"; $reason = "BASELINE_POLICY_DENY"
  }
  elseif($hashBefore -ne $expected){
    $verdict = "HANDOFF_TARGET_MODIFIED"; $reason = "HANDOFF_HASH_MISMATCH"
  }
  elseif($requireSigned -and ($sigStatus -ne "Valid")){
    $verdict = "HANDOFF_TARGET_UNSIGNED"; $reason = "HANDOFF_SIGNATURE_NOT_VALID"
  }
  elseif($expectedSigner -and $signer -and ($expectedSigner -ne $signer)){
    $verdict = "HANDOFF_TARGET_POLICY_DENIED"; $reason = "HANDOFF_SIGNER_UNTRUSTED"
  }
  else {
    $verdict = "HANDOFF_TARGET_VALID"; $reason = "HANDOFF_TARGET_OK"
  }
}

$hashAfter = Sha256HexFile $targetFull
if($hashBefore -ne $hashAfter){ throw ("HANDOFF_VERIFY_MUTATED_TARGET: " + $targetFull) }

$allowed = ($verdict -eq "HANDOFF_TARGET_VALID")

$reportDir = Join-Path $RepoRoot "reports\validator_handoff_target"
EnsureDir $reportDir
$runId = [Guid]::NewGuid().ToString("N")
$outPath = Join-Path $reportDir ($runId + ".handoff_target.json")
$obj = [ordered]@{
  schema = "clarity.handoff_target.v1"
  run_id = $runId
  created_at_utc = UtcNow
  target_path = $targetFull
  target_sha256 = $hashBefore
  verdict = $verdict
  reason_code = $reason
  allowed = $allowed
  expected_sha256 = $expected
  signature_status = $sigStatus
  signer_subject = $signer
  baseline_path = $BaselinePath
  baseline_hash = $baselineHash
}
WriteUtf8NoBomLf $outPath (($obj | ConvertTo-Json -Compress -Depth 6))
Write-Host ("VALIDATOR_HANDOFF_TARGET_OK: " + $outPath + " verdict=" + $verdict) -ForegroundColor Green
Write-Output ("HANDOFF_TARGET_REPORT=" + $outPath)
Write-Output ("HANDOFF_TARGET_VERDICT=" + $verdict)
Write-Output "CLARITY_HANDOFF_TARGET_OK"
