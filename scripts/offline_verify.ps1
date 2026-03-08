param(
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$OsDrive,
  [Parameter(Mandatory=$false)][string]$RunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Find-SshKeygen {
  $here = Split-Path -Parent $MyInvocation.MyCommand.Path
  $bundled = Join-Path $here "tools\ssh-keygen.exe"
  if (Test-Path -LiteralPath $bundled) { return $bundled }

  $cmd = Get-Command "ssh-keygen.exe" -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

# Use the same checker you already wrote
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$checker = Join-Path $here "check_artifact.ps1"
if (-not (Test-Path -LiteralPath $checker)) { throw "Missing checker: $checker" }

# In WinPE, ProgramData path depends on mounted OS volume
$base = Join-Path $OsDrive "ProgramData\Clarity\runs"
if (-not (Test-Path -LiteralPath $base)) { throw "No runs directory on OS drive: $base" }

$runDir = $null
if ($RunId -and $RunId.Trim() -ne "") {
  $cand = Join-Path $base $RunId
  if (-not (Test-Path -LiteralPath $cand)) { throw "RunId not found: $cand" }
  $runDir = Get-Item -LiteralPath $cand
} else {
  $runDir = Get-ChildItem -LiteralPath $base -Directory | Sort-Object Name -Descending | Select-Object -First 1
}

if (-not $runDir) { throw "No runs found under: $base" }

$artifact = Join-Path $runDir.FullName "artifact"
Write-Host ("OS Drive:     {0}" -f $OsDrive) -ForegroundColor Cyan
Write-Host ("Latest Run:   {0}" -f $runDir.Name) -ForegroundColor Cyan
Write-Host ("ArtifactDir:  {0}" -f $artifact) -ForegroundColor Cyan

# Ensure ssh-keygen exists somewhere (bundled or in PATH)
$ssh = Find-SshKeygen
if (-not $ssh) {
  Write-Host "FAIL: ssh-keygen.exe not available in WinPE environment (bundle it into tools\ssh-keygen.exe)" -ForegroundColor Red
  exit 2
}

# If we bundled ssh-keygen, prepend it so check_artifact can find it via PATH if needed
$toolDir = Split-Path -Parent $ssh
$env:PATH = $toolDir + ";" + $env:PATH

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checker -ArtifactDir $artifact
exit $LASTEXITCODE
