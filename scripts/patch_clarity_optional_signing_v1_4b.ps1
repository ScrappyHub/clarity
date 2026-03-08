param([Parameter(Mandatory=$true)][string]$MainPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $MainPath)) { throw "Missing MainPath: $MainPath" }

$src = Get-Content -Raw -LiteralPath $MainPath -Encoding UTF8

function Find-FunctionRange([string]$text, [string]$fnName) {
  $m = [regex]::Match($text, "(?m)^\s*function\s+$([regex]::Escape($fnName))\b")
  if (-not $m.Success) { return $null }

  $i = $m.Index + $m.Length
  $open = $text.IndexOf("{", $i)
  if ($open -lt 0) { throw "Could not find '{' for function $fnName" }

  $depth = 0
  for ($p = $open; $p -lt $text.Length; $p++) {
    $ch = $text[$p]
    if ($ch -eq "{") { $depth++ }
    elseif ($ch -eq "}") {
      $depth--
      if ($depth -eq 0) {
        # include closing brace
        return [ordered]@{ Start=$m.Index; End=($p+1) }
      }
    }
  }
  throw "Could not find matching '}' for function $fnName"
}

function Replace-Function([string]$fnName, [string]$newText) {
  $r = Find-FunctionRange -text $script:src -fnName $fnName
  if (-not $r) { throw "Patch failed: function not found: $fnName" }
  $before = $script:src.Substring(0, $r.Start)
  $after  = $script:src.Substring($r.End)
  $script:src = $before + $newText + "`r`n`r`n" + $after
}

function Ensure-HelperInsertedAfterSha256([string]$helperText) {
  if ($script:src -match "function\s+Get-SigningBackend\b") { return }

  $m = [regex]::Match($script:src, "(?s)function\s+Sha256\s*\(\[string\]\$path\)\s*\{.*?\}")
  if (-not $m.Success) { throw "Patch failed: could not find Sha256() block to inject helper after" }

  $insertAt = $m.Index + $m.Length
  $script:src = $script:src.Substring(0,$insertAt) + "`r`n`r`n" + $helperText + "`r`n`r`n" + $script:src.Substring($insertAt)
}

# --- 1) Require-OpenSSL -> NO-OP (so openssl missing never blocks core commands) ---
$requireNoop = @"
function Require-OpenSSL() {
  return
}
"@
Replace-Function -fnName "Require-OpenSSL" -newText $requireNoop

# --- 2) Inject backend helper (ssh-keygen preferred) ---
$helper = @"
function Find-Exe([string]`$name) {
  `$cmd = Get-Command `$name -ErrorAction SilentlyContinue
  if (`$cmd) { return `$cmd.Source }
  return `$null
}

function Get-SigningBackend {
  `$ssh = Find-Exe "ssh-keygen.exe"
  if (`$ssh) { return [ordered]@{ kind="sshkeygen"; path=`$ssh } }

  `$ossl = Find-Exe "openssl.exe"
  if (`$ossl) { return [ordered]@{ kind="openssl"; path=`$ossl } }

  return [ordered]@{ kind="none"; path="" }
}
"@
Ensure-HelperInsertedAfterSha256 -helperText $helper

# --- 3) KeyGen backend-aware ---
$keyGen = @"
function KeyGen([string]`$keyRoot) {
  Ensure-Dir `$keyRoot
  `$kp = KeyPaths -keyRoot `$keyRoot

  if (Test-Path -LiteralPath `$kp.priv -or Test-Path -LiteralPath `$kp.pub) {
    throw "Key files already exist. Refusing to overwrite: `$(`$kp.priv) / `$(`$kp.pub)"
  }

  `$b = Get-SigningBackend
  if (`$b.kind -eq "sshkeygen") {
    & `$b.path -t ed25519 -f `$kp.priv -N "" | Out-Null
    Protect-PrivateKey -keyPath `$kp.priv

    `$pubFrom = (`$kp.priv + ".pub")
    if (-not (Test-Path -LiteralPath `$pubFrom)) { throw "ssh-keygen did not produce public key: `$pubFrom" }
    Move-Item -LiteralPath `$pubFrom -Destination `$kp.pub -Force
  }
  elseif (`$b.kind -eq "openssl") {
    & `$b.path genpkey -algorithm Ed25519 -out `$kp.priv | Out-Null
    Protect-PrivateKey -keyPath `$kp.priv
    & `$b.path pkey -in `$kp.priv -pubout -out `$kp.pub | Out-Null
  }
  else {
    throw "No signing backend available. Install OpenSSH (ssh-keygen) or OpenSSL to generate keys."
  }

  `$meta = [ordered]@{
    clarity      = "Clarity Validator"
    action       = "KEYGEN"
    issued_at_utc= [DateTime]::UtcNow.ToString("o")
    key_root     = `$keyRoot
    priv_path    = `$kp.priv
    pub_path     = `$kp.pub
    pub_sha256   = (Sha256 `$kp.pub)
    backend      = `$b.kind
    mode         = "windows_userland_v1_4b"
  }

  Write-Text (Join-Path `$keyRoot "keygen.json") (Json `$meta)

  Write-Host "CLARITY keygen OK" -ForegroundColor Green
  Write-Host ("  Backend:     {0}" -f `$b.kind)
  Write-Host ("  Public key:  {0}" -f `$kp.pub)
  Write-Host ("  Pub sha256:  {0}" -f `$meta.pub_sha256)
}
"@
Replace-Function -fnName "KeyGen" -newText $keyGen

# --- Write safely: temp -> parse -> swap ---
$backup = ($MainPath + ".bak_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
Copy-Item -LiteralPath $MainPath -Destination $backup -Force

$tmp = ($MainPath + ".tmp")
Set-Content -LiteralPath $tmp -Value $src -Encoding UTF8

# parse check using the same engine (no pwsh -Command quoting)
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $tmp -Encoding UTF8)) | Out-Null

Move-Item -LiteralPath $tmp -Destination $MainPath -Force

Write-Host "PATCH OK" -ForegroundColor Green
Write-Host ("Backup: {0}" -f $backup) -ForegroundColor Gray
}
