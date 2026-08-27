param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $RepoRoot "scripts\lib\canon.ps1")

function Get-OutPath([object[]]$Output,[string]$Pattern){
  $m = @($Output | ForEach-Object {
    $line = $_.ToString().Trim()
    $v = $line
    $i = $line.IndexOf("=")
    if($i -gt 0){ $v = $line.Substring($i + 1).Trim() }
    if($v -like $Pattern -and (Test-Path -LiteralPath $v)){ $v }
  })
  if($m.Count -eq 0){ throw ("OUTPUT_NOT_FOUND: " + $Pattern) }
  return $m[$m.Count - 1]
}

$Principal   = "clarity-seal-test"
$Namespace   = "clarity.validator_run.v1"
$root        = Join-Path ([IO.Path]::GetTempPath()) ("clarity-seal-test-" + [Guid]::NewGuid().ToString("N"))
$runtimeRoot = Join-Path $root "runtime"
$fixture     = Join-Path $root "fixture"
$keysDir     = Join-Path $runtimeRoot "keys"
$keyBase     = Join-Path $keysDir "clarity_dev_ed25519"
$repoCleanup = New-Object System.Collections.Generic.List[string]

try {
  New-Item -ItemType Directory -Force -Path $runtimeRoot,$fixture,$keysDir,(Join-Path $runtimeRoot "outbox") | Out-Null
  WriteUtf8NoBomLf (Join-Path $fixture "readme.txt") "clean`n"

  # Fresh signing key + allowed_signers (self-contained; no machine key needed).
  $genArg = ('-t ed25519 -f "' + $keyBase + '" -N "" -C clarity-seal-test -q')
  $g = Start-Process -FilePath "ssh-keygen.exe" -ArgumentList $genArg -Wait -PassThru -NoNewWindow
  if($g.ExitCode -ne 0){ throw ("KEYGEN_FAILED exit=" + $g.ExitCode) }
  if(-not (Test-Path -LiteralPath ($keyBase + ".pub") -PathType Leaf)){ throw "PUBKEY_NOT_PRODUCED" }
  $pub = (Get-Content -Raw -LiteralPath ($keyBase + ".pub") -Encoding UTF8).Trim()
  $parts = $pub -split '\s+'
  WriteUtf8NoBomLf (Join-Path $keysDir "allowed_signers") ($Principal + " " + $parts[0] + " " + $parts[1] + "`n")

  # Produce a real validator run to seal.
  $runOut = @(& (Join-Path $RepoRoot "scripts\validator_run.ps1") -RepoRoot $RepoRoot -RuntimeRoot $runtimeRoot -Tenant test -Principal $Principal -ProducerInstance seal-test -TargetRoots @($fixture) -MaxFiles 20)
  $runPath = Get-OutPath $runOut "*.run.json"
  $run = Get-Content -Raw -LiteralPath $runPath -Encoding UTF8 | ConvertFrom-Json
  $repoCleanup.Add($runPath)
  $repoCleanup.Add([string]$run.phases.preflight.path)
  $repoCleanup.Add((Split-Path -Parent ([string]$run.phases.scan.path)))
  $repoCleanup.Add([string]$run.phases.isolation.path)
  $repoCleanup.Add([string]$run.phases.handoff.path)

  # Seal it.
  $sealOut = @(& (Join-Path $RepoRoot "scripts\validator_seal.ps1") -RunPath $runPath -RuntimeRoot $runtimeRoot -RepoRoot $RepoRoot -Principal $Principal -KeyBase $keyBase -Namespace $Namespace)
  $sealDir = Get-OutPath $sealOut "*validator_seals*"
  $repoCleanup.Add($sealDir)
  if(-not (Test-Path -LiteralPath (Join-Path $sealDir "signature.sig") -PathType Leaf)){ throw "SIGNATURE_NOT_WRITTEN" }
  if(-not (Test-Path -LiteralPath (Join-Path $sealDir "seal.json") -PathType Leaf)){ throw "SEAL_JSON_NOT_WRITTEN" }

  $verifyScript = Join-Path $RepoRoot "scripts\validator_verify_seal.ps1"

  # Positive verification.
  $vOut = @(& $verifyScript -SealDir $sealDir -RuntimeRoot $runtimeRoot -Principal $Principal -Namespace $Namespace)
  if(($vOut | ForEach-Object { $_.ToString().Trim() }) -notcontains "CLARITY_VALIDATOR_SEAL_VERIFY_OK"){ throw "POSITIVE_VERIFY_FAILED" }

  # Negative A: corrupt a sealed artifact -> hash binding fails.
  $reportCopy = Join-Path $sealDir "report.json"
  $origReport = [IO.File]::ReadAllBytes($reportCopy)
  [IO.File]::AppendAllText($reportCopy,"x",(New-Object System.Text.UTF8Encoding($false)))
  $hashFail = $false
  try { & $verifyScript -SealDir $sealDir -RuntimeRoot $runtimeRoot -Principal $Principal -Namespace $Namespace | Out-Null }
  catch { if($_.Exception.Message -like "*SEAL_FILE_HASH_MISMATCH*"){ $hashFail = $true } else { throw } }
  [IO.File]::WriteAllBytes($reportCopy,$origReport)
  if(-not $hashFail){ throw "CORRUPT_ARTIFACT_NOT_DETECTED" }

  # Negative B: a valid signature over a different message must not verify.
  $sigPath = Join-Path $sealDir "signature.sig"
  $origSig = [IO.File]::ReadAllBytes($sigPath)
  $wrongMsg = Join-Path $root "wrong.txt"
  WriteUtf8NoBomLf $wrongMsg "not-the-sums`n"
  $ws = Start-Process -FilePath "ssh-keygen.exe" -ArgumentList ('-Y sign -f "' + $keyBase + '" -n ' + $Namespace + ' -I "' + $Principal + '" "' + $wrongMsg + '"') -Wait -PassThru -NoNewWindow
  if($ws.ExitCode -ne 0){ throw "WRONG_SIGN_FAILED" }
  Copy-Item -LiteralPath ($wrongMsg + ".sig") -Destination $sigPath -Force
  $sigFail = $false
  try { & $verifyScript -SealDir $sealDir -RuntimeRoot $runtimeRoot -Principal $Principal -Namespace $Namespace | Out-Null }
  catch { if($_.Exception.Message -like "*SEAL_SIGNATURE_INVALID*"){ $sigFail = $true } else { throw } }
  [IO.File]::WriteAllBytes($sigPath,$origSig)
  if(-not $sigFail){ throw "WRONG_SIGNATURE_NOT_DETECTED" }

  # Original signature verifies again after restore.
  $vOut2 = @(& $verifyScript -SealDir $sealDir -RuntimeRoot $runtimeRoot -Principal $Principal -Namespace $Namespace)
  if(($vOut2 | ForEach-Object { $_.ToString().Trim() }) -notcontains "CLARITY_VALIDATOR_SEAL_VERIFY_OK"){ throw "RESTORED_VERIFY_FAILED" }

  Write-Host "CLARITY_TIER1_STEP9_OK" -ForegroundColor Green
}
finally {
  foreach($p in $repoCleanup){
    if(Test-Path -LiteralPath $p -PathType Container){ Remove-Item -LiteralPath $p -Recurse -Force }
    elseif(Test-Path -LiteralPath $p -PathType Leaf){ Remove-Item -LiteralPath $p -Force }
  }
  if(Test-Path -LiteralPath $root -PathType Container){ Remove-Item -LiteralPath $root -Recurse -Force }
}
