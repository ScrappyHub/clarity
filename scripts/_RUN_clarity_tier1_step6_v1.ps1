param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

Write-Output "TIER1_STEP6: targeted_scan"

& (Join-Path $RepoRoot "scripts\validator_scan_targeted.ps1") `
  -RepoRoot $RepoRoot

Write-Output "CLARITY_TIER1_STEP6_OK"
