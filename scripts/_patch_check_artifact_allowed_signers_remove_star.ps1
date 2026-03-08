Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$CheckerPath = "C:\dev\clarity\scripts\check_artifact.ps1"
if (-not (Test-Path -LiteralPath $CheckerPath)) { throw "Missing: $CheckerPath" }
$src = Get-Content -Raw -LiteralPath $CheckerPath -Encoding UTF8
$before = $src
$src = $src -replace '\("\{0\}\s+\*\s+\{1\}"\s+-f\s+\$SigIdentity,\s+\$pubLine(\.Trim\(\))?\)','("{0} {1}" -f $SigIdentity, $pubLine.Trim())'
if ($src -eq $before) { throw "Patch failed: did not find the '{0} * {1}' pattern to replace." }
$backup = ($CheckerPath + ".bak_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
Copy-Item -LiteralPath $CheckerPath -Destination $backup -Force
$tmp = ($CheckerPath + ".tmp")
Set-Content -LiteralPath $tmp -Value $src -Encoding UTF8
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $tmp -Encoding UTF8)) | Out-Null
Move-Item -LiteralPath $tmp -Destination $CheckerPath -Force
Write-Host "PATCH OK: removed '*' from allowed_signers line (ssh-keygen compatibility)" -ForegroundColor Green
Write-Host ("Backup: {0}" -f $backup) -ForegroundColor Gray
