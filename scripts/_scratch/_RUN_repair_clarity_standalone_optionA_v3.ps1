param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

function EnsureDir([string]$p){ if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function NormalizeText([string]$t){
  if($null -eq $t){ $t = "" }
  $t = $t -replace "`r`n","`n" -replace "`r","`n"
  if(-not $t.EndsWith("`n")){ $t += "`n" }
  return $t
}
function WriteUtf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ EnsureDir $dir }
  $enc = Utf8NoBom
  $t = NormalizeText $Text
  [IO.File]::WriteAllBytes($Path, $enc.GetBytes($t))
}
function ReadUtf8Text([string]$Path){
  $b = [IO.File]::ReadAllBytes($Path)
  return [Text.Encoding]::UTF8.GetString($b)
}
function Sha256HexBytes([byte[]]$bytes){
  if($null -eq $bytes){ $bytes = [byte[]]@() }
  $sha = [Security.Cryptography.SHA256]::Create()
  ($sha.ComputeHash([byte[]]$bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
}
function Sha256HexTextNormalized([string]$text){
  $enc = Utf8NoBom
  $t = NormalizeText $text
  return Sha256HexBytes ($enc.GetBytes($t))
}
function Sha256HexFile([string]$Path){ Sha256HexBytes ([IO.File]::ReadAllBytes($Path)) }
function ParseGateFile([string]$p){ [void][ScriptBlock]::Create((Get-Content -Raw -LiteralPath $p -Encoding UTF8)) }

function EscapeJson([string]$s){
  if($null -eq $s){ return "" }
  $s = $s -replace "\\","\\\\"
  $s = $s -replace "`"","\\`""
  $s = $s -replace "`n","\\n"
  $s = $s -replace "`t","\\t"
  return $s
}

# --------------------------------
# Write scripts (PS5.1-safe)
# --------------------------------
$ScriptsDir = Join-Path $RepoRoot "scripts"
$LibDir     = Join-Path $ScriptsDir "lib"
EnsureDir $ScriptsDir
EnsureDir $LibDir
$canonPath = Join-Path $LibDir "canon.ps1"
$bootPath  = Join-Path $ScriptsDir "_bootstrap_clarity_standalone_v1.ps1"
$mkPath    = Join-Path $ScriptsDir "make_packet.ps1"
$vpPath    = Join-Path $ScriptsDir "verify_packet.ps1"
$dnPath    = Join-Path $ScriptsDir "duplicate_to_nfl.ps1"

function WriteScript([string]$Path,[string[]]$Lines){
  $txt = (($Lines -join "`n") + "`n")
  WriteUtf8NoBomLf $Path $txt
  ParseGateFile $Path
}

# canon.ps1
$canon = @()
$canon += 'Set-StrictMode -Version Latest'
$canon += '$ErrorActionPreference="Stop"'
$canon += 'function EnsureDir([string]$p){ if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }'
$canon += 'function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }'
$canon += 'function NormalizeText([string]$t){ if($null -eq $t){ $t="" }; $t=$t -replace "`r`n","`n" -replace "`r","`n"; if(-not $t.EndsWith("`n")){ $t += "`n" }; return $t }'
$canon += 'function WriteUtf8NoBomLf([string]$Path,[string]$Text){ $dir=Split-Path -Parent $Path; if($dir){ EnsureDir $dir }; $enc=Utf8NoBom; $t=NormalizeText $Text; [IO.File]::WriteAllBytes($Path,$enc.GetBytes($t)) }'
$canon += 'function ReadUtf8Text([string]$Path){ [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($Path)) }'
$canon += 'function Sha256HexBytes([byte[]]$bytes){ if($null -eq $bytes){ $bytes=[byte[]]@() }; $sha=[Security.Cryptography.SHA256]::Create(); ($sha.ComputeHash([byte[]]$bytes) | ForEach-Object { $_.ToString("x2") }) -join "" }'
$canon += 'function Sha256HexFile([string]$Path){ Sha256HexBytes ([IO.File]::ReadAllBytes($Path)) }'
$canon += 'function Sha256HexTextNormalized([string]$text){ $enc=Utf8NoBom; $t=NormalizeText $text; Sha256HexBytes ($enc.GetBytes($t)) }'
$canon += 'function EscapeJson([string]$s){ if($null -eq $s){ return "" }; $s=$s -replace "\\","\\\\"; $s=$s -replace "`"","\\`""; $s=$s -replace "`n","\\n"; $s=$s -replace "`t","\\t"; return $s }'
WriteScript $canonPath $canon

# _bootstrap_clarity_standalone_v1.ps1
$boot = @()
$boot += 'param([string]$RepoRoot="C:\dev\clarity",[string]$RuntimeRoot="C:\ProgramData\Clarity",[string]$NflInbox="C:\ProgramData\NFL\inbox",[string]$Principal="single-tenant/operator/user/alec")'
$boot += 'Set-StrictMode -Version Latest'
$boot += '$ErrorActionPreference="Stop"'
$boot += '. "$PSScriptRoot\lib\canon.ps1"'
$boot += '# Repo dirs'
$boot += 'EnsureDir (Join-Path $RepoRoot "contracts")'
$boot += 'EnsureDir (Join-Path $RepoRoot "schemas")'
$boot += 'EnsureDir (Join-Path $RepoRoot "scripts")'
$boot += 'EnsureDir (Join-Path $RepoRoot "scripts\lib")'
$boot += '# Runtime dirs (standalone)'
$boot += 'EnsureDir $RuntimeRoot'
$boot += 'EnsureDir (Join-Path $RuntimeRoot "keys")'
$boot += 'EnsureDir (Join-Path $RuntimeRoot "pledges")'
$boot += 'EnsureDir (Join-Path $RuntimeRoot "outbox")'
$boot += 'EnsureDir (Join-Path $RuntimeRoot "library\ledger")'
$boot += 'EnsureDir (Join-Path $RuntimeRoot "library\objects\sha256")'
$boot += 'EnsureDir (Join-Path $RuntimeRoot "library\manifests\sha256")'
$boot += 'EnsureDir (Join-Path $RuntimeRoot "library\access\sessions")'
$boot += '# NFL OPTIONAL'
$boot += 'if(Test-Path -LiteralPath $NflInbox -PathType Container){ EnsureDir $NflInbox }'

$boot += '# LAW.md (ASCII only; keep boring)'
$boot += '$law = @()'
$boot += '$law += "# Clarity LAW.md (LOCKED) - Standalone v1 + Packet Constitution v1 Option A"'
$boot += '$law += ""'
$boot += '$law += "Clarity MUST boot and run standalone. NFL is an integration target, never a dependency."'
$boot += '$law += ""'
$boot += '$law += "Packet Constitution v1 (Option A): manifest.json MUST NOT contain packet_id; packet_id.txt does; sha256sums.txt last."'
$boot += 'WriteUtf8NoBomLf (Join-Path $RepoRoot "LAW.md") (($law -join "`n") + "`n")'

$boot += '# contracts/event_types.v1.json (static; no nested quoting games)'
$boot += '$evText = "{`n  `"`"schema`"`": `"`"event_types.v1`"`",`n  `"`"producer`"`": `"`"clarity`"`",`n  `"`"types`"`": [`n    `"`"clarity.run.started.v1`"`",`n    `"`"clarity.verification.result.v1`"`",`n    `"`"clarity.run.completed.v1`"`",`n    `"`"clarity.library.object.added.v1`"`",`n    `"`"clarity.library.object.sealed.v1`"`",`n    `"`"clarity.nfl.packet.built.v1`"`",`n    `"`"clarity.nfl.packet.verified.v1`"`",`n    `"`"clarity.nfl.pledged.local.v1`"`",`n    `"`"clarity.nfl.duplicated.v1`"`",`n    `"`"clarity.nfl.duplicate.failed.v1`"`"`n  ]`n}`n"'
$boot += 'WriteUtf8NoBomLf (Join-Path $RepoRoot "contracts\event_types.v1.json") $evText'

$boot += '# Dev key + allowed_signers (standalone)'
$boot += '$keyBase = Join-Path $RuntimeRoot "keys\clarity_dev_ed25519"'
$boot += '$pubPath = $keyBase + ".pub"'
$boot += '$allowed = Join-Path $RuntimeRoot "keys\allowed_signers"'
$boot += 'if(-not(Test-Path -LiteralPath $keyBase -PathType Leaf) -or -not(Test-Path -LiteralPath $pubPath -PathType Leaf)){'
$boot += '  # preserve -N "" using Start-Process with a single string'
$boot += '  $arg = "-t ed25519 -f `"" + $keyBase + "`" -N `"`"`""'
$boot += '  $p = Start-Process -FilePath "ssh-keygen.exe" -ArgumentList $arg -Wait -PassThru -NoNewWindow'
$boot += '  if($p.ExitCode -ne 0){ throw ("ssh-keygen failed exit_code=" + $p.ExitCode) }'
$boot += '}'
$boot += '$pubLine = (Get-Content -Raw -LiteralPath $pubPath -Encoding UTF8).Trim()'
$boot += '$allowedLine = ("{0} {1}" -f $Principal, $pubLine)'
$boot += 'WriteUtf8NoBomLf $allowed ($allowedLine + "`n")'
$boot += 'Write-Host ("BOOTSTRAP OK: RepoRoot=" + $RepoRoot) -ForegroundColor Green'
$boot += 'Write-Host ("BOOTSTRAP OK: RuntimeRoot=" + $RuntimeRoot) -ForegroundColor Green'
$boot += 'if(Test-Path -LiteralPath $NflInbox -PathType Container){ Write-Host ("NFL present (optional): " + $NflInbox) -ForegroundColor DarkGray } else { Write-Host "NFL not present (OK): skipping NFL wiring" -ForegroundColor DarkGray }'
WriteScript $bootPath $boot

# make_packet.ps1 (complete; boring; no JSON parser)
$mk = @()
$mk += 'param([Parameter(Mandatory=$true)][string]$RuntimeRoot,[Parameter(Mandatory=$true)][string]$Tenant,[Parameter(Mandatory=$true)][string]$Principal,[Parameter(Mandatory=$true)][string]$ProducerInstance,[Parameter(Mandatory=$true)][string]$EventType,[Parameter(Mandatory=$true)][string]$ContentRef,[Parameter(Mandatory=$true)][ValidateSet("evidence","deterministic")][string]$Strength)'
$mk += 'Set-StrictMode -Version Latest'
$mk += '$ErrorActionPreference="Stop"'
$mk += '. "$PSScriptRoot\lib\canon.ps1"'
$mk += 'function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }'
$mk += 'function FileSha([string]$p){ Sha256HexFile $p }'
$mk += '$KeyBase  = Join-Path $RuntimeRoot "keys\clarity_dev_ed25519"'
$mk += '$Allowed  = Join-Path $RuntimeRoot "keys\allowed_signers"'
$mk += 'if(-not(Test-Path -LiteralPath $KeyBase -PathType Leaf)){ throw ("Missing key: " + $KeyBase) }'
$mk += 'if(-not(Test-Path -LiteralPath ($KeyBase + ".pub") -PathType Leaf)){ throw ("Missing pubkey: " + ($KeyBase + ".pub")) }'
$mk += 'if(-not(Test-Path -LiteralPath $Allowed -PathType Leaf)){ throw ("Missing allowed_signers: " + $Allowed) }'
$mk += '$outbox = Join-Path $RuntimeRoot "outbox"; EnsureDir $outbox'
$mk += '$tmp = Join-Path $outbox ("tmp_" + [Guid]::NewGuid().ToString("N")); EnsureDir $tmp'
$mk += 'EnsureDir (Join-Path $tmp "payload")'
$mk += 'EnsureDir (Join-Path $tmp "signatures")'

$mk += '# 1) commit.payload.json (ordered keys; minified; LF)'
$mk += '$eventTime = UtcNow'
$mk += '$ing = "{"'
$mk += '$ing += "`"schema`":`"nfl.ingest.v1`","'
$mk += '$ing += "`"packet_id`":`"__PENDING__`","'
$mk += '$ing += "`"commit_hash`":`"" + $commitHash + "`","'
$mk += '$ing += "`"producer`":`"clarity`","'
$mk += '$ing += "`"producer_instance`":`"" + (EscapeJson $ProducerInstance) + "`","'
$mk += '$ing += "`"tenant`":`"" + (EscapeJson $Tenant) + "`","'
$mk += '$ing += "`"principal`":`"" + (EscapeJson $Principal) + "`","'
$mk += '$ing += "`"event_type`":`"" + (EscapeJson $EventType) + "`","'
$mk += '$ing += "`"event_time_utc`":`"" + (EscapeJson $eventTime) + "`","'
$mk += '$ing += "`"prev_links`":[],"'
$mk += '$ing += "`"payload_mode`":`"pointer_only`","'
$mk += '$ing += "`"payload_ref`":`"" + (EscapeJson $ContentRef) + "`","'
$mk += '$ing += "`"producer_key_id`":`"clarity-dev-ed25519`","'
$mk += '$ing += "`"producer_sig_ref`":`"signatures/ingest.sig`""'
$mk += '$ing += "}"'
$mk += '$ingPath = Join-Path $tmp "payload\nfl.ingest.json"'
$mk += 'WriteUtf8NoBomLf $ingPath $ing'

$mk += '# 3) manifest.json WITHOUT packet_id (Option A; fixed file order)'
$mk += '$createdAt = UtcNow'
$mk += '$p1 = Join-Path $tmp "payload\commit.payload.json"'
$mk += '$p2 = Join-Path $tmp "payload\commit_hash.txt"'
$mk += '$p3 = Join-Path $tmp "payload\nfl.ingest.json"'
$mk += '$fi1 = Get-Item -LiteralPath $p1; $fi2 = Get-Item -LiteralPath $p2; $fi3 = Get-Item -LiteralPath $p3'
$mk += '$h1 = FileSha $fi1.FullName; $h2 = FileSha $fi2.FullName; $h3 = FileSha $fi3.FullName'
$mk += '$m = "{"'
$mk += '$m += "`"schema`":`"packet_manifest.v1`","'
$mk += '$m += "`"producer`":`"clarity`","'
$mk += '$m += "`"producer_instance`":`"" + (EscapeJson $ProducerInstance) + "`","'
$mk += '$m += "`"created_at_utc`":`"" + (EscapeJson $createdAt) + "`","'
$mk += '$m += "`"files`":["'
$mk += '$m += "{`"path`":`"payload/commit.payload.json`",`"bytes`":" + [int]$fi1.Length + ",`"sha256`":`"" + $h1 + "`"},"'
$mk += '$m += "{`"path`":`"payload/commit_hash.txt`",`"bytes`":" + [int]$fi2.Length + ",`"sha256`":`"" + $h2 + "`"},"'
$mk += '$m += "{`"path`":`"payload/nfl.ingest.json`",`"bytes`":" + [int]$fi3.Length + ",`"sha256`":`"" + $h3 + "`"}"'
$mk += '$m += "]"'
$mk += '$m += "}"'
$mk += '$manPath = Join-Path $tmp "manifest.json"'
$mk += 'WriteUtf8NoBomLf $manPath $m'
$mk += '$packetId = Sha256HexTextNormalized $m'
$mk += 'WriteUtf8NoBomLf (Join-Path $tmp "packet_id.txt") ($packetId + "`n")'

$mk += '# 4) update nfl.ingest.json packet_id (manifest never changes)'
$mk += '$ing2 = $ing -replace "`"packet_id`":`"__PENDING__`"","`"packet_id`":`"" + $packetId + "`""'
$mk += 'WriteUtf8NoBomLf $ingPath $ing2'
$mk += '$ingHash = Sha256HexTextNormalized $ing2'

$mk += '# 5) detached signature over msg = commit_hash + packet_id + ingest_hash'
$mk += '$msg = Join-Path $env:TEMP ("clarity_signmsg_" + [Guid]::NewGuid().ToString("N") + ".txt")'
$mk += 'WriteUtf8NoBomLf $msg (($commitHash + "`n" + $packetId + "`n" + $ingHash + "`n"))'
$mk += '& ssh-keygen.exe -Y sign -f $KeyBase -n "nfl.ingest.v1" -I $Principal -o $msg | Out-Null'
$mk += '$sigFrom = $msg + ".sig"'
$mk += '$sigTo   = Join-Path $tmp "signatures\ingest.sig"'
$mk += 'Copy-Item -LiteralPath $sigFrom -Destination $sigTo -Force'
$mk += 'Remove-Item -LiteralPath $sigFrom -Force -ErrorAction SilentlyContinue'
$mk += 'Remove-Item -LiteralPath $msg -Force -ErrorAction SilentlyContinue'

$mk += '# 6) sha256sums LAST over final bytes'
$mk += '$files = Get-ChildItem -LiteralPath $tmp -Recurse -File | Where-Object { $_.Name -ne "sha256sums.txt" }'
$mk += '$out = New-Object System.Collections.Generic.List[string]'
$mk += 'foreach($f in $files){ $rel=$f.FullName.Substring($tmp.Length).TrimStart("\") -replace "\\","/"; $h=Sha256HexFile $f.FullName; [void]$out.Add(("{0}  {1}" -f $h,$rel)) }'
$mk += 'WriteUtf8NoBomLf (Join-Path $tmp "sha256sums.txt") ((($out.ToArray() | Sort-Object) -join "`n") + "`n")'

$mk += '# finalize folder name = PacketId'
$mk += '$final = Join-Path $outbox $packetId'
$mk += 'if(Test-Path -LiteralPath $final){ throw ("Packet already exists: " + $final) }'
$mk += 'Move-Item -LiteralPath $tmp -Destination $final -Force'
$mk += 'Write-Host ("PACKET OK (Option A): " + $final) -ForegroundColor Green'
$mk += 'Write-Output $final'
WriteScript $mkPath $mk

# verify_packet.ps1 (no mutation; no JSON parsing)
$vp = @()
$vp += 'param([Parameter(Mandatory=$true)][string]$PacketRoot,[Parameter(Mandatory=$true)][string]$RuntimeRoot,[Parameter(Mandatory=$true)][string]$Principal)'
$vp += 'Set-StrictMode -Version Latest'
$vp += '$ErrorActionPreference="Stop"'
$vp += '. "$PSScriptRoot\lib\canon.ps1"'
$vp += '$Allowed = Join-Path $RuntimeRoot "keys\allowed_signers"'
$vp += 'if(-not(Test-Path -LiteralPath $Allowed -PathType Leaf)){ throw ("Missing allowed_signers: " + $Allowed) }'
$vp += '$manPath = Join-Path $PacketRoot "manifest.json"; if(-not(Test-Path -LiteralPath $manPath -PathType Leaf)){ throw "Missing manifest.json" }'
$vp += '$manRaw = ReadUtf8Text $manPath'
$vp += '$packetId = Sha256HexTextNormalized $manRaw'
$vp += '$folderId = Split-Path -Leaf $PacketRoot'
$vp += 'if($folderId -ne $packetId){ throw ("PACKET_ID_MISMATCH folder=" + $folderId + " computed=" + $packetId) }'
$vp += '$pidPath = Join-Path $PacketRoot "packet_id.txt"; if(-not(Test-Path -LiteralPath $pidPath -PathType Leaf)){ throw "Missing packet_id.txt" }'
$vp += '$pid = (Get-Content -Raw -LiteralPath $pidPath -Encoding UTF8).Trim(); if($pid -ne $packetId){ throw "packet_id.txt mismatch" }'
$vp += '$shaPath = Join-Path $PacketRoot "sha256sums.txt"; if(-not(Test-Path -LiteralPath $shaPath -PathType Leaf)){ throw "Missing sha256sums.txt" }'
$vp += '$lines = Get-Content -LiteralPath $shaPath -Encoding UTF8'
$vp += 'foreach($ln in $lines){ if($ln.Trim() -eq ""){ continue }; $parts = $ln -split "\s{2,}"; if(@($parts).Count -lt 2){ throw ("Bad sha256sums line: " + $ln) }; $h=$parts[0].Trim(); $rel=$parts[1].Trim(); $p=Join-Path $PacketRoot ($rel -replace "/","\"); if(-not(Test-Path -LiteralPath $p -PathType Leaf)){ throw ("Missing file in packet: " + $rel) }; $hh=Sha256HexFile $p; if($hh -ne $h){ throw ("SHA256_MISMATCH: " + $rel) } }'
$vp += '$commitPath = Join-Path $PacketRoot "payload\commit.payload.json"'
$vp += '$commitRaw = ReadUtf8Text $commitPath'
$vp += '$commitHash = Sha256HexTextNormalized $commitRaw'
$vp += '$expected = (Get-Content -Raw -LiteralPath (Join-Path $PacketRoot "payload\commit_hash.txt") -Encoding UTF8).Trim()'
$vp += 'if($commitHash -ne $expected){ throw "COMMIT_HASH_MISMATCH" }'
$vp += '$ingPath = Join-Path $PacketRoot "payload\nfl.ingest.json"'
$vp += '$ingRaw = ReadUtf8Text $ingPath'
$vp += '$ingHash = Sha256HexTextNormalized $ingRaw'
$vp += '$msg = Join-Path $env:TEMP ("clarity_verifymsg_" + [Guid]::NewGuid().ToString("N") + ".txt")'
$vp += 'WriteUtf8NoBomLf $msg (($commitHash + "`n" + $packetId + "`n" + $ingHash + "`n"))'
$vp += '$sig = Join-Path $PacketRoot "signatures\ingest.sig"; if(-not(Test-Path -LiteralPath $sig -PathType Leaf)){ throw "Missing signatures/ingest.sig" }'
$vp += '& ssh-keygen.exe -Y verify -n "nfl.ingest.v1" -I $Principal -f $Allowed -s $sig -o $msg | Out-Null'
$vp += 'Remove-Item -LiteralPath $msg -Force -ErrorAction SilentlyContinue'
$vp += 'Write-Host ("VERIFY OK (Option A): " + $PacketRoot) -ForegroundColor Green'
WriteScript $vpPath $vp

# duplicate_to_nfl.ps1 (unchanged behavior; param first)
$dn = @()
$dn += 'param([Parameter(Mandatory=$true)][string]$PacketRoot,[string]$NflInbox="C:\ProgramData\NFL\inbox")'
$dn += 'Set-StrictMode -Version Latest'
$dn += '$ErrorActionPreference="Stop"'
$dn += 'if(-not(Test-Path -LiteralPath $PacketRoot -PathType Container)){ throw ("Missing PacketRoot: " + $PacketRoot) }'
$dn += 'if(-not(Test-Path -LiteralPath $NflInbox -PathType Container)){ Write-Host "NFL not present (OK): skipping duplication." -ForegroundColor DarkGray; return }'
$dn += '$id = Split-Path -Leaf $PacketRoot'
$dn += '$dst = Join-Path $NflInbox $id'
$dn += 'if(Test-Path -LiteralPath $dst){ throw ("NFL destination already exists: " + $dst) }'
$dn += 'Copy-Item -LiteralPath $PacketRoot -Destination $dst -Recurse -Force'
$dn += 'Write-Host ("NFL DUPLICATE OK: " + $dst) -ForegroundColor Green'
WriteScript $dnPath $dn

Write-Host ("REPAIR_V3_OK: wrote + parse-gated scripts under " + (Join-Path $RepoRoot "scripts")) -ForegroundColor Green
Write-Host "NEXT:" -ForegroundColor DarkGray
Write-Host ("  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"" + (Join-Path $RepoRoot "scripts\_bootstrap_clarity_standalone_v1.ps1") + "`" -RepoRoot `"" + $RepoRoot + "`"") -ForegroundColor DarkGray
Write-Host ("  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"" + (Join-Path $RepoRoot "scripts\make_packet.ps1") + "`" -RuntimeRoot `"C:\ProgramData\Clarity`" -Tenant `"single-tenant`" -Principal `"single-tenant/operator/user/alec`" -ProducerInstance `"$env:COMPUTERNAME-standalone-1`" -EventType `"clarity.run.started.v1`" -ContentRef `"cas:sha256:deadbeef`" -Strength `"evidence`"") -ForegroundColor DarkGray
Write-Host "  # verify using the printed packet path:" -ForegroundColor DarkGray
Write-Host ("  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"" + (Join-Path $RepoRoot "scripts\verify_packet.ps1") + "`" -PacketRoot `"<PACKET_PATH>`" -RuntimeRoot `"C:\ProgramData\Clarity`" -Principal `"single-tenant/operator/user/alec`"") -ForegroundColor DarkGray
