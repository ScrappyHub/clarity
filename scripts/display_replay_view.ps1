param(
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$SessionId
)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
. "$PSScriptRoot\lib\canon.ps1"
. "$PSScriptRoot\lib\clarity_display_common.ps1"

if(-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)){ throw ("MISSING_RUNTIME_ROOT: " + $RuntimeRoot) }
if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){ throw ("MISSING_REPO_ROOT: " + $RepoRoot) }

$sessionPath = CL-SessionPath $RuntimeRoot $SessionId
if(-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)){ throw ("MISSING_SESSION: " + $sessionPath) }
$session = Get-Content -Raw -LiteralPath $sessionPath -Encoding UTF8 | ConvertFrom-Json

$receiptPath = CL-DisplayReceiptsPath $RuntimeRoot
if(-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)){ throw ("MISSING_DISPLAY_RECEIPTS: " + $receiptPath) }
$allReceiptLines = @((Get-Content -LiteralPath $receiptPath -Encoding UTF8) | Where-Object { $_ -and $_.Trim() -ne "" })
$receipts = New-Object System.Collections.Generic.List[object]
foreach($line in $allReceiptLines){
  $obj = $line | ConvertFrom-Json
  if([string]$obj.session_id -eq $SessionId){ [void]$receipts.Add($obj) }
}
if($receipts.Count -le 0){ throw "NO_RECEIPTS_FOR_SESSION" }

$reportDir = Join-Path $RepoRoot "reports\display_replay"
EnsureDir $reportDir
$reportPath = Join-Path $reportDir ($SessionId + ".replay.json")
$timelinePath = Join-Path $reportDir ($SessionId + ".timeline.txt")

$timeline = New-Object System.Collections.Generic.List[string]
$normalizedReceipts = New-Object System.Collections.Generic.List[object]
foreach($r in $receipts){
  [void]$timeline.Add(([string]$r.created_at_utc + " | " + [string]$r.receipt_type + " | " + [string]$r.status + " | " + [string]$r.detail))
  [void]$normalizedReceipts.Add([ordered]@{
    created_at_utc = [string]$r.created_at_utc
    receipt_type = [string]$r.receipt_type
    status = [string]$r.status
    detail = [string]$r.detail
    receipt_hash = [string]$r.receipt_hash
  })
}

$reportObj = [ordered]@{
  schema = "clarity.display_replay_report.v1"
  session_id = [string]$session.session_id
  tenant = [string]$session.tenant
  principal = [string]$session.principal
  content_ref = [string]$session.content_ref
  adapter = [string]$session.adapter
  display_mode = [string]$session.display_mode
  opened_at_utc = [string]$session.opened_at_utc
  closed_at_utc = [string]$session.closed_at_utc
  status = [string]$session.status
  receipt_count = [int]$normalizedReceipts.Count
  receipts = $normalizedReceipts
}

$reportJson = ($reportObj | ConvertTo-Json -Compress -Depth 10)
WriteUtf8NoBomLf $reportPath $reportJson
WriteUtf8NoBomLf $timelinePath (($timeline.ToArray() -join "`n") + "`n")

Write-Host ("DISPLAY_REPLAY_OK: " + $SessionId) -ForegroundColor Green
Write-Output $reportPath
Write-Output $timelinePath
