param(
  [Parameter(Mandatory=$true)][string]$MainPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $MainPath)) { throw "Missing MainPath: $MainPath" }
$src = Get-Content -Raw -LiteralPath $MainPath

function Replace-Once([string]$pattern, [string]$replacement, [string]$label) {
  if ($script:src -notmatch $pattern) {
    throw ("Patch failed: could not find pattern for: {0}" -f $label)
  }
  $script:src = [regex]::Replace($script:src, $pattern, $replacement, 1)
}

# 1) Make Require-OpenSSL a NO-OP (so missing openssl never kills core commands)
#    This targets the function by name (your transcript shows it exists and throws).
$noopRequireOpenSsl =
  "function Require-OpenSSL {" + "`r`n" +
  "  return" + "`r`n" +
  "}" + "`r`n"

$patRequireOpenSsl = '(?s)function\s+Require-OpenSSL\s*\(\s*\)\s*\{.*?\}\s*'
if ($src -match $patRequireOpenSsl) {
  Replace-Once $patRequireOpenSsl $noopRequireOpenSsl "Require-OpenSSL() -> no-op"
} else {
  # If signature differs, fall back to a looser match (no params)
  $patRequireOpenSsl2 = '(?s)function\s+Require-OpenSSL\s*\{.*?\}\s*'
  Replace-Once $patRequireOpenSsl2 $noopRequireOpenSsl "Require-OpenSSL -> no-op (loose)"
}

# 2) Ensure ANY top-level calls to Require-OpenSSL are commented out (belt + suspenders)
#    This prevents startup/parse-time hard-fails if someone inlined it.
$src = [regex]::Replace(
  $src,
  '(?m)^\s*Require-OpenSSL\s*$',
  '# Require-OpenSSL (disabled: optional signing backend)',
  0
)

# 3) Add backend discovery helper if missing
if ($src -notmatch 'function\s+Get-SigningBackend') {
  $helper =
    "function Find-Exe([string]`$name) {" + "`r`n" +
    "  `$cmd = Get-Command `$name -ErrorAction SilentlyContinue" + "`r`n" +
    "  if (`$cmd) { return `$cmd.Source }" + "`r`n" +
    "  return `$null" + "`r`n" +
    "}" + "`r`n" +
    "" + "`r`n" +
    "function Get-SigningBackend {" + "`r`n" +
    "  `$ssh = Find-Exe 'ssh-keygen.exe'" + "`r`n" +
    "  if (`$ssh) { return [ordered]@{ kind='sshkeygen'; path=`$ssh } }" + "`r`n" +
    "  `$ossl = Find-Exe 'openssl.exe'" + "`r`n" +
    "  if (`$ossl) { return [ordered]@{ kind='openssl'; path=`$ossl } }" + "`r`n" +
    "  return [ordered]@{ kind='none'; path='' }" + "`r`n" +
    "}" + "`r`n"

  # Inject after Sha256 helper (present in your file)
  $injectPoint = '(?s)(function\s+Sha256\s*\(\[string\]\$path\)\s*\{.*?\}\s*)'
  if ($src -notmatch $injectPoint) { throw "Patch failed: could not find Sha256() injection point" }
  $src = [regex]::Replace($src, $injectPoint, ('$1' + "`r`n" + $helper), 1)
}

# 4) KeyGen should use ssh-keygen if present; else openssl; else throw.
#    If your KeyGen body differs, this patch will fail loudly (as it should).
$keyGenPattern = '(?s)function\s+KeyGen\(\[string\]\$keyRoot\)\s*\{.*?\}\s*'
$keyGenReplacement =
  "function KeyGen([string]`$keyRoot) {" + "`r`n" +
  "  Ensure-Dir `$keyRoot" + "`r`n" +
  "  `$kp = KeyPaths -keyRoot `$keyRoot" + "`r`n" +
  "  if (Test-Path -LiteralPath `$kp.priv -or Test-Path -LiteralPath `$kp.pub) {" + "`r`n" +
  "    throw ""Key files already exist. Refusing to overwrite: `$(`$kp.priv) / `$(`$kp.pub)""" + "`r`n" +
  "  }" + "`r`n" +
  "" + "`r`n" +
  "  `$b = Get-SigningBackend" + "`r`n" +
  "  if (`$b.kind -eq 'sshkeygen') {" + "`r`n" +
  "    & `$b.path -t ed25519 -f `$kp.priv -N '' | Out-Null" + "`r`n" +
  "    Protect-PrivateKey -keyPath `$kp.priv" + "`r`n" +
  "    `$pubFrom = (`$kp.priv + '.pub')" + "`r`n" +
  "    if (-not (Test-Path -LiteralPath `$pubFrom)) { throw ""ssh-keygen did not produce public key: `$pubFrom"" }" + "`r`n" +
  "    Move-Item -LiteralPath `$pubFrom -Destination `$kp.pub -Force" + "`r`n" +
  "  } elseif (`$b.kind -eq 'openssl') {" + "`r`n" +
  "    & `$b.path genpkey -algorithm Ed25519 -out `$kp.priv | Out-Null" + "`r`n" +
  "    Protect-PrivateKey -keyPath `$kp.priv" + "`r`n" +
  "    & `$b.path pkey -in `$kp.priv -pubout -out `$kp.pub | Out-Null" + "`r`n" +
  "  } else {" + "`r`n" +
  "    throw 'No signing backend available. Install OpenSSH (ssh-keygen) or OpenSSL to generate keys.'" + "`r`n" +
  "  }" + "`r`n" +
  "" + "`r`n" +
  "  `$meta = [ordered]@{ clarity='Clarity Validator'; action='KEYGEN'; issued_at_utc=[DateTime]::UtcNow.ToString('o'); key_root=`$keyRoot; priv_path=`$kp.priv; pub_path=`$kp.pub; pub_sha256=(Sha256 `$kp.pub); backend=`$b.kind; mode='windows_userland_v1_4a' }" + "`r`n" +
  "  Write-Text (Join-Path `$keyRoot 'keygen.json') (Json `$meta)" + "`r`n" +
  "  Write-Host 'CLARITY keygen OK' -ForegroundColor Green" + "`r`n" +
  "  Write-Host ('  Backend:     {0}' -f `$b.kind)" + "`r`n" +
  "  Write-Host ('  Public key:  {0}' -f `$kp.pub)" + "`r`n" +
  "  Write-Host ('  Pub sha256:  {0}' -f `$meta.pub_sha256)" + "`r`n" +
  "}" + "`r`n"

Replace-Once $keyGenPattern $keyGenReplacement "Patch KeyGen()"

# Write back
Set-Content -LiteralPath $MainPath -Value $src -Encoding UTF8

# Parse check (deterministic)
pwsh -NoProfile -Command ("[ScriptBlock]::Create((Get-Content -Raw -LiteralPath ''{0}'')) | Out-Null; ''PATCH OK: clarity.ps1 parses''" -f $MainPath) | Out-Host
