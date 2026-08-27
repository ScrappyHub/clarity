param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$false)][string[]]$TargetRoots,
  [Parameter(Mandatory=$false)][int]$MaxFiles = 5000,
  [Parameter(Mandatory=$false)][string]$RulesPath = "",
  [Parameter(Mandatory=$false)][string]$BaselinePath = ""
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
$scanErrors = @()
$seenBaselinePaths = New-Object System.Collections.Generic.HashSet[string]

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

      if($baselineByPath.ContainsKey($key)){
        [void]$seenBaselinePaths.Add($key)
        $e = $baselineByPath[$key]
        $h = Sha256HexFile $full
        $expected = ([string]$e.sha256).ToLowerInvariant()
        if($h -eq $expected){
          $verifiedCount++
        } else {
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
        }
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

# findings ndjson holds ONLY isolatable findings; suspicious_count == its line count.
$isolatableCount = $findings.Count

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
}

$scanJson = ($scanObj | ConvertTo-Json -Depth 6)
WriteUtf8NoBomLf $scanFile $scanJson

# A zero-finding scan is still valid and must provide the stable findings
# artifact expected by downstream isolation and replay steps.
WriteUtf8NoBomLf $findingsFile ""
if($findings.Count -gt 0){
  $findingText = (($findings | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }) -join "`n") + "`n"
  WriteUtf8NoBomLf $findingsFile $findingText
}

Write-Output ("SCAN_REPORT=" + $scanFile)
Write-Output ("SCAN_FINDINGS=" + $findingsFile)
Write-Output "CLARITY_TIER1_STEP6_SCAN_OK"
