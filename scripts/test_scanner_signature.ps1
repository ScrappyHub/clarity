param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $RepoRoot "scripts\lib\canon.ps1")

function Get-ScanReport([object[]]$Output){
  $m = @($Output | ForEach-Object {
    $line = $_.ToString().Trim()
    $v = $line
    $i = $line.IndexOf("=")
    if($i -gt 0){ $v = $line.Substring($i + 1).Trim() }
    if($v -like "*.scan.json" -and (Test-Path -LiteralPath $v -PathType Leaf)){ $v }
  })
  if($m.Count -eq 0){ throw "SCAN_REPORT_NOT_FOUND" }
  return $m[$m.Count - 1]
}

# This test needs a real, validly-signed binary on the host to exercise the
# positive path and the signer-mismatch path honestly (a fabricated signature
# can't be constructed in-test). notepad.exe is signed on every supported
# Windows version and is read-only copied, never executed or modified.
$signedSource = Join-Path $env:SystemRoot "System32\notepad.exe"
if(-not (Test-Path -LiteralPath $signedSource -PathType Leaf)){ throw ("SIGNED_FIXTURE_SOURCE_MISSING: " + $signedSource) }
$sourceSig = Get-AuthenticodeSignature -LiteralPath $signedSource -ErrorAction Stop
if([string]$sourceSig.Status -ne "Valid"){ throw ("SIGNED_FIXTURE_SOURCE_NOT_VALID: " + $sourceSig.Status) }
$sourceSigner = [string]$sourceSig.SignerCertificate.Subject

$root = Join-Path ([IO.Path]::GetTempPath()) ("clarity-scanner-sig-test-" + [Guid]::NewGuid().ToString("N"))
$fixture = Join-Path $root "fixture"
$createdScanDirs = New-Object System.Collections.Generic.List[string]
try {
  New-Item -ItemType Directory -Force -Path $fixture | Out-Null

  $unsignedPath = Join-Path $fixture "unsigned_but_required.dat"
  WriteUtf8NoBomLf $unsignedPath "not-signed-content`n"

  $signedValidPath = Join-Path $fixture "signed_valid.dat"
  Copy-Item -LiteralPath $signedSource -Destination $signedValidPath -Force

  $signedMismatchPath = Join-Path $fixture "signed_mismatch.dat"
  Copy-Item -LiteralPath $signedSource -Destination $signedMismatchPath -Force

  $rulesPath = Join-Path $root "rules.json"
  $rulesObj = [ordered]@{
    version = "scanner_signature_test"
    suspicion = [ordered]@{
      startup_bad_extensions = @()
      temp_exec_extensions = @()
      double_extension_regex = ""
    }
    scan = [ordered]@{ skip_dir_names = @() }
  }
  WriteUtf8NoBomLf $rulesPath (($rulesObj | ConvertTo-Json -Depth 6))

  $unsignedHash = Sha256HexFile $unsignedPath
  $signedValidHash = Sha256HexFile $signedValidPath
  $signedMismatchHash = Sha256HexFile $signedMismatchPath

  $baselinePath = Join-Path $root "baseline.json"
  $baselineObj = [ordered]@{
    schema = "clarity.baseline.v1"
    baseline_id = "scanner-signature-test-baseline"
    version = "1.0.0"
    entries = @(
      [ordered]@{ path = $unsignedPath;       sha256 = $unsignedHash;       require_signed = $true },
      [ordered]@{ path = $signedValidPath;     sha256 = $signedValidHash;    require_signed = $true },
      [ordered]@{ path = $signedMismatchPath;  sha256 = $signedMismatchHash; signer = "CN=Definitely Not The Real Signer, O=Clarity Test, C=US" }
    )
  }
  WriteUtf8NoBomLf $baselinePath (($baselineObj | ConvertTo-Json -Depth 6))

  # Snapshot fixture hashes before the scan (mutation check).
  $before = @{}
  Get-ChildItem -LiteralPath $fixture -Recurse -File | ForEach-Object { $before[$_.FullName] = (Sha256HexFile $_.FullName) }

  $out = @(& (Join-Path $RepoRoot "scripts\validator_scan_targeted.ps1") `
    -RepoRoot $RepoRoot `
    -TargetRoots @($fixture) `
    -RulesPath $rulesPath `
    -BaselinePath $baselinePath `
    -MaxFiles 100)

  $scanPath = Get-ScanReport $out
  $createdScanDirs.Add((Split-Path -Parent $scanPath))
  $scan = Get-Content -Raw -LiteralPath $scanPath -Encoding UTF8 | ConvertFrom-Json

  if([int]$scan.classified_counts.verified -ne 1){ throw "EXPECTED_ONE_VERIFIED" }
  if([int]$scan.classified_counts.compromised -ne 2){ throw "EXPECTED_TWO_COMPROMISED" }
  if([int]$scan.signature_checks_performed -ne 3){ throw "EXPECTED_THREE_SIGNATURE_CHECKS" }

  $findingLines = @(Get-Content -LiteralPath ([string]$scan.findings_path) -Encoding UTF8 | Where-Object { $_ -and $_.Trim() -ne "" })
  if($findingLines.Count -ne 2){ throw "EXPECTED_TWO_FINDING_LINES" }
  $byReason = @{}
  foreach($fl in $findingLines){
    $f = $fl | ConvertFrom-Json
    $byReason[[string]$f.reason_code] = $f
  }
  if(-not $byReason.ContainsKey("FILE_SIGNATURE_NOT_VALID")){ throw "MISSING_SIGNATURE_NOT_VALID_FINDING" }
  if(-not $byReason.ContainsKey("FILE_SIGNER_UNTRUSTED")){ throw "MISSING_SIGNER_UNTRUSTED_FINDING" }

  $notValid = $byReason["FILE_SIGNATURE_NOT_VALID"]
  if([string]$notValid.target_path -ne $unsignedPath){ throw "SIGNATURE_NOT_VALID_WRONG_TARGET" }
  if([string]$notValid.severity -ne "critical"){ throw "SIGNATURE_NOT_VALID_SEVERITY_WRONG" }
  if([string]$notValid.signature_status -eq "Valid"){ throw "SIGNATURE_NOT_VALID_STATUS_WRONG" }

  $untrusted = $byReason["FILE_SIGNER_UNTRUSTED"]
  if([string]$untrusted.target_path -ne $signedMismatchPath){ throw "SIGNER_UNTRUSTED_WRONG_TARGET" }
  if([string]$untrusted.severity -ne "critical"){ throw "SIGNER_UNTRUSTED_SEVERITY_WRONG" }
  if([string]$untrusted.signature_status -ne "Valid"){ throw "SIGNER_UNTRUSTED_EXPECTED_VALID_SIGNATURE" }
  if([string]$untrusted.signer_subject -ne $sourceSigner){ throw "SIGNER_UNTRUSTED_SIGNER_SUBJECT_WRONG" }

  # Positive path: a genuinely signed+valid file with require_signed=true
  # must stay verified, not compromised (asserted via classified_counts
  # above: signedValidPath is the only contributor to `verified`).

  # Mutation check: scan must not alter any target, including the copied
  # signed binaries.
  $after = @{}
  Get-ChildItem -LiteralPath $fixture -Recurse -File | ForEach-Object { $after[$_.FullName] = (Sha256HexFile $_.FullName) }
  if($before.Count -ne $after.Count){ throw "SCAN_MUTATED_TARGET_SET" }
  foreach($k in $before.Keys){
    if(-not $after.ContainsKey($k) -or ($before[$k] -ne $after[$k])){ throw ("SCAN_MUTATED_TARGET: " + $k) }
  }

  Write-Host "SCANNER_SIGNATURE_TEST_OK" -ForegroundColor Green
  Write-Output "CLARITY_TIER1_SCANNER_SIGNER_OK"
}
finally {
  foreach($d in $createdScanDirs){ if(Test-Path -LiteralPath $d -PathType Container){ Remove-Item -LiteralPath $d -Recurse -Force } }
  if(Test-Path -LiteralPath $root -PathType Container){ Remove-Item -LiteralPath $root -Recurse -Force }
}
