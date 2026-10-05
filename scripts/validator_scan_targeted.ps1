param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$false)][string[]]$TargetRoots,
  [Parameter(Mandatory=$false)][int]$MaxFiles = 5000,
  [Parameter(Mandatory=$false)][string]$RulesPath = "",
  [Parameter(Mandatory=$false)][string]$BaselinePath = "",
  [Parameter(Mandatory=$false)][switch]$EmitInventory,
  [Parameter(Mandatory=$false)][string]$PreviousInventoryPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
. "$PSScriptRoot\lib\canon.ps1"

function HasProp($obj,[string]$name){
  if($null -eq $obj){ return $false }
  return [bool]($obj.PSObject.Properties.Name -contains $name)
}

$runId = [Guid]::NewGuid().ToString("N")
$reportDir = Join-Path $RepoRoot ("reports\validator_scan\" + $runId)
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

$scanFile = Join-Path $reportDir ($runId + ".scan.json")
$findingsFile = Join-Path $reportDir ($runId + ".findings.ndjson")

# ---- Rules (clarity_rules.json) ----
if([string]::IsNullOrWhiteSpace($RulesPath)){ $RulesPath = Join-Path $RepoRoot "clarity_rules.json" }
$rulesVersion = "none"
$rulesHash = ""
$startupBad = @()
$tempExec = @()
$doubleExtRegex = ""
$skipDirs = @()
$criticalPrefixes = @()
$maxHashBytes = [int64](25 * 1024 * 1024)
if(Test-Path -LiteralPath $RulesPath -PathType Leaf){
  $rulesRaw = (ReadUtf8Text $RulesPath).TrimStart([char]0xFEFF)
  $rules = $rulesRaw | ConvertFrom-Json
  $rulesHash = Sha256HexTextNormalized $rulesRaw
  if(HasProp $rules "version"){ $rulesVersion = [string]$rules.version }
  if(HasProp $rules "suspicion"){
    $s = $rules.suspicion
    if(HasProp $s "startup_bad_extensions"){ $startupBad = @($s.startup_bad_extensions | ForEach-Object { ([string]$_).ToLowerInvariant() }) }
    if(HasProp $s "temp_exec_extensions"){ $tempExec = @($s.temp_exec_extensions | ForEach-Object { ([string]$_).ToLowerInvariant() }) }
    if(HasProp $s "double_extension_regex"){ $doubleExtRegex = [string]$s.double_extension_regex }
  }
  if(HasProp $rules "scan"){
    if(HasProp $rules.scan "skip_dir_names"){ $skipDirs = @($rules.scan.skip_dir_names | ForEach-Object { ([string]$_).ToLowerInvariant() }) }
    if(HasProp $rules.scan "critical_prefixes"){
      $criticalPrefixes = @($rules.scan.critical_prefixes | ForEach-Object {
        ([IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$_))).TrimEnd('\').ToLowerInvariant() + '\'
      })
    }
  }
  if(HasProp $rules "quarantine"){
    if(HasProp $rules.quarantine "max_hash_mb"){ $maxHashBytes = [int64]([int64]$rules.quarantine.max_hash_mb * 1024 * 1024) }
  }
}

# ---- Baseline (clarity.baseline.v1, optional) ----
$baselineHash = ""
$baselineByPath = @{}
$baselineEntries = @()
if($BaselinePath){
  if(-not (Test-Path -LiteralPath $BaselinePath -PathType Leaf)){ throw ("MISSING_BASELINE: " + $BaselinePath) }
  $baselineRaw = (ReadUtf8Text $BaselinePath).TrimStart([char]0xFEFF)
  $baseline = $baselineRaw | ConvertFrom-Json
  if([string]$baseline.schema -ne "clarity.baseline.v1"){ throw "UNSUPPORTED_BASELINE_SCHEMA" }
  $baselineHash = Sha256HexTextNormalized $baselineRaw
  if(HasProp $baseline "entries"){ $baselineEntries = @($baseline.entries) }
  foreach($e in $baselineEntries){
    $ep = ([IO.Path]::GetFullPath([string]$e.path)).ToLowerInvariant()
    $baselineByPath[$ep] = $e
  }
}

# ---- Previous inventory (optional): enables new/changed/unchanged/removed tracking ----
$prevByPath = @{}
$prevInventoryHash = $null
$haveBaselineInventory = $false
if($PreviousInventoryPath){
  if(-not (Test-Path -LiteralPath $PreviousInventoryPath -PathType Leaf)){ throw ("MISSING_PREVIOUS_INVENTORY: " + $PreviousInventoryPath) }
  $prevRaw = (ReadUtf8Text $PreviousInventoryPath).TrimStart([char]0xFEFF)
  $prevInventoryHash = Sha256HexTextNormalized $prevRaw
  foreach($ln in ($prevRaw -split "`n")){
    $lt = $ln.Trim()
    if(-not $lt){ continue }
    $po = $lt | ConvertFrom-Json
    $prevByPath[([string]$po.path).ToLowerInvariant()] = $po
  }
  $haveBaselineInventory = $true
}
$trackInventory = ($EmitInventory.IsPresent -or $haveBaselineInventory)

if(-not $TargetRoots -or $TargetRoots.Count -eq 0){
  $TargetRoots = @(
    "$env:SystemRoot\System32",
    "$env:SystemRoot\SysWOW64",
    "$env:ProgramFiles",
    "$env:ProgramFiles(x86)"
  )
}
$scannedFull = @($TargetRoots | ForEach-Object { ([IO.Path]::GetFullPath([string]$_)).TrimEnd('\') + '\' })

$findings = New-Object System.Collections.Generic.List[object]  # isolatable: suspicious|critical
$verifiedCount = 0
$unknownCount = 0
$suspiciousCount = 0
$compromisedCount = 0
$examinedFiles = 0
$signatureChecks = 0
$scanErrors = @()
$seenBaselinePaths = New-Object System.Collections.Generic.HashSet[string]
$fileMeta = @{}
$inventoryEntries = New-Object System.Collections.Generic.List[object]

function Get-SuspicionReason([System.IO.FileInfo]$fi){
  $ext = $fi.Extension.ToLowerInvariant()
  $name = $fi.Name.ToLowerInvariant()
  $pathLower = $fi.FullName.ToLowerInvariant()
  if(($pathLower -like "*\startup\*") -and ($startupBad -contains $ext)){ return "SUSPICIOUS_STARTUP_EXTENSION" }
  if(($pathLower -like "*\temp\*") -and ($tempExec -contains $ext)){ return "SUSPICIOUS_TEMP_EXECUTABLE" }
  if($doubleExtRegex -and ($name -match $doubleExtRegex)){ return "DOUBLE_EXTENSION" }
  if(($ext -in ".exe",".dll",".sys") -and ($fi.Length -eq 0)){ return "ZERO_LENGTH_EXECUTABLE" }
  return $null
}

# Per-file signer/signature validation (host-observed Authenticode; same
# pattern as validator_handoff_target.ps1). Only invoked for baseline
# entries that opt in via require_signed / signer, so a byte-identical
# file can still be rejected when its signature is invalid or untrusted
# (e.g. a revoked certificate), even though the hash matches the baseline.
function Get-FileSignatureInfo([string]$Path){
  $status = "unknown"
  $signer = $null
  try {
    $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    $status = [string]$sig.Status
    if($null -ne $sig.SignerCertificate){ $signer = [string]$sig.SignerCertificate.Subject }
  } catch { $status = "unavailable" }
  return [pscustomobject]@{ Status = $status; Signer = $signer }
}

foreach($t in $TargetRoots){
  if($examinedFiles -ge $MaxFiles){ break }
  if(Test-Path -LiteralPath $t -PathType Container){
    Get-ChildItem -LiteralPath $t -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable +scanErrors | ForEach-Object {
      if($examinedFiles -ge $MaxFiles){ return }
      $fi = $_

      $skip = $false
      foreach($seg in ($fi.DirectoryName -split '[\\/]')){
        if($seg -and ($skipDirs -contains $seg.ToLowerInvariant())){ $skip = $true; break }
      }
      if($skip){ return }

      $examinedFiles++
      $full = $fi.FullName
      $key = $full.ToLowerInvariant()

      if($trackInventory){
        $curSha = $null
        if($fi.Length -le $maxHashBytes){ try { $curSha = Sha256HexFile $full } catch { $curSha = $null } }
        $mtime = $fi.LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
        $changeState = "no_baseline"
        $prevFlag = ""
        if($haveBaselineInventory){
          if($prevByPath.ContainsKey($key)){
            $prevEntry = $prevByPath[$key]
            $prevSha = [string]$prevEntry.sha256
            $prevFlag = [string]$prevEntry.flag
            $same = $false
            if($curSha -and $prevSha){ $same = ($curSha -eq $prevSha) }
            else { $same = (([int64]$prevEntry.size -eq [int64]$fi.Length) -and ([string]$prevEntry.mtime_utc -eq $mtime)) }
            $changeState = if($same){ "unchanged" } else { "changed" }
          } else { $changeState = "new" }
        }
        $fileMeta[$key] = [pscustomobject]@{ Path = $full; State = $changeState; PrevFlag = $prevFlag }
        $inventoryEntries.Add([pscustomobject]@{ key = $key; path = $full; size = [int64]$fi.Length; mtime_utc = $mtime; sha256 = $curSha })
      }

      if($baselineByPath.ContainsKey($key)){
        [void]$seenBaselinePaths.Add($key)
        $e = $baselineByPath[$key]
        $h = Sha256HexFile $full
        $expected = ([string]$e.sha256).ToLowerInvariant()
        if($h -ne $expected){
          $compromisedCount++
          $findings.Add([ordered]@{
            schema = "clarity.validator_finding.v1"
            target_path = $full
            reason_code = "FILE_HASH_MISMATCH"
            severity = "critical"
            classification = "compromised"
            sha256 = $h
            baseline_sha256 = $expected
          })
          return
        }

        $requireSigned = (HasProp $e "require_signed") -and [bool]$e.require_signed
        $expectedSigner = if(HasProp $e "signer"){ [string]$e.signer } else { "" }
        if($requireSigned -or $expectedSigner){
          $signatureChecks++
          $sigInfo = Get-FileSignatureInfo $full
          if($requireSigned -and ($sigInfo.Status -ne "Valid")){
            $compromisedCount++
            $findings.Add([ordered]@{
              schema = "clarity.validator_finding.v1"
              target_path = $full
              reason_code = "FILE_SIGNATURE_NOT_VALID"
              severity = "critical"
              classification = "compromised"
              sha256 = $h
              signature_status = $sigInfo.Status
              signer_subject = $sigInfo.Signer
            })
            return
          }
          if($expectedSigner -and $sigInfo.Signer -and ($expectedSigner -ne $sigInfo.Signer)){
            $compromisedCount++
            $findings.Add([ordered]@{
              schema = "clarity.validator_finding.v1"
              target_path = $full
              reason_code = "FILE_SIGNER_UNTRUSTED"
              severity = "critical"
              classification = "compromised"
              sha256 = $h
              signature_status = $sigInfo.Status
              signer_subject = $sigInfo.Signer
              expected_signer = $expectedSigner
            })
            return
          }
        }

        $verifiedCount++
        return
      }

      $reason = Get-SuspicionReason $fi
      if($reason){
        $h = Sha256HexFile $full
        $suspiciousCount++
        $findings.Add([ordered]@{
          schema = "clarity.validator_finding.v1"
          target_path = $full
          reason_code = $reason
          severity = "suspicious"
          classification = "suspicious"
          sha256 = $h
        })
      } else {
        $unknownCount++
      }
    }
  }
}

# ---- Missing required baseline files (not isolatable; recorded only) ----
$missingCritical = New-Object System.Collections.Generic.List[string]
foreach($e in $baselineEntries){
  $required = $false
  if(HasProp $e "required"){ $required = [bool]$e.required }
  if(-not $required){ continue }
  $ep = ([IO.Path]::GetFullPath([string]$e.path))
  if(-not (Test-Path -LiteralPath $ep -PathType Leaf)){
    [void]$missingCritical.Add($ep)
  }
}

# ---- Routing -------------------------------------------------------------
# Protected files (Windows / boot-critical prefixes from the rules, or required
# baseline entries) are REPORTED but never isolated. Files that were flagged
# for the same reason in the previous scan and are unchanged are not
# re-isolated. Everything else flagged (new or changed) is isolatable.
# Reporting never weakens the handoff gate: protected and known-persisting
# findings still deny handoff there.
$flagByKey = @{}
foreach($f in $findings){ $flagByKey[([string]$f.target_path).ToLowerInvariant()] = [string]$f.reason_code }

function Test-ProtectedPath([string]$full){
  $k = $full.ToLowerInvariant()
  foreach($p in $criticalPrefixes){ if($k.StartsWith($p)){ return $true } }
  if($baselineByPath.ContainsKey($k)){
    $be = $baselineByPath[$k]
    if((HasProp $be "required") -and [bool]$be.required){ return $true }
  }
  return $false
}

$isolatable = New-Object System.Collections.Generic.List[object]
$protectedFlagged = New-Object System.Collections.Generic.List[object]
$knownUnchanged = New-Object System.Collections.Generic.List[object]
foreach($f in $findings){
  $k = ([string]$f.target_path).ToLowerInvariant()
  $state = "no_baseline"
  $prevFlagForFile = ""
  if($fileMeta.ContainsKey($k)){ $state = $fileMeta[$k].State; $prevFlagForFile = $fileMeta[$k].PrevFlag }
  $f["change_state"] = $state
  if(Test-ProtectedPath ([string]$f.target_path)){
    $f["disposition"] = "protected_not_isolated"
    $protectedFlagged.Add($f)
  }
  elseif(($state -eq "unchanged") -and ($prevFlagForFile -eq [string]$f.reason_code)){
    $f["disposition"] = "known_unchanged_already_isolated"
    $knownUnchanged.Add($f)
  }
  else {
    $f["disposition"] = "isolated"
    $isolatable.Add($f)
  }
}

# ---- Change tracking + inventory ------------------------------------------
$removedList = New-Object System.Collections.Generic.List[object]
$removedComputed = $false
if($haveBaselineInventory -and ($examinedFiles -lt $MaxFiles)){
  $removedComputed = $true
  $curKeys = @{}
  foreach($ie in $inventoryEntries){ $curKeys[$ie.key] = $true }
  foreach($pk in $prevByPath.Keys){
    if($curKeys.ContainsKey($pk)){ continue }
    $under = $false
    foreach($sr in $scannedFull){ if($pk.StartsWith($sr.ToLowerInvariant())){ $under = $true; break } }
    if($under){ $removedList.Add($prevByPath[$pk]) }
  }
}

$inventoryPath = $null
$inventoryHash = $null
if($trackInventory){
  $inventoryPath = Join-Path $reportDir ($runId + ".inventory.ndjson")
  $invLines = @($inventoryEntries | Sort-Object -Property key | ForEach-Object {
    $fl = $null
    if($flagByKey.ContainsKey($_.key)){ $fl = $flagByKey[$_.key] }
    ([ordered]@{ path = $_.path; size = $_.size; mtime_utc = $_.mtime_utc; sha256 = $_.sha256; flag = $fl } | ConvertTo-Json -Compress)
  })
  $invText = ""
  if($invLines.Count -gt 0){ $invText = ($invLines -join "`n") + "`n" }
  WriteUtf8NoBomLf $inventoryPath $invText
  $inventoryHash = Sha256HexFile $inventoryPath
}

$nNew = 0; $nChanged = 0; $nUnchanged = 0
foreach($m in $fileMeta.Values){
  if($m.State -eq "new"){ $nNew++ } elseif($m.State -eq "changed"){ $nChanged++ } elseif($m.State -eq "unchanged"){ $nUnchanged++ }
}
$changeSummary = [ordered]@{
  compared = $haveBaselineInventory
  previous_inventory_path = if($haveBaselineInventory){ $PreviousInventoryPath } else { $null }
  previous_inventory_hash = $prevInventoryHash
  new = $nNew
  changed = $nChanged
  unchanged = $nUnchanged
  removed = $removedList.Count
  removed_computed = $removedComputed
}

$changeCap = 200
$changes = New-Object System.Collections.Generic.List[object]
$flaggedKeys = @{}
foreach($f in $findings){
  $flaggedKeys[([string]$f.target_path).ToLowerInvariant()] = $true
  $changes.Add([ordered]@{ path = [string]$f.target_path; state = [string]$f["change_state"]; disposition = [string]$f["disposition"]; reason_code = [string]$f.reason_code; severity = [string]$f.severity })
}
foreach($m in @($fileMeta.Values | Sort-Object -Property Path)){
  if(($m.State -eq "new" -or $m.State -eq "changed") -and -not $flaggedKeys.ContainsKey($m.Path.ToLowerInvariant())){
    $changes.Add([ordered]@{ path = $m.Path; state = $m.State; disposition = "no_finding"; reason_code = $null; severity = $null })
  }
}
foreach($r in $removedList){
  $changes.Add([ordered]@{ path = [string]$r.path; state = "removed"; disposition = "removed"; reason_code = $null; severity = $null })
}
$changesTruncated = ($changes.Count -gt $changeCap)
$changesOut = @($changes | Select-Object -First $changeCap)

# findings ndjson holds ONLY isolatable findings; suspicious_count == its line count.
$isolatableCount = $isolatable.Count

$scanObj = [ordered]@{
  schema = "clarity.validator_scan.v1"
  run_id = $runId
  created_at_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  scanned_targets = @($TargetRoots)
  examined_file_count = $examinedFiles
  max_files = $MaxFiles
  suspicious_count = $isolatableCount
  scan_error_count = $scanErrors.Count
  scan_complete = ($scanErrors.Count -eq 0)
  scan_errors = @($scanErrors | ForEach-Object { $_.Exception.Message })
  findings_path = $findingsFile
  rules_version = $rulesVersion
  rules_hash = $rulesHash
  baseline_path = if($BaselinePath){ $BaselinePath } else { $null }
  baseline_hash = if($BaselinePath){ $baselineHash } else { $null }
  classified_counts = [ordered]@{
    verified = $verifiedCount
    unknown = $unknownCount
    suspicious = $suspiciousCount
    compromised = $compromisedCount
  }
  missing_critical_count = $missingCritical.Count
  missing_critical = @($missingCritical.ToArray())
  signature_checks_performed = $signatureChecks
  protected_flagged_count = $protectedFlagged.Count
  protected_flagged = @($protectedFlagged | Select-Object -First 200 | ForEach-Object { [ordered]@{ path = [string]$_.target_path; reason_code = [string]$_.reason_code; severity = [string]$_.severity; change_state = [string]$_["change_state"] } })
  known_unchanged_suspicious_count = $knownUnchanged.Count
  change_summary = $changeSummary
  changes = $changesOut
  changes_truncated = $changesTruncated
  inventory_path = $inventoryPath
  inventory_hash = $inventoryHash
  inventory_count = $inventoryEntries.Count
}

$scanJson = ($scanObj | ConvertTo-Json -Depth 6)
WriteUtf8NoBomLf $scanFile $scanJson

# A zero-finding scan is still valid and must provide the stable findings
# artifact expected by downstream isolation and replay steps.
WriteUtf8NoBomLf $findingsFile ""
if($isolatable.Count -gt 0){
  $findingText = (($isolatable | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }) -join "`n") + "`n"
  WriteUtf8NoBomLf $findingsFile $findingText
}

Write-Output ("SCAN_REPORT=" + $scanFile)
Write-Output ("SCAN_FINDINGS=" + $findingsFile)
Write-Output "CLARITY_TIER1_STEP6_SCAN_OK"
