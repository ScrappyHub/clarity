param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $RepoRoot "scripts\lib\canon.ps1")

function Get-OutPath([object[]]$Output,[string]$Pattern){
  $m = @($Output | ForEach-Object {
    $line = $_.ToString().Trim()
    $v = $line
    $i = $line.IndexOf("=")
    if($i -gt 0){ $v = $line.Substring($i + 1).Trim() }
    if($v -like $Pattern -and (Test-Path -LiteralPath $v -PathType Leaf)){ $v }
  })
  if($m.Count -eq 0){ throw ("OUTPUT_NOT_FOUND: " + $Pattern) }
  return $m[$m.Count - 1]
}

$root        = Join-Path ([IO.Path]::GetTempPath()) ("clarity-restore-test-" + [Guid]::NewGuid().ToString("N"))
$fixture     = Join-Path $root "fixture"
$runtimeRoot = Join-Path $root "runtime"
$restoreDir  = Join-Path $root "restored"
$criticalDir = Join-Path $root "critical"
$repoReports = New-Object System.Collections.Generic.List[string]

try {
  New-Item -ItemType Directory -Force -Path $fixture,$runtimeRoot,$restoreDir,$criticalDir | Out-Null
  # Double-extension name so detection is location-independent (the OS temp
  # path is not guaranteed to contain a "\temp\" segment on every machine).
  $payloadPath = Join-Path $fixture "payload.pdf.exe"
  WriteUtf8NoBomLf $payloadPath "malicious-bytes`n"

  # One rules file serves both scan detection (double-extension only) and the
  # restore policy (allowed restore root + a critical prefix, both under temp).
  $rulesPath = Join-Path $root "rules.json"
  $rulesObj = [ordered]@{
    suspicion = [ordered]@{
      startup_bad_extensions = @()
      temp_exec_extensions = @()
      double_extension_regex = "\.(pdf|doc)\.(exe|scr|bat|cmd)$"
    }
    scan = [ordered]@{ skip_dir_names = @(); critical_prefixes = @($criticalDir) }
    quarantine = [ordered]@{ allowed_block_roots = @($restoreDir) }
  }
  WriteUtf8NoBomLf $rulesPath (($rulesObj | ConvertTo-Json -Depth 6))

  # 1. Produce a real vault object: scan the fixture, then isolate.
  $scanOut = @(& (Join-Path $RepoRoot "scripts\validator_scan_targeted.ps1") -RepoRoot $RepoRoot -TargetRoots @($fixture) -MaxFiles 50 -RulesPath $rulesPath)
  $scanPath = Get-OutPath $scanOut "*.scan.json"
  $repoReports.Add((Split-Path -Parent $scanPath))
  $scan = Get-Content -Raw -LiteralPath $scanPath -Encoding UTF8 | ConvertFrom-Json
  if([int]$scan.suspicious_count -lt 1){ throw "FIXTURE_NOT_FLAGGED_SUSPICIOUS" }

  $isoOut = @(& (Join-Path $RepoRoot "scripts\validator_isolate_copy.ps1") -RuntimeRoot $runtimeRoot -RepoRoot $RepoRoot -ScanReportPath $scanPath -Tenant "test" -Principal "test" -ProducerInstance "restore-test")
  $isoPath = Get-OutPath $isoOut "*.isolation.json"
  $repoReports.Add($isoPath)
  $iso = Get-Content -Raw -LiteralPath $isoPath -Encoding UTF8 | ConvertFrom-Json
  if([int]$iso.isolated_count -lt 1){ throw "NOTHING_ISOLATED" }

  $vaultLedger = Join-Path $runtimeRoot "vault\ledger\vault.ndjson"
  $vaultLines = @(Get-Content -LiteralPath $vaultLedger -Encoding UTF8 | Where-Object { $_ -and $_.Trim() -ne "" })
  $sha = [string](($vaultLines[$vaultLines.Count - 1]) | ConvertFrom-Json).object_sha256
  $restoreScript = Join-Path $RepoRoot "scripts\isolation_restore.ps1"

  # 2. Unauthorized restore is denied before anything is touched.
  $denied = $false
  try {
    & $restoreScript -RuntimeRoot $runtimeRoot -RepoRoot $RepoRoot -ObjectSha256 $sha -DestinationPath (Join-Path $restoreDir "r1.bin") -Tenant t -Principal t -ProducerInstance rt -RulesPath $rulesPath | Out-Null
  } catch { if($_.Exception.Message -like "*UNAUTHORIZED_RESTORE*"){ $denied = $true } else { throw } }
  if(-not $denied){ throw "UNAUTHORIZED_RESTORE_NOT_DENIED" }

  # 3. A corrupted vault object is rejected on identity verification.
  $objDir = Join-Path (Join-Path (Join-Path $runtimeRoot "vault\objects\sha256") $sha.Substring(0,2)) $sha
  $contentPath = Join-Path $objDir "content.bin"
  $origBytes = [IO.File]::ReadAllBytes($contentPath)
  [IO.File]::AppendAllText($contentPath,"x",(New-Object System.Text.UTF8Encoding($false)))
  $corruptDetected = $false
  try {
    & $restoreScript -RuntimeRoot $runtimeRoot -RepoRoot $RepoRoot -ObjectSha256 $sha -DestinationPath (Join-Path $restoreDir "r1.bin") -Tenant t -Principal t -ProducerInstance rt -RulesPath $rulesPath -Authorize | Out-Null
  } catch { if($_.Exception.Message -like "*ISOLATION_OBJECT_CORRUPT*"){ $corruptDetected = $true } else { throw } }
  [IO.File]::WriteAllBytes($contentPath,$origBytes)
  if(-not $corruptDetected){ throw "CORRUPT_OBJECT_NOT_DETECTED" }

  # 4. Restore over a boot-critical prefix is denied without an explicit override.
  $critDenied = $false
  try {
    & $restoreScript -RuntimeRoot $runtimeRoot -RepoRoot $RepoRoot -ObjectSha256 $sha -DestinationPath (Join-Path $criticalDir "sys.bin") -Tenant t -Principal t -ProducerInstance rt -RulesPath $rulesPath -Authorize | Out-Null
  } catch { if($_.Exception.Message -like "*RESTORE_TO_CRITICAL_DENIED*"){ $critDenied = $true } else { throw } }
  if(-not $critDenied){ throw "CRITICAL_RESTORE_NOT_DENIED" }

  # 5. Authorized restore into an allowed root succeeds, hash-verified, evidence preserved.
  $destPath = Join-Path $restoreDir "recovered.bin"
  $rout = @(& $restoreScript -RuntimeRoot $runtimeRoot -RepoRoot $RepoRoot -ObjectSha256 $sha -DestinationPath $destPath -Tenant test -Principal test -ProducerInstance restore-test -RulesPath $rulesPath -Authorize)
  $restoreReport = Get-OutPath $rout "*.restore.json"
  $repoReports.Add($restoreReport)
  if(-not (Test-Path -LiteralPath $destPath -PathType Leaf)){ throw "RESTORED_FILE_MISSING" }
  if((Sha256HexFile $destPath) -ne $sha){ throw "RESTORED_HASH_MISMATCH" }
  if(-not (Test-Path -LiteralPath $contentPath -PathType Leaf)){ throw "VAULT_EVIDENCE_DESTROYED" }

  $restoreLedger = Join-Path $runtimeRoot "vault\ledger\restore.ndjson"
  $rlines = @(Get-Content -LiteralPath $restoreLedger -Encoding UTF8 | Where-Object { $_ -and $_.Trim() -ne "" })
  if($rlines.Count -ne 1){ throw "EXPECTED_ONE_RESTORE_LEDGER_ENTRY" }
  $rl = $rlines[0] | ConvertFrom-Json
  if([string]$rl.object_sha256 -ne $sha){ throw "RESTORE_LEDGER_SHA_MISMATCH" }
  if([string]$rl.decision -ne "restored"){ throw "RESTORE_LEDGER_DECISION_WRONG" }

  Write-Host "CLARITY_TIER1_STEP7_OK" -ForegroundColor Green
}
finally {
  foreach($p in $repoReports){
    if(Test-Path -LiteralPath $p -PathType Container){ Remove-Item -LiteralPath $p -Recurse -Force }
    elseif(Test-Path -LiteralPath $p -PathType Leaf){ Remove-Item -LiteralPath $p -Force }
  }
  if(Test-Path -LiteralPath $root -PathType Container){ Remove-Item -LiteralPath $root -Recurse -Force }
}
