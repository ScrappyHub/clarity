param(
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$Principal
)

Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

function EnsureDir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ throw "ENSURE_DIR_EMPTY" }
  if(-not (Test-Path -LiteralPath $p -PathType Container)){
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }
}
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function WriteUtf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ EnsureDir $dir }
  $t = $Text.Replace("`r`n","`n").Replace("`r","`n")
  if(-not $t.EndsWith("`n")){ $t += "`n" }
  $enc = Utf8NoBom
  [IO.File]::WriteAllBytes($Path, $enc.GetBytes($t))
}

$keysDir = Join-Path $RuntimeRoot "keys"
EnsureDir $keysDir

$keyBase = Join-Path $keysDir "clarity_dev_ed25519"
$pubPath = $keyBase + ".pub"
$allowed = Join-Path $keysDir "allowed_signers"

# backup any existing key material
$bkDir = Join-Path $keysDir ("backups_" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ"))
EnsureDir $bkDir

foreach($p in @($keyBase,$pubPath)){
  if(Test-Path -LiteralPath $p -PathType Leaf){
    $dst = Join-Path $bkDir (Split-Path -Leaf $p)
    Move-Item -LiteralPath $p -Destination $dst -Force
    Write-Host ("BACKUP_KEY: " + $dst) -ForegroundColor DarkGray
  }
}

# regenerate UNENCRYPTED key (critical: -N "")
$argList = @("-t","ed25519","-f",$keyBase,"-N","","-C","clarity-dev-ed25519")
$p = Start-Process -FilePath "ssh-keygen.exe" -ArgumentList $argList -Wait -PassThru -NoNewWindow
if($p.ExitCode -ne 0){ throw ("SSH_KEYGEN_KEYGEN_FAIL exit_code=" + $p.ExitCode) }

if(-not (Test-Path -LiteralPath $keyBase -PathType Leaf)){ throw ("MISSING_KEY: " + $keyBase) }
if(-not (Test-Path -LiteralPath $pubPath -PathType Leaf)){ throw ("MISSING_PUB: " + $pubPath) }

# allowed_signers: "principal <pubkeyline>"
$pubLine = (Get-Content -Raw -LiteralPath $pubPath -Encoding UTF8).Trim()
if([string]::IsNullOrWhiteSpace($pubLine)){ throw "EMPTY_PUBKEY_LINE" }

WriteUtf8NoBomLf $allowed ($Principal + " " + $pubLine + "`n")

Write-Host ("REGEN_KEY_OK: " + $keyBase) -ForegroundColor Green
Write-Host ("ALLOWED_SIGNERS_OK: " + $allowed) -ForegroundColor Green