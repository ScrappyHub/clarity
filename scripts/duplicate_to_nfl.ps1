param([Parameter(Mandatory=$true)][string]$PacketRoot,[string]$NflInbox="C:\ProgramData\NFL\inbox")
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
if(-not(Test-Path -LiteralPath $PacketRoot -PathType Container)){ throw ("Missing PacketRoot: " + $PacketRoot) }
if(-not(Test-Path -LiteralPath $NflInbox -PathType Container)){ Write-Host "NFL not present (OK): skipping duplication." -ForegroundColor DarkGray; return }
$id = Split-Path -Leaf $PacketRoot
$dst = Join-Path $NflInbox $id
if(Test-Path -LiteralPath $dst){ throw ("NFL destination already exists: " + $dst) }
Copy-Item -LiteralPath $PacketRoot -Destination $dst -Recurse -Force
Write-Host ("NFL DUPLICATE OK: " + $dst) -ForegroundColor Green
