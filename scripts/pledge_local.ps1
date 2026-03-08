param(
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$Tenant,
  [Parameter(Mandatory=$true)][string]$Principal,
  [Parameter(Mandatory=$true)][string]$ProducerInstance,
  [Parameter(Mandatory=$true)][string]$CommitHash,
  [Parameter(Mandatory=$true)][string]$SigPath,
  [Parameter(Mandatory=$true)][string]$KeyId
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\canon.ps1"
function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
$log = Join-Path $RuntimeRoot "pledges\pledges.ndjson"
EnsureDir (Split-Path -Parent $log)
$prevLogHash = "GENESIS"
$seq = 1
if(Test-Path -LiteralPath $log -PathType Leaf){
  $existingLines = @((Get-Content -LiteralPath $log -Encoding UTF8) | Where-Object { $_ -and $_.Trim() -ne "" })
  if($existingLines.Count -gt 0){
    $last = $existingLines[$existingLines.Count - 1] | ConvertFrom-Json
    $prevLogHash = [string]$last.log_hash
    $seq = [int]$last.seq + 1
  }
}
$obj = [ordered]@{
  schema="local_pledge.v1"
  created_at_utc=UtcNow
  seq=$seq
  producer="clarity"
  producer_instance=$ProducerInstance
  tenant=$Tenant
  principal=$Principal
  key_id=$KeyId
  commit_hash=$CommitHash
  sig_path=$SigPath
  prev_log_hash=$prevLogHash
}
$noHashJson = ($obj | ConvertTo-Json -Compress)
$logHash = Sha256HexTextNormalized $noHashJson
$obj["log_hash"] = $logHash
$line = ($obj | ConvertTo-Json -Compress)
$existingText = ""
if(Test-Path -LiteralPath $log -PathType Leaf){ $existingText = Get-Content -Raw -LiteralPath $log -Encoding UTF8 }
WriteUtf8NoBomLf $log ($existingText + $line + "`n")
Write-Host ("PLEDGE_OK seq=" + $seq + " commit=" + $CommitHash) -ForegroundColor Green
Write-Output $logHash
