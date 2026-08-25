param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-PathOutput([object[]]$Output,[string]$Pattern){
  $m=@($Output|%{$v=$_.ToString().Trim();if($v -like $Pattern -and(Test-Path -LiteralPath $v -PathType Leaf)){$v}})
  if($m.Count -eq 0){throw("MISSING_DISPLAY_OUTPUT: "+$Pattern)}
  $m[$m.Count-1]
}

$root=Join-Path ([IO.Path]::GetTempPath()) ("clarity-display-test-"+[Guid]::NewGuid().ToString("N"))
$reports=New-Object System.Collections.Generic.List[string]
try {
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  foreach($adapter in @("windows_sandbox","hyperv")){
    $profilePath = if($adapter -eq "hyperv") { Join-Path $RepoRoot "vm_profiles\protected_review_hyperv.v1.json" } else { Join-Path $RepoRoot "vm_profiles\protected_review_sandbox.v1.json" }
    $open=@(& (Join-Path $RepoRoot "scripts\display_session_open.ps1") -RuntimeRoot $root -Tenant test -Principal test -ProducerInstance display-test -ContentRef "cas:sha256:test" -Adapter $adapter -DisplayMode protected_review)
    $sid=@($open|%{$v=$_.ToString().Trim();if($v -match '^[0-9a-f]{32}$'){$v}})[-1]
    if(-not $sid){throw "SESSION_ID_NOT_FOUND"}
    if($adapter -eq "windows_sandbox"){
      & (Join-Path $RepoRoot "scripts\display_adapter_windows_sandbox.ps1") -RuntimeRoot $root -SessionId $sid -ProfilePath $profilePath | Out-Null
    } else {
      & (Join-Path $RepoRoot "scripts\display_adapter_hyperv.ps1") -RuntimeRoot $root -SessionId $sid -ProfilePath $profilePath | Out-Null
    }
    & (Join-Path $RepoRoot "scripts\display_session_close.ps1") -RuntimeRoot $root -SessionId $sid | Out-Null
    $requestPath=Join-Path (Join-Path (Join-Path (Join-Path $root "display\adapters") $adapter) "requests") ($sid + "\request.json")
    $requestObj=Get-Content -Raw -LiteralPath $requestPath -Encoding UTF8 | ConvertFrom-Json
    $reports.Add([string]$requestObj.profile_validation_path)
    $originalRequest=Get-Content -Raw -LiteralPath $requestPath -Encoding UTF8
    $enc=New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($requestPath,($originalRequest -replace "cas:sha256:test","cas:sha256:tampered"),$enc)
    $requestTamperFailed=$false
    try { & (Join-Path $RepoRoot "scripts\display_replay_view.ps1") -RuntimeRoot $root -RepoRoot $RepoRoot -SessionId $sid | Out-Null } catch {$requestTamperFailed=$true}
    [IO.File]::WriteAllText($requestPath,$originalRequest,$enc)
    if(-not $requestTamperFailed){throw "DISPLAY_REQUEST_TAMPER_NOT_DETECTED"}
    $replay=@(& (Join-Path $RepoRoot "scripts\display_replay_view.ps1") -RuntimeRoot $root -RepoRoot $RepoRoot -SessionId $sid)
    $replayPath=Get-PathOutput $replay "*.replay.json"
    $timelinePath=Get-PathOutput $replay "*.timeline.txt"
    $reports.Add($replayPath);$reports.Add($timelinePath)
    $replayObj=Get-Content -Raw -LiteralPath $replayPath|ConvertFrom-Json
    if([string]$replayObj.adapter -ne $adapter){throw "REPLAY_ADAPTER_MISMATCH"}
    if([int]$replayObj.receipt_count -lt 3){throw "REPLAY_RECEIPTS_TOO_FEW"}
    $closeFailed=$false
    try { & (Join-Path $RepoRoot "scripts\display_session_close.ps1") -RuntimeRoot $root -SessionId $sid | Out-Null } catch {$closeFailed=$true}
    if(-not $closeFailed){throw "DOUBLE_CLOSE_NOT_REJECTED"}
  }

  $tamperSession=@(Get-ChildItem -LiteralPath (Join-Path $root "display\sessions") -Directory | Select-Object -First 1 -ExpandProperty Name)
  $receiptPath=Join-Path $root "display\receipts\display_receipts.ndjson"
  $original=Get-Content -Raw -LiteralPath $receiptPath -Encoding UTF8
  $enc=New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($receiptPath,($original -replace "session.opened","session.tampered"),$enc)
  $tamperFailed=$false
  try { & (Join-Path $RepoRoot "scripts\display_replay_view.ps1") -RuntimeRoot $root -RepoRoot $RepoRoot -SessionId $tamperSession | Out-Null } catch {$tamperFailed=$true}
  [IO.File]::WriteAllText($receiptPath,$original,$enc)
  if(-not $tamperFailed){throw "DISPLAY_TAMPER_NOT_DETECTED"}
  Write-Host "PROTECTED_DISPLAY_TEST_OK" -ForegroundColor Green
}
finally {
  foreach($p in $reports){if(Test-Path -LiteralPath $p -PathType Leaf){Remove-Item -LiteralPath $p -Force}}
  if(Test-Path -LiteralPath $root -PathType Container){Remove-Item -LiteralPath $root -Recurse -Force}
}
