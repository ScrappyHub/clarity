param(
  [Parameter(Mandatory=$true)][string]$PacketRoot,
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$Principal
)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
. "$PSScriptRoot\lib\canon.ps1"
Write-Host "CLARITY_VERIFY_SENTINEL_V1F" -ForegroundColor DarkGray
function STEP([string]$s){ Write-Host ("STEP: " + $s) -ForegroundColor DarkGray }
function Invoke-SshKeygenVerifyQuiet([string]$ArgString,[string]$StdinText,[int]$TimeoutMs){
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "C:\WINDOWS\System32\OpenSSH\ssh-keygen.exe"
  $psi.Arguments = $ArgString
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $p.StandardInput.Write($StdinText)
  $p.StandardInput.Close()
  if(-not $p.WaitForExit($TimeoutMs)){ try{ $p.Kill() } catch {}; throw ("SSH_KEYGEN_TIMEOUT_MS=" + $TimeoutMs) }
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  [ordered]@{ exit=[int]$p.ExitCode; stdout=$stdout; stderr=$stderr }
}
STEP "inputs"
if(-not (Test-Path -LiteralPath $PacketRoot -PathType Container)){ throw ("Missing PacketRoot: " + $PacketRoot) }
if(-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)){ throw ("Missing RuntimeRoot: " + $RuntimeRoot) }
$Allowed = Join-Path $RuntimeRoot "keys\allowed_signers"
if(-not (Test-Path -LiteralPath $Allowed -PathType Leaf)){ throw ("Missing allowed_signers: " + $Allowed) }
$leaf = Split-Path -Leaf $PacketRoot
if([string]::IsNullOrWhiteSpace($leaf)){ throw "EMPTY_PACKET_LEAF" }
STEP "read:manifest"
$manPath = Join-Path $PacketRoot "manifest.json"
if(-not (Test-Path -LiteralPath $manPath -PathType Leaf)){ throw ("Missing manifest.json: " + $manPath) }
$manJson = Get-Content -Raw -LiteralPath $manPath -Encoding UTF8
$packetId = Sha256HexTextNormalized $manJson
if($packetId -ne $leaf){ throw ("PACKET_DIRNAME_MISMATCH dir=" + $leaf + " computed=" + $packetId) }
STEP "read:packet_id.txt"
$pidPath = Join-Path $PacketRoot "packet_id.txt"
if(-not (Test-Path -LiteralPath $pidPath -PathType Leaf)){ throw ("Missing packet_id.txt: " + $pidPath) }
$pidTxt = (Get-Content -Raw -LiteralPath $pidPath -Encoding UTF8).Trim()
if($pidTxt -ne $packetId){ throw ("PACKET_ID_TXT_MISMATCH txt=" + $pidTxt + " computed=" + $packetId) }
STEP "sha256sums"
$sumPath = Join-Path $PacketRoot "sha256sums.txt"
if(-not (Test-Path -LiteralPath $sumPath -PathType Leaf)){ throw ("Missing sha256sums.txt: " + $sumPath) }
$sumLines = @((Get-Content -LiteralPath $sumPath -Encoding UTF8) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach($line in $sumLines){
  $idx = $line.IndexOf("  ")
  if($idx -lt 0){ throw ("BAD_SHA256SUMS_LINE_NO_DOUBLESPACE: " + $line) }
  $hex = $line.Substring(0,$idx).Trim()
  $rel = $line.Substring($idx+2).Trim()
  if([string]::IsNullOrWhiteSpace($rel)){ throw ("BAD_SHA256SUMS_EMPTY_PATH: " + $line) }
  $relFs = $rel.Replace("/","\")
  $abs = Join-Path $PacketRoot $relFs
  if(-not (Test-Path -LiteralPath $abs -PathType Leaf)){ throw ("SHA256SUMS_MISSING_FILE: " + $rel) }
  $h = Sha256HexFile $abs
  if($h -ne $hex){ throw ("SHA256SUM_MISMATCH file=" + $rel + " expected=" + $hex + " got=" + $h) }
}
STEP "read:commit+ingest"
$commitHashPath = Join-Path $PacketRoot "payload\commit_hash.txt"
$ingPath = Join-Path $PacketRoot "payload\nfl.ingest.json"
if(-not (Test-Path -LiteralPath $commitHashPath -PathType Leaf)){ throw ("Missing commit_hash.txt: " + $commitHashPath) }
if(-not (Test-Path -LiteralPath $ingPath -PathType Leaf)){ throw ("Missing nfl.ingest.json: " + $ingPath) }
$commitHash = (Get-Content -Raw -LiteralPath $commitHashPath -Encoding UTF8).Trim()
$ingJson = Get-Content -Raw -LiteralPath $ingPath -Encoding UTF8
$ingHash = Sha256HexTextNormalized $ingJson
STEP "sig:verify"
$sigPath = Join-Path $PacketRoot "signatures\ingest.sig"
if(-not (Test-Path -LiteralPath $sigPath -PathType Leaf)){ throw ("Missing signature: " + $sigPath) }
$stdin = $commitHash + "`n" + $packetId + "`n" + $ingHash + "`n"
$argStr = ("-q -Y verify -f ""{0}"" -I ""{1}"" -n nfl.ingest.v1 -s ""{2}""" -f $Allowed,$Principal,$sigPath)
$res = Invoke-SshKeygenVerifyQuiet $argStr $stdin 15000
if($res.exit -ne 0){ throw ("SSHKEYGEN_VERIFY_EXIT_NONZERO=" + $res.exit + "`nSTDOUT:`n" + $res.stdout + "`nSTDERR:`n" + $res.stderr) }
STEP "ok"
Write-Host ("VERIFY_OK_OPTIONA: " + $PacketRoot) -ForegroundColor Green
