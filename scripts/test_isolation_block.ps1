param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $RepoRoot "scripts\lib\canon.ps1")

function Get-BlockReport([object[]]$Output){
  $m = @($Output | ForEach-Object {
    $line = $_.ToString().Trim()
    $v = $line
    $i = $line.IndexOf("=")
    if($i -gt 0){ $v = $line.Substring($i + 1).Trim() }
    if($v -like "*.block.json" -and (Test-Path -LiteralPath $v -PathType Leaf)){ $v }
  })
  if($m.Count -eq 0){ throw "BLOCK_REPORT_NOT_FOUND" }
  return $m[$m.Count - 1]
}

$root        = Join-Path ([IO.Path]::GetTempPath()) ("clarity-block-test-" + [Guid]::NewGuid().ToString("N"))
$runtimeRoot = Join-Path $root "runtime"
$allowedDir  = Join-Path $root "allowed"
$criticalDir = Join-Path $root "critical"
$otherDir    = Join-Path $root "other"
$repoReports = New-Object System.Collections.Generic.List[string]
$blockScript = Join-Path $RepoRoot "scripts\isolation_block.ps1"

try {
  New-Item -ItemType Directory -Force -Path $runtimeRoot,$allowedDir,$criticalDir,$otherDir | Out-Null
  $targetAllowed  = Join-Path $allowedDir  "susp.exe"
  $targetCritical = Join-Path $criticalDir "sys.dll"
  $targetOther    = Join-Path $otherDir    "rogue.exe"
  WriteUtf8NoBomLf $targetAllowed  "allowed-bytes`n"
  WriteUtf8NoBomLf $targetCritical "critical-bytes`n"
  WriteUtf8NoBomLf $targetOther    "other-bytes`n"

  $rulesPath = Join-Path $root "rules.json"
  $rulesObj = [ordered]@{
    scan = [ordered]@{ critical_prefixes = @($criticalDir) }
    quarantine = [ordered]@{ allowed_block_roots = @($allowedDir); default_mode = "ReportOnly" }
  }
  WriteUtf8NoBomLf $rulesPath (($rulesObj | ConvertTo-Json -Depth 6))

  $hAllowed  = Sha256HexFile $targetAllowed
  $hCritical = Sha256HexFile $targetCritical

  # A. ReportOnly on an allowed target: recorded, but nothing written next to it.
  $outA = @(& $blockScript -RuntimeRoot $runtimeRoot -RepoRoot $RepoRoot -TargetPath $targetAllowed -Tenant t -Principal t -ProducerInstance bt -Mode ReportOnly -RulesPath $rulesPath)
  $repoReports.Add((Get-BlockReport $outA))
  $repA = Get-Content -Raw -LiteralPath (Get-BlockReport $outA) -Encoding UTF8 | ConvertFrom-Json
  if([string]$repA.decision -ne "block_reported"){ throw "REPORTONLY_DECISION_WRONG" }
  if(Test-Path -LiteralPath ($targetAllowed + ".clarity_blocked.json")){ throw "REPORTONLY_WROTE_MARKER" }

  # B. Marker on an allowed target: sidecar written, original untouched.
  $outB = @(& $blockScript -RuntimeRoot $runtimeRoot -RepoRoot $RepoRoot -TargetPath $targetAllowed -Tenant t -Principal t -ProducerInstance bt -Mode Marker -RulesPath $rulesPath)
  $repoReports.Add((Get-BlockReport $outB))
  $repB = Get-Content -Raw -LiteralPath (Get-BlockReport $outB) -Encoding UTF8 | ConvertFrom-Json
  if([string]$repB.decision -ne "blocked_marker"){ throw "MARKER_DECISION_WRONG" }
  if(-not (Test-Path -LiteralPath ($targetAllowed + ".clarity_blocked.json"))){ throw "MARKER_NOT_WRITTEN" }
  if((Sha256HexFile $targetAllowed) -ne $hAllowed){ throw "MARKER_MUTATED_ORIGINAL" }

  # C. Marker on a critical target: logical block only, nothing written near it.
  $outC = @(& $blockScript -RuntimeRoot $runtimeRoot -RepoRoot $RepoRoot -TargetPath $targetCritical -Tenant t -Principal t -ProducerInstance bt -Mode Marker -RulesPath $rulesPath)
  $repoReports.Add((Get-BlockReport $outC))
  $repC = Get-Content -Raw -LiteralPath (Get-BlockReport $outC) -Encoding UTF8 | ConvertFrom-Json
  if([string]$repC.decision -ne "blocked_logical"){ throw "CRITICAL_DECISION_WRONG" }
  if(Test-Path -LiteralPath ($targetCritical + ".clarity_blocked.json")){ throw "CRITICAL_WROTE_MARKER" }
  if((Sha256HexFile $targetCritical) -ne $hCritical){ throw "CRITICAL_MUTATED_ORIGINAL" }

  # D. Marker on a path in neither an allowed root nor a critical prefix: denied.
  $denied = $false
  try {
    & $blockScript -RuntimeRoot $runtimeRoot -RepoRoot $RepoRoot -TargetPath $targetOther -Tenant t -Principal t -ProducerInstance bt -Mode Marker -RulesPath $rulesPath | Out-Null
  } catch { if($_.Exception.Message -like "*BLOCK_PATH_NOT_ALLOWED*"){ $denied = $true } else { throw } }
  if(-not $denied){ throw "NOT_ALLOWED_PATH_NOT_DENIED" }

  # Ledger accumulated the three successful block events (A, B, C).
  $ledger = Join-Path $runtimeRoot "vault\ledger\block.ndjson"
  $lines = @(Get-Content -LiteralPath $ledger -Encoding UTF8 | Where-Object { $_ -and $_.Trim() -ne "" })
  if($lines.Count -ne 3){ throw "EXPECTED_THREE_BLOCK_LEDGER_ENTRIES" }
  $decisions = @($lines | ForEach-Object { ($_ | ConvertFrom-Json).decision })
  foreach($d in @("block_reported","blocked_marker","blocked_logical")){
    if($decisions -notcontains $d){ throw ("LEDGER_MISSING_DECISION: " + $d) }
  }

  Write-Host "CLARITY_TIER1_STEP7B_OK" -ForegroundColor Green
}
finally {
  foreach($p in $repoReports){ if(Test-Path -LiteralPath $p -PathType Leaf){ Remove-Item -LiteralPath $p -Force } }
  if(Test-Path -LiteralPath $root -PathType Container){ Remove-Item -LiteralPath $root -Recurse -Force }
}
