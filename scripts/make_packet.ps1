param(
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$Tenant,
  [Parameter(Mandatory=$true)][string]$Principal,
  [Parameter(Mandatory=$true)][string]$ProducerInstance,
  [Parameter(Mandatory=$true)][string]$EventType,
  [Parameter(Mandatory=$true)][string]$ContentRef,
  [Parameter(Mandatory=$true)][ValidateSet("evidence","deterministic")][string]$Strength
)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
. "$PSScriptRoot\lib\canon.ps1"
function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }

$KeyBase = Join-Path $RuntimeRoot "keys\clarity_dev_ed25519"
$Allowed = Join-Path $RuntimeRoot "keys\allowed_signers"
if(-not (Test-Path -LiteralPath $KeyBase -PathType Leaf)){ throw ("Missing key: " + $KeyBase) }
if(-not (Test-Path -LiteralPath ($KeyBase + ".pub") -PathType Leaf)){ throw ("Missing pubkey: " + ($KeyBase + ".pub")) }
if(-not (Test-Path -LiteralPath $Allowed -PathType Leaf)){ throw ("Missing allowed_signers: " + $Allowed) }

$outbox = Join-Path $RuntimeRoot "outbox"; EnsureDir $outbox
$tmp = Join-Path $outbox ("tmp_" + [Guid]::NewGuid().ToString("N")); EnsureDir $tmp
EnsureDir (Join-Path $tmp "payload"); EnsureDir (Join-Path $tmp "signatures")

$eventTime = UtcNow; $createdAt = UtcNow

$commitObj = [ordered]@{ schema="commitment.v1"; producer="clarity"; producer_instance=$ProducerInstance; tenant=$Tenant; principal=$Principal; event_type=$EventType; event_time_utc=$eventTime; prev_links=@(); content_ref=$ContentRef; strength=$Strength }
$commitPath = Join-Path $tmp "payload\commit.payload.json"
$commitJson = ($commitObj | ConvertTo-Json -Compress)
WriteUtf8NoBomLf $commitPath $commitJson
$commitHash = Sha256HexTextNormalized $commitJson
WriteUtf8NoBomLf (Join-Path $tmp "payload\commit_hash.txt") ($commitHash + "`n")

$p1 = Join-Path $tmp "payload\commit.payload.json"; $p2 = Join-Path $tmp "payload\commit_hash.txt"
$fi1 = Get-Item -LiteralPath $p1; $fi2 = Get-Item -LiteralPath $p2
$h1 = Sha256HexFile $fi1.FullName; $h2 = Sha256HexFile $fi2.FullName
$filesArr = @([ordered]@{ path="payload/commit.payload.json"; bytes=[int]$fi1.Length; sha256=$h1 },[ordered]@{ path="payload/commit_hash.txt"; bytes=[int]$fi2.Length; sha256=$h2 })
$manObj = [ordered]@{ schema="packet_manifest.v1"; producer="clarity"; producer_instance=$ProducerInstance; created_at_utc=$createdAt; files=$filesArr }
$manJson = ($manObj | ConvertTo-Json -Compress)
WriteUtf8NoBomLf (Join-Path $tmp "manifest.json") $manJson
$packetId = Sha256HexTextNormalized $manJson
WriteUtf8NoBomLf (Join-Path $tmp "packet_id.txt") ($packetId + "`n")

$ingObj = [ordered]@{ schema="nfl.ingest.v1"; packet_id=$packetId; commit_hash=$commitHash; producer="clarity"; producer_instance=$ProducerInstance; tenant=$Tenant; principal=$Principal; event_type=$EventType; event_time_utc=$eventTime; prev_links=@(); payload_mode="pointer_only"; payload_ref=$ContentRef; producer_key_id="clarity-dev-ed25519"; producer_sig_ref="signatures/ingest.sig" }
$ingJson = ($ingObj | ConvertTo-Json -Compress)
WriteUtf8NoBomLf (Join-Path $tmp "payload\nfl.ingest.json") $ingJson
$ingHash = Sha256HexTextNormalized $ingJson

$msg = Join-Path $env:TEMP ("clarity_signmsg_" + [Guid]::NewGuid().ToString("N") + ".txt")
WriteUtf8NoBomLf $msg (($commitHash + "`n" + $packetId + "`n" + $ingHash + "`n"))
$arg = "-Y sign -f `"" + $KeyBase + "`" -n nfl.ingest.v1 -I `"" + $Principal + "`" `"" + $msg + "`""
$sp = Start-Process -FilePath "ssh-keygen.exe" -ArgumentList $arg -Wait -PassThru -NoNewWindow
if($sp.ExitCode -ne 0){ throw ("ssh-keygen sign failed exit_code=" + $sp.ExitCode) }
Copy-Item -LiteralPath ($msg + ".sig") -Destination (Join-Path $tmp "signatures\ingest.sig") -Force
Remove-Item -LiteralPath ($msg + ".sig") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $msg -Force -ErrorAction SilentlyContinue

$files = @(Get-ChildItem -LiteralPath $tmp -Recurse -File | Where-Object { $_.Name -ne "sha256sums.txt" })
$rows = New-Object System.Collections.Generic.List[string]
foreach($f in $files){ $rel = $f.FullName.Substring($tmp.Length).TrimStart("\") -replace "\\","/"; $h = Sha256HexFile $f.FullName; [void]$rows.Add(("{0}  {1}" -f $h,$rel)) }
$sorted = @($rows.ToArray() | Sort-Object)
WriteUtf8NoBomLf (Join-Path $tmp "sha256sums.txt") ((($sorted -join "`n") + "`n"))

$final = Join-Path $outbox $packetId
if(Test-Path -LiteralPath $final -PathType Container){ throw ("Packet already exists: " + $final) }
Move-Item -LiteralPath $tmp -Destination $final -Force
Write-Host ("PACKET_OK_OPTIONA: " + $final) -ForegroundColor Green
Write-Output $final
