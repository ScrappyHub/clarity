Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

function EnsureDir([string]$p){ if(-not(Test-Path -LiteralPath $p)){ New-Item -ItemType Directory -Path $p -Force | Out-Null } }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function WriteUtf8NoBomLf([string]$p,[string]$t){ $dir=Split-Path -Parent $p; if($dir){ EnsureDir $dir }; $norm=$t.Replace("`r`n","`n").Replace("`r","`n"); [IO.File]::WriteAllBytes($p,(Utf8NoBom).GetBytes($norm)) }

function WriteUtf8NoBomLf([string]$p,[string]$t){ $dir=Split-Path -Parent $p; if($dir){ if(-not(Test-Path -LiteralPath $dir)){ New-Item -ItemType Directory -Path $dir -Force|Out-Null } }; $norm=$t.Replace("`r`n","`n").Replace("`r","`n"); [IO.File]::WriteAllBytes($p,(New-Object System.Text.UTF8Encoding($false)).GetBytes($norm)) }
WriteUtf8NoBomLf "C:\dev\clarity\scripts\lib\canon.ps1" (@'Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function EnsureDir([string]$p){ if(-not(Test-Path -LiteralPath $p)){ New-Item -ItemType Directory -Path $p -Force | Out-Null } }
function WriteUtf8Lf([string]$path,[string]$text){
  $dir = Split-Path -Parent $path
  if($dir){ EnsureDir $dir }
  $norm = $text.Replace("`r`n","`n").Replace("`r","`n")
  [IO.File]::WriteAllBytes($path,(Utf8NoBom).GetBytes($norm))
}
function ReadAllBytes([string]$p){ [IO.File]::ReadAllBytes($p) }
function Sha256Hex([byte[]]$bytes){
  if($null -eq $bytes){ $bytes = [byte[]]@() }
  $sha = [Security.Cryptography.SHA256]::Create()
  ($sha.ComputeHash([byte[]]$bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
}
function Sha256HexFile([string]$p){ Sha256Hex (ReadAllBytes $p) }

# Canonical JSON v1: recurse-sort object keys (ordinal), arrays preserve order, minified.
function ConvertTo-OrderedJsonNode([System.Text.Json.Nodes.JsonNode]$n){
  if($null -eq $n){ return $null }
  if($n -is [System.Text.Json.Nodes.JsonObject]){
    $o = [System.Text.Json.Nodes.JsonObject]::new()
    $names = @()
    foreach($kv in $n.GetEnumerator()){ $names += $kv.Key }
    foreach($name in ($names | Sort-Object)){
      $child = $n[$name]
      $o[$name] = (ConvertTo-OrderedJsonNode $child)
    }
    return $o
  }
  if($n -is [System.Text.Json.Nodes.JsonArray]){
    $a = [System.Text.Json.Nodes.JsonArray]::new()
    foreach($item in $n){ [void]$a.Add((ConvertTo-OrderedJsonNode $item)) }
    return $a
  }
  return $n
}
function Canon-JsonString([string]$json){
  $node = [System.Text.Json.Nodes.JsonNode]::Parse($json)
  $ord  = ConvertTo-OrderedJsonNode $node
  $opts = [System.Text.Json.JsonSerializerOptions]::new()
  $opts.WriteIndented = $false
  return $ord.ToJsonString($opts)
}
function Canon-JsonFileBytes([string]$path){
  $raw = [System.Text.Encoding]::UTF8.GetString((ReadAllBytes $path))
  $canon = Canon-JsonString $raw
  return (Utf8NoBom).GetBytes($canon)
}'@ + "`n")
WriteUtf8NoBomLf "C:\dev\clarity\scripts\make_packet.ps1" (@'Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
. "$PSScriptRoot\lib\canon.ps1"

param(
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$Tenant,
  [Parameter(Mandatory=$true)][string]$Principal,
  [Parameter(Mandatory=$true)][string]$ProducerInstance,
  [Parameter(Mandatory=$true)][string]$EventType,
  [Parameter(Mandatory=$true)][string]$ContentRef,
  [Parameter(Mandatory=$true)][ValidateSet("evidence","deterministic")][string]$Strength
)

function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
function FileSha([string]$p){ Sha256HexFile $p }

$KeyBase  = Join-Path $RuntimeRoot "keys\clarity_dev_ed25519"
$Allowed  = Join-Path $RuntimeRoot "keys\allowed_signers"
if(-not(Test-Path -LiteralPath $KeyBase)){ throw ("Missing key: " + $KeyBase) }
if(-not(Test-Path -LiteralPath ($KeyBase + ".pub"))){ throw ("Missing pubkey: " + ($KeyBase + ".pub")) }
if(-not(Test-Path -LiteralPath $Allowed)){ throw ("Missing allowed_signers: " + $Allowed) }

# ---- 1) Write ALL payload files first ----
$payloadDir = Join-Path $env:TEMP ("clarity_payload_" + [Guid]::NewGuid().ToString("N"))
EnsureDir $payloadDir

$commitPath = Join-Path $payloadDir "commit.payload.json"
$commitObj = [System.Text.Json.Nodes.JsonObject]::new()
$commitObj["schema"]="commitment.v1"
$commitObj["producer"]="clarity"
$commitObj["producer_instance"]=$ProducerInstance
$commitObj["tenant"]=$Tenant
$commitObj["principal"]=$Principal
$commitObj["event_type"]=$EventType
$commitObj["event_time_utc"]=UtcNow
$commitObj["prev_links"]=[System.Text.Json.Nodes.JsonArray]::new()
$commitObj["content_ref"]=$ContentRef
$commitObj["strength"]=$Strength
$commitCanon = Canon-JsonString ($commitObj.ToJsonString())
WriteUtf8Lf $commitPath ($commitCanon + "`n")
$commitHash = Sha256Hex ((Utf8NoBom).GetBytes($commitCanon))
$commitHashPath = Join-Path $payloadDir "commit_hash.txt"
WriteUtf8Lf $commitHashPath ($commitHash + "`n")

$ingestPath = Join-Path $payloadDir "nfl.ingest.json"
$ing = [System.Text.Json.Nodes.JsonObject]::new()
$ing["schema"]="nfl.ingest.v1"
$ing["packet_id"]="__PENDING__"
$ing["commit_hash"]=$commitHash
$ing["producer"]="clarity"
$ing["producer_instance"]=$ProducerInstance
$ing["tenant"]=$Tenant
$ing["principal"]=$Principal
$ing["event_type"]=$EventType
$ing["event_time_utc"]=UtcNow
$ing["prev_links"]=[System.Text.Json.Nodes.JsonArray]::new()
$ing["payload_mode"]="pointer_only"
$ing["payload_ref"]=$ContentRef
$ing["producer_key_id"]="clarity-dev-ed25519"
$ing["producer_sig_ref"]="signatures/ingest.sig"
$ingCanonPending = Canon-JsonString ($ing.ToJsonString())
WriteUtf8Lf $ingestPath ($ingCanonPending + "`n")

# ---- 2) Create packet working dir; copy payloads ----
$outbox = Join-Path $RuntimeRoot "outbox"
EnsureDir $outbox
$tmpPacket = Join-Path $outbox ("tmp_" + [Guid]::NewGuid().ToString("N"))
EnsureDir $tmpPacket
EnsureDir (Join-Path $tmpPacket "payload")
EnsureDir (Join-Path $tmpPacket "signatures")
Copy-Item -LiteralPath $commitPath     -Destination (Join-Path $tmpPacket "payload\commit.payload.json") -Force
Copy-Item -LiteralPath $commitHashPath -Destination (Join-Path $tmpPacket "payload\commit_hash.txt") -Force
Copy-Item -LiteralPath $ingestPath     -Destination (Join-Path $tmpPacket "payload\nfl.ingest.json") -Force

# ---- 3) Write manifest.json WITHOUT packet_id (canonical JSON bytes) ----
function BuildManifestNoId([string]$root,[string]$createdAt){
  # Manifest lists required payload files only (stable before signatures).
  $files = @(
    (Join-Path $root "payload\commit.payload.json"),
    (Join-Path $root "payload\commit_hash.txt"),
    (Join-Path $root "payload\nfl.ingest.json")
  )
  $arr = [System.Text.Json.Nodes.JsonArray]::new()
  foreach($p in $files){
    if(-not(Test-Path -LiteralPath $p)){ throw ("Missing required payload file: " + $p) }
    $fi = Get-Item -LiteralPath $p
    $rel = $fi.FullName.Substring($root.Length).TrimStart("\") -replace "\\","/"
    $o = [System.Text.Json.Nodes.JsonObject]::new()
    $o["path"]=$rel
    $o["bytes"]=[int]$fi.Length
    $o["sha256"]=FileSha $fi.FullName
    [void]$arr.Add($o)
  }
  $m=[System.Text.Json.Nodes.JsonObject]::new()
  $m["schema"]="packet_manifest.v1"
  $m["producer"]="clarity"
  $m["producer_instance"]=$ProducerInstance
  $m["created_at_utc"]=$createdAt
  $m["files"]=$arr
  return $m
}

$createdAt = UtcNow
$manObj = BuildManifestNoId $tmpPacket $createdAt
$manCanon = Canon-JsonString ($manObj.ToJsonString())
WriteUtf8Lf (Join-Path $tmpPacket "manifest.json") ($manCanon + "`n")

# ---- 4) Compute PacketId from canonical bytes(manifest-without-id) ----
$packetId = Sha256Hex ((Utf8NoBom).GetBytes($manCanon))

# ---- 5) Persist PacketId (Option A) ----
WriteUtf8Lf (Join-Path $tmpPacket "packet_id.txt") ($packetId + "`n")

# Update ingest packet_id (not manifest) now that PacketId is known
$ing["packet_id"]=$packetId
$ingCanon = Canon-JsonString ($ing.ToJsonString())
WriteUtf8Lf (Join-Path $tmpPacket "payload\nfl.ingest.json") ($ingCanon + "`n")
$ingestHash = Sha256Hex ((Utf8NoBom).GetBytes($ingCanon))

# ---- 6) Write detached signatures AFTER payload + manifest exist ----
$envObj=[System.Text.Json.Nodes.JsonObject]::new()
$envObj["schema"]="sig_envelope.v1"
$envObj["algo"]="ed25519"
$envObj["key_id"]="clarity-dev-ed25519"
$envObj["signing_context"]="nfl.ingest.v1"
$signs=[System.Text.Json.Nodes.JsonObject]::new()
$signs["commit_hash"]=$commitHash
$signs["packet_id"]=$packetId
$signs["ingest_hash"]=$ingestHash
$envObj["signs"]=$signs
$envCanon = Canon-JsonString ($envObj.ToJsonString())
WriteUtf8Lf (Join-Path $tmpPacket "payload\sig_envelope.json") ($envCanon + "`n")

$msgPath = Join-Path $env:TEMP ("clarity_signmsg_" + [Guid]::NewGuid().ToString("N") + ".txt")
WriteUtf8Lf $msgPath (($commitHash + "`n" + $packetId + "`n" + $ingestHash + "`n"))
& ssh-keygen.exe -Y sign -f $KeyBase -n "nfl.ingest.v1" -I $Principal -o $msgPath | Out-Null
$written = ($msgPath + ".sig")
$sigPath = Join-Path $tmpPacket "signatures\ingest.sig"
Copy-Item -LiteralPath $written -Destination $sigPath -Force
Remove-Item -LiteralPath $written -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $msgPath -Force -ErrorAction SilentlyContinue

# ---- 7) Generate sha256sums.txt LAST over final on-disk bytes ----
function BuildSha256Sums([string]$root){
  $files = Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Name -ne "sha256sums.txt" }
  $out = New-Object System.Collections.Generic.List[string]
  foreach($f in $files){
    $rel = $f.FullName.Substring($root.Length).TrimStart("\") -replace "\\","/"
    $h = FileSha $f.FullName
    $out.Add(("{0}  {1}" -f $h,$rel)) | Out-Null
  }
  return (($out | Sort-Object) -join "`n")
}
WriteUtf8Lf (Join-Path $tmpPacket "sha256sums.txt") ((BuildSha256Sums $tmpPacket) + "`n")

# Rename folder to PacketId (final)
$final = Join-Path $outbox $packetId
if(Test-Path -LiteralPath $final){ throw ("Packet already exists: " + $final) }
Move-Item -LiteralPath $tmpPacket -Destination $final -Force
Write-Host ("PACKET OK (Option A): " + $final) -ForegroundColor Green
Write-Output $final'@ + "`n")
WriteUtf8NoBomLf "C:\dev\clarity\scripts\verify_packet.ps1" (@'Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
. "$PSScriptRoot\lib\canon.ps1"

param(
  [Parameter(Mandatory=$true)][string]$PacketRoot,
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$Principal
)

function FileSha([string]$p){ Sha256HexFile $p }
$Allowed = Join-Path $RuntimeRoot "keys\allowed_signers"
if(-not(Test-Path -LiteralPath $Allowed)){ throw ("Missing allowed_signers: " + $Allowed) }

# 1) Recompute PacketId from canonical bytes(manifest-without-id) (Option A => manifest.json)
$manPath = Join-Path $PacketRoot "manifest.json"
if(-not(Test-Path -LiteralPath $manPath)){ throw "Missing manifest.json" }
$manCanon = [System.Text.Encoding]::UTF8.GetString((Canon-JsonFileBytes $manPath))
$packetId = Sha256Hex ((Utf8NoBom).GetBytes($manCanon))
$folderId = Split-Path -Leaf $PacketRoot
if($folderId -ne $packetId){ throw ("PACKET_ID_MISMATCH folder=" + $folderId + " computed=" + $packetId) }

# 2) packet_id.txt must exist and match
$pidPath = Join-Path $PacketRoot "packet_id.txt"
if(-not(Test-Path -LiteralPath $pidPath)){ throw "Missing packet_id.txt" }
$pid = (Get-Content -Raw -LiteralPath $pidPath -Encoding UTF8).Trim()
if($pid -ne $packetId){ throw "packet_id.txt mismatch" }

# 3) sha256sums verify (must include manifest.json + packet_id.txt + signatures + payload)
$shaPath = Join-Path $PacketRoot "sha256sums.txt"
if(-not(Test-Path -LiteralPath $shaPath)){ throw "Missing sha256sums.txt" }
$lines = Get-Content -LiteralPath $shaPath -Encoding UTF8
foreach($ln in $lines){
  if($ln.Trim() -eq ""){ continue }
  $parts = $ln -split "\s{2,}"
  if(@($parts).Count -lt 2){ throw ("Bad sha256sums line: " + $ln) }
  $h = $parts[0].Trim()
  $rel = $parts[1].Trim()
  $p = Join-Path $PacketRoot ($rel -replace "/","\")
  if(-not(Test-Path -LiteralPath $p)){ throw ("Missing file in packet: " + $rel) }
  $hh = FileSha $p
  if($hh -ne $h){ throw ("SHA256_MISMATCH: " + $rel) }
}

# 4) CommitHash verify
$commitPath = Join-Path $PacketRoot "payload\commit.payload.json"
$commitCanon = [System.Text.Encoding]::UTF8.GetString((Canon-JsonFileBytes $commitPath))
$commitHash = Sha256Hex ((Utf8NoBom).GetBytes($commitCanon))
$expected = (Get-Content -Raw -LiteralPath (Join-Path $PacketRoot "payload\commit_hash.txt") -Encoding UTF8).Trim()
if($commitHash -ne $expected){ throw "COMMIT_HASH_MISMATCH" }

# 5) Signature verify (ssh-keygen -Y verify) over msg = commit_hash + packet_id + ingest_hash
$ingPath = Join-Path $PacketRoot "payload\nfl.ingest.json"
$ingCanon = [System.Text.Encoding]::UTF8.GetString((Canon-JsonFileBytes $ingPath))
$ingHash = Sha256Hex ((Utf8NoBom).GetBytes($ingCanon))
$msg = Join-Path $env:TEMP ("clarity_verifymsg_" + [Guid]::NewGuid().ToString("N") + ".txt")
WriteUtf8Lf $msg (($commitHash + "`n" + $packetId + "`n" + $ingHash + "`n"))
$sig = Join-Path $PacketRoot "signatures\ingest.sig"
if(-not(Test-Path -LiteralPath $sig)){ throw "Missing signatures/ingest.sig" }
& ssh-keygen.exe -Y verify -n "nfl.ingest.v1" -I $Principal -f $Allowed -s $sig -o $msg | Out-Null
Remove-Item -LiteralPath $msg -Force -ErrorAction SilentlyContinue

Write-Host ("VERIFY OK (Option A): " + $PacketRoot) -ForegroundColor Green'@ + "`n")

# Parse-gate the scripts we wrote
$RepoRoot = "C:\dev\clarity"
$toParse = @(
  (Join-Path $RepoRoot "scripts\lib\canon.ps1"),
  (Join-Path $RepoRoot "scripts\make_packet.ps1"),
  (Join-Path $RepoRoot "scripts\verify_packet.ps1")
)
foreach($p in $toParse){ [ScriptBlock]::Create((Get-Content -Raw -LiteralPath $p -Encoding UTF8)) | Out-Null }
Write-Host "PATCH OK: Packet Constitution v1 Option A installed + parse-gated." -ForegroundColor Green
