param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

$ScriptsDir = Join-Path $RepoRoot "scripts"
if(-not (Test-Path -LiteralPath $ScriptsDir -PathType Container)){ throw ("MISSING_SCRIPTS_DIR: " + $ScriptsDir) }
$mkPath = Join-Path $ScriptsDir "make_packet.ps1"
$vpPath = Join-Path $ScriptsDir "verify_packet.ps1"

function ParseGateFile([string]$p){ [void][ScriptBlock]::Create((Get-Content -Raw -LiteralPath $p -Encoding UTF8)) }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function NormalizeText([string]$t){ if($null -eq $t){ $t="" }; $t=$t -replace "`r`n","`n" -replace "`r","`n"; if(-not $t.EndsWith("`n")){ $t += "`n" }; return $t }
function WriteUtf8NoBomLf([string]$Path,[string]$Text){ $dir=Split-Path -Parent $Path; if($dir -and -not(Test-Path -LiteralPath $dir -PathType Container)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }; $enc=Utf8NoBom; $t=NormalizeText $Text; [IO.File]::WriteAllBytes($Path,$enc.GetBytes($t)) }
function ReadUtf8Text([string]$Path){ [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($Path)) }
function Sha256HexBytes([byte[]]$bytes){ if($null -eq $bytes){ $bytes=[byte[]]@() }; $sha=[Security.Cryptography.SHA256]::Create(); ($sha.ComputeHash([byte[]]$bytes) | ForEach-Object { $_.ToString("x2") }) -join "" }
function Sha256HexFile([string]$Path){ Sha256HexBytes ([IO.File]::ReadAllBytes($Path)) }
function Sha256HexTextNormalized([string]$text){ $enc=Utf8NoBom; $t=NormalizeText $text; Sha256HexBytes ($enc.GetBytes($t)) }
function EnsureDir([string]$p){ if(-not(Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function EscapeJson([string]$s){ if($null -eq $s){ return "" }; $s=$s -replace "\\","\\\\"; $s=$s -replace "`"","\\`""; $s=$s -replace "`n","\\n"; $s=$s -replace "`t","\\t"; return $s }
function RunExe([string]$Exe,[string[]]$Args,[string]$Stdout,[string]$Stderr){
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Exe
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true
  foreach($a in @($Args)){ [void]$psi.ArgumentList.Add([string]$a) }
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $so = $p.StandardOutput.ReadToEnd()
  $se = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  WriteUtf8NoBomLf $Stdout $so
  WriteUtf8NoBomLf $Stderr $se
  return @{ exit = [int]$p.ExitCode; out=$Stdout; err=$Stderr }
}

function WriteScript([string]$Path,[string[]]$Lines){
  $txt = (($Lines -join "`n") + "`n")
  WriteUtf8NoBomLf $Path $txt
  ParseGateFile $Path
}

$mk = @()
$mk += 'param([Parameter(Mandatory=$true)][string]$RuntimeRoot,[Parameter(Mandatory=$true)][string]$Tenant,[Parameter(Mandatory=$true)][string]$Principal,[Parameter(Mandatory=$true)][string]$ProducerInstance,[Parameter(Mandatory=$true)][string]$EventType,[Parameter(Mandatory=$true)][string]$ContentRef,[Parameter(Mandatory=$true)][ValidateSet("evidence","deterministic")][string]$Strength)'
$mk += 'Set-StrictMode -Version Latest'
$mk += '$ErrorActionPreference="Stop"'
$mk += '. "$PSScriptRoot\lib\canon.ps1"'
$mk += 'function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }'
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
$mk += '$commit = "{"'
$mk += '$commit += "`"schema`":`"commitment.v1`","'
$mk += '$commit += "`"producer`":`"clarity`","'
$mk += '$commit += "`"producer_instance`":`"" + (EscapeJson $ProducerInstance) + "`","'
$mk += '$commit += "`"tenant`":`"" + (EscapeJson $Tenant) + "`","'
$mk += '$commit += "`"principal`":`"" + (EscapeJson $Principal) + "`","'
$mk += '$commit += "`"event_type`":`"" + (EscapeJson $EventType) + "`","'
$mk += '$commit += "`"event_time_utc`":`"" + (EscapeJson $eventTime) + "`","'
$mk += '$commit += "`"prev_links`":[],"'
$mk += '$commit += "`"content_ref`":`"" + (EscapeJson $ContentRef) + "`","'
$mk += '$commit += "`"strength`":`"" + (EscapeJson $Strength) + "`""'
$mk += '$commit += "}"'
$mk += '$commitPath = Join-Path $tmp "payload\commit.payload.json"'
$mk += 'WriteUtf8NoBomLf $commitPath $commit'
$mk += '$commitHash = Sha256HexTextNormalized $commit'
$mk += 'WriteUtf8NoBomLf (Join-Path $tmp "payload\commit_hash.txt") ($commitHash + "`n")'

$mk += '# 2) nfl.ingest.json (packet_id filled later)'
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
$mk += '$h1 = Sha256HexFile $fi1.FullName; $h2 = Sha256HexFile $fi2.FullName; $h3 = Sha256HexFile $fi3.FullName'
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

$mk += '# 5) detached signature over msg = commit_hash + packet_id + ingest_hash (file is last arg)'
$mk += '$msg = Join-Path $env:TEMP ("clarity_signmsg_" + [Guid]::NewGuid().ToString("N") + ".txt")'
$mk += 'WriteUtf8NoBomLf $msg ($commitHash + "`n" + $packetId + "`n" + $ingHash + "`n")'
$mk += '$so = Join-Path $env:TEMP ("clarity_ssh_sign_out_" + [Guid]::NewGuid().ToString("N") + ".log")'
$mk += '$se = Join-Path $env:TEMP ("clarity_ssh_sign_err_" + [Guid]::NewGuid().ToString("N") + ".log")'
$mk += '$r = RunExe "ssh-keygen.exe" @("-Y","sign","-f",$KeyBase,"-n","nfl.ingest.v1","-I",$Principal,$msg) $so $se'
$mk += 'if($r.exit -ne 0){ throw ("SSHKEYGEN_SIGN_FAIL exit=" + $r.exit + " out=" + $r.out + " err=" + $r.err) }'
$mk += '$sigFrom = $msg + ".sig"'
$mk += '$sigTo   = Join-Path $tmp "signatures\ingest.sig"'
$mk += 'if(-not(Test-Path -LiteralPath $sigFrom -PathType Leaf)){ throw ("MISSING_SIG_FROM_SSHKEYGEN: " + $sigFrom) }'
$mk += 'Copy-Item -LiteralPath $sigFrom -Destination $sigTo -Force'
$mk += 'Remove-Item -LiteralPath $sigFrom -Force -ErrorAction SilentlyContinue'
$mk += 'Remove-Item -LiteralPath $msg -Force -ErrorAction SilentlyContinue'

$mk += '# 6) sha256sums LAST over final bytes (sorted by relpath)'
$mk += '$files = Get-ChildItem -LiteralPath $tmp -Recurse -File | Where-Object { $_.Name -ne "sha256sums.txt" }'
$mk += '$rows = New-Object System.Collections.Generic.List[string]'
$mk += 'foreach($f in $files){ $rel=$f.FullName.Substring($tmp.Length).TrimStart("\"); $rel=$rel.Replace("\","/"); $h=Sha256HexFile $f.FullName; [void]$rows.Add(("{0}  {1}" -f $h,$rel)) }'
$mk += 'WriteUtf8NoBomLf (Join-Path $tmp "sha256sums.txt") ((($rows.ToArray() | Sort-Object) -join "`n") + "`n")'

$mk += '# finalize folder name = PacketId'
$mk += '$final = Join-Path $outbox $packetId'
$mk += 'if(Test-Path -LiteralPath $final){ throw ("Packet already exists: " + $final) }'
$mk += 'Move-Item -LiteralPath $tmp -Destination $final -Force'
$mk += 'Write-Host ("PACKET OK (Option A): " + $final) -ForegroundColor Green'
$mk += 'Write-Output $final'
WriteScript $mkPath $mk

$vp = @()
$vp += 'param([Parameter(Mandatory=$true)][string]$PacketRoot,[Parameter(Mandatory=$true)][string]$RuntimeRoot,[Parameter(Mandatory=$true)][string]$Principal)'
$vp += 'Set-StrictMode -Version Latest'
$vp += '$ErrorActionPreference="Stop"'
$vp += '. "$PSScriptRoot\lib\canon.ps1"'
$vp += '$Allowed = Join-Path $RuntimeRoot "keys\allowed_signers"'
$vp += 'if(-not(Test-Path -LiteralPath $Allowed -PathType Leaf)){ throw ("Missing allowed_signers: " + $Allowed) }'
$vp += 'if(-not(Test-Path -LiteralPath $PacketRoot -PathType Container)){ throw ("Missing PacketRoot: " + $PacketRoot) }'
$vp += '$manPath = Join-Path $PacketRoot "manifest.json"; if(-not(Test-Path -LiteralPath $manPath -PathType Leaf)){ throw "Missing manifest.json" }'
$vp += '$manRaw = ReadUtf8Text $manPath'
$vp += '$packetId = Sha256HexTextNormalized $manRaw'
$vp += '$folderId = Split-Path -Leaf $PacketRoot'
$vp += 'if($folderId -ne $packetId){ throw ("PACKET_ID_MISMATCH folder=" + $folderId + " computed=" + $packetId) }'
$vp += '$pidPath = Join-Path $PacketRoot "packet_id.txt"; if(-not(Test-Path -LiteralPath $pidPath -PathType Leaf)){ throw "Missing packet_id.txt" }'
$vp += '$pid = (Get-Content -Raw -LiteralPath $pidPath -Encoding UTF8).Trim(); if($pid -ne $packetId){ throw ("PACKET_ID_TXT_MISMATCH txt=" + $pid + " computed=" + $packetId) }'
$vp += '$shaPath = Join-Path $PacketRoot "sha256sums.txt"; if(-not(Test-Path -LiteralPath $shaPath -PathType Leaf)){ throw "Missing sha256sums.txt" }'
$vp += '$lines = Get-Content -LiteralPath $shaPath -Encoding UTF8'
$vp += 'foreach($ln in $lines){ $t=$ln.Trim(); if($t -eq ""){ continue }; $parts = $ln -split "\s{2,}"; if(@($parts).Count -lt 2){ throw ("BAD_SHA256SUMS_LINE: " + $ln) }; $h=$parts[0].Trim(); $rel=$parts[1].Trim(); if($rel.Contains("..")){ throw ("PATH_TRAVERSAL: " + $rel) }; $p=Join-Path $PacketRoot ($rel.Replace("/","\")); if(-not(Test-Path -LiteralPath $p -PathType Leaf)){ throw ("MISSING_FILE: " + $rel) }; $hh=Sha256HexFile $p; if($hh -ne $h){ throw ("SHA256_MISMATCH: " + $rel) } }'
$vp += '$commitPath = Join-Path $PacketRoot "payload\commit.payload.json"; if(-not(Test-Path -LiteralPath $commitPath -PathType Leaf)){ throw "Missing payload/commit.payload.json" }'
$vp += '$commitRaw = ReadUtf8Text $commitPath'
$vp += '$commitHash = Sha256HexTextNormalized $commitRaw'
$vp += '$expected = (Get-Content -Raw -LiteralPath (Join-Path $PacketRoot "payload\commit_hash.txt") -Encoding UTF8).Trim()'
$vp += 'if($commitHash -ne $expected){ throw "COMMIT_HASH_MISMATCH" }'
$vp += '$ingPath = Join-Path $PacketRoot "payload\nfl.ingest.json"; if(-not(Test-Path -LiteralPath $ingPath -PathType Leaf)){ throw "Missing payload/nfl.ingest.json" }'
$vp += '$ingRaw = ReadUtf8Text $ingPath'
$vp += '$ingHash = Sha256HexTextNormalized $ingRaw'
$vp += '$sig = Join-Path $PacketRoot "signatures\ingest.sig"; if(-not(Test-Path -LiteralPath $sig -PathType Leaf)){ throw "Missing signatures/ingest.sig" }'
$vp += '$msg = Join-Path $env:TEMP ("clarity_verifymsg_" + [Guid]::NewGuid().ToString("N") + ".txt")'
$vp += 'WriteUtf8NoBomLf $msg ($commitHash + "`n" + $packetId + "`n" + $ingHash + "`n")'
$vp += '$so = Join-Path $env:TEMP ("clarity_ssh_verify_out_" + [Guid]::NewGuid().ToString("N") + ".log")'
$vp += '$se = Join-Path $env:TEMP ("clarity_ssh_verify_err_" + [Guid]::NewGuid().ToString("N") + ".log")'
$vp += '$r = RunExe "ssh-keygen.exe" @("-Y","verify","-f",$Allowed,"-I",$Principal,"-n","nfl.ingest.v1","-s",$sig,$msg) $so $se'
$vp += 'Remove-Item -LiteralPath $msg -Force -ErrorAction SilentlyContinue'
$vp += 'if($r.exit -ne 0){ throw ("SSHKEYGEN_VERIFY_FAIL exit=" + $r.exit + " out=" + $r.out + " err=" + $r.err) }'
$vp += 'Write-Host ("VERIFY OK (Option A): " + $PacketRoot) -ForegroundColor Green'
WriteScript $vpPath $vp

Write-Host ("PATCH_OK: overwrote make_packet.ps1 + verify_packet.ps1") -ForegroundColor Green
