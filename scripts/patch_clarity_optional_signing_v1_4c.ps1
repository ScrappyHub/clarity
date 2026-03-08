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
      if ($depth -eq 0) { return [ordered]@{ Start=$m.Index; End=($p+1) } }
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

function Insert-AfterFunction([string]$afterFn, [string]$insertText) {
  $r = Find-FunctionRange -text $script:src -fnName $afterFn
  if (-not $r) { throw "Patch failed: function not found for injection point: $afterFn" }
  $before = $script:src.Substring(0, $r.End)
  $after  = $script:src.Substring($r.End)
  $script:src = $before + "`r`n`r`n" + $insertText + "`r`n`r`n" + $after
}

# 0) Safety: comment out any bare top-level Require-OpenSSL call lines
$src = [regex]::Replace(
  $src,
  '(?m)^\s*Require-OpenSSL\s*\(\s*\)\s*$',
  '# Require-OpenSSL() (disabled: optional signing backend)',
  0
)
$src = [regex]::Replace(
  $src,
  '(?m)^\s*Require-OpenSSL\s*$',
  '# Require-OpenSSL (disabled: optional signing backend)',
  0
)

# 1) Require-OpenSSL() -> no-op
$requireNoop =
  "function Require-OpenSSL() {" + "`r`n" +
  "  return" + "`r`n" +
  "}" + "`r`n"
Replace-Function -fnName "Require-OpenSSL" -newText $requireNoop

# 2) Inject backend discovery if missing
if ($src -notmatch "(?m)^\s*function\s+Get-SigningBackend\b") {
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

  # inject after Sha256 (must exist in your file)
  $script:src = $src
  Insert-AfterFunction -afterFn "Sha256" -insertText $helper
  $src = $script:src
} else {
  $script:src = $src
}

# 3) Replace KeyGen with backend-aware version
$keyGen =
  "function KeyGen([string]`$keyRoot) {" + "`r`n" +
  "  Ensure-Dir `$keyRoot" + "`r`n" +
  "  `$kp = KeyPaths -keyRoot `$keyRoot" + "`r`n" +
  "  if (Test-Path -LiteralPath `$kp.priv -or Test-Path -LiteralPath `$kp.pub) {" + "`r`n" +
  "    throw ""Key files already exist. Refusing to overwrite: `$(`$kp.priv) / `$(`$kp.pub)""" + "`r`n" +
  "  }" + "`r`n" +
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
  "  `$meta = [ordered]@{ clarity='Clarity Validator'; action='KEYGEN'; issued_at_utc=[DateTime]::UtcNow.ToString('o'); key_root=`$keyRoot; priv_path=`$kp.priv; pub_path=`$kp.pub; pub_sha256=(Sha256 `$kp.pub); backend=`$b.kind; mode='windows_userland_v1_4c' }" + "`r`n" +
  "  Write-Text (Join-Path `$keyRoot 'keygen.json') (Json `$meta)" + "`r`n" +
  "  Write-Host 'CLARITY keygen OK' -ForegroundColor Green" + "`r`n" +
  "  Write-Host ('  Backend:     {0}' -f `$b.kind)" + "`r`n" +
  "  Write-Host ('  Public key:  {0}' -f `$kp.pub)" + "`r`n" +
  "  Write-Host ('  Pub sha256:  {0}' -f `$meta.pub_sha256)" + "`r`n" +
  "}" + "`r`n"

Replace-Function -fnName "KeyGen" -newText $keyGen
$src = $script:src

# Write safely: backup -> temp -> parse -> swap
$backup = ($MainPath + ".bak_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
Copy-Item -LiteralPath $MainPath -Destination $backup -Force

$tmp = ($MainPath + ".tmp")
Set-Content -LiteralPath $tmp -Value $src -Encoding UTF8

[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $tmp -Encoding UTF8)) | Out-Null

Move-Item -LiteralPath $tmp -Destination $MainPath -Force

Write-Host "PATCH OK" -ForegroundColor Green
Write-Host ("Backup: {0}" -f $backup) -ForegroundColor Gray
