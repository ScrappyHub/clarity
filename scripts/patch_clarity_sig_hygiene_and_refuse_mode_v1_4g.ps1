param([Parameter(Mandatory=$true)][string]$MainPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $MainPath)) { throw "Missing MainPath: $MainPath" }
$src = Get-Content -Raw -LiteralPath $MainPath -Encoding UTF8

function Find-FunctionRange([string]$text, [string]$fnName) {
  $m = [regex]::Match($text, "(?m)^\s*function\s+$([regex]::Escape($fnName))\b")
  if (-not $m.Success) { return $null }

  $i = $m.Index + $m.Length
  $open = $text.IndexOf("{", $i)
  if ($open -lt 0) { throw "Could not find '{' for function $fnName" }

  $depth = 0
  for ($p = $open; $p -lt $text.Length; $p++) {
    $ch = $text[$p]
    if ($ch -eq "{") { $depth++ }
    elseif ($ch -eq "}") {
      $depth--
      if ($depth -eq 0) { return [ordered]@{ Start=$m.Index; End=($p+1) } }
    }
  }
  throw "Could not find matching '}' for function $fnName"
}

function Replace-Function([string]$fnName, [string]$newText) {
  $r = Find-FunctionRange -text $script:src -fnName $fnName
  if (-not $r) { throw "Patch failed: function not found: $fnName" }
  $before = $script:src.Substring(0, $r.Start)
  $after  = $script:src.Substring($r.End)
  $script:src = $before + $newText + "`r`n`r`n" + $after
}

function Replace-Once([string]$pattern, [string]$replacement, [string]$label) {
  $m = [regex]::Match($script:src, $pattern)
  if (-not $m.Success) { throw ("Patch failed: could not find pattern for: {0}" -f $label) }
  $script:src = [regex]::Replace($script:src, $pattern, $replacement, 1)
}

$script:src = $src

# ------------------------------------------------------------
# 1) Sign-ArtifactBundle: ssh-keygen hygiene
#    - still let ssh-keygen create sha256sums.txt.sig
#    - move it to signature.ed25519
#    - then explicitly remove transient if it somehow remains
#    Do this in BOTH the first sign and the re-sign pass.
# ------------------------------------------------------------
$signFn = Find-FunctionRange -text $script:src -fnName "Sign-ArtifactBundle"
if (-not $signFn) { throw "Patch failed: Sign-ArtifactBundle not found" }

$signBlock = $script:src.Substring($signFn.Start, $signFn.End - $signFn.Start)

# First-pass ssh-keygen move: ensure we clean up $tmp after Move-Item
# We look for:
#   Move-Item -LiteralPath $tmp -Destination $sig -Force
# and replace with the same + cleanup guard.
$signBlock2 = $signBlock
$signBlock2 = [regex]::Replace(
  $signBlock2,
  '(?m)^\s*Move-Item\s+-LiteralPath\s+\$tmp\s+-Destination\s+\$sig\s+-Force\s*$',
  '    Move-Item -LiteralPath $tmp -Destination $sig -Force' + "`r`n" +
  '    if (Test-Path -LiteralPath $tmp) { Remove-Item -Force -LiteralPath $tmp }',
  1
)

# Second-pass ssh-keygen move: ensure we clean up $tmp2 after Move-Item
$signBlock2 = [regex]::Replace(
  $signBlock2,
  '(?m)^\s*Move-Item\s+-LiteralPath\s+\$tmp2\s+-Destination\s+\$sig\s+-Force\s*$',
  '    Move-Item -LiteralPath $tmp2 -Destination $sig -Force' + "`r`n" +
  '    if (Test-Path -LiteralPath $tmp2) { Remove-Item -Force -LiteralPath $tmp2 }',
  1
)

if ($signBlock2 -eq $signBlock) {
  throw "Patch failed: did not find expected Move-Item lines inside Sign-ArtifactBundle (tmp/tmp2). Refusing to guess."
}

# Splice back the modified Sign-ArtifactBundle
$before = $script:src.Substring(0, $signFn.Start)
$after  = $script:src.Substring($signFn.End)
$script:src = $before + $signBlock2 + "`r`n`r`n" + $after

# ------------------------------------------------------------
# 2) REFUSE_SCAN mode string consistency
#    Find the REFUSE_SCAN metadata block by locating action="REFUSE_SCAN"
#    then replace the next mode="windows_userland_*" with v1_4f.
# ------------------------------------------------------------
$actionIdx = [regex]::Match($script:src, '(?m)^\s*action\s*=\s*"(REFUSE_SCAN)"\s*$')
if (-not $actionIdx.Success) {
  # Some builds may have action='REFUSE_SCAN' single quotes
  $actionIdx = [regex]::Match($script:src, "(?m)^\s*action\s*=\s*'(REFUSE_SCAN)'\s*$")
}
if (-not $actionIdx.Success) { throw "Patch failed: could not find REFUSE_SCAN action assignment" }

# Search forward a bounded window for the mode assignment
$windowStart = $actionIdx.Index
$windowLen   = [Math]::Min(2000, $script:src.Length - $windowStart)
$window = $script:src.Substring($windowStart, $windowLen)

$mMode = [regex]::Match($window, '(?m)^\s*mode\s*=\s*"(windows_userland_[^"]+)"\s*$')
if (-not $mMode.Success) {
  $mMode = [regex]::Match($window, "(?m)^\s*mode\s*=\s*'(windows_userland_[^']+)'\s*$")
}
if (-not $mMode.Success) { throw "Patch failed: could not find mode assignment near REFUSE_SCAN block" }

# Replace only within this window (first match)
$windowPat = [regex]::Escape($mMode.Value)
$windowNew = $mMode.Value
if ($windowNew -match '"') {
  $windowNew = ($windowNew -replace '(?m)^(?<lead>\s*mode\s*=\s*)".*?"\s*$', '${lead}"windows_userland_v1_4f"')
} else {
  $windowNew = ($windowNew -replace "(?m)^(?<lead>\s*mode\s*=\s*)'.*?'\s*$", '${lead}"windows_userland_v1_4f"')
}

# Apply the replacement back into full text at correct spot
$window2 = [regex]::Replace($window, $windowPat, [regex]::Escape($windowNew), 1)
$window2 = $window2 -replace '\\Q','' -replace '\\E',''  # defensive (no-op if not present)

$script:src = $script:src.Substring(0,$windowStart) + $window2 + $script:src.Substring($windowStart + $windowLen)

# ------------------------------------------------------------
# Safe write: backup -> tmp -> parse -> swap
# ------------------------------------------------------------
$backup = ($MainPath + ".bak_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
Copy-Item -LiteralPath $MainPath -Destination $backup -Force

$tmp = ($MainPath + ".tmp")
Set-Content -LiteralPath $tmp -Value $script:src -Encoding UTF8

# Parse check in-process (no pwsh -Command quoting footguns)
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $tmp -Encoding UTF8)) | Out-Null

Move-Item -LiteralPath $tmp -Destination $MainPath -Force

Write-Host "PATCH OK (v1_4g)" -ForegroundColor Green
Write-Host ("Backup: {0}" -f $backup) -ForegroundColor Gray
