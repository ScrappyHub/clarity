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

function Insert-AfterFunction([string]$afterFn, [string]$insertText) {
  $r = Find-FunctionRange -text $script:src -fnName $afterFn
  if (-not $r) { throw "Patch failed: function not found for injection point: $afterFn" }
  $before = $script:src.Substring(0, $r.End)
  $after  = $script:src.Substring($r.End)
  $script:src = $before + "`r`n`r`n" + $insertText + "`r`n`r`n" + $after
}

function Assert-Changed([string]$before,[string]$after,[string]$label) {
  if ($before -eq $after) { throw "Patch failed: no change applied for $label" }
}

$script:src = $src

# ------------------------------------------------------------
# 1) Add verify helpers (only if not already present)
# ------------------------------------------------------------
if ($script:src -notmatch "(?m)^\s*function\s+Verify-ArtifactBundle\b") {

$verifyBlock = @"
function Invoke-ProcessBytesToStdin([string]`$Exe, [string[]]`$Args, [string]`$InputFile) {
  # Runs a process and feeds exact bytes of InputFile to STDIN (deterministic, avoids encoding drift)
  `$psi = New-Object System.Diagnostics.ProcessStartInfo
  `$psi.FileName = `$Exe
  `$psi.Arguments = ([string]::Join(' ', (`$Args | ForEach-Object { if (`$_ -match '\s') { '""' + `$_ + '""' } else { `$_ } } )))
  `$psi.RedirectStandardInput  = `$true
  `$psi.RedirectStandardOutput = `$true
  `$psi.RedirectStandardError  = `$true
  `$psi.UseShellExecute = `$false
  `$psi.CreateNoWindow  = `$true

  `$p = New-Object System.Diagnostics.Process
  `$p.StartInfo = `$psi
  [void]`$p.Start()

  # write bytes
  `$bytes = [System.IO.File]::ReadAllBytes(`$InputFile)
  `$p.StandardInput.BaseStream.Write(`$bytes, 0, `$bytes.Length)
  `$p.StandardInput.Close()

  `$out = `$p.StandardOutput.ReadToEnd()
  `$err = `$p.StandardError.ReadToEnd()
  `$p.WaitForExit()

  return [ordered]@{ ExitCode=`$p.ExitCode; StdOut=`$out; StdErr=`$err; Exe=`$Exe; Args=`$psi.Arguments }
}

function Parse-Sha256Sums([string]`$SumsPath) {
  if (-not (Test-Path -LiteralPath `$SumsPath)) { throw "Missing sha256sums: `$SumsPath" }
  `$raw = (Get-Content -Raw -LiteralPath `$SumsPath -Encoding UTF8) -replace "`r",""
  `$lines = `$raw -split "`n" | Where-Object { `$_ -and (`$_ -notmatch '^\s*$') }

  `$items = @()
  foreach (`$ln in `$lines) {
    # format: <64hex><2 spaces><filename>
    if (`$ln -notmatch '^(?<h>[0-9a-f]{64})\s{2}(?<f>.+)$') {
      throw "Bad sha256sums line: `$ln"
    }
    `$items += [ordered]@{ hash=`$Matches.h; file=`$Matches.f }
  }
  return `$items
}

function Verify-ArtifactBundle([string]`$ArtifactDir) {
  if (-not (Test-Path -LiteralPath `$ArtifactDir)) { throw "Missing ArtifactDir: `$ArtifactDir" }

  # Hard rule: transient must not exist
  `$transient = Join-Path `$ArtifactDir "sha256sums.txt.sig"
  if (Test-Path -LiteralPath `$transient) { throw "FAIL: transient sha256sums.txt.sig still present: `$transient" }

  # Required canonical set
  foreach (`$f in @("sha256sums.txt","signature.ed25519","signature.json","pubkey_ed25519.pem")) {
    if (-not (Test-Path -LiteralPath (Join-Path `$ArtifactDir `$f))) {
      throw ("FAIL: missing `{0}`" -f `$f)
    }
  }

  # sha256sums must include signature.ed25519 (CRLF-safe)
  `$sumsText = (Get-Content -Raw -LiteralPath (Join-Path `$ArtifactDir "sha256sums.txt") -Encoding UTF8) -replace "`r",""
  if (`$sumsText -notmatch '(?m)\s+signature\.ed25519$') {
    throw "FAIL: sha256sums.txt missing signature.ed25519 entry"
  }

  # 1) Verify hashes for every entry in sha256sums.txt
  `$sumsPath = Join-Path `$ArtifactDir "sha256sums.txt"
  `$items = Parse-Sha256Sums -SumsPath `$sumsPath
  foreach (`$it in `$items) {
    `$p = Join-Path `$ArtifactDir `$it.file
    if (-not (Test-Path -LiteralPath `$p)) { throw "FAIL: sums references missing file: `$(`$it.file)" }
    `$h = (Sha256 `$p).ToLowerInvariant()
    if (`$h -ne `$it.hash) { throw "FAIL: hash mismatch: `$(`$it.file)" }
  }

  # 2) Verify signature of sha256sums.txt using ssh-keygen -Y verify (if available)
  #    (We keep this strong but optional: if no backend, fail deterministically.)
  `$b = Get-SigningBackend
  if (`$b.kind -ne "sshkeygen") {
    throw "FAIL: signature verify requires ssh-keygen backend; current backend=`$(`$b.kind)"
  }

  `$pubPath = Join-Path `$ArtifactDir "pubkey_ed25519.pem"
  `$sigPath = Join-Path `$ArtifactDir "signature.ed25519"

  # allowed_signers format: <identity> <publickey...>
  `$pubLine = (Get-Content -Raw -LiteralPath `$pubPath -Encoding UTF8).Trim()
  if (`$pubLine -notmatch '^ssh-ed25519\s+') {
    throw "FAIL: pubkey_ed25519.pem is not OpenSSH public key format (expected 'ssh-ed25519 ...')"
  }

  `$tmpDir = Join-Path `$ArtifactDir "_verify_tmp"
  Ensure-Dir `$tmpDir
  `$allowed = Join-Path `$tmpDir "allowed_signers"
  Set-Content -LiteralPath `$allowed -Value ("clarity " + `$pubLine) -Encoding ASCII

  # namespace/identity must match signing. We standardize on: clarity
  `$args = @("-Y","verify","-f",`$allowed,"-I","clarity","-n","clarity","-s",`$sigPath)

  `$r = Invoke-ProcessBytesToStdin -Exe `$b.path -Args `$args -InputFile `$sumsPath

  # cleanup (best effort)
  try { Remove-Item -Force -Recurse -LiteralPath `$tmpDir } catch { }

  if (`$r.ExitCode -ne 0) {
    throw ("FAIL: signature verify failed (exit {0}). stderr={1}" -f `$r.ExitCode, `$r.StdErr.Trim())
  }

  Write-Host "CLARITY VERIFY PASS" -ForegroundColor Green
  Write-Host ("  Artifact: {0}" -f `$ArtifactDir)
  return
}
"@

  # Insert after Get-SigningBackend if present; otherwise after Sha256
  if ($script:src -match "(?m)^\s*function\s+Get-SigningBackend\b") {
    Insert-AfterFunction -afterFn "Get-SigningBackend" -insertText $verifyBlock
  } else {
    Insert-AfterFunction -afterFn "Sha256" -insertText $verifyBlock
  }
}

# ------------------------------------------------------------
# 2) Add 'verify' command to switch($Command) dispatcher
#    Insert a case near the top of the switch body.
# ------------------------------------------------------------
$before = $script:src

$script:src = [regex]::Replace(
  $script:src,
  '(?ms)(switch\s*\(\s*\$Command\s*\)\s*\{\s*)',
  '$1' + "`r`n" +
  "  'verify' {`r`n" +
  "    try { Verify-ArtifactBundle -ArtifactDir `$ArtifactDir } catch { Write-Host `$_.Exception.Message -ForegroundColor Red; exit 2 }`r`n" +
  "    exit 0`r`n" +
  "  }`r`n",
  1
)

# If no replacement occurred, fail (we need a reliable dispatch point)
Assert-Changed $before $script:src "insert verify case into switch($Command)"

# ------------------------------------------------------------
# 3) Add a parameter for -ArtifactDir if script doesn't already have it
#    (We do NOT try to fully rewrite the param block. We only add a fallback default path variable.)
#    We'll keep it simple: define $ArtifactDir default to latest run artifact if not provided.
# ------------------------------------------------------------
if ($script:src -notmatch "(?m)^\s*\$ArtifactDir\s*=") {
  $injection = @"
# --- v1_5a: default ArtifactDir for verify (if caller does not pass one) ---
if (-not (Get-Variable -Name ArtifactDir -Scope Script -ErrorAction SilentlyContinue)) {
  # no-op: variable not defined in script scope; leave it
} elseif (-not `$ArtifactDir -or `$ArtifactDir -eq '') {
  try {
    `$latest = Get-ChildItem "C:\ProgramData\Clarity\runs" -Directory | Sort-Object Name -Descending | Select-Object -First 1
    if (`$latest) { `$ArtifactDir = (Join-Path `$latest.FullName "artifact") }
  } catch { }
}
"@
  # Put this near the top (after strict/error prefs if possible)
  $script:src = $injection + "`r`n`r`n" + $script:src
}

# ------------------------------------------------------------
# Safe write: backup -> tmp -> parse -> swap
# ------------------------------------------------------------
$backup = ($MainPath + ".bak_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
Copy-Item -LiteralPath $MainPath -Destination $backup -Force

$tmp = ($MainPath + ".tmp")
Set-Content -LiteralPath $tmp -Value $script:src -Encoding UTF8

[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $tmp -Encoding UTF8)) | Out-Null

Move-Item -LiteralPath $tmp -Destination $MainPath -Force

Write-Host "PATCH OK (v1_5a): verify command added" -ForegroundColor Green
Write-Host ("Backup: {0}" -f $backup) -ForegroundColor Gray
