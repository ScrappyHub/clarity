param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $RepoRoot "scripts\lib\canon.ps1")

function Get-OutPath([object[]]$Output,[string]$Pattern){
  $m = @($Output | ForEach-Object {
    $line = $_.ToString().Trim(); $v = $line; $i = $line.IndexOf("=")
    if($i -gt 0){ $v = $line.Substring($i+1).Trim() }
    if($v -like $Pattern -and (Test-Path -LiteralPath $v)){ $v }
  })
  if($m.Count -eq 0){ throw ("OUTPUT_NOT_FOUND: " + $Pattern) }
  return $m[$m.Count-1]
}
function HasProp($obj,[string]$n){ return [bool]($obj.PSObject.Properties.Name -contains $n) }

$Principal   = "clarity-run-test"
$root        = Join-Path ([IO.Path]::GetTempPath()) ("clarity-run-ht-test-" + [Guid]::NewGuid().ToString("N"))
$runtimeRoot = Join-Path $root "runtime"
$fixture     = Join-Path $root "fixture"
$boot        = Join-Path $root "boot"
$keysDir     = Join-Path $runtimeRoot "keys"
$keyBase     = Join-Path $keysDir "clarity_dev_ed25519"
$repoCleanup = New-Object System.Collections.Generic.List[string]

function Track([object]$run){
  $repoCleanup.Add([string]$run.phases.preflight.path)
  $repoCleanup.Add((Split-Path -Parent ([string]$run.phases.scan.path)))
  $repoCleanup.Add([string]$run.phases.isolation.path)
  $repoCleanup.Add([string]$run.phases.handoff.path)
  if(HasProp $run.phases "handoff_target"){ $repoCleanup.Add([string]$run.phases.handoff_target.path) }
}

try {
  New-Item -ItemType Directory -Force -Path $runtimeRoot,$fixture,$boot,$keysDir,(Join-Path $runtimeRoot "outbox") | Out-Null
  WriteUtf8NoBomLf (Join-Path $fixture "readme.txt") "clean`n"

  # Signing key + allowed_signers (for seal) and DEGRADED-capable runtime.
  $g = Start-Process -FilePath "ssh-keygen.exe" -ArgumentList ('-t ed25519 -f "' + $keyBase + '" -N "" -C run-ht-test -q') -Wait -PassThru -NoNewWindow
  if($g.ExitCode -ne 0){ throw "KEYGEN_FAILED" }
  $pub = (Get-Content -Raw -LiteralPath ($keyBase + ".pub") -Encoding UTF8).Trim(); $parts = $pub -split '\s+'
  WriteUtf8NoBomLf (Join-Path $keysDir "allowed_signers") ($Principal + " " + $parts[0] + " " + $parts[1] + "`n")

  # Boot target(s) + baseline (one valid, one modified).
  $validBoot    = Join-Path $boot "bootmgr.bin"
  $modifiedBoot = Join-Path $boot "modified.bin"
  WriteUtf8NoBomLf $validBoot    "valid-boot`n"
  WriteUtf8NoBomLf $modifiedBoot "tampered-boot`n"
  $baselinePath = Join-Path $root "boot_baseline.json"
  $baselineObj = [ordered]@{
    schema = "clarity.baseline.v1"; baseline_id = "run-ht-test"; version = "1.0.0"
    entries = @(
      [ordered]@{ path = $validBoot;    sha256 = (Sha256HexFile $validBoot) },
      [ordered]@{ path = $modifiedBoot; sha256 = ("a" * 64) }
    )
  }
  WriteUtf8NoBomLf $baselinePath (($baselineObj | ConvertTo-Json -Depth 6))

  $runner = Join-Path $RepoRoot "scripts\validator_run.ps1"
  $verifier = Join-Path $RepoRoot "scripts\validator_verify_run.ps1"

  # --- Case A: VALID boot target, DEGRADED allowed -> run proceeds, allowed=true ---
  $outA = @(& $runner -RepoRoot $RepoRoot -RuntimeRoot $runtimeRoot -Tenant test -Principal $Principal -ProducerInstance run-ht-A -TargetRoots @($fixture) -MaxFiles 20 -AllowDegraded -HandoffTargetPath $validBoot -HandoffBaselinePath $baselinePath)
  $runA = Get-OutPath $outA "*.run.json"
  $rA = Get-Content -Raw -LiteralPath $runA -Encoding UTF8 | ConvertFrom-Json
  $repoCleanup.Add($runA); Track $rA
  if(-not (HasProp $rA.phases "handoff_target")){ throw "A_MISSING_HANDOFF_TARGET_PHASE" }
  if([string]$rA.phases.handoff_target.verdict -ne "HANDOFF_TARGET_VALID"){ throw "A_VERDICT_NOT_VALID" }
  if(-not [bool]$rA.decision.allowed){ throw "A_EXPECTED_ALLOWED_WITH_VALID_TARGET" }
  & $verifier -RunPath $runA | Out-Null

  # Seal case A and verify the sealed bundle includes handoff_target.json.
  $sealOut = @(& (Join-Path $RepoRoot "scripts\validator_seal.ps1") -RunPath $runA -RuntimeRoot $runtimeRoot -RepoRoot $RepoRoot -Principal $Principal -KeyBase $keyBase)
  $sealDir = Get-OutPath $sealOut "*validator_seals*"
  $repoCleanup.Add($sealDir)
  if(-not (Test-Path -LiteralPath (Join-Path $sealDir "handoff_target.json") -PathType Leaf)){ throw "SEAL_MISSING_HANDOFF_TARGET" }
  & (Join-Path $RepoRoot "scripts\validator_verify_seal.ps1") -SealDir $sealDir -RuntimeRoot $runtimeRoot -Principal $Principal | Out-Null

  # --- Case B: MODIFIED boot target -> gate forces deny even with -AllowDegraded ---
  $outB = @(& $runner -RepoRoot $RepoRoot -RuntimeRoot $runtimeRoot -Tenant test -Principal $Principal -ProducerInstance run-ht-B -TargetRoots @($fixture) -MaxFiles 20 -AllowDegraded -HandoffTargetPath $modifiedBoot -HandoffBaselinePath $baselinePath)
  $runB = Get-OutPath $outB "*.run.json"
  $rB = Get-Content -Raw -LiteralPath $runB -Encoding UTF8 | ConvertFrom-Json
  $repoCleanup.Add($runB); Track $rB
  if([string]$rB.phases.handoff_target.verdict -ne "HANDOFF_TARGET_MODIFIED"){ throw "B_VERDICT_NOT_MODIFIED" }
  if([bool]$rB.decision.allowed){ throw "B_EXPECTED_DENY_WITH_MODIFIED_TARGET" }
  & $verifier -RunPath $runB | Out-Null

  Write-Host "CLARITY_TIER2_STEP8_WIRED_OK" -ForegroundColor Green
}
finally {
  foreach($p in $repoCleanup){
    if(Test-Path -LiteralPath $p -PathType Container){ Remove-Item -LiteralPath $p -Recurse -Force }
    elseif(Test-Path -LiteralPath $p -PathType Leaf){ Remove-Item -LiteralPath $p -Force }
  }
  if(Test-Path -LiteralPath $root -PathType Container){ Remove-Item -LiteralPath $root -Recurse -Force }
}
