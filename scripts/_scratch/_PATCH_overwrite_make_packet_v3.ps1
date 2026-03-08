param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

function EnsureDir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ throw "ENSURE_DIR_EMPTY" }
  if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null }
}
function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $t = $Text.Replace("`r`n","`n").Replace("`r","`n")
  if(-not $t.EndsWith("`n")){ $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllBytes($Path,$enc.GetBytes($t))
}
function Parse-GatePs1([string]$Path){
  $tok=$null; $err=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err)
  $errs=@(@($err))
  if($errs -and $errs.Count -gt 0){
    $msg = ($errs | ForEach-Object { $_.ToString() }) -join "`n"
    throw ("PARSEGATE_FAIL: " + $Path + "`n" + $msg)
  }
}

$ScriptsDir = Join-Path $RepoRoot "scripts"
EnsureDir $ScriptsDir
$mkPath = Join-Path $ScriptsDir "make_packet.ps1"

$L = New-Object System.Collections.Generic.List[string]

[void]$L.Add('param(')
[void]$L.Add('  [Parameter(Mandatory=$true)][string]$RuntimeRoot,')
[void]$L.Add('  [Parameter(Mandatory=$true)][string]$Tenant,')
[void]$L.Add('  [Parameter(Mandatory=$true)][string]$Principal,')
[void]$L.Add('  [Parameter(Mandatory=$true)][string]$ProducerInstance,')
[void]$L.Add('  [Parameter(Mandatory=$true)][string]$EventType,')
[void]$L.Add('  [Parameter(Mandatory=$true)][string]$ContentRef,')
[void]$L.Add('  [Parameter(Mandatory=$true)][ValidateSet("evidence","deterministic")][string]$Strength')
[void]$L.Add(')')
[void]$L.Add('Set-StrictMode -Version Latest')
[void]$L.Add('$ErrorActionPreference="Stop"')
[void]$L.Add('. "$PSScriptRoot\lib\canon.ps1"')
[void]$L.Add('function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }')
[void]$L.Add('')
[void]$L.Add('$KeyBase = Join-Path $RuntimeRoot "keys\clarity_dev_ed25519"')
[void]$L.Add('$Allowed = Join-Path $RuntimeRoot "keys\allowed_signers"')
[void]$L.Add('if(-not (Test-Path -LiteralPath $KeyBase -PathType Leaf)){ throw ("Missing key: " + $KeyBase) }')
[void]$L.Add('if(-not (Test-Path -LiteralPath ($KeyBase + ".pub") -PathType Leaf)){ throw ("Missing pubkey: " + ($KeyBase + ".pub")) }')
[void]$L.Add('if(-not (Test-Path -LiteralPath $Allowed -PathType Leaf)){ throw ("Missing allowed_signers: " + $Allowed) }')
[void]$L.Add('')
[void]$L.Add('$outbox = Join-Path $RuntimeRoot "outbox"; EnsureDir $outbox')
[void]$L.Add('$tmp = Join-Path $outbox ("tmp_" + [Guid]::NewGuid().ToString("N")); EnsureDir $tmp')
[void]$L.Add('EnsureDir (Join-Path $tmp "payload"); EnsureDir (Join-Path $tmp "signatures")')
[void]$L.Add('')
[void]$L.Add('$eventTime = UtcNow; $createdAt = UtcNow')
[void]$L.Add('')
[void]$L.Add('$commitObj = [ordered]@{ schema="commitment.v1"; producer="clarity"; producer_instance=$ProducerInstance; tenant=$Tenant; principal=$Principal; event_type=$EventType; event_time_utc=$eventTime; prev_links=@(); content_ref=$ContentRef; strength=$Strength }')
[void]$L.Add('$commitPath = Join-Path $tmp "payload\commit.payload.json"')
[void]$L.Add('$commitJson = ($commitObj | ConvertTo-Json -Compress)')
[void]$L.Add('WriteUtf8NoBomLf $commitPath $commitJson')
[void]$L.Add('$commitHash = Sha256HexTextNormalized $commitJson')
[void]$L.Add('WriteUtf8NoBomLf (Join-Path $tmp "payload\commit_hash.txt") ($commitHash + "`n")')
[void]$L.Add('')
[void]$L.Add('$p1 = Join-Path $tmp "payload\commit.payload.json"; $p2 = Join-Path $tmp "payload\commit_hash.txt"')
[void]$L.Add('$fi1 = Get-Item -LiteralPath $p1; $fi2 = Get-Item -LiteralPath $p2')
[void]$L.Add('$h1 = Sha256HexFile $fi1.FullName; $h2 = Sha256HexFile $fi2.FullName')
[void]$L.Add('$filesArr = @([ordered]@{ path="payload/commit.payload.json"; bytes=[int]$fi1.Length; sha256=$h1 },[ordered]@{ path="payload/commit_hash.txt"; bytes=[int]$fi2.Length; sha256=$h2 })')
[void]$L.Add('$manObj = [ordered]@{ schema="packet_manifest.v1"; producer="clarity"; producer_instance=$ProducerInstance; created_at_utc=$createdAt; files=$filesArr }')
[void]$L.Add('$manJson = ($manObj | ConvertTo-Json -Compress)')
[void]$L.Add('WriteUtf8NoBomLf (Join-Path $tmp "manifest.json") $manJson')
[void]$L.Add('$packetId = Sha256HexTextNormalized $manJson')
[void]$L.Add('WriteUtf8NoBomLf (Join-Path $tmp "packet_id.txt") ($packetId + "`n")')
[void]$L.Add('')
[void]$L.Add('$ingObj = [ordered]@{ schema="nfl.ingest.v1"; packet_id=$packetId; commit_hash=$commitHash; producer="clarity"; producer_instance=$ProducerInstance; tenant=$Tenant; principal=$Principal; event_type=$EventType; event_time_utc=$eventTime; prev_links=@(); payload_mode="pointer_only"; payload_ref=$ContentRef; producer_key_id="clarity-dev-ed25519"; producer_sig_ref="signatures/ingest.sig" }')
[void]$L.Add('$ingJson = ($ingObj | ConvertTo-Json -Compress)')
[void]$L.Add('WriteUtf8NoBomLf (Join-Path $tmp "payload\nfl.ingest.json") $ingJson')
[void]$L.Add('$ingHash = Sha256HexTextNormalized $ingJson')
[void]$L.Add('')
[void]$L.Add('$msg = Join-Path $env:TEMP ("clarity_signmsg_" + [Guid]::NewGuid().ToString("N") + ".txt")')
[void]$L.Add('WriteUtf8NoBomLf $msg (($commitHash + "`n" + $packetId + "`n" + $ingHash + "`n"))')
[void]$L.Add('$arg = "-Y sign -f `"" + $KeyBase + "`" -n nfl.ingest.v1 -I `"" + $Principal + "`" `"" + $msg + "`""')
[void]$L.Add('$sp = Start-Process -FilePath "ssh-keygen.exe" -ArgumentList $arg -Wait -PassThru -NoNewWindow')
[void]$L.Add('if($sp.ExitCode -ne 0){ throw ("ssh-keygen sign failed exit_code=" + $sp.ExitCode) }')
[void]$L.Add('Copy-Item -LiteralPath ($msg + ".sig") -Destination (Join-Path $tmp "signatures\ingest.sig") -Force')
[void]$L.Add('Remove-Item -LiteralPath ($msg + ".sig") -Force -ErrorAction SilentlyContinue')
[void]$L.Add('Remove-Item -LiteralPath $msg -Force -ErrorAction SilentlyContinue')
[void]$L.Add('')
[void]$L.Add('$files = @(Get-ChildItem -LiteralPath $tmp -Recurse -File | Where-Object { $_.Name -ne "sha256sums.txt" })')
[void]$L.Add('$rows = New-Object System.Collections.Generic.List[string]')
[void]$L.Add('foreach($f in $files){ $rel = $f.FullName.Substring($tmp.Length).TrimStart("\") -replace "\\","/"; $h = Sha256HexFile $f.FullName; [void]$rows.Add(("{0}  {1}" -f $h,$rel)) }')
[void]$L.Add('$sorted = @($rows.ToArray() | Sort-Object)')
[void]$L.Add('WriteUtf8NoBomLf (Join-Path $tmp "sha256sums.txt") ((($sorted -join "`n") + "`n"))')
[void]$L.Add('')
[void]$L.Add('$final = Join-Path $outbox $packetId')
[void]$L.Add('if(Test-Path -LiteralPath $final -PathType Container){ throw ("Packet already exists: " + $final) }')
[void]$L.Add('Move-Item -LiteralPath $tmp -Destination $final -Force')
[void]$L.Add('Write-Host ("PACKET_OK_OPTIONA: " + $final) -ForegroundColor Green')
[void]$L.Add('Write-Output $final')

$mkText = ($L.ToArray() -join "`n") + "`n"
Write-Utf8NoBomLf $mkPath $mkText
Parse-GatePs1 $mkPath
Write-Host ("PATCH_OK: overwrote " + $mkPath) -ForegroundColor Green
