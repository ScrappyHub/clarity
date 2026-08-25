param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$false)][string[]]$TargetRoots,
  [Parameter(Mandatory=$false)][int]$MaxFiles = 5000
)

Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
. "$PSScriptRoot\lib\canon.ps1"

$runId = [Guid]::NewGuid().ToString("N")
$reportDir = Join-Path $RepoRoot ("reports\validator_scan\" + $runId)
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

$scanFile = Join-Path $reportDir ($runId + ".scan.json")
$findingsFile = Join-Path $reportDir ($runId + ".findings.ndjson")

if(-not $TargetRoots -or $TargetRoots.Count -eq 0){
  $TargetRoots = @(
    "$env:SystemRoot\System32",
    "$env:SystemRoot\SysWOW64",
    "$env:ProgramFiles",
    "$env:ProgramFiles(x86)"
  )
}

$suspicious = @()
$examinedFiles = 0
$scanErrors = @()

foreach($t in $TargetRoots){
  if($examinedFiles -ge $MaxFiles){ break }
  if(Test-Path -LiteralPath $t -PathType Container){
    Get-ChildItem -LiteralPath $t -Recurse -File -ErrorAction SilentlyContinue -ErrorVariable +scanErrors | ForEach-Object {
      if($examinedFiles -ge $MaxFiles){ return }
      $examinedFiles++
      if($_.Extension -in ".exe",".dll",".sys"){
        if($_.Length -eq 0){
          $suspicious += @{
            target_path = $_.FullName
            reason_code = "ZERO_LENGTH_EXECUTABLE"
            severity = "suspicious"
          }
        }
      }
    }
  }
}

$scanObj = [ordered]@{
  schema = "clarity.validator_scan.v1"
  run_id = $runId
  created_at_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  scanned_targets = @($TargetRoots)
  examined_file_count = $examinedFiles
  max_files = $MaxFiles
  suspicious_count = $suspicious.Count
  scan_error_count = $scanErrors.Count
  scan_complete = ($scanErrors.Count -eq 0)
  scan_errors = @($scanErrors | ForEach-Object { $_.Exception.Message })
  findings_path = $findingsFile
}

$scanJson = ($scanObj | ConvertTo-Json -Depth 5)
WriteUtf8NoBomLf $scanFile $scanJson

# A zero-finding scan is still a valid scan and must provide the stable
# findings artifact expected by downstream isolation and replay steps.
WriteUtf8NoBomLf $findingsFile ""

if($suspicious.Count -gt 0){
  $findingText = (($suspicious | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join "`n") + "`n"
  WriteUtf8NoBomLf $findingsFile $findingText
}

Write-Output ("SCAN_REPORT=" + $scanFile)
Write-Output ("SCAN_FINDINGS=" + $findingsFile)
Write-Output "CLARITY_TIER1_STEP6_SCAN_OK"
