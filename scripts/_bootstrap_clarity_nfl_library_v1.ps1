Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

$RepoRoot = "C:\dev\clarity"
$Runtime = "C:\ProgramData\Clarity"
$NflInbox = "C:\ProgramData\NFL\inbox"

function EnsureDir([string]$p){ if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function WriteUtf8Lf([string]$path,[string]$text){
  $dir = Split-Path -Parent $path
  if ($dir) { EnsureDir $dir }
  $bytes = (Utf8NoBom).GetBytes(($text -replace "`r`n","`n"))
  [IO.File]::WriteAllBytes($path,$bytes)
  if (-not (Test-Path -LiteralPath $path)) { throw ("WRITE_FAILED: " + $path) }
}
function Sha256Hex([byte[]]$bytes){
  $sha = [Security.Cryptography.SHA256]::Create()
  ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
}
function ReadAllBytes([string]$p){ [IO.File]::ReadAllBytes($p) }

# --- write lib\canon.ps1 ---
$CanonPath = Join-Path $RepoRoot "scripts\lib\canon.ps1"
$canon = @()
$canon += 'Set-StrictMode -Version Latest'
$canon += '$ErrorActionPreference="Stop"'
$canon += ''
$canon += 'function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }'
$canon += 'function Sha256Hex([byte[]]$bytes){ $sha=[Security.Cryptography.SHA256]::Create(); ($sha.ComputeHash($bytes)|ForEach-Object{$_.ToString("x2")}) -join "" }'
$canon += 'function WriteUtf8Lf([string]$path,[string]$text){ $dir=Split-Path -Parent $path; if($dir -and -not (Test-Path -LiteralPath $dir)){ New-Item -ItemType Directory -Path $dir -Force|Out-Null }; $bytes=(Utf8NoBom).GetBytes(($text -replace "`r`n","`n")); [IO.File]::WriteAllBytes($path,$bytes) }'
$canon += 'function Canon-JsonString([string]$json){'
$canon += '  $node = [System.Text.Json.Nodes.JsonNode]::Parse($json)'
$canon += '  function SortNode([System.Text.Json.Nodes.JsonNode]$n){'
$canon += '    if ($n -is [System.Text.Json.Nodes.JsonObject]) {'
$canon += '      $obj = [System.Text.Json.Nodes.JsonObject]::new()'
$canon += '      foreach ($k in ($n.AsObject().Select({$_.Key}) | Sort-Object)) { $obj[$k] = SortNode($n[$k]) }'
$canon += '      return $obj'
$canon += '    }'
$canon += '    if ($n -is [System.Text.Json.Nodes.JsonArray]) {'
$canon += '      $arr = [System.Text.Json.Nodes.JsonArray]::new()'
$canon += '      foreach ($x in $n.AsArray()) { [void]$arr.Add((SortNode $x)) }'
$canon += '      return $arr'
$canon += '    }'
$canon += '    return $n'
$canon += '  }'
$canon += '  $sorted = SortNode $node'
$canon += '  $opt = [System.Text.Json.JsonSerializerOptions]::new()'
$canon += '  $opt.WriteIndented = $false'
$canon += '  return [System.Text.Json.JsonSerializer]::Serialize($sorted, $opt)'
$canon += '}'
$canon += 'function Canon-JsonBytes([string]$json){ (Utf8NoBom).GetBytes((Canon-JsonString $json)) }'
$canon += 'function Canon-JsonFileBytes([string]$path){ Canon-JsonBytes (Get-Content -Raw -LiteralPath $path -Encoding UTF8) }'
WriteUtf8Lf $CanonPath ($canon -join "`n")

EnsureDir (Join-Path $RepoRoot "schemas")
EnsureDir (Join-Path $RepoRoot "contracts")
EnsureDir (Join-Path $RepoRoot "scripts")
EnsureDir (Join-Path $RepoRoot "scripts\lib")
EnsureDir (Join-Path $RepoRoot "tests\vectors\sample_packet\payload")
EnsureDir (Join-Path $RepoRoot "tests\vectors\sample_packet\signatures")
EnsureDir (Join-Path $RepoRoot "tests\vectors\sample_packet")

EnsureDir (Join-Path $Runtime "pledges")
EnsureDir (Join-Path $Runtime "outbox")
EnsureDir (Join-Path $Runtime "keys")
EnsureDir (Join-Path $Runtime "library\ledger")
EnsureDir (Join-Path $Runtime "library\objects\sha256")
EnsureDir (Join-Path $Runtime "library\manifests\sha256")
EnsureDir (Join-Path $Runtime "library\access\sessions")
EnsureDir (Join-Path $Runtime "runs")
EnsureDir $NflInbox

$Law = @()
$Law += "# Clarity LAW.md (LOCKED) — NFL Skeleton v1.1 + Library Gate v1"
$Law += ""
$Law += "Clarity MUST:"
$Law += "- Maintain an append-only local pledge log (pledges.ndjson), chained by prev_log_hash + log_hash."
$Law += "- For every pledge event, build a packet directory (manifest.json + sha256sums.txt + payload + signature) under outbox/<PacketId>."
$Law += "- Duplicate the *byte-identical* packet into NFL inbox under C:\ProgramData\NFL\inbox\<PacketId>\\"
$Law += "- Never do direct inter-project RPC. Hashes + NFL only."
$Law += ""
$Law += "Clarity Library (mini-NFL) MUST:"
$Law += "- Store objects content-addressed: content_ref = cas:sha256:<hex>."
$Law += "- Append-only library ledger (library.ndjson), hash-chained."
$Law += "- Sealed objects are not readable until user verification grants access (AccessGrant v1)."
WriteUtf8Lf (Join-Path $RepoRoot "LAW.md") ($Law -join "`n")

$ev = @
{
  "schema": "event_types.v1",
  "producer": "clarity",
  "types": [
    "clarity.run.started.v1",
    "clarity.verification.result.v1",
    "clarity.run.completed.v1",
    "clarity.library.object.added.v1",
    "clarity.library.object.sealed.v1",
    "clarity.nfl.packet.built.v1",
    "clarity.nfl.packet.verified.v1",
    "clarity.nfl.pledged.local.v1",
    "clarity.nfl.duplicated.v1",
    "clarity.nfl.duplicate.failed.v1"
  ]
}
@
WriteUtf8Lf (Join-Path $RepoRoot "contracts\event_types.v1.json") $ev

$KeyBase = Join-Path $Runtime "keys\clarity_dev_ed25519"
$Pub = ($KeyBase + ".pub")
if (-not (Test-Path -LiteralPath $KeyBase) -or -not (Test-Path -LiteralPath $Pub)) {
  & ssh-keygen.exe -t ed25519 -f $KeyBase -N "" | Out-Null
}
$Allowed = Join-Path $Runtime "keys\allowed_signers"
$principal = "single-tenant/operator/user/alec"
$pubLine = (Get-Content -Raw -LiteralPath $Pub -Encoding UTF8).Trim()
$allowedLine = ("{0} {1}" -f $principal, $pubLine)
WriteUtf8Lf $Allowed ($allowedLine + "`n")

$libPut = @()
$libPut += 'Set-StrictMode -Version Latest'
$libPut += '$ErrorActionPreference="Stop"'
$libPut += '. "$PSScriptRoot\lib\canon.ps1"'
$libPut += ''
$libPut += 'param('
$libPut += '  [Parameter(Mandatory=$true)][string]$RuntimeRoot,'
$libPut += '  [Parameter(Mandatory=$true)][string]$InputPath,'
$libPut += '  [Parameter(Mandatory=$true)][string]$Tenant,'
$libPut += '  [Parameter(Mandatory=$true)][string]$Principal,'
$libPut += '  [Parameter(Mandatory=$true)][string]$ProducerInstance,'
$libPut += '  [Parameter(Mandatory=$false)][switch]$Sealed'
$libPut += ')'
$libPut += ''
$libPut += 'function EnsureDir([string]$p){ if(-not(Test-Path -LiteralPath $p)){ New-Item -ItemType Directory -Path $p -Force|Out-Null } }'
$libPut += 'function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }'
$libPut += 'function ReadAllBytes([string]$p){ [IO.File]::ReadAllBytes($p) }'
$libPut += 'function Sha256File([string]$p){ Sha256Hex (ReadAllBytes $p) }'
$libPut += ''
$libPut += '$ledger = Join-Path $RuntimeRoot "library\ledger\library.ndjson"'
$libPut += 'EnsureDir (Split-Path -Parent $ledger)'
$libPut += '$objHash = Sha256File $InputPath'
$libPut += '$hh = $objHash.Substring(0,2)'
$libPut += '$objDir = Join-Path $RuntimeRoot ("library\objects\sha256\{0}\{1}" -f $hh, $objHash)'
$libPut += 'EnsureDir $objDir'
$libPut += '$dst = Join-Path $objDir (Split-Path -Leaf $InputPath)'
$libPut += 'Copy-Item -LiteralPath $InputPath -Destination $dst -Force'
$libPut += '$contentRef = ("cas:sha256:{0}" -f $objHash)'
$libPut += ''
$libPut += '# append ledger entry (hash chained)'
$libPut += '$prev="GENESIS"; $seq=1'
$libPut += 'if (Test-Path -LiteralPath $ledger) {'
$libPut += '  $tail = Get-Content -LiteralPath $ledger -Tail 1 -ErrorAction SilentlyContinue'
$libPut += '  if ($tail) {'
$libPut += '    $t = [System.Text.Json.Nodes.JsonNode]::Parse($tail)'
$libPut += '    $prev = $t["log_hash"].ToString()'
$libPut += '    $seq = [int]$t["seq"].ToString() + 1'
$libPut += '  }'
$libPut += '}'
$libPut += '$etype = $(if($Sealed){"clarity.library.object.sealed.v1"}else{"clarity.library.object.added.v1"})'
$libPut += '$lineObj = [System.Text.Json.Nodes.JsonObject]::new()'
$libPut += '$lineObj["schema"]="clarity.library_ledger.v1"'
$libPut += '$lineObj["seq"]=$seq'
$libPut += '$lineObj["created_at_utc"]=UtcNow'
$libPut += '$lineObj["event_type"]=$etype'
$libPut += '$lineObj["object_sha256"]=$objHash'
$libPut += '$lineObj["content_ref"]=$contentRef'
$libPut += '$lineObj["producer_instance"]=$ProducerInstance'
$libPut += '$lineObj["tenant"]=$Tenant'
$libPut += '$lineObj["principal"]=$Principal'
$libPut += '$lineObj["prev_log_hash"]=$prev'
$libPut += '$lineNoHash = (Canon-JsonString ($lineObj.ToJsonString()))'
$libPut += '$logHash = Sha256Hex ((Utf8NoBom).GetBytes($lineNoHash))'
$libPut += '$lineObj["log_hash"]=$logHash'
$libPut += '$final = Canon-JsonString ($lineObj.ToJsonString())'
$libPut += 'WriteUtf8Lf $ledger ((if(Test-Path $ledger){(Get-Content -Raw -LiteralPath $ledger -Encoding UTF8)}else{""}) + $final + "`n")'
$libPut += ''
$libPut += 'Write-Host ("LIB PUT OK: {0}" -f $contentRef) -ForegroundColor Green'
$libPut += 'Write-Output $contentRef'
WriteUtf8Lf (Join-Path $RepoRoot "scripts\library_put.ps1") ($libPut -join "`n")

$mk = @()
$mk += 'Set-StrictMode -Version Latest'
$mk += '$ErrorActionPreference="Stop"'
$mk += '. "$PSScriptRoot\lib\canon.ps1"'
$mk += ''
$mk += 'param('
$mk += '  [Parameter(Mandatory=$true)][string]$RuntimeRoot,'
$mk += '  [Parameter(Mandatory=$true)][string]$Tenant,'
$mk += '  [Parameter(Mandatory=$true)][string]$Principal,'
$mk += '  [Parameter(Mandatory=$true)][string]$ProducerInstance,'
$mk += '  [Parameter(Mandatory=$true)][string]$EventType,'
$mk += '  [Parameter(Mandatory=$true)][string]$ContentRef,'
$mk += '  [Parameter(Mandatory=$true)][ValidateSet("evidence","deterministic")][string]$Strength'
$mk += ')'
$mk += ''
$mk += 'function EnsureDir([string]$p){ if(-not(Test-Path -LiteralPath $p)){ New-Item -ItemType Directory -Path $p -Force|Out-Null } }'
$mk += 'function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }'
$mk += 'function ReadAllBytes([string]$p){ [IO.File]::ReadAllBytes($p) }'
$mk += 'function FileSha([string]$p){ Sha256Hex (ReadAllBytes $p) }'
$mk += '$KeyBase = Join-Path $RuntimeRoot "keys\clarity_dev_ed25519"'
$mk += '$Allowed = Join-Path $RuntimeRoot "keys\allowed_signers"'
$mk += ''
$mk += '# 1) Build commitment payload'
$mk += '$payloadDir = Join-Path $env:TEMP ("clarity_payload_" + [Guid]::NewGuid().ToString("N"))'
$mk += 'EnsureDir $payloadDir'
$mk += '$commitPath = Join-Path $payloadDir "commit.payload.json"'
$mk += '$commitObj = [System.Text.Json.Nodes.JsonObject]::new()'
$mk += '$commitObj["schema"]="commitment.v1"'
$mk += '$commitObj["producer"]="clarity"'
$mk += '$commitObj["producer_instance"]=$ProducerInstance'
$mk += '$commitObj["tenant"]=$Tenant'
$mk += '$commitObj["principal"]=$Principal'
$mk += '$commitObj["event_type"]=$EventType'
$mk += '$commitObj["event_time_utc"]=UtcNow'
$mk += '$commitObj["prev_links"]=[System.Text.Json.Nodes.JsonArray]::new()'
$mk += '$commitObj["content_ref"]=$ContentRef'
$mk += '$commitObj["strength"]=$Strength'
$mk += '$commitCanon = Canon-JsonString ($commitObj.ToJsonString())'
$mk += 'WriteUtf8Lf $commitPath ($commitCanon + "`n")'
$mk += '$commitHash = Sha256Hex ((Utf8NoBom).GetBytes($commitCanon))'
$mk += '$commitHashPath = Join-Path $payloadDir "commit_hash.txt"'
$mk += 'WriteUtf8Lf $commitHashPath ($commitHash + "`n")'
$mk += ''
$mk += '# 2) Build ingest json (packet_id filled later)'
$mk += '$ingestPath = Join-Path $payloadDir "nfl.ingest.json"'
$mk += '$ing = [System.Text.Json.Nodes.JsonObject]::new()'
$mk += '$ing["schema"]="nfl.ingest.v1"'
$mk += '$ing["packet_id"]="__PENDING__"'
$mk += '$ing["commit_hash"]=$commitHash'
$mk += '$ing["producer"]="clarity"'
$mk += '$ing["producer_instance"]=$ProducerInstance'
$mk += '$ing["tenant"]=$Tenant'
$mk += '$ing["principal"]=$Principal'
$mk += '$ing["event_type"]=$EventType'
$mk += '$ing["event_time_utc"]=(UtcNow)'
$mk += '$ing["prev_links"]=[System.Text.Json.Nodes.JsonArray]::new()'
$mk += '$ing["payload_mode"]="pointer_only"'
$mk += '$ing["payload_ref"]=$ContentRef'
$mk += '$ing["producer_key_id"]="clarity-dev-ed25519"'
$mk += '$ing["producer_sig_ref"]="signatures/ingest.sig"'
$mk += '$ingCanonPending = Canon-JsonString ($ing.ToJsonString())'
$mk += 'WriteUtf8Lf $ingestPath ($ingCanonPending + "`n")'
$mk += ''
$mk += '# 3) Create packet folder under outbox, then finalize manifest/packet_id'
$mk += '$outbox = Join-Path $RuntimeRoot "outbox"'
$mk += 'EnsureDir $outbox'
$mk += '$tmpPacket = Join-Path $outbox ("tmp_" + [Guid]::NewGuid().ToString("N"))'
$mk += 'EnsureDir $tmpPacket'
$mk += 'EnsureDir (Join-Path $tmpPacket "payload")'
$mk += 'EnsureDir (Join-Path $tmpPacket "signatures")'
$mk += 'Copy-Item -LiteralPath $commitPath -Destination (Join-Path $tmpPacket "payload\commit.payload.json") -Force'
$mk += 'Copy-Item -LiteralPath $commitHashPath -Destination (Join-Path $tmpPacket "payload\commit_hash.txt") -Force'
$mk += 'Copy-Item -LiteralPath $ingestPath -Destination (Join-Path $tmpPacket "payload\nfl.ingest.json") -Force'
$mk += '# sig_envelope will be written after packet_id is known'
$mk += ''
$mk += 'function BuildSha256Sums([string]$root){'
$mk += '  $files = Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Name -ne "sha256sums.txt" }'
$mk += '  $lines = New-Object System.Collections.Generic.List[string]'
$mk += '  foreach ($f in $files) {'
$mk += '    $rel = $f.FullName.Substring($root.Length).TrimStart("\") -replace "\\","/"'
$mk += '    $h = FileSha $f.FullName'
$mk += '    $lines.Add(("{0}  {1}" -f $h, $rel)) | Out-Null'
$mk += '  }'
$mk += '  return ($lines | Sort-Object) -join "`n"'
$mk += '}'
$mk += 'function BuildManifestNoId([string]$root,[string]$createdAt){'
$mk += '  $files = Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Name -ne "manifest.json" }'
$mk += '  $arr = [System.Text.Json.Nodes.JsonArray]::new()'
$mk += '  foreach ($f in $files) {'
$mk += '    $rel = $f.FullName.Substring($root.Length).TrimStart("\") -replace "\\","/"'
$mk += '    $o = [System.Text.Json.Nodes.JsonObject]::new()'
$mk += '    $o["path"]=$rel'
$mk += '    $o["bytes"]=[int]$f.Length'
$mk += '    $o["sha256"]=FileSha $f.FullName'
$mk += '    [void]$arr.Add($o)'
$mk += '  }'
$mk += '  $m=[System.Text.Json.Nodes.JsonObject]::new()'
$mk += '  $m["schema"]="packet_manifest.v1"'
$mk += '  $m["packet_id"]="__PENDING__"'
$mk += '  $m["producer"]="clarity"'
$mk += '  $m["producer_instance"]=$ProducerInstance'
$mk += '  $m["created_at_utc"]=$createdAt'
$mk += '  $m["files"]=$arr'
$mk += '  return $m'
$mk += '}'
$mk += ''
$mk += '$createdAt = UtcNow'
$mk += '$shaPath = Join-Path $tmpPacket "sha256sums.txt"'
$mk += 'WriteUtf8Lf $shaPath ((BuildSha256Sums $tmpPacket) + "`n")'
$mk += '$manObj = BuildManifestNoId $tmpPacket $createdAt'
$mk += '$manCanonPending = Canon-JsonString ($manObj.ToJsonString())'
$mk += '$packetId = Sha256Hex ((Utf8NoBom).GetBytes($manCanonPending))'
$mk += '# finalize manifest + ingest packet_id'
$mk += '$manObj["packet_id"]=$packetId'
$mk += '$manCanon = Canon-JsonString ($manObj.ToJsonString())'
$mk += 'WriteUtf8Lf (Join-Path $tmpPacket "manifest.json") ($manCanon + "`n")'
$mk += '# update ingest'
$mk += '$ing["packet_id"]=$packetId'
$mk += '$ingCanon = Canon-JsonString ($ing.ToJsonString())'
$mk += 'WriteUtf8Lf (Join-Path $tmpPacket "payload\nfl.ingest.json") ($ingCanon + "`n")'
$mk += '$ingestHash = Sha256Hex ((Utf8NoBom).GetBytes($ingCanon))'
$mk += ''
$mk += '# 4) sig_envelope + signature (ssh-keygen -Y)'
$mk += '$envObj=[System.Text.Json.Nodes.JsonObject]::new()'
$mk += '$envObj["schema"]="sig_envelope.v1"'
$mk += '$envObj["algo"]="ed25519"'
$mk += '$envObj["key_id"]="clarity-dev-ed25519"'
$mk += '$envObj["signing_context"]="nfl.ingest.v1"'
$mk += '$signs=[System.Text.Json.Nodes.JsonObject]::new()'
$mk += '$signs["commit_hash"]=$commitHash'
$mk += '$signs["packet_id"]=$packetId'
$mk += '$signs["ingest_hash"]=$ingestHash'
$mk += '$envObj["signs"]=$signs'
$mk += '$envCanon = Canon-JsonString ($envObj.ToJsonString())'
$mk += 'WriteUtf8Lf (Join-Path $tmpPacket "payload\sig_envelope.json") ($envCanon + "`n")'
$mk += '$msgPath = Join-Path $env:TEMP ("clarity_signmsg_" + [Guid]::NewGuid().ToString("N") + ".txt")'
$mk += 'WriteUtf8Lf $msgPath (($commitHash + "`n" + $packetId + "`n" + $ingestHash + "`n"))'
$mk += '$sigPath = Join-Path $tmpPacket "signatures\ingest.sig"'
$mk += '& ssh-keygen.exe -Y sign -f $KeyBase -n "nfl.ingest.v1" -I $Principal -o $msgPath | Out-Null'
$mk += '# ssh-keygen writes <file>.sig'
$mk += '$written = ($msgPath + ".sig")'
$mk += 'Copy-Item -LiteralPath $written -Destination $sigPath -Force'
$mk += 'Remove-Item -LiteralPath $written -Force -ErrorAction SilentlyContinue'
$mk += 'Remove-Item -LiteralPath $msgPath -Force -ErrorAction SilentlyContinue'
$mk += ''
$mk += '# 5) rebuild sha256sums now that manifest/sig_envelope/sig exist'
$mk += 'WriteUtf8Lf $shaPath ((BuildSha256Sums $tmpPacket) + "`n")'
$mk += '# finalize folder name'
$mk += '$final = Join-Path $outbox $packetId'
$mk += 'if (Test-Path -LiteralPath $final) { throw ("Packet already exists: " + $final) }'
$mk += 'Move-Item -LiteralPath $tmpPacket -Destination $final -Force'
$mk += 'Write-Host ("PACKET OK: {0}" -f $final) -ForegroundColor Green'
$mk += 'Write-Output $final'
WriteUtf8Lf (Join-Path $RepoRoot "scripts\make_packet.ps1") ($mk -join "`n")

$vp = @()
$vp += 'Set-StrictMode -Version Latest'
$vp += '$ErrorActionPreference="Stop"'
$vp += '. "$PSScriptRoot\lib\canon.ps1"'
$vp += ''
$vp += 'param([Parameter(Mandatory=$true)][string]$PacketRoot,[Parameter(Mandatory=$true)][string]$RuntimeRoot,[Parameter(Mandatory=$true)][string]$Principal)'
$vp += 'function ReadAllBytes([string]$p){ [IO.File]::ReadAllBytes($p) }'
$vp += 'function FileSha([string]$p){ Sha256Hex (ReadAllBytes $p) }'
$vp += '$Allowed = Join-Path $RuntimeRoot "keys\allowed_signers"'
$vp += 'if (-not (Test-Path -LiteralPath $Allowed)) { throw ("Missing allowed_signers: " + $Allowed) }'
$vp += ''
$vp += '# 1) sha256sums.txt verify'
$vp += '$shaPath = Join-Path $PacketRoot "sha256sums.txt"'
$vp += '$lines = Get-Content -LiteralPath $shaPath -Encoding UTF8'
$vp += 'foreach ($ln in $lines) { if ($ln.Trim() -eq "") { continue } ; $parts = $ln -split "\s{2,}"; if ($parts.Count -lt 2) { throw ("Bad sha256sums line: " + $ln) } ; $h=$parts[0].Trim(); $rel=$parts[1].Trim(); $p = Join-Path $PacketRoot ($rel -replace "/","\"); if (-not (Test-Path -LiteralPath $p)) { throw ("Missing file in packet: " + $rel) } ; $hh = FileSha $p; if ($hh -ne $h) { throw ("SHA256 MISMATCH: " + $rel) } }'
$vp += '# 2) commit hash verify'
$vp += '$commit = Join-Path $PacketRoot "payload\commit.payload.json"'
$vp += '$commitCanon = [System.Text.Encoding]::UTF8.GetString((Canon-JsonFileBytes $commit))'
$vp += '$commitHash = Sha256Hex ((Utf8NoBom).GetBytes($commitCanon))'
$vp += '$expected = (Get-Content -Raw -LiteralPath (Join-Path $PacketRoot "payload\commit_hash.txt") -Encoding UTF8).Trim()'
$vp += 'if ($commitHash -ne $expected) { throw "CommitHash mismatch" }'
$vp += '# 3) verify signature (ssh-keygen -Y verify)'
$vp += '$envPath = Join-Path $PacketRoot "payload\sig_envelope.json"'
$vp += '$envCanon = [System.Text.Encoding]::UTF8.GetString((Canon-JsonFileBytes $envPath))'
$vp += '$envNode = [System.Text.Json.Nodes.JsonNode]::Parse($envCanon)'
$vp += '$packetId = $envNode["signs"]["packet_id"].ToString()'
$vp += '$ingPath = Join-Path $PacketRoot "payload\nfl.ingest.json"'
$vp += '$ingCanon = [System.Text.Encoding]::UTF8.GetString((Canon-JsonFileBytes $ingPath))'
$vp += '$ingHash = Sha256Hex ((Utf8NoBom).GetBytes($ingCanon))'
$vp += '$msg = Join-Path $env:TEMP ("clarity_verifymsg_" + [Guid]::NewGuid().ToString("N") + ".txt")'
$vp += 'WriteUtf8Lf $msg (($commitHash + "`n" + $packetId + "`n" + $ingHash + "`n"))'
$vp += '$sig = Join-Path $PacketRoot "signatures\ingest.sig"'
$vp += '& ssh-keygen.exe -Y verify -n "nfl.ingest.v1" -I $Principal -f $Allowed -s $sig -o $msg | Out-Null'
$vp += 'Remove-Item -LiteralPath $msg -Force -ErrorAction SilentlyContinue'
$vp += 'Write-Host "VERIFY OK" -ForegroundColor Green'
WriteUtf8Lf (Join-Path $RepoRoot "scripts\verify_packet.ps1") ($vp -join "`n")

$pl = @()
$pl += 'Set-StrictMode -Version Latest'
$pl += '$ErrorActionPreference="Stop"'
$pl += '. "$PSScriptRoot\lib\canon.ps1"'
$pl += 'param([Parameter(Mandatory=$true)][string]$RuntimeRoot,[Parameter(Mandatory=$true)][string]$Tenant,[Parameter(Mandatory=$true)][string]$Principal,[Parameter(Mandatory=$true)][string]$ProducerInstance,[Parameter(Mandatory=$true)][string]$CommitHash,[Parameter(Mandatory=$true)][string]$SigPath,[Parameter(Mandatory=$true)][string]$KeyId)'
$pl += 'function EnsureDir([string]$p){ if(-not(Test-Path -LiteralPath $p)){ New-Item -ItemType Directory -Path $p -Force|Out-Null } }'
$pl += 'function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }'
$pl += '$log = Join-Path $RuntimeRoot "pledges\pledges.ndjson"'
$pl += 'EnsureDir (Split-Path -Parent $log)'
$pl += '$prev="GENESIS"; $seq=1'
$pl += 'if (Test-Path -LiteralPath $log) { $tail = Get-Content -LiteralPath $log -Tail 1 -ErrorAction SilentlyContinue; if ($tail) { $t=[System.Text.Json.Nodes.JsonNode]::Parse($tail); $prev=$t["log_hash"].ToString(); $seq=[int]$t["seq"].ToString()+1 } }'
$pl += '$o=[System.Text.Json.Nodes.JsonObject]::new()'
$pl += '$o["schema"]="local_pledge.v1"'
$pl += '$o["created_at_utc"]=UtcNow'
$pl += '$o["seq"]=$seq'
$pl += '$o["producer"]="clarity"'
$pl += '$o["producer_instance"]=$ProducerInstance'
$pl += '$o["tenant"]=$Tenant'
$pl += '$o["principal"]=$Principal'
$pl += '$o["key_id"]=$KeyId'
$pl += '$o["commit_hash"]=$CommitHash'
$pl += '$o["sig_path"]=$SigPath'
$pl += '$o["prev_log_hash"]=$prev'
$pl += '$no = Canon-JsonString ($o.ToJsonString())'
$pl += '$h = Sha256Hex ((Utf8NoBom).GetBytes($no))'
$pl += '$o["log_hash"]=$h'
$pl += '$line = Canon-JsonString ($o.ToJsonString())'
$pl += '$existing = $(if(Test-Path $log){ Get-Content -Raw -LiteralPath $log -Encoding UTF8 } else { "" })'
$pl += 'WriteUtf8Lf $log ($existing + $line + "`n")'
$pl += 'Write-Host ("PLEDGE OK seq={0} commit={1}" -f $seq, $CommitHash) -ForegroundColor Green'
WriteUtf8Lf (Join-Path $RepoRoot "scripts\pledge_local.ps1") ($pl -join "`n")

$dup = @()
$dup += 'Set-StrictMode -Version Latest'
$dup += '$ErrorActionPreference="Stop"'
$dup += 'param([Parameter(Mandatory=$true)][string]$PacketRoot,[Parameter(Mandatory=$true)][string]$NflInbox)'
$dup += '$packetId = Split-Path -Leaf $PacketRoot'
$dup += '$dst = Join-Path $NflInbox $packetId'
$dup += 'if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }'
$dup += 'Copy-Item -LiteralPath $PacketRoot -Destination $dst -Recurse -Force'
$dup += 'Write-Host ("DUP OK -> {0}" -f $dst) -ForegroundColor Green'
WriteUtf8Lf (Join-Path $RepoRoot "scripts\duplicate_to_nfl.ps1") ($dup -join "`n")

$lg = @()
$lg += 'Set-StrictMode -Version Latest'
$lg += '$ErrorActionPreference="Stop"'
$lg += 'param([Parameter(Mandatory=$true)][string]$RuntimeRoot,[Parameter(Mandatory=$true)][string]$ContentRef,[Parameter(Mandatory=$true)][string]$GrantId)'
$lg += 'if ($ContentRef -notmatch "^cas:sha256:([0-9a-f]{64})$") { throw "Bad content_ref" }'
$lg += '$h = $Matches[1]'
$lg += '$grantPath = Join-Path $RuntimeRoot ("library\access\sessions\{0}.json" -f $GrantId)'
$lg += 'if (-not (Test-Path -LiteralPath $grantPath)) { throw "ACCESS DENIED: missing grant" }'
$lg += '$hh = $h.Substring(0,2)'
$lg += '$objDir = Join-Path $RuntimeRoot ("library\objects\sha256\{0}\{1}" -f $hh, $h)'
$lg += 'if (-not (Test-Path -LiteralPath $objDir)) { throw "Missing object" }'
$lg += '$file = Get-ChildItem -LiteralPath $objDir -File | Select-Object -First 1'
$lg += 'if (-not $file) { throw "Missing object bytes" }'
$lg += 'Write-Host ("LIB GET OK: {0} -> {1}" -f $ContentRef, $file.FullName) -ForegroundColor Green'
$lg += 'Write-Output $file.FullName'
WriteUtf8Lf (Join-Path $RepoRoot "scripts\library_get.ps1") ($lg -join "`n")

$toParse = @(
  (Join-Path $RepoRoot "scripts\lib\canon.ps1"),
  (Join-Path $RepoRoot "scripts\library_put.ps1"),
  (Join-Path $RepoRoot "scripts\library_get.ps1"),
  (Join-Path $RepoRoot "scripts\make_packet.ps1"),
  (Join-Path $RepoRoot "scripts\verify_packet.ps1"),
  (Join-Path $RepoRoot "scripts\pledge_local.ps1"),
  (Join-Path $RepoRoot "scripts\duplicate_to_nfl.ps1")
)
foreach ($p in $toParse) { [ScriptBlock]::Create((Get-Content -Raw -LiteralPath $p -Encoding UTF8)) | Out-Null }
Write-Host ("BOOTSTRAP OK: " + $RepoRoot) -ForegroundColor Green
Write-Host ("RUNTIME   OK: " + $Runtime)  -ForegroundColor Green
Write-Host ("NFL INBOX OK: " + $NflInbox) -ForegroundColor Green
$Tenant="single-tenant"
$Principal="single-tenant/operator/user/alec"
$ProducerInstance="clarity-local-1"
$tmpTxt = Join-Path $env:TEMP ("clarity_transcript_" + [Guid]::NewGuid().ToString("N") + ".ndjson")
WriteUtf8Lf $tmpTxt ('{"schema":"clarity.transcript.v1","seq":1,"type":"clarity.verification.result.v1","ok":true}' + "`n")
$contentRef = & (Join-Path $RepoRoot "scripts\library_put.ps1") -RuntimeRoot $Runtime -InputPath $tmpTxt -Tenant $Tenant -Principal $Principal -ProducerInstance $ProducerInstance
$pkt = & (Join-Path $RepoRoot "scripts\make_packet.ps1") -RuntimeRoot $Runtime -Tenant $Tenant -Principal $Principal -ProducerInstance $ProducerInstance -EventType "clarity.verification.result.v1" -ContentRef $contentRef -Strength "evidence"
& (Join-Path $RepoRoot "scripts\verify_packet.ps1") -PacketRoot $pkt -RuntimeRoot $Runtime -Principal $Principal
$commitHash = (Get-Content -Raw -LiteralPath (Join-Path $pkt "payload\commit_hash.txt") -Encoding UTF8).Trim()
& (Join-Path $RepoRoot "scripts\pledge_local.ps1") -RuntimeRoot $Runtime -Tenant $Tenant -Principal $Principal -ProducerInstance $ProducerInstance -CommitHash $commitHash -SigPath ("outbox/" + (Split-Path -Leaf $pkt) + "/signatures/ingest.sig") -KeyId "clarity-dev-ed25519"
& (Join-Path $RepoRoot "scripts\duplicate_to_nfl.ps1") -PacketRoot $pkt -NflInbox $NflInbox
