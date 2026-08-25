param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root=Join-Path ([IO.Path]::GetTempPath()) ("clarity-preflight-cap-"+[Guid]::NewGuid().ToString("N"))
$reports=New-Object System.Collections.Generic.List[string]
try {
  New-Item -ItemType Directory -Force -Path (Join-Path $root "keys"),(Join-Path $root "outbox") | Out-Null
  foreach($name in @("clarity_dev_ed25519","clarity_dev_ed25519.pub","allowed_signers")){
    New-Item -ItemType File -Force -Path (Join-Path $root ("keys\"+$name)) | Out-Null
  }
  $out=@(& (Join-Path $RepoRoot "scripts\validator_preflight.ps1") -RuntimeRoot $root -RepoRoot $RepoRoot -Tenant test -Principal test -ProducerInstance preflight-cap-test)
  $matches=@($out|%{$v=$_.ToString().Trim();if($v -like '*.preflight.json' -and(Test-Path -LiteralPath $v -PathType Leaf)){$v}})
  if($matches.Count -eq 0){throw 'PREFLIGHT_REPORT_NOT_FOUND'}
  $path=$matches[$matches.Count-1];$reports.Add($path)
  $pre=Get-Content -Raw -LiteralPath $path|ConvertFrom-Json
  if([string]$pre.trust_tier -ne 'DEGRADED'){throw 'HOST_PREFLIGHT_ESCAPED_DEGRADED_CAP'}
  if([string]$pre.assurance_level -ne 'A1_HOST_OBSERVED'){throw 'HOST_PREFLIGHT_ASSURANCE_LEVEL_INVALID'}
  if(@($pre.reason_codes) -notcontains 'HOST_ONLY_ASSURANCE_CAP'){throw 'HOST_CAP_REASON_MISSING'}
  Write-Host 'PREFLIGHT_ASSURANCE_CAP_TEST_OK' -ForegroundColor Green
}
finally {
  foreach($p in $reports){if(Test-Path -LiteralPath $p -PathType Leaf){Remove-Item -LiteralPath $p -Force}}
  if(Test-Path -LiteralPath $root -PathType Container){Remove-Item -LiteralPath $root -Recurse -Force}
}
