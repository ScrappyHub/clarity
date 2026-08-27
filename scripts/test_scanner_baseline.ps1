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

$root = Join-Path ([IO.Path]::GetTempPath()) ("clarity-scanner-test-" + [Guid]::NewGuid().ToString("N"))
$fixture = Join-Path $root "fixture"
$createdScanDirs = New-Object System.Collections.Generic.List[string]
try {
  New-Item -ItemType Directory -Force -Path $fixture | Out-Null

  $verifiedPath = Join-Path $fixture "verified.dat"
  $changedPath  = Join-Path $fixture "changed.dat"
  $unknownPath  = Join-Path $fixture "readme.txt"
  $doublePath   = Join-Path $fixture "invoice.pdf.exe"
  WriteUtf8NoBomLf $verifiedPath "verified-content`n"
  WriteUtf8NoBomLf $changedPath  "actual-content`n"
  WriteUtf8NoBomLf $unknownPath  "hello`n"
  WriteUtf8NoBomLf $doublePath   "x`n"

  # Test-local rules: empty startup/temp lists so the OS temp path can't
  # perturb classification; only the double-extension rule is active.
  $rulesPath = Join-Path $root "rules.json"
  $rulesObj = [ordered]@{
    version = "scanner_baseline_test"
    suspicion = [ordered]@{
      startup_bad_extensions = @()
      temp_exec_extensions = @()
      double_extension_regex = "\.(pdf|doc)\.(exe|scr|bat|cmd)$"
    }
    scan = [ordered]@{ skip_dir_names = @() }
  }
  WriteUtf8NoBomLf $rulesPath (($rulesObj | ConvertTo-Json -Depth 6))

  $verifiedHash = Sha256HexFile $verifiedPath
  $ghostPath = Join-Path $fixture "ghost\missing.sys"
  $baselinePath = Join-Path $root "baseline.json"
  $baselineObj = [ordered]@{
    schema = "clarity.baseline.v1"
    baseline_id = "scanner-test-baseline"
    version = "1.0.0"
    entries = @(
      [ordered]@{ path = $verifiedPath; sha256 = $verifiedHash; required = $false },
      [ordered]@{ path = $changedPath;  sha256 = ("a" * 64);     required = $false },
      [ordered]@{ path = $ghostPath;    sha256 = ("b" * 64);     required = $true }
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
  if([int]$scan.classified_counts.compromised -ne 1){ throw "EXPECTED_ONE_COMPROMISED" }
  if([int]$scan.classified_counts.suspicious -ne 1){ throw "EXPECTED_ONE_SUSPICIOUS" }
  if([int]$scan.classified_counts.unknown -ne 1){ throw "EXPECTED_ONE_UNKNOWN" }
  if([int]$scan.suspicious_count -ne 2){ throw "EXPECTED_TWO_ISOLATABLE_FINDINGS" }
  if([int]$scan.missing_critical_count -ne 1){ throw "EXPECTED_ONE_MISSING_CRITICAL" }
  if(-not (@($scan.missing_critical)[0].ToLowerInvariant().EndsWith("missing.sys"))){ throw "MISSING_CRITICAL_PATH_WRONG" }
  if([string]$scan.rules_version -ne "scanner_baseline_test"){ throw "RULES_VERSION_NOT_RECORDED" }
  if([string]::IsNullOrEmpty([string]$scan.baseline_hash)){ throw "BASELINE_HASH_NOT_RECORDED" }

  $findingLines = @(Get-Content -LiteralPath ([string]$scan.findings_path) -Encoding UTF8 | Where-Object { $_ -and $_.Trim() -ne "" })
  if($findingLines.Count -ne 2){ throw "EXPECTED_TWO_FINDING_LINES" }
  $reasons = @($findingLines | ForEach-Object { ($_ | ConvertFrom-Json).reason_code })
  if($reasons -notcontains "FILE_HASH_MISMATCH"){ throw "MISSING_HASH_MISMATCH_FINDING" }
  if($reasons -notcontains "DOUBLE_EXTENSION"){ throw "MISSING_DOUBLE_EXTENSION_FINDING" }
  foreach($fl in $findingLines){
    $f = $fl | ConvertFrom-Json
    if([string]$f.reason_code -eq "FILE_HASH_MISMATCH" -and [string]$f.severity -ne "critical"){ throw "COMPROMISED_NOT_CRITICAL" }
    if([string]$f.reason_code -eq "DOUBLE_EXTENSION" -and [string]$f.severity -ne "suspicious"){ throw "SUSPICIOUS_SEVERITY_WRONG" }
  }

  # Mutation check: scan must not alter any target.
  $after = @{}
  Get-ChildItem -LiteralPath $fixture -Recurse -File | ForEach-Object { $after[$_.FullName] = (Sha256HexFile $_.FullName) }
  if($before.Count -ne $after.Count){ throw "SCAN_MUTATED_TARGET_SET" }
  foreach($k in $before.Keys){
    if(-not $after.ContainsKey($k) -or ($before[$k] -ne $after[$k])){ throw ("SCAN_MUTATED_TARGET: " + $k) }
  }

  Write-Host "SCANNER_BASELINE_TEST_OK" -ForegroundColor Green
}
finally {
  foreach($d in $createdScanDirs){ if(Test-Path -LiteralPath $d -PathType Container){ Remove-Item -LiteralPath $d -Recurse -Force } }
  if(Test-Path -LiteralPath $root -PathType Container){ Remove-Item -LiteralPath $root -Recurse -Force }
}
