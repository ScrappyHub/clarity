param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source
$ScriptsDir = Join-Path $RepoRoot "scripts"
$PledgePath = Join-Path $ScriptsDir "pledge_local.ps1"
$RunPath    = Join-Path $ScriptsDir "_RUN_clarity_tier0_step2_v1.ps1"
$CanonPath  = Join-Path $ScriptsDir "lib\canon.ps1"
if(-not (Test-Path -LiteralPath $CanonPath -PathType Leaf)){ throw ("MISSING_CANON_LIB: " + $CanonPath) }

function Ensure-Dir {
  param([Parameter(Mandatory=$true)][string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { throw "ENSURE_DIR_EMPTY" }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}
function Write-Utf8NoBomLf {
  param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Text)
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
  param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string[]]$Lines)
  $txt = (($Lines -join "`n") + "`n")
  Write-Utf8NoBomLf -Path $Path -Text $txt
  Parse-GatePs1 -Path $Path
}

# --- pledge_local.ps1 ---
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
[void]$Pledge.Add('$log = Join-Path $RuntimeRoot "pledges\pledges.ndjson"')
[void]$Pledge.Add('EnsureDir (Split-Path -Parent $log)')
[void]$Pledge.Add('$prevLogHash = "GENESIS"')
[void]$Pledge.Add('$seq = 1')
[void]$Pledge.Add('if(Test-Path -LiteralPath $log -PathType Leaf){')
[void]$Pledge.Add('  $existingLines = @((Get-Content -LiteralPath $log -Encoding UTF8) | Where-Object { $_ -and $_.Trim() -ne "" })')
[void]$Pledge.Add('  if($existingLines.Count -gt 0){')
[void]$Pledge.Add('    $last = $existingLines[$existingLines.Count - 1] | ConvertFrom-Json')
[void]$Pledge.Add('    $prevLogHash = [string]$last.log_hash')
[void]$Pledge.Add('    $seq = [int]$last.seq + 1')
[void]$Pledge.Add('  }')
[void]$Pledge.Add('}')
[void]$Pledge.Add('$obj = [ordered]@{')
[void]$Pledge.Add('  schema="local_pledge.v1"')
[void]$Pledge.Add('  created_at_utc=UtcNow' )
[void]$Pledge.Add('  seq=$seq')
[void]$Pledge.Add('  producer="clarity"')
[void]$Pledge.Add('  producer_instance=$ProducerInstance')
[void]$Pledge.Add('  tenant=$Tenant')
[void]$Pledge.Add('  principal=$Principal')
[void]$Pledge.Add('  key_id=$KeyId')
[void]$Pledge.Add('  commit_hash=$CommitHash')
[void]$Pledge.Add('  sig_path=$SigPath')
[void]$Pledge.Add('  prev_log_hash=$prevLogHash')
[void]$Pledge.Add('}')
[void]$Pledge.Add('$noHashJson = ($obj | ConvertTo-Json -Compress)')
[void]$Pledge.Add('$logHash = Sha256HexTextNormalized $noHashJson')
[void]$Pledge.Add('$obj["log_hash"] = $logHash')
[void]$Pledge.Add('$line = ($obj | ConvertTo-Json -Compress)')
[void]$Pledge.Add('$existingText = ""')
[void]$Pledge.Add('if(Test-Path -LiteralPath $log -PathType Leaf){ $existingText = Get-Content -Raw -LiteralPath $log -Encoding UTF8 }')
[void]$Pledge.Add('WriteUtf8NoBomLf $log ($existingText + $line + "`n")')
[void]$Pledge.Add('Write-Host ("PLEDGE_OK seq=" + $seq + " commit=" + $CommitHash) -ForegroundColor Green')
[void]$Pledge.Add('Write-Output $logHash')
Write-Script -Path $PledgePath -Lines $Pledge

# --- _RUN_clarity_tier0_step2_v1.ps1 ---
$Run = New-Object System.Collections.Generic.List[string]
[void]$Run.Add('param([Parameter(Mandatory=$true)][string]$RepoRoot)')
[void]$Run.Add('Set-StrictMode -Version Latest')
[void]$Run.Add('$ErrorActionPreference = "Stop"')
[void]$Run.Add('$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source')
[void]$Run.Add('function Get-TrimmedNonEmptyLines {')
[void]$Run.Add('  param([object[]]$InputObjects)')
[void]$Run.Add('  $out = New-Object System.Collections.Generic.List[string]')
[void]$Run.Add('  foreach($obj in @($InputObjects)){')
[void]$Run.Add('    if($null -eq $obj){ continue }')
[void]$Run.Add('    $s = $obj.ToString().Trim()')
[void]$Run.Add('    if(-not [string]::IsNullOrWhiteSpace($s)){ [void]$out.Add($s) }')
[void]$Run.Add('  }')
[void]$Run.Add('  return @($out.ToArray())')
[void]$Run.Add('}')
[void]$Run.Add('function Get-LastMatchingLine {')
[void]$Run.Add('  param([string[]]$Lines,[scriptblock]$Predicate)')
[void]$Run.Add('  $matches = New-Object System.Collections.Generic.List[string]')
[void]$Run.Add('  foreach($line in @($Lines)){ if(& $Predicate $line){ [void]$matches.Add($line) } }')
[void]$Run.Add('  if($matches.Count -le 0){ return $null }')
[void]$Run.Add('  return $matches[$matches.Count - 1]')
[void]$Run.Add('}')
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
[void]$Run.Add('Write-Host "STEP2: bootstrap" -ForegroundColor DarkGray')
[void]$Run.Add('& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Bootstrap -RepoRoot $RepoRoot | Out-Host')
[void]$Run.Add('Write-Host "STEP2: make_packet" -ForegroundColor DarkGray')
[void]$Run.Add('$pktOutRaw = @(& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Make -RuntimeRoot $RuntimeRoot -Tenant $Tenant -Principal $Principal -ProducerInstance $ProducerInstance -EventType "clarity.run.started.v1" -ContentRef "cas:sha256:deadbeef" -Strength "evidence")')
[void]$Run.Add('$pktOut = @(Get-TrimmedNonEmptyLines -InputObjects $pktOutRaw)')
[void]$Run.Add('$pkt = Get-LastMatchingLine -Lines $pktOut -Predicate { param($line) (Test-Path -LiteralPath $line -PathType Container) -and $line.StartsWith("C:\ProgramData\Clarity\outbox\", [StringComparison]::OrdinalIgnoreCase) }')
[void]$Run.Add('if([string]::IsNullOrWhiteSpace($pkt)){')
[void]$Run.Add('  Write-Host "MAKE_PACKET_OUTPUT_BEGIN" -ForegroundColor DarkYellow')
[void]$Run.Add('  foreach($x in @($pktOut)){ Write-Host $x }')
[void]$Run.Add('  Write-Host "MAKE_PACKET_OUTPUT_END" -ForegroundColor DarkYellow')
[void]$Run.Add('  throw "NO_PACKET_DIR_FOUND_IN_OUTPUT"')
[void]$Run.Add('}')
[void]$Run.Add('Write-Host ("PACKET_PATH=" + $pkt) -ForegroundColor Yellow')
[void]$Run.Add('Write-Host "STEP2: verify_packet" -ForegroundColor DarkGray')
[void]$Run.Add('& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Verify -PacketRoot $pkt -RuntimeRoot $RuntimeRoot -Principal $Principal | Out-Host')
[void]$Run.Add('$commitHashPath = Join-Path $pkt "payload\commit_hash.txt"')
[void]$Run.Add('if(-not (Test-Path -LiteralPath $commitHashPath -PathType Leaf)){ throw ("MISSING_COMMIT_HASH_TXT: " + $commitHashPath) }')
[void]$Run.Add('$commitHash = (Get-Content -Raw -LiteralPath $commitHashPath -Encoding UTF8).Trim()')
[void]$Run.Add('if([string]::IsNullOrWhiteSpace($commitHash)){ throw "EMPTY_COMMIT_HASH" }')
[void]$Run.Add('$sigRel = ("outbox/" + (Split-Path -Leaf $pkt) + "/signatures/ingest.sig")')
[void]$Run.Add('Write-Host "STEP2: pledge_local" -ForegroundColor DarkGray')
[void]$Run.Add('$pledgeOutRaw = @(& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Pledge -RuntimeRoot $RuntimeRoot -Tenant $Tenant -Principal $Principal -ProducerInstance $ProducerInstance -CommitHash $commitHash -SigPath $sigRel -KeyId "clarity-dev-ed25519")')
[void]$Run.Add('$pledgeOut = @(Get-TrimmedNonEmptyLines -InputObjects $pledgeOutRaw)')
[void]$Run.Add('$pledgeHash = Get-LastMatchingLine -Lines $pledgeOut -Predicate { param($line) $line -match "^[0-9a-f]{64}$" }')
[void]$Run.Add('if([string]::IsNullOrWhiteSpace($pledgeHash)){')
[void]$Run.Add('  Write-Host "PLEDGE_OUTPUT_BEGIN" -ForegroundColor DarkYellow')
[void]$Run.Add('  foreach($x in @($pledgeOut)){ Write-Host $x }')
[void]$Run.Add('  Write-Host "PLEDGE_OUTPUT_END" -ForegroundColor DarkYellow')
[void]$Run.Add('  throw "NO_PLEDGE_HASH_FOUND_IN_OUTPUT"')
[void]$Run.Add('}')
[void]$Run.Add('Write-Host ("PLEDGE_HASH=" + $pledgeHash) -ForegroundColor Yellow')
[void]$Run.Add('if (Test-Path -LiteralPath $NflInbox -PathType Container) {')
[void]$Run.Add('  Write-Host "STEP2: duplicate_to_nfl" -ForegroundColor DarkGray')
[void]$Run.Add('  & $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Dup -PacketRoot $pkt -NflInbox $NflInbox | Out-Host')
[void]$Run.Add('} else {')
[void]$Run.Add('  Write-Host "NFL_OPTIONAL_ABSENT_OK" -ForegroundColor DarkGray')
[void]$Run.Add('}')
[void]$Run.Add('$pledgeLog = Join-Path $RuntimeRoot "pledges\pledges.ndjson"')
[void]$Run.Add('if(-not (Test-Path -LiteralPath $pledgeLog -PathType Leaf)){ throw ("MISSING_PLEDGE_LOG: " + $pledgeLog) }')
[void]$Run.Add('$pledgeLines = @((Get-Content -LiteralPath $pledgeLog -Encoding UTF8) | Where-Object { $_ -and $_.Trim() -ne "" })')
[void]$Run.Add('if($pledgeLines.Count -le 0){ throw "EMPTY_PLEDGE_LOG" }')
[void]$Run.Add('$lastLine = $pledgeLines[$pledgeLines.Count - 1]')
[void]$Run.Add('$lastObj = $lastLine | ConvertFrom-Json')
[void]$Run.Add('if([string]$lastObj.commit_hash -ne $commitHash){ throw "PLEDGE_POSTCHECK_COMMIT_HASH_MISMATCH" }')
[void]$Run.Add('Write-Host "CLARITY_TIER0_STEP2_OK" -ForegroundColor Green')
Write-Script -Path $RunPath -Lines $Run

Write-Host ("PATCH_OK: wrote " + $PledgePath) -ForegroundColor Green
Write-Host ("PATCH_OK: wrote " + $RunPath) -ForegroundColor Green
