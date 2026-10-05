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
function Read-Json([string]$p){ Get-Content -Raw -LiteralPath $p -Encoding UTF8 | ConvertFrom-Json }
function Snapshot([string]$dir){
  $h = @{}
  Get-ChildItem -LiteralPath $dir -Recurse -File | ForEach-Object { $h[$_.FullName] = (Sha256HexFile $_.FullName) }
  return $h
}
function Assert-SameSnapshot($a,$b,[string]$what){
  if($a.Count -ne $b.Count){ throw ("MUTATED_FILE_SET: " + $what) }
  foreach($k in $a.Keys){ if(-not $b.ContainsKey($k) -or $a[$k] -ne $b[$k]){ throw ("MUTATED_TARGET: " + $what + " " + $k) } }
}

$Principal   = "clarity-delta-test"
$root        = Join-Path ([IO.Path]::GetTempPath()) ("clarity-delta-test-" + [Guid]::NewGuid().ToString("N"))
$runtimeRoot = Join-Path $root "runtime"
$fixture     = Join-Path $root "fixture"
$winlike     = Join-Path $fixture "winlike"
$userDir     = Join-Path $fixture "user"
$keysDir     = Join-Path $runtimeRoot "keys"
$keyBase     = Join-Path $keysDir "clarity_dev_ed25519"
$cleanup     = New-Object System.Collections.Generic.List[string]

function Invoke-Run([string]$prevInventory){
  $a = @{
    RepoRoot = $RepoRoot; RuntimeRoot = $runtimeRoot; Tenant = "test"; Principal = $Principal; ProducerInstance = "delta-test"
    TargetRoots = @($fixture); MaxFiles = 50; AllowDegraded = $true; RulesPath = $script:rulesPath; EmitInventory = $true
  }
  if($prevInventory){ $a["PreviousInventoryPath"] = $prevInventory }
  $out = @(& (Join-Path $RepoRoot "scripts\validator_run.ps1") @a)
  $runPath = Get-OutPath $out "*.run.json"
  $run = Read-Json $runPath
  $cleanup.Add($runPath)
  $cleanup.Add([string]$run.phases.preflight.path)
  $cleanup.Add((Split-Path -Parent ([string]$run.phases.scan.path)))
  $cleanup.Add([string]$run.phases.isolation.path)
  $cleanup.Add([string]$run.phases.handoff.path)
  return [pscustomobject]@{ RunPath = $runPath; Run = $run; Scan = (Read-Json ([string]$run.phases.scan.path)); Isolation = (Read-Json ([string]$run.phases.isolation.path)); Handoff = (Read-Json ([string]$run.phases.handoff.path)) }
}

try {
  New-Item -ItemType Directory -Force -Path $runtimeRoot,$winlike,$userDir,$keysDir,(Join-Path $runtimeRoot "outbox") | Out-Null

  # Test-local rules: only the double-extension heuristic is active, and the
  # fake "winlike" directory stands in for Windows / boot-critical paths.
  $script:rulesPath = Join-Path $root "rules.json"
  WriteUtf8NoBomLf $script:rulesPath (([ordered]@{
    version = "delta_test"
    suspicion = [ordered]@{ startup_bad_extensions = @(); temp_exec_extensions = @(); double_extension_regex = "\.(pdf|doc)\.(exe|scr|bat|cmd)$" }
    scan = [ordered]@{ skip_dir_names = @(); critical_prefixes = @($winlike) }
    quarantine = [ordered]@{ max_hash_mb = 25 }
  } | ConvertTo-Json -Depth 6))

  $g = Start-Process -FilePath "ssh-keygen.exe" -ArgumentList ('-t ed25519 -f "' + $keyBase + '" -N "" -C delta-test -q') -Wait -PassThru -NoNewWindow
  if($g.ExitCode -ne 0){ throw "KEYGEN_FAILED" }
  $pub = (Get-Content -Raw -LiteralPath ($keyBase + ".pub") -Encoding UTF8).Trim(); $parts = $pub -split '\s+'
  WriteUtf8NoBomLf (Join-Path $keysDir "allowed_signers") ($Principal + " " + $parts[0] + " " + $parts[1] + "`n")

  # ---- State S0 ----
  $clean   = Join-Path $userDir "clean.txt"
  $oldBad  = Join-Path $userDir "old_bad.pdf.exe"
  $sysBad  = Join-Path $winlike "sys.pdf.exe"
  $coreDll = Join-Path $winlike "core.dll"
  WriteUtf8NoBomLf $clean "clean-v1`n"
  WriteUtf8NoBomLf $oldBad "old-malicious`n"
  WriteUtf8NoBomLf $sysBad "protected-payload`n"
  WriteUtf8NoBomLf $coreDll "core`n"
  $sysHash = Sha256HexFile $sysBad
  $oldHash = Sha256HexFile $oldBad

  $snap0 = Snapshot $fixture
  $r1 = Invoke-Run ""
  Assert-SameSnapshot $snap0 (Snapshot $fixture) "run1"

  # RUN 1: no previous inventory.
  if([int]$r1.Scan.examined_file_count -ne 4){ throw "R1_EXPECTED_4_EXAMINED" }
  if([bool]$r1.Scan.change_summary.compared){ throw "R1_SHOULD_NOT_BE_COMPARED" }
  if([int]$r1.Scan.suspicious_count -ne 1){ throw "R1_EXPECTED_1_ISOLATABLE" }
  if([int]$r1.Scan.protected_flagged_count -ne 1){ throw "R1_EXPECTED_1_PROTECTED" }
  if([int]$r1.Isolation.isolated_count -ne 1){ throw "R1_EXPECTED_1_ISOLATED" }
  if([int]$r1.Scan.inventory_count -ne 4){ throw "R1_EXPECTED_4_INVENTORY" }
  if(-not (Test-Path -LiteralPath ([string]$r1.Scan.inventory_path) -PathType Leaf)){ throw "R1_INVENTORY_MISSING" }
  $vaultSys = Join-Path $runtimeRoot ("vault\objects\sha256\" + $sysHash.Substring(0,2) + "\" + $sysHash)
  if(Test-Path -LiteralPath $vaultSys){ throw "PROTECTED_FILE_WAS_ISOLATED" }
  $vaultOld = Join-Path $runtimeRoot ("vault\objects\sha256\" + $oldHash.Substring(0,2) + "\" + $oldHash)
  if(-not (Test-Path -LiteralPath $vaultOld)){ throw "R1_MALICIOUS_FILE_NOT_ISOLATED" }
  $prot1 = @($r1.Scan.protected_flagged)[0]
  if(([string]$prot1.path).ToLowerInvariant() -ne $sysBad.ToLowerInvariant()){ throw "R1_PROTECTED_PATH_WRONG" }
  if([string]$r1.Handoff.reason_code -ne "SUSPICIOUS_FINDINGS_PRESENT" -or [bool]$r1.Handoff.allowed){ throw "R1_GATE_SHOULD_DENY_SUSPICIOUS" }

  # ---- State S1: +new malicious, +new clean, clean.txt changed, core.dll removed ----
  $newBad   = Join-Path $userDir "new_bad.doc.scr"
  $newClean = Join-Path $userDir "new_clean.txt"
  WriteUtf8NoBomLf $newBad "new-malicious`n"
  WriteUtf8NoBomLf $newClean "fresh`n"
  WriteUtf8NoBomLf $clean "clean-v2`n"
  Remove-Item -LiteralPath $coreDll -Force
  $newHash = Sha256HexFile $newBad

  $snap1 = Snapshot $fixture
  $r2 = Invoke-Run ([string]$r1.Scan.inventory_path)
  Assert-SameSnapshot $snap1 (Snapshot $fixture) "run2"

  # RUN 2: only NEW/CHANGED flagged content is isolated; known + protected are reported, not copied.
  $cs = $r2.Scan.change_summary
  if(-not [bool]$cs.compared){ throw "R2_SHOULD_BE_COMPARED" }
  if([int]$cs.new -ne 2){ throw ("R2_EXPECTED_2_NEW got " + $cs.new) }
  if([int]$cs.changed -ne 1){ throw ("R2_EXPECTED_1_CHANGED got " + $cs.changed) }
  if([int]$cs.unchanged -ne 2){ throw ("R2_EXPECTED_2_UNCHANGED got " + $cs.unchanged) }
  if([int]$cs.removed -ne 1){ throw ("R2_EXPECTED_1_REMOVED got " + $cs.removed) }
  if([int]$r2.Scan.suspicious_count -ne 1){ throw "R2_EXPECTED_1_ISOLATABLE" }
  if([int]$r2.Scan.known_unchanged_suspicious_count -ne 1){ throw "R2_EXPECTED_1_KNOWN" }
  if([int]$r2.Scan.protected_flagged_count -ne 1){ throw "R2_EXPECTED_1_PROTECTED" }
  if([int]$r2.Isolation.isolated_count -ne 1){ throw "R2_EXPECTED_1_ISOLATED" }
  $f2 = @(Get-Content -LiteralPath ([string]$r2.Scan.findings_path) -Encoding UTF8 | Where-Object { $_ -and $_.Trim() }) | ForEach-Object { $_ | ConvertFrom-Json }
  if(@($f2).Count -ne 1 -or ([string]@($f2)[0].target_path).ToLowerInvariant() -ne $newBad.ToLowerInvariant()){ throw "R2_ONLY_NEW_BAD_SHOULD_BE_ISOLATED" }
  if([string]@($f2)[0].change_state -ne "new"){ throw "R2_FINDING_STATE_NOT_NEW" }
  if(-not (Test-Path -LiteralPath (Join-Path $runtimeRoot ("vault\objects\sha256\" + $newHash.Substring(0,2) + "\" + $newHash)))){ throw "R2_NEW_MALICIOUS_NOT_ISOLATED" }
  if(Test-Path -LiteralPath $vaultSys){ throw "R2_PROTECTED_FILE_WAS_ISOLATED" }
  $dispo = @{}; foreach($c in @($r2.Scan.changes)){ $dispo[([string]$c.path).ToLowerInvariant()] = ([string]$c.state + "|" + [string]$c.disposition) }
  if($dispo[$newBad.ToLowerInvariant()] -ne "new|isolated"){ throw "R2_CHANGES_NEWBAD_WRONG" }
  if($dispo[$oldBad.ToLowerInvariant()] -ne "unchanged|known_unchanged_already_isolated"){ throw "R2_CHANGES_OLDBAD_WRONG" }
  if($dispo[$sysBad.ToLowerInvariant()] -ne "unchanged|protected_not_isolated"){ throw "R2_CHANGES_SYS_WRONG" }
  if($dispo[$coreDll.ToLowerInvariant()] -ne "removed|removed"){ throw "R2_CHANGES_REMOVED_WRONG" }
  if($dispo[$clean.ToLowerInvariant()] -ne "changed|no_finding"){ throw "R2_CHANGES_CLEAN_WRONG" }
  if([string]$r2.Handoff.reason_code -ne "SUSPICIOUS_FINDINGS_PRESENT" -or [bool]$r2.Handoff.allowed){ throw "R2_GATE_SHOULD_DENY" }

  # Seal + protected display: the change view must render from sealed evidence.
  $sealOut = @(& (Join-Path $RepoRoot "scripts\validator_seal.ps1") -RunPath $r2.RunPath -RuntimeRoot $runtimeRoot -RepoRoot $RepoRoot -Principal $Principal -KeyBase $keyBase)
  $sealDir = Get-OutPath $sealOut "*validator_seals*"
  $cleanup.Add($sealDir)
  $view = @(& (Join-Path $RepoRoot "scripts\validator_result_view.ps1") -SealDir $sealDir -RuntimeRoot $runtimeRoot -Principal $Principal)
  $text = ($view | ForEach-Object { $_.ToString() }) -join "`n"
  foreach($pat in @("CHANGES SINCE PREVIOUS SCAN","New:\s+2","Changed:\s+1","Unchanged:\s+2","Removed:\s+1","Protected files flagged[^\n]*:\s+1","Known unchanged files[^\n]*:\s+1","\[new\] isolated","\[removed\] removed","signature verified")){
    if($text -notmatch $pat){ throw ("VIEW_MISSING: " + $pat) }
  }

  # RUN 3: nothing changed. Nothing new to isolate, but the protected finding must still deny handoff.
  $snap2 = Snapshot $fixture
  $r3 = Invoke-Run ([string]$r2.Scan.inventory_path)
  Assert-SameSnapshot $snap2 (Snapshot $fixture) "run3"
  if([int]$r3.Scan.change_summary.new -ne 0 -or [int]$r3.Scan.change_summary.changed -ne 0 -or [int]$r3.Scan.change_summary.removed -ne 0){ throw "R3_EXPECTED_NO_CHANGES" }
  if([int]$r3.Scan.suspicious_count -ne 0){ throw "R3_EXPECTED_0_ISOLATABLE" }
  if([int]$r3.Isolation.isolated_count -ne 0){ throw "R3_EXPECTED_0_ISOLATED" }
  if([int]$r3.Scan.known_unchanged_suspicious_count -ne 2){ throw "R3_EXPECTED_2_KNOWN" }
  if([int]$r3.Scan.protected_flagged_count -ne 1){ throw "R3_EXPECTED_1_PROTECTED" }
  if([bool]$r3.Handoff.allowed -or [string]$r3.Handoff.reason_code -ne "PROTECTED_FILE_FLAGGED"){ throw ("R3_GATE_EXPECTED_PROTECTED_FILE_FLAGGED got " + $r3.Handoff.reason_code) }

  Write-Host "SCAN_DELTA_ISOLATION_TEST_OK" -ForegroundColor Green
  Write-Output "CLARITY_TIER2_DELTA_ISOLATION_OK"
}
finally {
  foreach($d in $cleanup){ if($d -and (Test-Path -LiteralPath $d)){ Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }
  if(Test-Path -LiteralPath $root -PathType Container){ Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
