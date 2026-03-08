param(
  [Parameter(Mandatory=$false)][ValidateSet("scan","status","disable","enable","verify","keygen")] [string]$Command = "scan",
  [Parameter(Mandatory=$false)][string]$TargetRoot = "C:\",
  [Parameter(Mandatory=$false)][switch]$FullScan,

  [Parameter(Mandatory=$false)][int]$MaxFindings = 50,
  [Parameter(Mandatory=$false)][int]$MaxSeconds = 20,
  [Parameter(Mandatory=$false)][int]$MaxFiles = 5000,
  [Parameter(Mandatory=$false)][int]$MaxDepth = 5,

  [Parameter(Mandatory=$false)][ValidateSet("ReportOnly","CopyOnly","CopyAndBlock")] [string]$QuarantineMode = "ReportOnly",
  [Parameter(Mandatory=$false)][ValidateSet("Marker")] [string]$BlockMethod = "Marker",

  [Parameter(Mandatory=$false)][int]$DisableMinutes = 30,
  [Parameter(Mandatory=$false)][string]$DisableReason = "",

  [Parameter(Mandatory=$false)][string]$ArtifactDir = "",
  [Parameter(Mandatory=$false)][string]$KeyRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$entry = Join-Path $repoRoot "scripts\clarity.ps1"

$argsList = @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", $entry,
  "-Command", $Command
)

if ($KeyRoot -and $KeyRoot.Trim() -ne "") {
  $argsList += @("-KeyRoot", $KeyRoot)
}

if ($Command -eq "scan") {
  $argsList += @(
    "-TargetRoot", $TargetRoot,
    "-MaxFindings", $MaxFindings,
    "-MaxSeconds", $MaxSeconds,
    "-MaxFiles", $MaxFiles,
    "-MaxDepth", $MaxDepth,
    "-QuarantineMode", $QuarantineMode,
    "-BlockMethod", $BlockMethod
  )
  if ($FullScan) { $argsList += @("-FullScan") }
}

if ($Command -eq "disable") {
  $argsList += @("-DisableMinutes", $DisableMinutes)
  if ($DisableReason -and $DisableReason.Trim() -ne "") { $argsList += @("-DisableReason", $DisableReason) }
}
# --- v1_6e: VERIFY uses external checker (no new CRUN) ---
if ($Command -eq "verify") {
  $checker = "C:\dev\clarity\scripts\check_artifact.ps1"
  if (-not (Test-Path -LiteralPath $checker)) { throw "Missing checker: $checker" }

  if (-not $ArtifactDir -or $ArtifactDir.Trim() -eq "") {
    $latestGood = Get-ChildItem "C:\ProgramData\Clarity\runs" -Directory |
      Sort-Object Name -Descending |
      Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "artifact\sha256sums.txt") } |
      Select-Object -First 1

    if (-not $latestGood) { throw "verify: no run with artifact\sha256sums.txt found under C:\ProgramData\Clarity\runs" }
    $ArtifactDir = Join-Path $latestGood.FullName "artifact"
  }

  Write-Host ("VERIFY (external): {0}" -f $ArtifactDir) -ForegroundColor Cyan
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checker -ArtifactDir $ArtifactDir
  exit $LASTEXITCODE
}
# --- end v1_6e ---
if ($Command -eq "verify") { throw "BUG: verify must exit inside verify handler (runner fallthrough)" }



Write-Host "CLARITY RUN:" -ForegroundColor Cyan
Write-Host ("powershell.exe {0}" -f ($argsList -join " ")) -ForegroundColor Gray

& powershell.exe @argsList
$code = $LASTEXITCODE
exit $code



