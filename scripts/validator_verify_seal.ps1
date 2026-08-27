param(
  [Parameter(Mandatory=$true)][string]$SealDir,
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$Principal,
  [Parameter(Mandatory=$false)][string]$Namespace = "clarity.validator_run.v1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\canon.ps1"

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

if(-not (Test-Path -LiteralPath $SealDir -PathType Container)){ throw ("MISSING_SEAL_DIR: " + $SealDir) }
$Allowed = Join-Path $RuntimeRoot "keys\allowed_signers"
if(-not (Test-Path -LiteralPath $Allowed -PathType Leaf)){ throw ("MISSING_ALLOWED_SIGNERS: " + $Allowed) }

$sumPath = Join-Path $SealDir "sha256sums.txt"
$sigPath = Join-Path $SealDir "signature.sig"
if(-not (Test-Path -LiteralPath $sumPath -PathType Leaf)){ throw "MISSING_SHA256SUMS" }
if(-not (Test-Path -LiteralPath $sigPath -PathType Leaf)){ throw "MISSING_SIGNATURE" }

# 1. Every listed artifact must still hash to its recorded value.
$sumLines = @((Get-Content -LiteralPath $sumPath -Encoding UTF8) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach($line in $sumLines){
  $idx = $line.IndexOf("  ")
  if($idx -lt 0){ throw ("BAD_SHA256SUMS_LINE: " + $line) }
  $hex = $line.Substring(0,$idx).Trim()
  $name = $line.Substring($idx+2).Trim()
  $abs = Join-Path $SealDir $name
  if(-not (Test-Path -LiteralPath $abs -PathType Leaf)){ throw ("SEAL_MISSING_FILE: " + $name) }
  $h = Sha256HexFile $abs
  if($h -ne $hex){ throw ("SEAL_FILE_HASH_MISMATCH: " + $name) }
}

# 2. The signature must verify over the exact sums manifest under an allowed signer.
$stdin = Get-Content -Raw -LiteralPath $sumPath -Encoding UTF8
$argStr = ("-q -Y verify -f `"" + $Allowed + "`" -I `"" + $Principal + "`" -n " + $Namespace + " -s `"" + $sigPath + "`"")
$res = Invoke-SshKeygenVerifyQuiet $argStr $stdin 15000
if($res.exit -ne 0){ throw ("SEAL_SIGNATURE_INVALID exit=" + $res.exit + " stderr=" + $res.stderr) }

Write-Host ("VALIDATOR_SEAL_VERIFY_OK: " + $SealDir) -ForegroundColor Green
Write-Output "CLARITY_VALIDATOR_SEAL_VERIFY_OK"
