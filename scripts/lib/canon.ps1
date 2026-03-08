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
