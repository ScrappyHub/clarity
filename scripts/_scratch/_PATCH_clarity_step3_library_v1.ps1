param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dir([string]$Path){
  if([string]::IsNullOrWhiteSpace($Path)){ throw "ENSURE_DIR_EMPTY" }
  if(-not (Test-Path -LiteralPath $Path -PathType Container)){
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ Ensure-Dir $dir }
  $t = $Text.Replace("`r`n","`n").Replace("`r","`n")
  if(-not $t.EndsWith("`n")){ $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllBytes($Path,$enc.GetBytes($t))
}

function Parse-GatePs1([string]$Path){
  $tok = $null
  $err = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err)
  $errs = @(@($err))
  if($errs.Count -gt 0){
    $msg = ($errs | ForEach-Object { $_.ToString() }) -join "`n"
    throw ("PARSEGATE_FAIL: " + $Path + "`n" + $msg)
  }
}

function Write-Script([string]$Path,[string[]]$Lines){
  $txt = (($Lines -join "`n") + "`n")
  Write-Utf8NoBomLf -Path $Path -Text $txt
  Parse-GatePs1 -Path $Path
}

$ScriptsDir = Join-Path $RepoRoot "scripts"
Ensure-Dir $ScriptsDir

$PutPath = Join-Path $ScriptsDir "library_put.ps1"
$GetPath = Join-Path $ScriptsDir "library_get.ps1"
$RunPath = Join-Path $ScriptsDir "_RUN_clarity_tier0_step3_v1.ps1"

$Put = @(
'param('
'  [Parameter(Mandatory=$true)][string]$RuntimeRoot,'
'  [Parameter(Mandatory=$true)][string]$InputPath,'
'  [Parameter(Mandatory=$true)][string]$Tenant,'
'  [Parameter(Mandatory=$true)][string]$Principal,'
'  [Parameter(Mandatory=$true)][string]$ProducerInstance,'
'  [switch]$Sealed'
')'
'Set-StrictMode -Version Latest'
'$ErrorActionPreference="Stop"'
'. "$PSScriptRoot\lib\canon.ps1"'
'function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }'
'if(-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)){ throw ("MISSING_RUNTIME_ROOT: " + $RuntimeRoot) }'
'if(-not (Test-Path -LiteralPath $InputPath -PathType Leaf)){ throw ("MISSING_INPUT: " + $InputPath) }'
'$ledgerDir = Join-Path $RuntimeRoot "library\ledger"'
'$objectsRoot = Join-Path $RuntimeRoot "library\objects\sha256"'
'EnsureDir $ledgerDir'
'EnsureDir $objectsRoot'
'$objHash = Sha256HexFile $InputPath'
'$prefix = $objHash.Substring(0,2)'
'$objDir = Join-Path (Join-Path $objectsRoot $prefix) $objHash'
'EnsureDir $objDir'
'$contentPath = Join-Path $objDir "content.bin"'
'Copy-Item -LiteralPath $InputPath -Destination $contentPath -Force'
'$contentRef = ("cas:sha256:" + $objHash)'
'$metaObj = [ordered]@{'
'  schema = "clarity.library_object_meta.v1"'
'  object_sha256 = $objHash'
'  content_ref = $contentRef'
'  stored_name = (Split-Path -Leaf $InputPath)'
'  stored_bytes = [int](Get-Item -LiteralPath $contentPath).Length'
'  sealed = [bool]$Sealed'
'  tenant = $Tenant'
'  principal = $Principal'
'  producer_instance = $ProducerInstance'
'  stored_at_utc = UtcNow'
'}'
'$metaJson = ($metaObj | ConvertTo-Json -Compress)'
'WriteUtf8NoBomLf (Join-Path $objDir "meta.json") $metaJson'
'$ledgerPath = Join-Path $ledgerDir "library.ndjson"'
'$prevLogHash = "GENESIS"'
'$seq = 1'
'if(Test-Path -LiteralPath $ledgerPath -PathType Leaf){'
'  $existing = @((Get-Content -LiteralPath $ledgerPath -Encoding UTF8) | Where-Object { $_ -and $_.Trim() -ne "" })'
'  if($existing.Count -gt 0){'
'    $last = $existing[$existing.Count - 1] | ConvertFrom-Json'
'    $prevLogHash = [string]$last.log_hash'
'    $seq = [int]$last.seq + 1'
'  }'
'}'
'$eventType = "clarity.library.object.added.v1"'
'if($Sealed){ $eventType = "clarity.library.object.sealed.v1" }'
'$lineObj = [ordered]@{'
'  schema = "clarity.library_ledger.v1"'
'  seq = $seq'
'  created_at_utc = UtcNow'
'  event_type = $eventType'
'  object_sha256 = $objHash'
'  content_ref = $contentRef'
'  content_path = ("library/objects/sha256/" + $prefix + "/" + $objHash + "/content.bin")'
'  sealed = [bool]$Sealed'
'  tenant = $Tenant'
'  principal = $Principal'
'  producer_instance = $ProducerInstance'
'  prev_log_hash = $prevLogHash'
'}'
'$lineJsonNoHash = ($lineObj | ConvertTo-Json -Compress)'
'$logHash = Sha256HexTextNormalized $lineJsonNoHash'
'$lineObj["log_hash"] = $logHash'
'$lineJson = ($lineObj | ConvertTo-Json -Compress)'
'if(Test-Path -LiteralPath $ledgerPath -PathType Leaf){'
'  $existingRaw = Get-Content -Raw -LiteralPath $ledgerPath -Encoding UTF8'
'} else {'
'  $existingRaw = ""'
'}'
'WriteUtf8NoBomLf $ledgerPath ($existingRaw + $lineJson + "`n")'
'Write-Host ("LIBRARY_PUT_OK: " + $contentRef) -ForegroundColor Green'
'Write-Output $contentRef'
)

$Get = @(
'param('
'  [Parameter(Mandatory=$true)][string]$RuntimeRoot,'
'  [Parameter(Mandatory=$true)][string]$ContentRef,'
'  [Parameter(Mandatory=$true)][string]$GrantId'
')'
'Set-StrictMode -Version Latest'
'$ErrorActionPreference="Stop"'
'. "$PSScriptRoot\lib\canon.ps1"'
'if(-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)){ throw ("MISSING_RUNTIME_ROOT: " + $RuntimeRoot) }'
'if($ContentRef -notmatch "^cas:sha256:([0-9a-f]{64})$"){ throw ("BAD_CONTENT_REF: " + $ContentRef) }'
'$objHash = $Matches[1]'
'$grantPath = Join-Path $RuntimeRoot ("library\access\sessions\" + $GrantId + ".json")'
'if(-not (Test-Path -LiteralPath $grantPath -PathType Leaf)){ throw ("ACCESS_DENIED_MISSING_GRANT: " + $GrantId) }'
'$grant = Get-Content -Raw -LiteralPath $grantPath -Encoding UTF8 | ConvertFrom-Json'
'if(-not [bool]$grant.verified){ throw "ACCESS_DENIED_UNVERIFIED_GRANT" }'
'if([string]$grant.content_ref -ne $ContentRef){ throw "ACCESS_DENIED_CONTENT_REF_MISMATCH" }'
'$prefix = $objHash.Substring(0,2)'
'$objDir = Join-Path (Join-Path (Join-Path $RuntimeRoot "library\objects\sha256") $prefix) $objHash'
'if(-not (Test-Path -LiteralPath $objDir -PathType Container)){ throw ("MISSING_OBJECT_DIR: " + $objDir) }'
'$contentPath = Join-Path $objDir "content.bin"'
'if(-not (Test-Path -LiteralPath $contentPath -PathType Leaf)){ throw ("MISSING_OBJECT_CONTENT: " + $contentPath) }'
'Write-Host ("LIBRARY_GET_OK: " + $ContentRef) -ForegroundColor Green'
'Write-Output $contentPath'
)

$Run = @(
'param([Parameter(Mandatory=$true)][string]$RepoRoot)'
'Set-StrictMode -Version Latest'
'$ErrorActionPreference="Stop"'
'$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source'
'$RuntimeRoot = "C:\ProgramData\Clarity"'
'$NflInbox = "C:\ProgramData\NFL\inbox"'
'$Principal = "single-tenant/operator/user/alec"'
'$Tenant = "single-tenant"'
'$ProducerInstance = ("{0}-standalone-1" -f $env:COMPUTERNAME)'
'$Bootstrap = Join-Path $RepoRoot "scripts\_bootstrap_clarity_standalone_v1.ps1"'
'$Put = Join-Path $RepoRoot "scripts\library_put.ps1"'
'$Get = Join-Path $RepoRoot "scripts\library_get.ps1"'
'$Make = Join-Path $RepoRoot "scripts\make_packet.ps1"'
'$Verify = Join-Path $RepoRoot "scripts\verify_packet.ps1"'
'$Pledge = Join-Path $RepoRoot "scripts\pledge_local.ps1"'
'$Dup = Join-Path $RepoRoot "scripts\duplicate_to_nfl.ps1"'
'Write-Host "STEP3: bootstrap" -ForegroundColor DarkGray'
'& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Bootstrap -RepoRoot $RepoRoot | Out-Host'
'$libraryLedger = Join-Path $RuntimeRoot "library\ledger\library.ndjson"'
'$beforeCount = 0'
'if(Test-Path -LiteralPath $libraryLedger -PathType Leaf){'
'  $beforeCount = @((Get-Content -LiteralPath $libraryLedger -Encoding UTF8) | Where-Object { $_ -and $_.Trim() -ne "" }).Count'
'}'
'$tmpArtifact = Join-Path $env:TEMP ("clarity_library_artifact_" + [Guid]::NewGuid().ToString("N") + ".ndjson")'
'$artifactLine = ''{"schema":"clarity.transcript.v1","seq":1,"type":"clarity.verification.result.v1","ok":true}'''
'$enc = New-Object System.Text.UTF8Encoding($false)'
'[IO.File]::WriteAllBytes($tmpArtifact,$enc.GetBytes($artifactLine + "`n"))'
'Write-Host "STEP3: library_put" -ForegroundColor DarkGray'
'$putOut = @(& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Put -RuntimeRoot $RuntimeRoot -InputPath $tmpArtifact -Tenant $Tenant -Principal $Principal -ProducerInstance $ProducerInstance -Sealed)'
'$contentRef = @($putOut | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -match "^cas:sha256:[0-9a-f]{64}$" })[-1]'
'if(-not $contentRef){ throw "NO_CONTENT_REF_FOUND" }'
'Write-Host ("CONTENT_REF=" + $contentRef) -ForegroundColor Yellow'
'$grantId = [Guid]::NewGuid().ToString("N")'
'$grantPath = Join-Path $RuntimeRoot ("library\access\sessions\" + $grantId + ".json")'
'$grantObj = [ordered]@{ schema="clarity.access_grant.v1"; grant_id=$grantId; principal=$Principal; verified=$true; content_ref=$contentRef; created_at_utc=(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }'
'$grantJson = ($grantObj | ConvertTo-Json -Compress)'
'[IO.File]::WriteAllBytes($grantPath,$enc.GetBytes($grantJson + "`n"))'
'Write-Host ("GRANT_ID=" + $grantId) -ForegroundColor Yellow'
'Write-Host "STEP3: library_get" -ForegroundColor DarkGray'
'$getOut = @(& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Get -RuntimeRoot $RuntimeRoot -ContentRef $contentRef -GrantId $grantId)'
'$retrievedPath = @($getOut | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })[-1]'
'if(-not $retrievedPath){ throw "NO_RETRIEVED_PATH_FOUND" }'
'if((Get-Content -Raw -LiteralPath $retrievedPath -Encoding UTF8).Trim() -ne $artifactLine){ throw "RETRIEVED_CONTENT_MISMATCH" }'
'Write-Host "STEP3: make_packet" -ForegroundColor DarkGray'
'$pktOut = @(& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Make -RuntimeRoot $RuntimeRoot -Tenant $Tenant -Principal $Principal -ProducerInstance $ProducerInstance -EventType "clarity.library.object.sealed.v1" -ContentRef $contentRef -Strength "evidence")'
'$pkt = @($pktOut | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) -and $_.StartsWith("C:\ProgramData\Clarity\outbox\", [StringComparison]::OrdinalIgnoreCase) })[-1]'
'if(-not $pkt){ throw "NO_PACKET_DIR_FOUND_IN_OUTPUT" }'
'Write-Host ("PACKET_PATH=" + $pkt) -ForegroundColor Yellow'
'Write-Host "STEP3: verify_packet" -ForegroundColor DarkGray'
'& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Verify -PacketRoot $pkt -RuntimeRoot $RuntimeRoot -Principal $Principal | Out-Host'
'$commitHash = (Get-Content -Raw -LiteralPath (Join-Path $pkt "payload\commit_hash.txt") -Encoding UTF8).Trim()'
'Write-Host "STEP3: pledge_local" -ForegroundColor DarkGray'
'$pledgeOut = @(& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Pledge -RuntimeRoot $RuntimeRoot -Tenant $Tenant -Principal $Principal -ProducerInstance $ProducerInstance -CommitHash $commitHash -SigPath ("outbox/" + (Split-Path -Leaf $pkt) + "/signatures/ingest.sig") -KeyId "clarity-dev-ed25519")'
'$pledgeHash = @($pledgeOut | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -match "^[0-9a-f]{64}$" })[-1]'
'if(-not $pledgeHash){ throw "NO_PLEDGE_HASH_FOUND" }'
'Write-Host ("PLEDGE_HASH=" + $pledgeHash) -ForegroundColor Yellow'
'if(Test-Path -LiteralPath $NflInbox -PathType Container){'
'  Write-Host "STEP3: duplicate_to_nfl" -ForegroundColor DarkGray'
'  & $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Dup -PacketRoot $pkt -NflInbox $NflInbox | Out-Host'
'} else {'
'  Write-Host "NFL_OPTIONAL_ABSENT_OK" -ForegroundColor DarkGray'
'}'
'$afterLines = @((Get-Content -LiteralPath $libraryLedger -Encoding UTF8) | Where-Object { $_ -and $_.Trim() -ne "" })'
'if($afterLines.Count -le $beforeCount){ throw "LIBRARY_LEDGER_NOT_APPENDED" }'
'$lastLibraryObj = $afterLines[$afterLines.Count - 1] | ConvertFrom-Json'
'if([string]$lastLibraryObj.content_ref -ne $contentRef){ throw "LIBRARY_LEDGER_CONTENT_REF_MISMATCH" }'
'$pledgeLog = Join-Path $RuntimeRoot "pledges\pledges.ndjson"'
'if(-not (Test-Path -LiteralPath $pledgeLog -PathType Leaf)){ throw ("MISSING_PLEDGE_LOG: " + $pledgeLog) }'
'$pledgeLines = @((Get-Content -LiteralPath $pledgeLog -Encoding UTF8) | Where-Object { $_ -and $_.Trim() -ne "" })'
'if($pledgeLines.Count -le 0){ throw "EMPTY_PLEDGE_LOG" }'
'$lastPledgeObj = $pledgeLines[$pledgeLines.Count - 1] | ConvertFrom-Json'
'if([string]$lastPledgeObj.commit_hash -ne $commitHash){ throw "PLEDGE_POSTCHECK_COMMIT_HASH_MISMATCH" }'
'Write-Host "CLARITY_TIER0_STEP3_OK" -ForegroundColor Green'
)

Write-Script -Path $PutPath -Lines $Put
Write-Script -Path $GetPath -Lines $Get
Write-Script -Path $RunPath -Lines $Run

Write-Host ("PATCH_OK: wrote " + $PutPath) -ForegroundColor Green
Write-Host ("PATCH_OK: wrote " + $GetPath) -ForegroundColor Green
Write-Host ("PATCH_OK: wrote " + $RunPath) -ForegroundColor Green