param(
  [Parameter(Mandatory=$true)][string]$BootstrapPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

function EnsureDir([string]$p){ if(-not(Test-Path -LiteralPath $p)){ New-Item -ItemType Directory -Path $p -Force | Out-Null } }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function WriteUtf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ EnsureDir $dir }
  $norm = $Text.Replace("`r`n","`n").Replace("`r","`n")
  $bytes = (Utf8NoBom).GetBytes($norm)
  [IO.File]::WriteAllBytes($Path,$bytes)
}

$bootstrap = @'
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

$RepoRoot = "C:\dev\clarity"
$Runtime  = "C:\ProgramData\Clarity"
$NflInbox = "C:\ProgramData\NFL\inbox"

function EnsureDir([string]$p){ if(-not(Test-Path -LiteralPath $p)){ New-Item -ItemType Directory -Path $p -Force | Out-Null } }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function WriteUtf8Lf([string]$path,[string]$text){
  $dir = Split-Path -Parent $path
  if($dir){ EnsureDir $dir }
  $bytes = (Utf8NoBom).GetBytes(($text -replace "`r`n","`n" -replace "`r","`n"))
  [IO.File]::WriteAllBytes($path,$bytes)
  if(-not(Test-Path -LiteralPath $path)){ throw ("WRITE_FAILED: " + $path) }
}
function Sha256Hex([byte[]]$bytes){
  $sha = [Security.Cryptography.SHA256]::Create()
  ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
}
function ReadAllBytes([string]$p){ [IO.File]::ReadAllBytes($p) }

# ------------------------------
# Repo layout (minimal)
# ------------------------------
EnsureDir (Join-Path $RepoRoot "schemas")
EnsureDir (Join-Path $RepoRoot "contracts")
EnsureDir (Join-Path $RepoRoot "scripts")
EnsureDir (Join-Path $RepoRoot "scripts\lib")

# ------------------------------
# Runtime layout
# ------------------------------
EnsureDir (Join-Path $Runtime "pledges")
EnsureDir (Join-Path $Runtime "outbox")
EnsureDir (Join-Path $Runtime "keys")
EnsureDir (Join-Path $Runtime "library\ledger")
EnsureDir (Join-Path $Runtime "library\objects\sha256")
EnsureDir (Join-Path $Runtime "library\manifests\sha256")
EnsureDir (Join-Path $Runtime "library\access\sessions")
EnsureDir $NflInbox

# ------------------------------
# LAW.md (Clarity-only)
# ------------------------------
$Law = @()
$Law += "# Clarity LAW.md (LOCKED) — NFL Skeleton v1.1 + Library Gate v1"
$Law += ""
$Law += "Clarity MUST:"
$Law += "- Maintain an append-only local pledge log (pledges.ndjson), chained by prev_log_hash + log_hash."
$Law += "- For every pledge event, build a packet directory (manifest.json + sha256sums.txt + payload + signature) under outbox/<PacketId>."
$Law += "- Duplicate the *byte-identical* packet into NFL inbox under C:\ProgramData\NFL\inbox\<PacketId>\"
$Law += "- Never do direct inter-project RPC. Hashes + NFL only."
$Law += ""
$Law += "Clarity Library (mini-NFL) MUST:"
$Law += "- Store objects content-addressed: content_ref = cas:sha256:<hex>."
$Law += "- Append-only library ledger (library.ndjson), hash-chained."
$Law += "- Sealed objects are not readable until user verification grants access (AccessGrant v1)."
WriteUtf8Lf (Join-Path $RepoRoot "LAW.md") (($Law -join "`n") + "`n")

# ------------------------------
# Event types registry (FIXED here-string)
# ------------------------------
$ev = @'
{
  "schema": "event_types.v1",
  "producer": "clarity",
  "types": [
    "clarity.run.started.v1",
    "clarity.verification.result.v1",
    "clarity.run.completed.v1",
    "clarity.library.object.added.v1",
    "clarity.library.object.sealed.v1",
    "clarity.nfl.packet.built.v1",
    "clarity.nfl.packet.verified.v1",
    "clarity.nfl.pledged.local.v1",
    "clarity.nfl.duplicated.v1",
    "clarity.nfl.duplicate.failed.v1"
  ]
}
