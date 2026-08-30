param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $RepoRoot "scripts\lib\canon.ps1")

$script:reports = New-Object System.Collections.Generic.List[string]
$verifier = Join-Path $RepoRoot "scripts\validator_handoff_target.ps1"

function Invoke-Verify([string]$TargetPath,[string]$BaselinePath){
  $out = @(& $verifier -RepoRoot $RepoRoot -TargetPath $TargetPath -BaselinePath $BaselinePath)
  $verdict = $null
  $report = $null
  foreach($line in $out){
    $t = $line.ToString().Trim()
    if($t -like "HANDOFF_TARGET_VERDICT=*"){ $verdict = $t.Substring($t.IndexOf("=")+1).Trim() }
    if($t -like "HANDOFF_TARGET_REPORT=*"){ $report = $t.Substring($t.IndexOf("=")+1).Trim() }
  }
  if($report){ $script:reports.Add($report) }
  if(-not $verdict){ throw "NO_VERDICT_EMITTED" }
  return $verdict
}

$root    = Join-Path ([IO.Path]::GetTempPath()) ("clarity-handoff-target-test-" + [Guid]::NewGuid().ToString("N"))
$fixture = Join-Path $root "boot"
try {
  New-Item -ItemType Directory -Force -Path $fixture | Out-Null
  $validPath    = Join-Path $fixture "bootmgr.bin"
  $modifiedPath = Join-Path $fixture "modified.bin"
  $unsignedPath = Join-Path $fixture "unsigned.bin"
  $revokedPath  = Join-Path $fixture "revoked.bin"
  $deniedPath   = Join-Path $fixture "denied.bin"
  $unknownPath  = Join-Path $fixture "stranger.bin"
  WriteUtf8NoBomLf $validPath    "valid-boot`n"
  WriteUtf8NoBomLf $modifiedPath "modified-boot`n"
  WriteUtf8NoBomLf $unsignedPath "unsigned-boot`n"
  WriteUtf8NoBomLf $revokedPath  "revoked-boot`n"
  WriteUtf8NoBomLf $deniedPath   "denied-boot`n"
  WriteUtf8NoBomLf $unknownPath  "stranger-boot`n"

  $baselinePath = Join-Path $root "boot_baseline.json"
  $baselineObj = [ordered]@{
    schema = "clarity.baseline.v1"
    baseline_id = "handoff-target-test"
    version = "1.0.0"
    entries = @(
      [ordered]@{ path = $validPath;    sha256 = (Sha256HexFile $validPath) },
      [ordered]@{ path = $modifiedPath; sha256 = ("a" * 64) },
      [ordered]@{ path = $unsignedPath; sha256 = (Sha256HexFile $unsignedPath); require_signed = $true },
      [ordered]@{ path = $revokedPath;  sha256 = (Sha256HexFile $revokedPath);  revoked = $true },
      [ordered]@{ path = $deniedPath;   sha256 = (Sha256HexFile $deniedPath);   policy = "deny" }
    )
  }
  WriteUtf8NoBomLf $baselinePath (($baselineObj | ConvertTo-Json -Depth 6))

  $cases = @(
    @{ p = $validPath;    want = "HANDOFF_TARGET_VALID" },
    @{ p = $modifiedPath; want = "HANDOFF_TARGET_MODIFIED" },
    @{ p = $unsignedPath; want = "HANDOFF_TARGET_UNSIGNED" },
    @{ p = $revokedPath;  want = "HANDOFF_TARGET_REVOKED" },
    @{ p = $deniedPath;   want = "HANDOFF_TARGET_POLICY_DENIED" },
    @{ p = $unknownPath;  want = "HANDOFF_TARGET_UNKNOWN" }
  )
  foreach($c in $cases){
    $got = Invoke-Verify $c.p $baselinePath
    if($got -ne $c.want){ throw ("VERDICT_MISMATCH target=" + (Split-Path -Leaf $c.p) + " want=" + $c.want + " got=" + $got) }
  }

  # No-mutation invariant on the valid target.
  $before = Sha256HexFile $validPath
  Invoke-Verify $validPath $baselinePath | Out-Null
  if((Sha256HexFile $validPath) -ne $before){ throw "HANDOFF_VERIFY_MUTATED_TARGET" }

  Write-Host "CLARITY_TIER2_STEP8_OK" -ForegroundColor Green
}
finally {
  foreach($r in $script:reports){ if(Test-Path -LiteralPath $r -PathType Leaf){ Remove-Item -LiteralPath $r -Force } }
  if(Test-Path -LiteralPath $root -PathType Container){ Remove-Item -LiteralPath $root -Recurse -Force }
}
