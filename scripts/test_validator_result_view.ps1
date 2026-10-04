param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $RepoRoot "scripts\lib\canon.ps1")

function Get-OutPath([object[]]$Output,[string]$Pattern){
  $m = @($Output | ForEach-Object {
    $line = $_.ToString().Trim(); $v = $line; $i = $line.IndexOf("=")
    if($i -gt 0){ $v = $line.Substring($i+1).Trim() }
    if($v -like $Pattern -and (Test-Path -LiteralPath $v)){ $v }
  })
  if($m.Count -eq 0){ throw ("OUTPUT_NOT_FOUND: " + $Pattern) }
  return $m[$m.Count-1]
}

$Principal   = "clarity-result-test"
$root        = Join-Path ([IO.Path]::GetTempPath()) ("clarity-result-test-" + [Guid]::NewGuid().ToString("N"))
$runtimeRoot = Join-Path $root "runtime"
$fixture     = Join-Path $root "fixture"
$keysDir     = Join-Path $runtimeRoot "keys"
$keyBase     = Join-Path $keysDir "clarity_dev_ed25519"
$cleanup     = New-Object System.Collections.Generic.List[string]

try {
  New-Item -ItemType Directory -Force -Path $runtimeRoot,$fixture,$keysDir,(Join-Path $runtimeRoot "outbox") | Out-Null

  # Double-extension name: detected by the shipped rules regardless of where TEMP lives.
  WriteUtf8NoBomLf (Join-Path $fixture "invoice.pdf.scr") "payload`n"

  $g = Start-Process -FilePath "ssh-keygen.exe" -ArgumentList ('-t ed25519 -f "' + $keyBase + '" -N "" -C result-test -q') -Wait -PassThru -NoNewWindow
  if($g.ExitCode -ne 0){ throw "KEYGEN_FAILED" }
  $pub = (Get-Content -Raw -LiteralPath ($keyBase + ".pub") -Encoding UTF8).Trim(); $parts = $pub -split '\s+'
  WriteUtf8NoBomLf (Join-Path $keysDir "allowed_signers") ($Principal + " " + $parts[0] + " " + $parts[1] + "`n")

  $bootTarget = Join-Path $root "bootmgr.bin"
  WriteUtf8NoBomLf $bootTarget "boot`n"
  $baselinePath = Join-Path $root "boot_baseline.json"
  WriteUtf8NoBomLf $baselinePath ((([ordered]@{
    schema="clarity.baseline.v1"; baseline_id="result-test"; version="1.0.0"
    entries=@([ordered]@{ path=$bootTarget; sha256=(Sha256HexFile $bootTarget) })
  }) | ConvertTo-Json -Depth 6))

  $outRun = @(& (Join-Path $RepoRoot "scripts\validator_run.ps1") -RepoRoot $RepoRoot -RuntimeRoot $runtimeRoot -Tenant test -Principal $Principal -ProducerInstance result-test -TargetRoots @($fixture) -MaxFiles 20 -AllowDegraded -HandoffTargetPath $bootTarget -HandoffBaselinePath $baselinePath)
  $runPath = Get-OutPath $outRun "*.run.json"
  $run = Get-Content -Raw -LiteralPath $runPath -Encoding UTF8 | ConvertFrom-Json
  $cleanup.Add($runPath)
  $cleanup.Add([string]$run.phases.preflight.path)
  $cleanup.Add((Split-Path -Parent ([string]$run.phases.scan.path)))
  $cleanup.Add([string]$run.phases.isolation.path)
  $cleanup.Add([string]$run.phases.handoff.path)
  $cleanup.Add([string]$run.phases.handoff_target.path)

  $sealOut = @(& (Join-Path $RepoRoot "scripts\validator_seal.ps1") -RunPath $runPath -RuntimeRoot $runtimeRoot -RepoRoot $RepoRoot -Principal $Principal -KeyBase $keyBase)
  $sealDir = Get-OutPath $sealOut "*validator_seals*"
  $cleanup.Add($sealDir)

  $htmlPath = Join-Path $root "result.html"
  $view = Join-Path $RepoRoot "scripts\validator_result_view.ps1"
  $vOut = @(& $view -SealDir $sealDir -RuntimeRoot $runtimeRoot -Principal $Principal -HtmlPath $htmlPath)
  $text = ($vOut -join "`n")

  # Every displayed number must come from the evidence.
  if($text -notmatch [regex]::Escape([string]$run.run_id)){ throw "RUN_ID_NOT_SHOWN" }
  if($text -notmatch "HANDOFF_TARGET_VALID"){ throw "BOOT_VERDICT_NOT_SHOWN" }
  if($text -notmatch "Suspicious:\s+1"){ throw "SUSPICIOUS_COUNT_WRONG" }
  if($text -notmatch "Isolated objects:\s+1"){ throw "ISOLATED_COUNT_WRONG" }
  if($text -notmatch "Allowed:\s+False"){ throw "DECISION_NOT_SHOWN_OR_WRONG" }
  if($text -notmatch "integrity verified \(\d+ files\)"){ throw "INTEGRITY_NOT_REPORTED" }
  if($text -notmatch "signature verified"){ throw "SIGNATURE_NOT_REPORTED" }
  if(-not (Test-Path -LiteralPath $htmlPath -PathType Leaf)){ throw "HTML_NOT_WRITTEN" }

  # Tampered evidence must never be rendered.
  $reportCopy = Join-Path $sealDir "report.json"
  $orig = [IO.File]::ReadAllBytes($reportCopy)
  [IO.File]::AppendAllText($reportCopy,"x",(New-Object System.Text.UTF8Encoding($false)))
  $refused = $false
  try { & $view -SealDir $sealDir | Out-Null }
  catch { if($_.Exception.Message -like "*SEAL_INTEGRITY_FAILED*"){ $refused = $true } else { throw } }
  [IO.File]::WriteAllBytes($reportCopy,$orig)
  if(-not $refused){ throw "TAMPERED_EVIDENCE_WAS_RENDERED" }

  Write-Host "CLARITY_TIER1_STEP10_OK" -ForegroundColor Green
}
finally {
  foreach($p in $cleanup){
    if(Test-Path -LiteralPath $p -PathType Container){ Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
    elseif(Test-Path -LiteralPath $p -PathType Leaf){ Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
  }
  if(Test-Path -LiteralPath $root -PathType Container){ Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
