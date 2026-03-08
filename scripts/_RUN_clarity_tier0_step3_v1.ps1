param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source
$RuntimeRoot = "C:\ProgramData\Clarity"
$NflInbox = "C:\ProgramData\NFL\inbox"
$Principal = "single-tenant/operator/user/alec"
$Tenant = "single-tenant"
$ProducerInstance = ("{0}-standalone-1" -f $env:COMPUTERNAME)
$Bootstrap = Join-Path $RepoRoot "scripts\_bootstrap_clarity_standalone_v1.ps1"
$Put = Join-Path $RepoRoot "scripts\library_put.ps1"
$Get = Join-Path $RepoRoot "scripts\library_get.ps1"
$Make = Join-Path $RepoRoot "scripts\make_packet.ps1"
$Verify = Join-Path $RepoRoot "scripts\verify_packet.ps1"
$Pledge = Join-Path $RepoRoot "scripts\pledge_local.ps1"
$Dup = Join-Path $RepoRoot "scripts\duplicate_to_nfl.ps1"
Write-Host "STEP3: bootstrap" -ForegroundColor DarkGray
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Bootstrap -RepoRoot $RepoRoot | Out-Host
$libraryLedger = Join-Path $RuntimeRoot "library\ledger\library.ndjson"
$beforeCount = 0
if(Test-Path -LiteralPath $libraryLedger -PathType Leaf){
  $beforeCount = @((Get-Content -LiteralPath $libraryLedger -Encoding UTF8) | Where-Object { $_ -and $_.Trim() -ne "" }).Count
}
$tmpArtifact = Join-Path $env:TEMP ("clarity_library_artifact_" + [Guid]::NewGuid().ToString("N") + ".ndjson")
$artifactLine = '{"schema":"clarity.transcript.v1","seq":1,"type":"clarity.verification.result.v1","ok":true}'
$enc = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllBytes($tmpArtifact,$enc.GetBytes($artifactLine + "`n"))
Write-Host "STEP3: library_put" -ForegroundColor DarkGray
$putOut = @(& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Put -RuntimeRoot $RuntimeRoot -InputPath $tmpArtifact -Tenant $Tenant -Principal $Principal -ProducerInstance $ProducerInstance -Sealed)
$contentRef = @($putOut | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -match "^cas:sha256:[0-9a-f]{64}$" })[-1]
if(-not $contentRef){ throw "NO_CONTENT_REF_FOUND" }
Write-Host ("CONTENT_REF=" + $contentRef) -ForegroundColor Yellow
$grantId = [Guid]::NewGuid().ToString("N")
$grantPath = Join-Path $RuntimeRoot ("library\access\sessions\" + $grantId + ".json")
$grantObj = [ordered]@{ schema="clarity.access_grant.v1"; grant_id=$grantId; principal=$Principal; verified=$true; content_ref=$contentRef; created_at_utc=(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
$grantJson = ($grantObj | ConvertTo-Json -Compress)
[IO.File]::WriteAllBytes($grantPath,$enc.GetBytes($grantJson + "`n"))
Write-Host ("GRANT_ID=" + $grantId) -ForegroundColor Yellow
Write-Host "STEP3: library_get" -ForegroundColor DarkGray
$getOut = @(& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Get -RuntimeRoot $RuntimeRoot -ContentRef $contentRef -GrantId $grantId)
$retrievedPath = @($getOut | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })[-1]
if(-not $retrievedPath){ throw "NO_RETRIEVED_PATH_FOUND" }
if((Get-Content -Raw -LiteralPath $retrievedPath -Encoding UTF8).Trim() -ne $artifactLine){ throw "RETRIEVED_CONTENT_MISMATCH" }
Write-Host "STEP3: make_packet" -ForegroundColor DarkGray
$pktOut = @(& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Make -RuntimeRoot $RuntimeRoot -Tenant $Tenant -Principal $Principal -ProducerInstance $ProducerInstance -EventType "clarity.library.object.sealed.v1" -ContentRef $contentRef -Strength "evidence")
$pkt = @($pktOut | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) -and $_.StartsWith("C:\ProgramData\Clarity\outbox\", [StringComparison]::OrdinalIgnoreCase) })[-1]
if(-not $pkt){ throw "NO_PACKET_DIR_FOUND_IN_OUTPUT" }
Write-Host ("PACKET_PATH=" + $pkt) -ForegroundColor Yellow
Write-Host "STEP3: verify_packet" -ForegroundColor DarkGray
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Verify -PacketRoot $pkt -RuntimeRoot $RuntimeRoot -Principal $Principal | Out-Host
$commitHash = (Get-Content -Raw -LiteralPath (Join-Path $pkt "payload\commit_hash.txt") -Encoding UTF8).Trim()
Write-Host "STEP3: pledge_local" -ForegroundColor DarkGray
$pledgeOut = @(& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Pledge -RuntimeRoot $RuntimeRoot -Tenant $Tenant -Principal $Principal -ProducerInstance $ProducerInstance -CommitHash $commitHash -SigPath ("outbox/" + (Split-Path -Leaf $pkt) + "/signatures/ingest.sig") -KeyId "clarity-dev-ed25519")
$pledgeHash = @($pledgeOut | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -match "^[0-9a-f]{64}$" })[-1]
if(-not $pledgeHash){ throw "NO_PLEDGE_HASH_FOUND" }
Write-Host ("PLEDGE_HASH=" + $pledgeHash) -ForegroundColor Yellow
if(Test-Path -LiteralPath $NflInbox -PathType Container){
  Write-Host "STEP3: duplicate_to_nfl" -ForegroundColor DarkGray
  & $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Dup -PacketRoot $pkt -NflInbox $NflInbox | Out-Host
} else {
  Write-Host "NFL_OPTIONAL_ABSENT_OK" -ForegroundColor DarkGray
}
$afterLines = @((Get-Content -LiteralPath $libraryLedger -Encoding UTF8) | Where-Object { $_ -and $_.Trim() -ne "" })
if($afterLines.Count -le $beforeCount){ throw "LIBRARY_LEDGER_NOT_APPENDED" }
$lastLibraryObj = $afterLines[$afterLines.Count - 1] | ConvertFrom-Json
if([string]$lastLibraryObj.content_ref -ne $contentRef){ throw "LIBRARY_LEDGER_CONTENT_REF_MISMATCH" }
$pledgeLog = Join-Path $RuntimeRoot "pledges\pledges.ndjson"
if(-not (Test-Path -LiteralPath $pledgeLog -PathType Leaf)){ throw ("MISSING_PLEDGE_LOG: " + $pledgeLog) }
$pledgeLines = @((Get-Content -LiteralPath $pledgeLog -Encoding UTF8) | Where-Object { $_ -and $_.Trim() -ne "" })
if($pledgeLines.Count -le 0){ throw "EMPTY_PLEDGE_LOG" }
$lastPledgeObj = $pledgeLines[$pledgeLines.Count - 1] | ConvertFrom-Json
if([string]$lastPledgeObj.commit_hash -ne $commitHash){ throw "PLEDGE_POSTCHECK_COMMIT_HASH_MISMATCH" }
Write-Host "CLARITY_TIER0_STEP3_OK" -ForegroundColor Green
