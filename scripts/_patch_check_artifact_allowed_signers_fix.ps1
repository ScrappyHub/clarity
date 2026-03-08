Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$CheckerPath = "C:\dev\clarity\scripts\check_artifact.ps1"
if (-not (Test-Path -LiteralPath $CheckerPath)) { throw "Missing: $CheckerPath" }

Invoke-ClarityTextPatch -TargetPath $CheckerPath -Tag "allowed_signers_fix" -PatchFn {
  param($src)
  return ($src -replace '\("\{0\}\s+\*\s+\{1\}"', '("{0} {1}"')
}
