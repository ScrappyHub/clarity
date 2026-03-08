Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RunnerPath = "C:\dev\clarity\scripts\run_clarity.ps1"
if (-not (Test-Path -LiteralPath $RunnerPath)) { throw "Missing: $RunnerPath" }

$PatchPath = "C:\dev\clarity\scripts\patch_run_clarity_verify_use_external_checker_v1_6b.ps1"

$patchSrc = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RunnerPath = "C:\dev\clarity\scripts\run_clarity.ps1"
if (-not (Test-Path -LiteralPath $RunnerPath)) { throw "Missing: $RunnerPath" }

$src    = Get-Content -Raw -LiteralPath $RunnerPath -Encoding UTF8
$before = $src

$anchor = '(?m)^\s*Write-Host\s+"CLARITY RUN:"'
if ($src -notmatch $anchor) { throw 'Patch failed: could not find anchor: Write-Host "CLARITY RUN:"' }

$inject = @'
# --- v1_6b: VERIFY uses external artifact checker (no new run creation) ---
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
# --- end v1_6b ---
