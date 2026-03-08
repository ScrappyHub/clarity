param([string]$RepoRoot="C:\dev\clarity",[string]$RuntimeRoot="C:\ProgramData\Clarity",[string]$NflInbox="C:\ProgramData\NFL\inbox",[string]$Principal="single-tenant/operator/user/alec")
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
. "$PSScriptRoot\lib\canon.ps1"
# Repo dirs
EnsureDir (Join-Path $RepoRoot "contracts")
EnsureDir (Join-Path $RepoRoot "schemas")
EnsureDir (Join-Path $RepoRoot "scripts")
EnsureDir (Join-Path $RepoRoot "scripts\lib")
# Runtime dirs (standalone)
EnsureDir $RuntimeRoot
EnsureDir (Join-Path $RuntimeRoot "keys")
EnsureDir (Join-Path $RuntimeRoot "pledges")
EnsureDir (Join-Path $RuntimeRoot "outbox")
EnsureDir (Join-Path $RuntimeRoot "library\ledger")
EnsureDir (Join-Path $RuntimeRoot "library\objects\sha256")
EnsureDir (Join-Path $RuntimeRoot "library\manifests\sha256")
EnsureDir (Join-Path $RuntimeRoot "library\access\sessions")
# NFL OPTIONAL
if(Test-Path -LiteralPath $NflInbox -PathType Container){ EnsureDir $NflInbox }
# LAW.md (ASCII only; keep boring)
$law = @()
$law += "# Clarity LAW.md (LOCKED) - Standalone v1 + Packet Constitution v1 Option A"
$law += ""
$law += "Clarity MUST boot and run standalone. NFL is an integration target, never a dependency."
$law += ""
$law += "Packet Constitution v1 (Option A): manifest.json MUST NOT contain packet_id; packet_id.txt does; sha256sums.txt last."
WriteUtf8NoBomLf (Join-Path $RepoRoot "LAW.md") (($law -join "`n") + "`n")
# contracts/event_types.v1.json (static; no nested quoting games)
$evText = "{`n  `"`"schema`"`": `"`"event_types.v1`"`",`n  `"`"producer`"`": `"`"clarity`"`",`n  `"`"types`"`": [`n    `"`"clarity.run.started.v1`"`",`n    `"`"clarity.verification.result.v1`"`",`n    `"`"clarity.run.completed.v1`"`",`n    `"`"clarity.library.object.added.v1`"`",`n    `"`"clarity.library.object.sealed.v1`"`",`n    `"`"clarity.nfl.packet.built.v1`"`",`n    `"`"clarity.nfl.packet.verified.v1`"`",`n    `"`"clarity.nfl.pledged.local.v1`"`",`n    `"`"clarity.nfl.duplicated.v1`"`",`n    `"`"clarity.nfl.duplicate.failed.v1`"`"`n  ]`n}`n"
WriteUtf8NoBomLf (Join-Path $RepoRoot "contracts\event_types.v1.json") $evText
# Dev key + allowed_signers (standalone)
$keyBase = Join-Path $RuntimeRoot "keys\clarity_dev_ed25519"
$pubPath = $keyBase + ".pub"
$allowed = Join-Path $RuntimeRoot "keys\allowed_signers"
if(-not(Test-Path -LiteralPath $keyBase -PathType Leaf) -or -not(Test-Path -LiteralPath $pubPath -PathType Leaf)){
  # preserve -N "" using Start-Process with a single string
  $arg = "-t ed25519 -f `"" + $keyBase + "`" -N `"`"`""
  $p = Start-Process -FilePath "ssh-keygen.exe" -ArgumentList $arg -Wait -PassThru -NoNewWindow
  if($p.ExitCode -ne 0){ throw ("ssh-keygen failed exit_code=" + $p.ExitCode) }
}
$pubLine = (Get-Content -Raw -LiteralPath $pubPath -Encoding UTF8).Trim()
$allowedLine = ("{0} {1}" -f $Principal, $pubLine)
WriteUtf8NoBomLf $allowed ($allowedLine + "`n")
Write-Host ("BOOTSTRAP OK: RepoRoot=" + $RepoRoot) -ForegroundColor Green
Write-Host ("BOOTSTRAP OK: RuntimeRoot=" + $RuntimeRoot) -ForegroundColor Green
if(Test-Path -LiteralPath $NflInbox -PathType Container){ Write-Host ("NFL present (optional): " + $NflInbox) -ForegroundColor DarkGray } else { Write-Host "NFL not present (OK): skipping NFL wiring" -ForegroundColor DarkGray }
