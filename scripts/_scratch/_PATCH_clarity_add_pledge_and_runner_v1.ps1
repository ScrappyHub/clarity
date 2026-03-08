param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dir {
  param([Parameter(Mandatory=$true)][string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { throw "ENSURE_DIR_EMPTY" }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Write-Utf8NoBomLf {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Text
  )
  $dir = Split-Path -Parent $Path
  if ($dir) { Ensure-Dir -Path $dir }
  $norm = $Text.Replace("`r`n","`n").Replace("`r","`n")
  if (-not $norm.EndsWith("`n")) { $norm += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllBytes($Path, $enc.GetBytes($norm))
}

function Parse-GatePs1 {
  param([Parameter(Mandatory=$true)][string]$Path)
  $tok = $null
  $err = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err)
  $errs = @(@($err))
  if ($errs.Count -gt 0) {
    $msg = ($errs | ForEach-Object { $_.ToString() }) -join "`n"
    throw ("PARSEGATE_FAIL: " + $Path + "`n" + $msg)
  }
}

function Write-Script {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string[]]$Lines
  )
  Write-Utf8NoBomLf -Path $Path -Text (($Lines -join "`n") + "`n")
  Parse-GatePs1 -Path $Path
}

$ScriptsDir = Join-Path $RepoRoot "scripts"
$PledgePath = Join-Path $ScriptsDir "pledge_local.ps1"
$RunPath    = Join-Path $ScriptsDir "_RUN_clarity_tier0_step2_v1.ps1"

# ---------------- pledge_local.ps1 ----------------
$Pledge = New-Object System.Collections.Generic.List[string]
[void]$Pledge.Add('param(')
[void]$Pledge.Add('  [Parameter(Mandatory=$true)][string]$RuntimeRoot,')
[void]$Pledge.Add('  [Parameter(Mandatory=$true)][string]$Tenant,')
[void]$Pledge.Add('  [Parameter(Mandatory=$true)][string]$Principal,')
[void]$Pledge.Add('  [Parameter(Mandatory=$true)][string]$ProducerInstance,')
[void]$Pledge.Add('  [Parameter(Mandatory=$true)][string]$CommitHash,')
[void]$Pledge.Add('  [Parameter(Mandatory=$true)][string]$SigPath,')
[void]$Pledge.Add('  [Parameter(Mandatory=$true)][string]$KeyId')
[void]$Pledge.Add(')')
[void]$Pledge.Add('Set-StrictMode -Version Latest')
[void]$Pledge.Add('$ErrorActionPreference = "Stop"')
[void]$Pledge.Add('. "$PSScriptRoot\lib\canon.ps1"')
[void]$Pledge.Add('function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }')
[void]$Pledge.Add('$logPath = Join-Path $RuntimeRoot "pledges\pledges.ndjson"')
[void]$Pledge.Add('Ensure-Dir -Path (Split-Path -Parent $logPath)')
[void]$Pledge.Add('$prevLogHash = "GENESIS"')
[void]$Pledge.Add('$seq = 1')
[void]$Pledge.Add('if (Test-Path -LiteralPath $logPath -PathType Leaf) {')
[void]$Pledge.Add('  $existingLines = @((Get-Content -LiteralPath $logPath -Encoding UTF8) | Where-Object { $_ -and $_.Trim() -ne "" })')
[void]$Pledge.Add('  if ($existingLines.Count -gt 0) {')
[void]$Pledge.Add('    $last = $existingLines[-1] | ConvertFrom-Json')
[void]$Pledge.Add('    $prevLogHash = [string]$last.log_hash')
[void]$Pledge.Add('    $seq = [int]$last.seq + 1')
[void]$Pledge.Add('  }')
[void]$Pledge.Add('}')
[void]$Pledge.Add('$obj = [ordered]@{')
[void]$Pledge.Add('  schema = "local_pledge.v1"')
[void]$Pledge.Add('  created_at_utc = (UtcNow)')
[void]$Pledge.Add('  seq = $seq')
[void]$Pledge.Add('  producer = "clarity"')
[void]$Pledge.Add('  producer_instance = $ProducerInstance')
[void]$Pledge.Add('  tenant = $Tenant')
[void]$Pledge.Add('  principal = $Principal')
[void]$Pledge.Add('  key_id = $KeyId')
[void]$Pledge.Add('  commit_hash = $CommitHash')
[void]$Pledge.Add('  sig_path = $SigPath')
[void]$Pledge.Add('  prev_log_hash = $prevLogHash')
[void]$Pledge.Add('}')
[void]$Pledge.Add('$jsonNoHash = ($obj | ConvertTo-Json -Compress)')
[void]$Pledge.Add('$logHash = Sha256HexTextNormalized $jsonNoHash')
[void]$Pledge.Add('$obj["log_hash"] = $logHash')
[void]$Pledge.Add('$line = ($obj | ConvertTo-Json -Compress)')
[void]$Pledge.Add('$existing = ""')
[void]$Pledge.Add('if (Test-Path -LiteralPath $logPath -PathType Leaf) { $existing = Get-Content -Raw -LiteralPath $logPath -Encoding UTF8 }')
[void]$Pledge.Add('WriteUtf8NoBomLf -Path $logPath -Text ($existing + $line + "`n")')
[void]$Pledge.Add('Write-Host ("PLEDGE_OK seq=" + $seq + " hash=" + $logHash) -ForegroundColor Green')
[void]$Pledge.Add('Write-Output $logHash')
Write-Script -Path $PledgePath -Lines $Pledge

# ---------------- _RUN_clarity_tier0_step2_v1.ps1 ----------------
$Run = New-Object System.Collections.Generic.List[string]
[void]$Run.Add('param([Parameter(Mandatory=$true)][string]$RepoRoot)')
[void]$Run.Add('Set-StrictMode -Version Latest')
[void]$Run.Add('$ErrorActionPreference = "Stop"')
[void]$Run.Add('$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source')
[void]$Run.Add('$Bootstrap = Join-Path $RepoRoot "scripts\_bootstrap_clarity_standalone_v1.ps1"')
[void]$Run.Add('$Make      = Join-Path $RepoRoot "scripts\make_packet.ps1"')
[void]$Run.Add('$Verify    = Join-Path $RepoRoot "scripts\verify_packet.ps1"')
[void]$Run.Add('$Pledge    = Join-Path $RepoRoot "scripts\pledge_local.ps1"')
[void]$Run.Add('$Dup       = Join-Path $RepoRoot "scripts\duplicate_to_nfl.ps1"')
[void]$Run.Add('$RuntimeRoot = "C:\ProgramData\Clarity"')
[void]$Run.Add('$Tenant = "single-tenant"')
[void]$Run.Add('$Principal = "single-tenant/operator/user/alec"')
[void]$Run.Add('$ProducerInstance = ("{0}-standalone-1" -f $env:COMPUTERNAME)')
[void]$Run.Add('$NflInbox = "C:\ProgramData\NFL\inbox"')
[void]$Run.Add('foreach($p in @($Bootstrap,$Make,$Verify,$Pledge,$Dup)){ if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ throw ("MISSING_SCRIPT: " + $p) } }')
[void]$Run.Add('& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Bootstrap -RepoRoot $RepoRoot | Out-Host')
[void]$Run.Add('$pktOut = @(& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Make -RuntimeRoot $RuntimeRoot -Tenant $Tenant -Principal $Principal -ProducerInstance $ProducerInstance -EventType "clarity.run.started.v1" -ContentRef "cas:sha256:deadbeef" -Strength "evidence")')
[void]$Run.Add('$pkt = @($pktOut | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) -and $_.StartsWith("C:\ProgramData\Clarity\outbox\", [StringComparison]::OrdinalIgnoreCase) })[-1]')
[void]$Run.Add('if(-not $pkt){ throw "NO_PACKET_DIR_FOUND_IN_OUTPUT" }')
[void]$Run.Add('Write-Host ("PACKET_PATH=" + $pkt) -ForegroundColor Yellow')
[void]$Run.Add('& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Verify -PacketRoot $pkt -RuntimeRoot $RuntimeRoot -Principal $Principal | Out-Host')
[void]$Run.Add('$commitHashPath = Join-Path $pkt "payload\commit_hash.txt"')
[void]$Run.Add('if(-not (Test-Path -LiteralPath $commitHashPath -PathType Leaf)){ throw ("MISSING_COMMIT_HASH_TXT: " + $commitHashPath) }')
[void]$Run.Add('$commitHash = (Get-Content -Raw -LiteralPath $commitHashPath -Encoding UTF8).Trim()')
[void]$Run.Add('$sigRel = ("outbox/" + (Split-Path -Leaf $pkt) + "/signatures/ingest.sig")')
[void]$Run.Add('$pledgeOut = @(& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Pledge -RuntimeRoot $RuntimeRoot -Tenant $Tenant -Principal $Principal -ProducerInstance $ProducerInstance -CommitHash $commitHash -SigPath $sigRel -KeyId "clarity-dev-ed25519")')
[void]$Run.Add('$pledgeHash = @($pledgeOut | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -and $_ -match "^[0-9a-f]{64}$" })[-1]')
[void]$Run.Add('if(-not $pledgeHash){ throw "NO_PLEDGE_HASH_FOUND_IN_OUTPUT" }')
[void]$Run.Add('Write-Host ("PLEDGE_HASH=" + $pledgeHash) -ForegroundColor Yellow')
[void]$Run.Add('if (Test-Path -LiteralPath $NflInbox -PathType Container) {')
[void]$Run.Add('  & $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Dup -PacketRoot $pkt -NflInbox $NflInbox | Out-Host')
[void]$Run.Add('} else {')
[void]$Run.Add('  Write-Host "NFL_OPTIONAL_ABSENT_OK" -ForegroundColor DarkGray')
[void]$Run.Add('}')
[void]$Run.Add('$pledgeLog = Join-Path $RuntimeRoot "pledges\pledges.ndjson"')
[void]$Run.Add('if(-not (Test-Path -LiteralPath $pledgeLog -PathType Leaf)){ throw ("MISSING_PLEDGE_LOG: " + $pledgeLog) }')
[void]$Run.Add('$lastLine = @((Get-Content -LiteralPath $pledgeLog -Encoding UTF8) | Where-Object { $_ -and $_.Trim() -ne "" })[-1]')
[void]$Run.Add('if(-not $lastLine){ throw "EMPTY_PLEDGE_LOG" }')
[void]$Run.Add('$lastObj = $lastLine | ConvertFrom-Json')
[void]$Run.Add('if([string]$lastObj.commit_hash -ne $commitHash){ throw "PLEDGE_POSTCHECK_COMMIT_HASH_MISMATCH" }')
[void]$Run.Add('Write-Host "CLARITY_TIER0_STEP2_OK" -ForegroundColor Green')
Write-Script -Path $RunPath -Lines $Run

Write-Host ("PATCH_OK: wrote " + $PledgePath) -ForegroundColor Green
Write-Host ("PATCH_OK: wrote " + $RunPath) -ForegroundColor Green
