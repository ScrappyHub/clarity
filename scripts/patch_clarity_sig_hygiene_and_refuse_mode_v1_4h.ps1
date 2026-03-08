param([Parameter(Mandatory=$true)][string]$MainPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $MainPath)) { throw "Missing MainPath: $MainPath" }
$src = Get-Content -Raw -LiteralPath $MainPath -Encoding UTF8

function Assert-Changed([string]$before,[string]$after,[string]$label) {
  if ($before -eq $after) { throw "Patch failed: no change applied for $label" }
}

# ------------------------------------------------------------
# 1) Hygiene: never leave sha256sums.txt.sig behind
#    After moving tmp/tmp2 -> signature.ed25519, delete tmp/tmp2 if it exists.
# ------------------------------------------------------------
$before = $src

# First-pass move cleanup (tmp)
$src = [regex]::Replace(
  $src,
  '(?m)^(?<i>\s*)Move-Item\s+-LiteralPath\s+\$tmp\s+-Destination\s+\$sig\s+-Force\s*$',
  '${i}Move-Item -LiteralPath $tmp -Destination $sig -Force' + "`r`n" +
  '${i}if (Test-Path -LiteralPath $tmp) { Remove-Item -Force -LiteralPath $tmp }',
  1
)

# Second-pass move cleanup (tmp2)
$src = [regex]::Replace(
  $src,
  '(?m)^(?<i>\s*)Move-Item\s+-LiteralPath\s+\$tmp2\s+-Destination\s+\$sig\s+-Force\s*$',
  '${i}Move-Item -LiteralPath $tmp2 -Destination $sig -Force' + "`r`n" +
  '${i}if (Test-Path -LiteralPath $tmp2) { Remove-Item -Force -LiteralPath $tmp2 }',
  1
)

Assert-Changed $before $src "sha256sums.txt.sig hygiene (tmp/tmp2)"

# ------------------------------------------------------------
# 2) REFUSE_SCAN mode: make it windows_userland_v1_4f for traceability
#    Do this by INDEX replacement (no escaping replacements).
# ------------------------------------------------------------
$action = [regex]::Match($src, '(?m)^\s*action\s*=\s*"(REFUSE_SCAN)"\s*$')
if (-not $action.Success) {
  $action = [regex]::Match($src, "(?m)^\s*action\s*=\s*'(REFUSE_SCAN)'\s*$")
}
if (-not $action.Success) { throw "Patch failed: could not find REFUSE_SCAN action assignment" }

# Search forward a bounded window from the REFUSE_SCAN action line
$windowStart = $action.Index
$windowLen   = [Math]::Min(2500, $src.Length - $windowStart)
$window      = $src.Substring($windowStart, $windowLen)

$mMode = [regex]::Match($window, '(?m)^(?<i>\s*)mode\s*=\s*"windows_userland_[^"]+"\s*$')
if (-not $mMode.Success) {
  $mMode = [regex]::Match($window, "(?m)^(?<i>\s*)mode\s*=\s*'windows_userland_[^']+'\s*$")
}
if (-not $mMode.Success) { throw "Patch failed: could not find mode assignment near REFUSE_SCAN block" }

$indent = $mMode.Groups['i'].Value
$newLine = $indent + 'mode = "windows_userland_v1_4f"'

# Replace the exact mode line in-window by index (no regex escaping)
$globalModeStart = $windowStart + $mMode.Index
$src = $src.Substring(0, $globalModeStart) + $newLine + $src.Substring($globalModeStart + $mMode.Length)

# ------------------------------------------------------------
# Safe write: backup -> tmp -> parse -> swap
# ------------------------------------------------------------
$backup = ($MainPath + ".bak_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
Copy-Item -LiteralPath $MainPath -Destination $backup -Force

$tmp = ($MainPath + ".tmp")
Set-Content -LiteralPath $tmp -Value $src -Encoding UTF8

# Parse check in-process
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $tmp -Encoding UTF8)) | Out-Null

Move-Item -LiteralPath $tmp -Destination $MainPath -Force

Write-Host "PATCH OK (v1_4h)" -ForegroundColor Green
Write-Host ("Backup: {0}" -f $backup) -ForegroundColor Gray
