param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

function EnsureDir([string]$p){ if([string]::IsNullOrWhiteSpace($p)){ throw "ENSURE_DIR_EMPTY" }; if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function NormalizeLf([string]$t){ if($null -eq $t){ $t="" }; $u=$t.Replace("`r`n","`n").Replace("`r","`n"); if(-not $u.EndsWith("`n")){ $u += "`n" }; return $u }
function WriteUtf8NoBomLf([string]$Path,[string]$Text){ $dir=Split-Path -Parent $Path; if($dir){ EnsureDir $dir }; $enc=Utf8NoBom; $t=NormalizeLf $Text; [IO.File]::WriteAllBytes($Path,$enc.GetBytes($t)) }
function ReadUtf8Text([string]$Path){ [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($Path)) }
function Sha256HexBytes([byte[]]$bytes){ if($null -eq $bytes){ $bytes=[byte[]]@() }; $sha=[Security.Cryptography.SHA256]::Create(); ($sha.ComputeHash([byte[]]$bytes) | ForEach-Object { $_.ToString("x2") }) -join "" }
function Sha256HexFile([string]$Path){ Sha256HexBytes ([IO.File]::ReadAllBytes($Path)) }
function Sha256HexTextNormalized([string]$text){ $enc=Utf8NoBom; $t=NormalizeLf $text; Sha256HexBytes ($enc.GetBytes($t)) }
function EscapeJson([string]$s){ if($null -eq $s){ return "" }; $s=$s.Replace("\","\\"); $s=$s.Replace("`"","\""`""); $s=$s.Replace("`n","\n"); $s=$s.Replace("`t","\t"); return $s }

function ParseGateFile([string]$p){ [void][ScriptBlock]::Create((Get-Content -Raw -LiteralPath $p -Encoding UTF8)) }
function WriteScript([string]$Path,[string[]]$Lines){ $txt=(($Lines -join "`n") + "`n"); WriteUtf8NoBomLf $Path $txt; ParseGateFile $Path }

$ScriptsDir = Join-Path $RepoRoot "scripts"
$LibDir     = Join-Path $ScriptsDir "lib"
EnsureDir $LibDir
$canonPath = Join-Path $LibDir "canon.ps1"
$vpPath    = Join-Path $ScriptsDir "verify_packet.ps1"

$canon = @()
$canon += 'Set-StrictMode -Version Latest'
$canon += '$ErrorActionPreference="Stop"'
$canon += 'function EnsureDir([string]$p){ if([string]::IsNullOrWhiteSpace($p)){ throw "ENSURE_DIR_EMPTY" }; if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }'
$canon += 'function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }'
$canon += 'function NormalizeLf([string]$t){ if($null -eq $t){ $t="" }; $u=$t.Replace("`r`n","`n").Replace("`r","`n"); if(-not $u.EndsWith("`n")){ $u += "`n" }; return $u }'
$canon += 'function WriteUtf8NoBomLf([string]$Path,[string]$Text){ $dir=Split-Path -Parent $Path; if($dir){ EnsureDir $dir }; $enc=Utf8NoBom; $t=NormalizeLf $Text; [IO.File]::WriteAllBytes($Path,$enc.GetBytes($t)) }'
$canon += 'function ReadUtf8Text([string]$Path){ [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($Path)) }'
$canon += 'function Sha256HexBytes([byte[]]$bytes){ if($null -eq $bytes){ $bytes=[byte[]]@() }; $sha=[Security.Cryptography.SHA256]::Create(); ($sha.ComputeHash([byte[]]$bytes) | ForEach-Object { $_.ToString("x2") }) -join "" }'
$canon += 'function Sha256HexFile([string]$Path){ Sha256HexBytes ([IO.File]::ReadAllBytes($Path)) }'
$canon += 'function Sha256HexTextNormalized([string]$text){ $enc=Utf8NoBom; $t=NormalizeLf $text; Sha256HexBytes ($enc.GetBytes($t)) }'
$canon += 'function EscapeJson([string]$s){ if($null -eq $s){ return "" }; $s=$s.Replace("\","\\"); $s=$s.Replace("`"","\""`""); $s=$s.Replace("`n","\n"); $s=$s.Replace("`t","\t"); return $s }'
WriteScript $canonPath $canon

$vp = @()
$vp += 'param([Parameter(Mandatory=$true)][string]$PacketRoot,[Parameter(Mandatory=$true)][string]$RuntimeRoot,[Parameter(Mandatory=$true)][string]$Principal)'
$vp += 'Set-StrictMode -Version Latest'
$vp += '$ErrorActionPreference="Stop"'
$vp += 'Write-Host "CLARITY_VERIFY_SENTINEL_V1C" -ForegroundColor DarkGray'
$vp += '. "$PSScriptRoot\lib\canon.ps1"'
$vp += 'if(-not(Test-Path -LiteralPath $PacketRoot -PathType Container)){ throw ("Missing PacketRoot: " + $PacketRoot) }'
$vp += '$Allowed = Join-Path $RuntimeRoot "keys\allowed_signers"'
$vp += 'if(-not(Test-Path -LiteralPath $Allowed -PathType Leaf)){ throw ("Missing allowed_signers: " + $Allowed) }'
$vp += '$manPath = Join-Path $PacketRoot "manifest.json"; if(-not(Test-Path -LiteralPath $manPath -PathType Leaf)){ throw "Missing manifest.json" }'
$vp += '$manRaw  = ReadUtf8Text $manPath'
$vp += '$packetId = Sha256HexTextNormalized $manRaw'
$vp += '$folderId = Split-Path -Leaf $PacketRoot'
$vp += 'if($folderId -ne $packetId){ throw ("PACKET_ID_MISMATCH folder=" + $folderId + " computed=" + $packetId) }'
$vp += '$pidPath = Join-Path $PacketRoot "packet_id.txt"; if(-not(Test-Path -LiteralPath $pidPath -PathType Leaf)){ throw "Missing packet_id.txt" }'
$vp += '$pid = (Get-Content -Raw -LiteralPath $pidPath -Encoding UTF8).Trim(); if($pid -ne $packetId){ throw ("PACKET_ID_TXT_MISMATCH txt=" + $pid + " computed=" + $packetId) }'
$vp += '$shaPath = Join-Path $PacketRoot "sha256sums.txt"; if(-not(Test-Path -LiteralPath $shaPath -PathType Leaf)){ throw "Missing sha256sums.txt" }'
$vp += '$lines = Get-Content -LiteralPath $shaPath -Encoding UTF8'
$vp += 'foreach($ln in $lines){'
$vp += '  $t = ($ln + "").Trim()'
$vp += '  if($t -eq ""){ continue }'
$vp += '  $ix = $t.IndexOf("  ")'
$vp += '  if($ix -lt 0){ throw ("BAD_SHA256SUMS_LINE_NO_DOUBLESPACE: " + $t) }'
$vp += '  $h   = $t.Substring(0,$ix).Trim()'
$vp += '  $rel = $t.Substring($ix).Trim()'
$vp += '  if($h.Length -ne 64){ throw ("BAD_SHA256SUMS_HASH_LEN: " + $h) }'
$vp += '  if($rel.Contains("..") -or $rel.StartsWith("/") -or $rel.StartsWith("\")){ throw ("PATH_TRAVERSAL: " + $rel) }'
$vp += '  $winRel = $rel.Replace("/","\")'
$vp += '  $p = Join-Path $PacketRoot $winRel'
$vp += '  if(-not(Test-Path -LiteralPath $p -PathType Leaf)){ throw ("MISSING_FILE: " + $rel) }'
$vp += '  $hh = Sha256HexFile $p'
$vp += '  if($hh -ne $h){ throw ("SHA256_MISMATCH: " + $rel) }'
$vp += '}'
$vp += '$commitPath = Join-Path $PacketRoot "payload\commit.payload.json"; if(-not(Test-Path -LiteralPath $commitPath -PathType Leaf)){ throw "Missing payload/commit.payload.json" }'
$vp += '$commitRaw  = ReadUtf8Text $commitPath'
$vp += '$commitHash = Sha256HexTextNormalized $commitRaw'
$vp += '$expected = (Get-Content -Raw -LiteralPath (Join-Path $PacketRoot "payload\commit_hash.txt") -Encoding UTF8).Trim()'
$vp += 'if($commitHash -ne $expected){ throw ("COMMIT_HASH_MISMATCH expected=" + $expected + " computed=" + $commitHash) }'
$vp += '$ingPath = Join-Path $PacketRoot "payload\nfl.ingest.json"; if(-not(Test-Path -LiteralPath $ingPath -PathType Leaf)){ throw "Missing payload/nfl.ingest.json" }'
$vp += '$ingRaw  = ReadUtf8Text $ingPath'
$vp += '$ingHash = Sha256HexTextNormalized $ingRaw'
$vp += '$msg = Join-Path $env:TEMP ("clarity_verifymsg_" + [Guid]::NewGuid().ToString("N") + ".txt")'
$vp += 'WriteUtf8NoBomLf $msg (($commitHash + "`n" + $packetId + "`n" + $ingHash + "`n"))'
$vp += '$sig = Join-Path $PacketRoot "signatures\ingest.sig"; if(-not(Test-Path -LiteralPath $sig -PathType Leaf)){ throw "Missing signatures/ingest.sig" }'
$vp += '$p = Start-Process -FilePath "ssh-keygen.exe" -ArgumentList ("-Y verify -n nfl.ingest.v1 -I `"" + $Principal + "`" -f `"" + $Allowed + "`" -s `"" + $sig + "`" -o `"" + $msg + "`"") -Wait -PassThru -NoNewWindow'
$vp += '$ec = $p.ExitCode'
$vp += 'Remove-Item -LiteralPath $msg -Force -ErrorAction SilentlyContinue'
$vp += 'if($ec -ne 0){ throw ("SIGNATURE_VERIFY_FAIL exit_code=" + $ec) }'
$vp += 'Write-Host ("VERIFY_OK_OPTIONA: " + $PacketRoot) -ForegroundColor Green'
WriteScript $vpPath $vp

Write-Host "PATCH_OK: overwrote scripts\lib\canon.ps1 + scripts\verify_packet.ps1 (NO -split) " -ForegroundColor Green
