param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source

function Get-TrimmedNonEmptyLines {
  param([object[]]$InputObjects)
  $out = New-Object System.Collections.Generic.List[string]
  foreach($obj in @($InputObjects)){
    if($null -eq $obj){ continue }
    $s = $obj.ToString().Trim()
    if(-not [string]::IsNullOrWhiteSpace($s)){ [void]$out.Add($s) }
  }
  return @($out.ToArray())
}

function Get-LastMatchingLine {
  param(
    [Parameter(Mandatory=$true)][string[]]$Lines,
    [Parameter(Mandatory=$true)][scriptblock]$Predicate
  )
  $matches = New-Object System.Collections.Generic.List[string]
  foreach($line in @($Lines)){
    if(& $Predicate $line){ [void]$matches.Add($line) }
  }
  if($matches.Count -le 0){ return $null }
  return $matches[$matches.Count - 1]
}

$Bootstrap = Join-Path $RepoRoot "scripts\_bootstrap_clarity_standalone_v1.ps1"
$Make      = Join-Path $RepoRoot "scripts\make_packet.ps1"
$Verify    = Join-Path $RepoRoot "scripts\verify_packet.ps1"
$Pledge    = Join-Path $RepoRoot "scripts\pledge_local.ps1"
$Dup       = Join-Path $RepoRoot "scripts\duplicate_to_nfl.ps1"
$RuntimeRoot = "C:\ProgramData\Clarity"
$Tenant = "single-tenant"
$Principal = "single-tenant/operator/user/alec"
$ProducerInstance = ("{0}-standalone-1" -f $env:COMPUTERNAME)
$NflInbox = "C:\ProgramData\NFL\inbox"

foreach($p in @($Bootstrap,$Make,$Verify,$Pledge,$Dup)){
  if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ throw ("MISSING_SCRIPT: " + $p) }
}

Write-Host "STEP2: bootstrap" -ForegroundColor DarkGray
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Bootstrap -RepoRoot $RepoRoot | Out-Host

Write-Host "STEP2: make_packet" -ForegroundColor DarkGray
$pktOutRaw = @(& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Make -RuntimeRoot $RuntimeRoot -Tenant $Tenant -Principal $Principal -ProducerInstance $ProducerInstance -EventType "clarity.run.started.v1" -ContentRef "cas:sha256:deadbeef" -Strength "evidence")
$pktOut = @(Get-TrimmedNonEmptyLines -InputObjects $pktOutRaw)
$pkt = Get-LastMatchingLine -Lines $pktOut -Predicate {
  param($line)
  (Test-Path -LiteralPath $line -PathType Container) -and $line.StartsWith("C:\ProgramData\Clarity\outbox\", [StringComparison]::OrdinalIgnoreCase)
}
if([string]::IsNullOrWhiteSpace($pkt)){
  Write-Host "MAKE_PACKET_OUTPUT_BEGIN" -ForegroundColor DarkYellow
  foreach($x in @($pktOut)){ Write-Host $x }
  Write-Host "MAKE_PACKET_OUTPUT_END" -ForegroundColor DarkYellow
  throw "NO_PACKET_DIR_FOUND_IN_OUTPUT"
}
Write-Host ("PACKET_PATH=" + $pkt) -ForegroundColor Yellow

Write-Host "STEP2: verify_packet" -ForegroundColor DarkGray
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Verify -PacketRoot $pkt -RuntimeRoot $RuntimeRoot -Principal $Principal | Out-Host

$commitHashPath = Join-Path $pkt "payload\commit_hash.txt"
if(-not (Test-Path -LiteralPath $commitHashPath -PathType Leaf)){ throw ("MISSING_COMMIT_HASH_TXT: " + $commitHashPath) }
$commitHash = (Get-Content -Raw -LiteralPath $commitHashPath -Encoding UTF8).Trim()
if([string]::IsNullOrWhiteSpace($commitHash)){ throw "EMPTY_COMMIT_HASH" }
$sigRel = ("outbox/" + (Split-Path -Leaf $pkt) + "/signatures/ingest.sig")

Write-Host "STEP2: pledge_local" -ForegroundColor DarkGray
$pledgeOutRaw = @(& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Pledge -RuntimeRoot $RuntimeRoot -Tenant $Tenant -Principal $Principal -ProducerInstance $ProducerInstance -CommitHash $commitHash -SigPath $sigRel -KeyId "clarity-dev-ed25519")
$pledgeOut = @(Get-TrimmedNonEmptyLines -InputObjects $pledgeOutRaw)
$pledgeHash = Get-LastMatchingLine -Lines $pledgeOut -Predicate {
  param($line)
  $line -match "^[0-9a-f]{64}$"
}
if([string]::IsNullOrWhiteSpace($pledgeHash)){
  Write-Host "PLEDGE_OUTPUT_BEGIN" -ForegroundColor DarkYellow
  foreach($x in @($pledgeOut)){ Write-Host $x }
  Write-Host "PLEDGE_OUTPUT_END" -ForegroundColor DarkYellow
  throw "NO_PLEDGE_HASH_FOUND_IN_OUTPUT"
}
Write-Host ("PLEDGE_HASH=" + $pledgeHash) -ForegroundColor Yellow

if (Test-Path -LiteralPath $NflInbox -PathType Container) {
  Write-Host "STEP2: duplicate_to_nfl" -ForegroundColor DarkGray
  & $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Dup -PacketRoot $pkt -NflInbox $NflInbox | Out-Host
} else {
  Write-Host "NFL_OPTIONAL_ABSENT_OK" -ForegroundColor DarkGray
}

$pledgeLog = Join-Path $RuntimeRoot "pledges\pledges.ndjson"
if(-not (Test-Path -LiteralPath $pledgeLog -PathType Leaf)){ throw ("MISSING_PLEDGE_LOG: " + $pledgeLog) }
$pledgeLines = @((Get-Content -LiteralPath $pledgeLog -Encoding UTF8) | Where-Object { $_ -and $_.Trim() -ne "" })
if($pledgeLines.Count -le 0){ throw "EMPTY_PLEDGE_LOG" }
$lastLine = $pledgeLines[$pledgeLines.Count - 1]
$lastObj = $lastLine | ConvertFrom-Json
if([string]$lastObj.commit_hash -ne $commitHash){ throw "PLEDGE_POSTCHECK_COMMIT_HASH_MISMATCH" }
Write-Host "CLARITY_TIER0_STEP2_OK" -ForegroundColor Green
