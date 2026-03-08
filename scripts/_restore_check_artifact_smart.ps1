Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Checker = "C:\dev\clarity\scripts\check_artifact.ps1"
if (-not (Test-Path -LiteralPath $Checker)) { throw "Missing: $Checker" }

function Fail([int]$code, [string]$msg) { Write-Host $msg -ForegroundColor Red; exit $code }

# Returns $true if the candidate is "safe enough" to restore
function Test-Candidate([string]$path) {
  try {
    # 1) Parse gate
    [ScriptBlock]::Create((Get-Content -Raw -LiteralPath $path -Encoding UTF8)) | Out-Null

    $txt = Get-Content -Raw -LiteralPath $path -Encoding UTF8

    # 2) Targeted invariant: allowed_signers line must NOT contain "*" token
    # This catches the exact broken behavior: "bad options: unknown key option"
    if ($txt -match '\("\{0\}\s+\*\s+\{1\}"') { return $false }

    # 3) Must include ssh-keygen verify invocation (we expect the new style)
    if ($txt -notmatch '-Y"\s*,\s*"verify' -and $txt -notmatch '-Y\s+verify') { return $false }

    return $true
  } catch {
    return $false
  }
}

$dir = Split-Path -Parent $Checker
$baks = Get-ChildItem -LiteralPath $dir -Filter "check_artifact.ps1.bak_*" | Sort-Object LastWriteTime -Descending
if (-not $baks -or $baks.Count -lt 1) { Fail 2 "No backups found (check_artifact.ps1.bak_*)" }

$chosen = $null
foreach ($b in $baks) {
  if (Test-Candidate $b.FullName) { $chosen = $b; break }
}
if (-not $chosen) { Fail 3 "No suitable backup found (all failed parse gate or invariant checks)." }

Write-Host ("SMART RESTORE: choosing backup: {0}" -f $chosen.FullName) -ForegroundColor Cyan
$pre = ($Checker + ".pre_restore_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
Copy-Item -LiteralPath $Checker -Destination $pre -Force

$tmp = ($Checker + ".tmp")
Copy-Item -LiteralPath $chosen.FullName -Destination $tmp -Force
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $tmp -Encoding UTF8)) | Out-Null
Move-Item -LiteralPath $tmp -Destination $Checker -Force

Write-Host "RESTORE OK: check_artifact.ps1 restored from newest passing backup" -ForegroundColor Green
Write-Host ("Pre-restore snapshot: {0}" -f $pre) -ForegroundColor Gray

