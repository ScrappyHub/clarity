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

$script:src = $src

$signFn = @"
function Sign-ArtifactBundle([string]`$artifactDir, [string]`$keyRoot) {
  `$kp = KeyPaths -keyRoot `$keyRoot

  `$sums = Join-Path `$artifactDir 'sha256sums.txt'
  if (-not (Test-Path -LiteralPath `$sums)) { throw "Missing sha256sums.txt in artifact dir: `$artifactDir" }

  `$b = Get-SigningBackend
  `$sig = Join-Path `$artifactDir 'signature.ed25519'
  `$pubCopy = Join-Path `$artifactDir 'pubkey_ed25519.pem'

  `$sigMeta = [ordered]@{
    clarity = 'Clarity Validator'
    action  = 'SIGN_ARTIFACT_BUNDLE'
    issued_at_utc = [DateTime]::UtcNow.ToString('o')
    artifact_dir = `$artifactDir
    sha256sums = 'sha256sums.txt'
    signature  = 'signature.ed25519'
    pubkey     = 'pubkey_ed25519.pem'
    backend    = `$b.kind
    unsigned_due_to_missing_tool = `$false
    unsigned_reason = ''
    tool_path = ''
    mode = 'windows_userland_v1_4f'
  }

  function Write-Unsigned([string]`$reason) {
    `$sigMeta.unsigned_due_to_missing_tool = `$true
    `$sigMeta.unsigned_reason = `$reason
    Write-Text (Join-Path `$artifactDir 'signature.json') (Json `$sigMeta)
    return `$false
  }

  # Never attempt to invoke a missing/empty tool path.
  if (`$b.kind -eq 'none') { return (Write-Unsigned 'NO_SIGNING_BACKEND_AVAILABLE') }
  if ([string]::IsNullOrWhiteSpace([string]`$b.path)) { return (Write-Unsigned 'BACKEND_PATH_EMPTY') }
  if (-not (Test-Path -LiteralPath `$b.path)) { `$sigMeta.tool_path = [string]`$b.path; return (Write-Unsigned 'BACKEND_PATH_NOT_FOUND') }

  `$sigMeta.tool_path = [string]`$b.path

  if (-not (Test-Path -LiteralPath `$kp.priv)) { return (Write-Unsigned 'MISSING_PRIVATE_KEY') }
  if (-not (Test-Path -LiteralPath `$kp.pub))  { return (Write-Unsigned 'MISSING_PUBLIC_KEY') }

  # ensure clean target files
  if (Test-Path -LiteralPath `$sig) { Remove-Item -Force -LiteralPath `$sig }
  Copy-Item -LiteralPath `$kp.pub -Destination `$pubCopy -Force

  try {
    if (`$b.kind -eq 'openssl') {
      & `$b.path pkeyutl -sign -inkey `$kp.priv -rawin -in `$sums -out `$sig | Out-Null
    }
    elseif (`$b.kind -eq 'sshkeygen') {
      `$tmp = Join-Path `$artifactDir 'sha256sums.txt.sig'
      if (Test-Path -LiteralPath `$tmp) { Remove-Item -Force -LiteralPath `$tmp }
      & `$b.path -Y sign -f `$kp.priv -n 'clarity' `$sums | Out-Null
      if (-not (Test-Path -LiteralPath `$tmp)) { return (Write-Unsigned 'SSHKEYGEN_NO_Y_SIGN_SUPPORT') }
      Move-Item -LiteralPath `$tmp -Destination `$sig -Force
    }
    else {
      return (Write-Unsigned 'UNKNOWN_BACKEND_KIND')
    }
  } catch {
    `$sigMeta.unsigned_due_to_missing_tool = `$true
    `$sigMeta.unsigned_reason = 'SIGNING_INVOKE_FAILED'
    `$sigMeta.error = (`$_.Exception.Message)
    Write-Text (Join-Path `$artifactDir 'signature.json') (Json `$sigMeta)
    return `$false
  }

  # record metadata
  `$sigMeta.pubkey_sha256 = (Sha256 `$kp.pub)
  Write-Text (Join-Path `$artifactDir 'signature.json') (Json `$sigMeta)

  # extend sums to include signature.json + pub copy + signature, then re-sign
  `$rel = (Get-ChildItem -LiteralPath `$artifactDir -File | ForEach-Object { `$_.Name }) |
    Where-Object { `$_ -ne 'sha256sums.txt' } | Sort-Object
  Write-Sha256Sums `$artifactDir `$rel

  if (Test-Path -LiteralPath `$sig) { Remove-Item -Force -LiteralPath `$sig }

  try {
    if (`$b.kind -eq 'openssl') {
      & `$b.path pkeyutl -sign -inkey `$kp.priv -rawin -in (Join-Path `$artifactDir 'sha256sums.txt') -out `$sig | Out-Null
    }
    elseif (`$b.kind -eq 'sshkeygen') {
      `$tmp2 = Join-Path `$artifactDir 'sha256sums.txt.sig'
      if (Test-Path -LiteralPath `$tmp2) { Remove-Item -Force -LiteralPath `$tmp2 }
      & `$b.path -Y sign -f `$kp.priv -n 'clarity' (Join-Path `$artifactDir 'sha256sums.txt') | Out-Null
      if (-not (Test-Path -LiteralPath `$tmp2)) { return (Write-Unsigned 'SSHKEYGEN_RE_SIGN_FAILED') }
      Move-Item -LiteralPath `$tmp2 -Destination `$sig -Force
    }
  } catch {
    return (Write-Unsigned 'RE_SIGN_INVOKE_FAILED')
  }

  return `$true
}
"@

Replace-Function -fnName "Sign-ArtifactBundle" -newText $signFn
$src = $script:src

# safe write: backup -> tmp -> parse -> swap
$backup = ($MainPath + ".bak_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
Copy-Item -LiteralPath $MainPath -Destination $backup -Force

$tmp = ($MainPath + ".tmp")
Set-Content -LiteralPath $tmp -Value $src -Encoding UTF8
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $tmp -Encoding UTF8)) | Out-Null

Move-Item -LiteralPath $tmp -Destination $MainPath -Force

Write-Host "PATCH OK (v1_4f)" -ForegroundColor Green
Write-Host ("Backup: {0}" -f $backup) -ForegroundColor Gray
