Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$checker = "C:\dev\clarity\scripts\check_artifact.ps1"

$latestRun = Get-ChildItem "C:\ProgramData\Clarity\runs" -Directory |
  Sort-Object Name -Descending |
  Select-Object -First 1

if (-not $latestRun) { throw "No runs found under C:\ProgramData\Clarity\runs" }

$artifact = Join-Path $latestRun.FullName "artifact"
Write-Host ("ArtifactDir: {0}" -f $artifact) -ForegroundColor Cyan

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checker -ArtifactDir $artifact
exit $LASTEXITCODE
