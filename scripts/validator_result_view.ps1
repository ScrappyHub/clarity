param(
  [Parameter(Mandatory=$true)][string]$SealDir,
  [Parameter(Mandatory=$false)][string]$RuntimeRoot = "",
  [Parameter(Mandatory=$false)][string]$Principal = "",
  [Parameter(Mandatory=$false)][string]$HtmlPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\canon.ps1"

function HasProp($obj,[string]$n){ if($null -eq $obj){ return $false }; return [bool]($obj.PSObject.Properties.Name -contains $n) }
function Val($obj,[string]$n,$default){ if(HasProp $obj $n){ return $obj.$n } else { return $default } }
function Pad([string]$label){ return ($label + (" " * [Math]::Max(0, 30 - $label.Length))) }

if(-not (Test-Path -LiteralPath $SealDir -PathType Container)){ throw ("MISSING_SEAL_DIR: " + $SealDir) }
$sumPath = Join-Path $SealDir "sha256sums.txt"
if(-not (Test-Path -LiteralPath $sumPath -PathType Leaf)){ throw "MISSING_SHA256SUMS" }

# 1. Integrity: nothing is displayed from evidence that does not hash correctly.
$fileCount = 0
foreach($line in @((Get-Content -LiteralPath $sumPath -Encoding UTF8) | ForEach-Object { $_.Trim() } | Where-Object { $_ })){
  $idx = $line.IndexOf("  ")
  if($idx -lt 0){ throw ("BAD_SHA256SUMS_LINE: " + $line) }
  $hex = $line.Substring(0,$idx).Trim()
  $name = $line.Substring($idx+2).Trim()
  $abs = Join-Path $SealDir $name
  if(-not (Test-Path -LiteralPath $abs -PathType Leaf)){ throw ("SEAL_INTEGRITY_FAILED: missing " + $name) }
  if((Sha256HexFile $abs) -ne $hex){ throw ("SEAL_INTEGRITY_FAILED: " + $name) }
  $fileCount++
}

# 2. Signature (only when a runtime + principal are supplied).
$sigState = "not checked"
if($RuntimeRoot -and $Principal){
  & (Join-Path $PSScriptRoot "validator_verify_seal.ps1") -SealDir $SealDir -RuntimeRoot $RuntimeRoot -Principal $Principal | Out-Null
  $sigState = "verified"
}

function Load([string]$n){
  $p = Join-Path $SealDir $n
  if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ return $null }
  return (Get-Content -Raw -LiteralPath $p -Encoding UTF8 | ConvertFrom-Json)
}
$report    = Load "report.json"
$preflight = Load "preflight.json"
$scan      = Load "scan.json"
$isolation = Load "isolation.json"
$decision  = Load "handoff_decision.json"
$target    = Load "handoff_target.json"
if($null -eq $report){ throw "MISSING_REPORT" }

$dev  = if(HasProp $preflight "device"){ $preflight.device } else { $null }
$caps = if(HasProp $preflight "capabilities"){ $preflight.capabilities } else { $null }
$cc   = if(HasProp $scan "classified_counts"){ $scan.classified_counts } else { $null }

$trustTier   = [string](Val $preflight "trust_tier" "unknown")
$examined    = [int](Val $scan "examined_file_count" 0)
$suspicious  = [int](Val $scan "suspicious_count" 0)
$isolated    = [int](Val $isolation "isolated_count" 0)
$scanComplete= [bool](Val $scan "scan_complete" $false)
$missingCrit = [int](Val $scan "missing_critical_count" 0)
$verifiedN   = [int](Val $cc "verified" 0)
$unknownN    = [int](Val $cc "unknown" 0)
$suspN       = [int](Val $cc "suspicious" 0)
$compN       = [int](Val $cc "compromised" 0)
$targetVerdict = if($null -ne $target){ [string]$target.verdict } else { "NOT VERIFIED" }

$L = New-Object System.Collections.Generic.List[string]
[void]$L.Add("CLARITY VALIDATOR RESULT")
[void]$L.Add("========================================")
[void]$L.Add("Run ID:        " + [string]$report.run_id)
[void]$L.Add("Created (UTC): " + [string]$report.created_at_utc)
[void]$L.Add("Validator:     " + [string]$report.validator)
[void]$L.Add("Assurance:     " + [string]$report.assurance_level)
[void]$L.Add("Evidence:      integrity verified (" + $fileCount + " files); signature " + $sigState)
[void]$L.Add("")
[void]$L.Add((Pad "STARTING VALIDATOR") + "done")
[void]$L.Add((Pad "VALIDATING PLATFORM") + $trustTier)
[void]$L.Add((Pad "VERIFYING BOOT TARGET") + $targetVerdict)
[void]$L.Add((Pad "SCANNING CRITICAL FILES") + $examined + " examined")
[void]$L.Add((Pad "ISOLATING SUSPICIOUS CONTENT") + $isolated + " isolated")
[void]$L.Add("")
[void]$L.Add("PLATFORM")
[void]$L.Add("  Device:        " + [string](Val $dev "computer_name" "unknown"))
[void]$L.Add("  OS:            " + [string](Val $dev "os_caption" "unknown") + " " + [string](Val $dev "os_version" ""))
[void]$L.Add("  TPM present:   " + [string](Val $caps "tpm_present" "unknown"))
[void]$L.Add("  Secure Boot:   " + [string](Val $caps "secure_boot_state" "unknown"))
[void]$L.Add("  Hypervisor:    " + [string](Val $caps "hypervisor_state" "unknown"))
[void]$L.Add("  Trust tier:    " + $trustTier)
[void]$L.Add("  Reasons:       " + ((@(Val $preflight "reason_codes" @())) -join ", "))
[void]$L.Add("")
[void]$L.Add("BOOT TARGET")
if($null -ne $target){
  [void]$L.Add("  Path:          " + [string]$target.target_path)
  [void]$L.Add("  Verdict:       " + [string]$target.verdict)
  [void]$L.Add("  Reason:        " + [string]$target.reason_code)
  [void]$L.Add("  SHA-256:       " + [string]$target.target_sha256)
} else {
  [void]$L.Add("  Not verified in this run.")
}
[void]$L.Add("")
[void]$L.Add("SCAN")
[void]$L.Add("  Examined:      " + $examined)
[void]$L.Add("  Verified:      " + $verifiedN)
[void]$L.Add("  Unknown:       " + $unknownN)
[void]$L.Add("  Suspicious:    " + $suspN)
[void]$L.Add("  Compromised:   " + $compN)
[void]$L.Add("  Missing critical: " + $missingCrit)
[void]$L.Add("  Scan complete: " + $scanComplete)
[void]$L.Add("")
[void]$L.Add("ISOLATION")
[void]$L.Add("  Isolated objects: " + $isolated)
[void]$L.Add("")
$cs      = if(HasProp $scan "change_summary"){ $scan.change_summary } else { $null }
$protN   = [int](Val $scan "protected_flagged_count" 0)
$knownN  = [int](Val $scan "known_unchanged_suspicious_count" 0)
[void]$L.Add("CHANGES SINCE PREVIOUS SCAN")
if($null -ne $cs -and [bool](Val $cs "compared" $false)){
  [void]$L.Add("  New:           " + [int](Val $cs "new" 0))
  [void]$L.Add("  Changed:       " + [int](Val $cs "changed" 0))
  [void]$L.Add("  Unchanged:     " + [int](Val $cs "unchanged" 0))
  [void]$L.Add("  Removed:       " + [int](Val $cs "removed" 0))
} else {
  [void]$L.Add("  No previous inventory supplied; change tracking not performed.")
}
[void]$L.Add("  Protected files flagged (reported, never isolated): " + $protN)
[void]$L.Add("  Known unchanged files already isolated previously:  " + $knownN)
$chg = @(Val $scan "changes" @())
$shown = 0
foreach($c in $chg){
  if($shown -ge 20){ break }
  $shown++
  [void]$L.Add("  [" + [string]$c.state + "] " + [string]$c.disposition + "  " + [string]$c.reason_code + "  " + [string]$c.path)
}
if($chg.Count -gt $shown){ [void]$L.Add("  ... " + ($chg.Count - $shown) + " more in the sealed scan report") }
[void]$L.Add("")
[void]$L.Add("DECISION")
[void]$L.Add("  Handoff:       " + [string](Val $decision "decision" "unknown"))
[void]$L.Add("  Allowed:       " + [string](Val $decision "allowed" "unknown"))
[void]$L.Add("  Reason:        " + [string](Val $decision "reason_code" "unknown"))
[void]$L.Add("========================================")

$text = ($L.ToArray() -join "`n")
Write-Output $text

if($HtmlPath){
  $esc = { param($s) ([string]$s).Replace("&","&amp;").Replace("<","&lt;").Replace(">","&gt;") }
  $body = (& $esc $text)
  $html = "<!doctype html><html><head><meta charset=""utf-8""><title>Clarity Validator Result</title>" +
    "<style>body{background:#0d1117;color:#c9d1d9;font:14px/1.5 ui-monospace,Consolas,monospace;padding:24px}" +
    "pre{white-space:pre-wrap;margin:0}h1{font-size:16px;color:#58a6ff;margin:0 0 12px}</style></head>" +
    "<body><h1>Clarity Validator Result</h1><pre>" + $body + "</pre></body></html>"
  WriteUtf8NoBomLf $HtmlPath $html
  Write-Output ("RESULT_HTML=" + $HtmlPath)
}

Write-Output "CLARITY_VALIDATOR_RESULT_OK"
