Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RunnerPath = "C:\dev\clarity\scripts\run_clarity.ps1"
if (-not (Test-Path -LiteralPath $RunnerPath)) { throw "Missing: $RunnerPath" }

$raw = Get-Content -Raw -LiteralPath $RunnerPath -Encoding UTF8
$before = $raw

# Anchor on your injected block end marker
$anchor = "# --- end v1_6e ---"
if ($raw -notmatch [regex]::Escape($anchor)) {
  throw "Patch failed: could not find anchor: $anchor"
}

# Don't double-insert
$guardLine = 'if ($Command -eq "verify") { throw "BUG: verify must exit inside verify handler (runner fallthrough)" }'
if ($raw -match [regex]::Escape($guardLine)) {
  Write-Host "SKIP: fallthrough guard already present." -ForegroundColor Yellow
  exit 0
}

# Insert guard immediately after the anchor
$patched = $raw.Replace($anchor, ($anchor + "`r`n" + $guardLine))

if ($patched -eq $before) { throw "Patch failed: no change applied." }

$backup = ($RunnerPath + ".bak_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
Copy-Item -LiteralPath $RunnerPath -Destination $backup -Force

$tmp = ($RunnerPath + ".tmp")
Set-Content -LiteralPath $tmp -Value $patched -Encoding UTF8
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $tmp -Encoding UTF8)) | Out-Null
Move-Item -LiteralPath $tmp -Destination $RunnerPath -Force

Write-Host "PATCH OK (v1_6f): verify fallthrough guard added" -ForegroundColor Green
Write-Host ("Backup: {0}" -f $backup) -ForegroundColor Gray
