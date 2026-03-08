param(
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$UsbRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dir([string]$p) { if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p | Out-Null } }

$srcRoot = "C:\dev\clarity\scripts"
$dstRoot = Join-Path $UsbRoot "clarity_offline"

Ensure-Dir $dstRoot
Ensure-Dir (Join-Path $dstRoot "tools")

Copy-Item -Force -LiteralPath (Join-Path $srcRoot "check_artifact.ps1") -Destination (Join-Path $dstRoot "check_artifact.ps1")
Copy-Item -Force -LiteralPath (Join-Path $srcRoot "offline_verify.ps1") -Destination (Join-Path $dstRoot "offline_verify.ps1")

# Optional: bundle ssh-keygen if it exists (WinPE often won't have it)
$ssh = (Get-Command "ssh-keygen.exe" -ErrorAction SilentlyContinue)
if ($ssh) {
  Copy-Item -Force -LiteralPath $ssh.Source -Destination (Join-Path $dstRoot "tools\ssh-keygen.exe")
  Write-Host ("Bundled ssh-keygen.exe from: {0}" -f $ssh.Source) -ForegroundColor Gray
} else {
  Write-Host "NOTE: ssh-keygen.exe not found on this host. Offline verification will require you to bring one (bundle into tools\ssh-keygen.exe)." -ForegroundColor Yellow
}

Write-Host ("OFFLINE USB READY: {0}" -f $dstRoot) -ForegroundColor Green
Write-Host "Run in WinPE/Recovery:" -ForegroundColor Cyan
Write-Host ("  powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"{0}`" -OsDrive C:" -f (Join-Path $dstRoot "offline_verify.ps1")) -ForegroundColor Cyan
