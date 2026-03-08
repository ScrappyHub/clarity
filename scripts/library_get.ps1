param(
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$ContentRef,
  [Parameter(Mandatory=$true)][string]$GrantId
)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
. "$PSScriptRoot\lib\canon.ps1"
if(-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)){ throw ("MISSING_RUNTIME_ROOT: " + $RuntimeRoot) }
if($ContentRef -notmatch "^cas:sha256:([0-9a-f]{64})$"){ throw ("BAD_CONTENT_REF: " + $ContentRef) }
$objHash = $Matches[1]
$grantPath = Join-Path $RuntimeRoot ("library\access\sessions\" + $GrantId + ".json")
if(-not (Test-Path -LiteralPath $grantPath -PathType Leaf)){ throw ("ACCESS_DENIED_MISSING_GRANT: " + $GrantId) }
$grant = Get-Content -Raw -LiteralPath $grantPath -Encoding UTF8 | ConvertFrom-Json
if(-not [bool]$grant.verified){ throw "ACCESS_DENIED_UNVERIFIED_GRANT" }
if([string]$grant.content_ref -ne $ContentRef){ throw "ACCESS_DENIED_CONTENT_REF_MISMATCH" }
$prefix = $objHash.Substring(0,2)
$objDir = Join-Path (Join-Path (Join-Path $RuntimeRoot "library\objects\sha256") $prefix) $objHash
if(-not (Test-Path -LiteralPath $objDir -PathType Container)){ throw ("MISSING_OBJECT_DIR: " + $objDir) }
$contentPath = Join-Path $objDir "content.bin"
if(-not (Test-Path -LiteralPath $contentPath -PathType Leaf)){ throw ("MISSING_OBJECT_CONTENT: " + $contentPath) }
Write-Host ("LIBRARY_GET_OK: " + $ContentRef) -ForegroundColor Green
Write-Output $contentPath
