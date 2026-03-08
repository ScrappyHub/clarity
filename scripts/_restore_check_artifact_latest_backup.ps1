Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Checker = "C:\dev\clarity\scripts\check_artifact.ps1"
if (-not (Test-Path -LiteralPath $Checker)) { throw "Missing: $Checker" }
$bak = Get-ChildItem -LiteralPath "C:\dev\clarity\scripts" -Filter "check_artifact.ps1.bak_*" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $bak) { throw "No backups found (check_artifact.ps1.bak_*)" }
Write-Host ("RESTORING FROM: {0}" -f $bak.FullName) -ForegroundColor Cyan
$tmp = ($Checker + ".tmp")
Copy-Item -LiteralPath $bak.FullName -Destination $tmp -Force
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $tmp -Encoding UTF8)) | Out-Null
Copy-Item -LiteralPath $Checker -Destination ($Checker + ".pre_restore_" + (Get-Date -Format "yyyyMMdd_HHmmss")) -Force
Move-Item -LiteralPath $tmp -Destination $Checker -Force
Write-Host "RESTORE OK: check_artifact.ps1 restored from latest backup" -ForegroundColor Green
