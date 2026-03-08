param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

$ScriptsDir = Join-Path $RepoRoot "scripts"
$vpPath = Join-Path $ScriptsDir "verify_packet.ps1"
if(-not (Test-Path -LiteralPath $ScriptsDir -PathType Container)){ throw ("MISSING_SCRIPTS_DIR: " + $ScriptsDir) }

function ParseGateFile([string]$p){ [void][ScriptBlock]::Create((Get-Content -Raw -LiteralPath $p -Encoding UTF8)) }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function NormalizeText([string]$t){ if($null -eq $t){ $t="" }; $t=$t -replace "`r`n","`n" -replace "`r","`n"; if(-not $t.EndsWith("`n")){ $t += "`n" }; return $t }
function WriteUtf8NoBomLf([string]$Path,[string]$Text){ $dir=Split-Path -Parent $Path; if($dir -and -not(Test-Path -LiteralPath $dir -PathType Container)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }; $enc=Utf8NoBom; $t=NormalizeText $Text; [IO.File]::WriteAllBytes($Path,$enc.GetBytes($t)) }
function ReadUtf8Text([string]$Path){ [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($Path)) }
function Sha256HexBytes([byte[]]$bytes){ if($null -eq $bytes){ $bytes=[byte[]]@() }; $sha=[Security.Cryptography.SHA256]::Create(); ($sha.ComputeHash([byte[]]$bytes) | ForEach-Object { $_.ToString("x2") }) -join "" }
function Sha256HexFile([string]$Path){ Sha256HexBytes ([IO.File]::ReadAllBytes($Path)) }
function Sha256HexTextNormalized([string]$text){ $enc=Utf8NoBom; $t=NormalizeText $text; Sha256HexBytes ($enc.GetBytes($t)) }
function EnsureDir([string]$p){ if(-not(Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }

function Run-External([string]$Exe,[string]$ArgLine,[string]$Stdout,[string]$Stderr){
  $p = Start-Process -FilePath $Exe -ArgumentList $ArgLine -NoNewWindow -Wait -PassThru -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
  return [int]$p.ExitCode
}

function WriteScript([string]$Path,[string[]]$Lines){
  $txt = (($Lines -join "`n") + "`n")
  WriteUtf8NoBomLf $Path $txt
  ParseGateFile $Path
}

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
$vp += '$rx = "^(?<h>[0-9a-f]{64})\s{2}(?<p>.+)$"'
$vp += 'foreach($ln in $lines){'
$vp += '  $t = $ln.Trim(); if($t -eq ""){ continue }'
$vp += '  if(-not ($ln -match $rx)){ throw ("BAD_SHA256SUMS_LINE: " + $ln) }'
$vp += '  $h   = $Matches["h"]'
$vp += '  $rel = $Matches["p"]'
$vp += '  if($rel.Contains("..")){ throw ("PATH_TRAVERSAL: " + $rel) }'
$vp += '  $p = Join-Path $PacketRoot ($rel.Replace("/","\"))'
$vp += '  if(-not(Test-Path -LiteralPath $p -PathType Leaf)){ throw ("MISSING_FILE: " + $rel) }'
$vp += '  $hh = Sha256HexFile $p'
$vp += '  if($hh -ne $h){ throw ("SHA256_MISMATCH: " + $rel) }'
$vp += '}'
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
$vp += '$arg = ("-Y verify -f `"{0}`" -I `"{1}`" -n `"{2}`" -s `"{3}`" `"{4}`"" -f $Allowed,$Principal,"nfl.ingest.v1",$sig,$msg)'
$vp += '$exit = (Start-Process -FilePath "ssh-keygen.exe" -ArgumentList $arg -NoNewWindow -Wait -PassThru -RedirectStandardOutput $so -RedirectStandardError $se).ExitCode'
$vp += 'Remove-Item -LiteralPath $msg -Force -ErrorAction SilentlyContinue'
$vp += 'if([int]$exit -ne 0){ throw ("SSHKEYGEN_VERIFY_FAIL exit=" + $exit + " out=" + $so + " err=" + $se) }'
$vp += 'Write-Host ("VERIFY OK (Option A): " + $PacketRoot) -ForegroundColor Green'
WriteScript $vpPath $vp
Write-Host "PATCH_OK: overwrote verify_packet.ps1 (no -split; PS5.1-safe)" -ForegroundColor Green
