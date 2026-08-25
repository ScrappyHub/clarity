param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-OutputPath([object[]]$Output,[string]$Pattern){
  $matches = @($Output | ForEach-Object {
    $line = $_.ToString().Trim()
    $candidate = $line
    $separator = $line.IndexOf("=")
    if($separator -gt 0){ $candidate = $line.Substring($separator + 1).Trim() }
    if($candidate -like $Pattern -and (Test-Path -LiteralPath $candidate -PathType Leaf)){ $candidate }
  })
  if($matches.Count -eq 0){ throw ("MISSING_TEST_OUTPUT: " + $Pattern) }
  return $matches[$matches.Count - 1]
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("clarity-host-slice-" + [Guid]::NewGuid().ToString("N"))
$cleanRoot = Join-Path $testRoot "clean"
$fixtureRoot = Join-Path $testRoot "fixture"
$cleanRuntimeRoot = Join-Path $testRoot "clean-runtime"
$runtimeRoot = Join-Path $testRoot "runtime"
$cleanFixturePath = Join-Path $cleanRoot "readme.txt"
$fixturePath = Join-Path $fixtureRoot "suspicious.exe"
$createdReports = New-Object System.Collections.Generic.List[string]

try {
  New-Item -ItemType Directory -Force -Path $cleanRoot,$fixtureRoot,$cleanRuntimeRoot,$runtimeRoot | Out-Null
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($cleanFixturePath,"clean fixture`n",$utf8NoBom)
  $fixtureStream = [IO.File]::Create($fixturePath)
  $fixtureStream.Dispose()

  $runner = Join-Path $RepoRoot "scripts\validator_run.ps1"
  $cleanOutput = @(& $runner `
    -RepoRoot $RepoRoot `
    -RuntimeRoot $cleanRuntimeRoot `
    -Tenant "test" `
    -Principal "test" `
    -ProducerInstance "clean-host-slice-test" `
    -TargetRoots @($cleanRoot) `
    -MaxFiles 10)
  $cleanRunPath = Get-OutputPath $cleanOutput "*.run.json"
  $cleanRun = Get-Content -Raw -LiteralPath $cleanRunPath | ConvertFrom-Json
  $createdReports.Add($cleanRunPath)
  $createdReports.Add([string]$cleanRun.phases.preflight.path)
  $cleanScanPath = [string]$cleanRun.phases.scan.path
  $cleanScan = Get-Content -Raw -LiteralPath $cleanScanPath | ConvertFrom-Json
  $createdReports.Add($cleanScanPath)
  $createdReports.Add([string]$cleanScan.findings_path)
  $createdReports.Add([string]$cleanRun.phases.isolation.path)
  $createdReports.Add([string]$cleanRun.phases.handoff.path)
  if([int]$cleanScan.suspicious_count -ne 0){ throw "CLEAN_PATH_FOUND_SUSPICIOUS_CONTENT" }
  if([int]$cleanRun.phases.isolation.isolated_count -ne 0){ throw "CLEAN_PATH_ISOLATED_CONTENT" }
  if([string]$cleanRun.phases.handoff.decision -ne "deny"){ throw "CLEAN_PATH_MUST_FAIL_CLOSED_WITHOUT_ATTESTATION" }

  $output = @(& $runner `
    -RepoRoot $RepoRoot `
    -RuntimeRoot $runtimeRoot `
    -Tenant "test" `
    -Principal "test" `
    -ProducerInstance "host-slice-test" `
    -TargetRoots @($fixtureRoot) `
    -MaxFiles 10)

  $runPath = Get-OutputPath $output "*.run.json"
  $run = Get-Content -Raw -LiteralPath $runPath | ConvertFrom-Json
  $createdReports.Add($runPath)
  $createdReports.Add([string]$run.phases.preflight.path)

  $scanPath = [string]$run.phases.scan.path
  $scan = Get-Content -Raw -LiteralPath $scanPath | ConvertFrom-Json
  $createdReports.Add($scanPath)
  $createdReports.Add([string]$scan.findings_path)

  $isolationPath = [string]$run.phases.isolation.path
  $isolation = Get-Content -Raw -LiteralPath $isolationPath | ConvertFrom-Json
  $createdReports.Add($isolationPath)
  $handoffPath = [string]$run.phases.handoff.path
  $createdReports.Add($handoffPath)

  & (Join-Path $RepoRoot "scripts\validator_verify_run.ps1") -RunPath $runPath | Out-Null

  $originalHandoff = Get-Content -Raw -LiteralPath $handoffPath -Encoding UTF8
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::AppendAllText($handoffPath,"`n",$utf8NoBom)
  $tamperDetected = $false
  try {
    & (Join-Path $RepoRoot "scripts\validator_verify_run.ps1") -RunPath $runPath | Out-Null
  } catch {
    if($_.Exception.Message -like "*ARTIFACT_HASH_MISMATCH*"){ $tamperDetected = $true } else { throw }
  } finally {
    [IO.File]::WriteAllText($handoffPath,$originalHandoff,$utf8NoBom)
  }
  if(-not $tamperDetected){ throw "TAMPER_NOT_DETECTED" }

  if([int]$scan.suspicious_count -ne 1){ throw "EXPECTED_ONE_SUSPICIOUS_FINDING" }
  if([int]$isolation.isolated_count -ne 1){ throw "EXPECTED_ONE_ISOLATED_OBJECT" }
  if([string]$run.phases.handoff.decision -ne "deny"){ throw "EXPECTED_FAIL_CLOSED_HANDOFF" }

  $ledgerLines = @(Get-Content -LiteralPath ([string]$isolation.ledger_path) | Where-Object { $_ -and $_.Trim() -ne "" })
  if($ledgerLines.Count -ne 1){ throw "EXPECTED_ONE_LEDGER_ENTRY" }
  $ledger = $ledgerLines[0] | ConvertFrom-Json
  $sourceHash = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if([string]$ledger.object_sha256 -ne $sourceHash){ throw "ISOLATED_HASH_MISMATCH" }

  Write-Host "HOST_SLICE_TEST_OK" -ForegroundColor Green
  Write-Output $runPath
}
finally {
  foreach($p in $createdReports){
    if(Test-Path -LiteralPath $p -PathType Leaf){ Remove-Item -LiteralPath $p -Force }
  }
  if(Test-Path -LiteralPath $testRoot -PathType Container){ Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
