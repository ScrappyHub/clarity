Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Checker = "C:\dev\clarity\scripts\check_artifact.ps1"
if (-not (Test-Path -LiteralPath $Checker)) { throw "Missing: $Checker" }

function Fail([int]$code, [string]$msg) { Write-Host $msg -ForegroundColor Red; exit $code }

function Repair-Text([string]$txt) {
  # Replace "{0} * {1}" -> "{0} {1}" (ssh-keygen allowed_signers compatibility)
  $fixed = [regex]::Replace($txt, '\("\{0\}\s+\*\s+\{1\}"\s+-f\s+\$SigIdentity,\s+\$pubLine(\.Trim\(\))?\)', '("{0} {1}" -f $SigIdentity, $pubLine.Trim())')
  return $fixed
}

function Test-Text([string]$txt) {
  # Invariants we care about for "safety to run":
  # 1) Must not contain the known-bad allowed_signers tokenization
  if ($txt -match '\("\{0\}\s+\*\s+\{1\}"') { return $false }
  # 2) Must mention ssh-keygen verify path (we accept either "-Y","verify" or "-Y verify")
  if ($txt -notmatch '-Y' -or $txt -notmatch 'verify') { return $false }
  return $true
}

function Parse-Gate([string]$path) {
  [ScriptBlock]::Create((Get-Content -Raw -LiteralPath $path -Encoding UTF8)) | Out-Null
}

function Candidate-FromFile([string]$path) {
  # Returns PSCustomObject { Ok, UsedRepair, TempPath, SourcePath }
  try {
    Parse-Gate $path
    $txt = Get-Content -Raw -LiteralPath $path -Encoding UTF8

    if (Test-Text $txt) {
      return [pscustomobject]@{ Ok=$true; UsedRepair=$false; TempPath=$null; SourcePath=$path }
    }

    # Try deterministic repair-in-temp
    $fixed = Repair-Text $txt
    if ($fixed -eq $txt) { return [pscustomobject]@{ Ok=$false; UsedRepair=$false; TempPath=$null; SourcePath=$path } }
    if (-not (Test-Text $fixed)) { return [pscustomobject]@{ Ok=$false; UsedRepair=$true; TempPath=$null; SourcePath=$path } }

    $tmp = Join-Path $env:TEMP ("clarity_restore_candidate_{0}.ps1" -f ([Guid]::NewGuid().ToString("N")))
    Set-Content -LiteralPath $tmp -Value $fixed -Encoding UTF8
    Parse-Gate $tmp

    return [pscustomobject]@{ Ok=$true; UsedRepair=$true; TempPath=$tmp; SourcePath=$path }
  } catch {
    return [pscustomobject]@{ Ok=$false; UsedRepair=$false; TempPath=$null; SourcePath=$path }
  }
}

Write-Host "SMART RESTORE v2: self-healing restore for check_artifact.ps1" -ForegroundColor Cyan

# 0) If current file is already healthy, NOOP (success)
$cur = Candidate-FromFile $Checker
if ($cur.Ok -and -not $cur.UsedRepair) {
  Write-Host "NOOP: current check_artifact.ps1 is already healthy (no restore needed)." -ForegroundColor Green
  exit 0
}

# 1) Find best backup candidate (newest -> oldest), allowing repair-in-temp
$dir = Split-Path -Parent $Checker
$baks = Get-ChildItem -LiteralPath $dir -Filter "check_artifact.ps1.bak_*" | Sort-Object LastWriteTime -Descending
if (-not $baks -or $baks.Count -lt 1) { Fail 2 "No backups found (check_artifact.ps1.bak_*)" }

$chosen = $null
foreach ($b in $baks) {
  $c = Candidate-FromFile $b.FullName
  if ($c.Ok) { $chosen = $c; break }
}
if (-not $chosen) { Fail 3 "No suitable backup found (all failed parse gate / invariant checks, even after repair)." }

Write-Host ("CHOSEN SOURCE: {0}" -f $chosen.SourcePath) -ForegroundColor Cyan
if ($chosen.UsedRepair) { Write-Host "NOTE: chosen backup required deterministic repair (removed invalid '*' token)." -ForegroundColor Yellow }

# 2) Safe swap: snapshot current -> stage tmp -> parse already passed -> swap
$pre = ($Checker + ".pre_restore_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
Copy-Item -LiteralPath $Checker -Destination $pre -Force

$tmpOut = ($Checker + ".tmp")
if ($chosen.UsedRepair -and $chosen.TempPath) {
  Copy-Item -LiteralPath $chosen.TempPath -Destination $tmpOut -Force
  Remove-Item -LiteralPath $chosen.TempPath -Force -ErrorAction SilentlyContinue
} else {
  Copy-Item -LiteralPath $chosen.SourcePath -Destination $tmpOut -Force
}

Parse-Gate $tmpOut
Move-Item -LiteralPath $tmpOut -Destination $Checker -Force

Write-Host "RESTORE OK: check_artifact.ps1 restored (smart v2)" -ForegroundColor Green
Write-Host ("Pre-restore snapshot: {0}" -f $pre) -ForegroundColor Gray

