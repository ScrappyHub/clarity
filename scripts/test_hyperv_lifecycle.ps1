param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $RepoRoot "scripts\lib\canon.ps1")

function Invoke-Lifecycle([string]$ProfilePath){
  $out = @(& (Join-Path $RepoRoot "scripts\hyperv_vm_lifecycle.ps1") -RepoRoot $RepoRoot -ProfilePath $ProfilePath)
  $p = @($out | ForEach-Object {
    $line = $_.ToString().Trim()
    if($line -like "HYPERV_LIFECYCLE_REPORT=*"){ $line.Substring("HYPERV_LIFECYCLE_REPORT=".Length) }
  })
  if($p.Count -eq 0){ throw "LIFECYCLE_REPORT_NOT_FOUND" }
  $path = $p[$p.Count - 1]
  return [pscustomobject]@{ Path = $path; Report = (Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json) }
}

function Get-ClarityVmCount(){
  if(-not (Get-Command Get-VM -ErrorAction SilentlyContinue)){ return 0 }
  try { return @(Get-VM -ErrorAction Stop | Where-Object { $_.Name -like "clarity-review-*" }).Count } catch { return 0 }
}

$baseProfile = Join-Path $RepoRoot "vm_profiles\protected_review_hyperv.v1.json"
if(-not (Test-Path -LiteralPath $baseProfile -PathType Leaf)){ throw "MISSING_BASE_PROFILE" }

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("clarity-hyperv-test-" + [Guid]::NewGuid().ToString("N"))
$createdDirs = New-Object System.Collections.Generic.List[string]
try {
  New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
  $vmsBefore = Get-ClarityVmCount

  # ---- Negative proof (runs on every host): a profile that weakens isolation
  # must be REFUSED before the host is touched at all.
  $badObj = Get-Content -Raw -LiteralPath $baseProfile -Encoding UTF8 | ConvertFrom-Json
  $badObj.configuration.networking = "enabled"
  $badPath = Join-Path $tmpRoot "networking_enabled.json"
  WriteUtf8NoBomLf $badPath ($badObj | ConvertTo-Json -Depth 8)

  $bad = Invoke-Lifecycle $badPath
  $createdDirs.Add((Split-Path -Parent $bad.Path))
  if([string]$bad.Report.schema -ne "clarity.hyperv_lifecycle.v1"){ throw "WRONG_SCHEMA" }
  if([string]$bad.Report.status -ne "refused"){ throw ("WEAKENED_PROFILE_NOT_REFUSED: status=" + $bad.Report.status) }
  if(@($bad.Report.reason_codes) -notcontains "NETWORKING_NOT_DISABLED"){ throw "REFUSAL_REASON_MISSING" }
  if($null -ne $bad.Report.vm_name){ throw "REFUSED_RUN_MUST_NOT_CREATE_VM" }
  if((Get-ClarityVmCount) -ne $vmsBefore){ throw "REFUSED_RUN_LEAKED_VM" }

  # ---- Real profile: lifecycle runs fully on a capable, elevated host and is
  # honestly deferred (with explicit reasons) everywhere else.
  $good = Invoke-Lifecycle $baseProfile
  $createdDirs.Add((Split-Path -Parent $good.Path))
  $r = $good.Report
  $st = [string]$r.status

  if($st -eq "deferred"){
    if(@($r.reason_codes).Count -eq 0){ throw "DEFERRED_WITHOUT_REASON" }
    if($null -ne $r.vm_name){ throw "DEFERRED_RUN_MUST_NOT_CREATE_VM" }
    if((Get-ClarityVmCount) -ne $vmsBefore){ throw "DEFERRED_RUN_LEAKED_VM" }
    Write-Host ("Hyper-V lifecycle DEFERRED on this host: " + (@($r.reason_codes) -join ", ")) -ForegroundColor Yellow
    Write-Host "HYPERV_LIFECYCLE_NEGATIVE_PROOFS_OK" -ForegroundColor Green
    Write-Output "CLARITY_TIER2_STEP11_DEFERRED_OK"
  }
  elseif($st -eq "completed"){
    foreach($c in @($r.config_checks)){ if(-not [bool]$c.ok){ throw ("CONFIG_CHECK_FAILED: " + $c.check) } }
    if(-not [bool]$r.boot.reached_running){ throw "VM_NEVER_RAN" }
    if(-not [bool]$r.boot.returned_to_off){ throw "VM_NOT_STOPPED" }
    if(-not [bool]$r.teardown.vm_removed){ throw "VM_NOT_REMOVED" }
    if(-not [bool]$r.teardown.files_removed){ throw "FILES_NOT_REMOVED" }
    if($r.host_contamination.switches_unchanged -ne $true){ throw "VSWITCH_CHANGED" }
    if($r.host_contamination.other_vms_unchanged -ne $true){ throw "OTHER_VMS_CHANGED" }
    if((Get-ClarityVmCount) -ne $vmsBefore){ throw "VM_LEAKED_AFTER_TEARDOWN" }
    Write-Host "Hyper-V lifecycle COMPLETED: provision, read-back, firmware boot, stop, teardown, no host contamination." -ForegroundColor Cyan
    Write-Host "HYPERV_LIFECYCLE_TEST_OK" -ForegroundColor Green
    Write-Output "CLARITY_TIER2_STEP11_OK"
  }
  else {
    throw ("LIFECYCLE_FAILED: " + (@($r.reason_codes) -join "; "))
  }
}
finally {
  foreach($d in $createdDirs){ if(Test-Path -LiteralPath $d -PathType Container){ Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }
  if(Test-Path -LiteralPath $tmpRoot -PathType Container){ Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
