param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $RepoRoot "scripts\lib\canon.ps1")

function Get-DiscoveryReport([object[]]$Output){
  $m = @($Output | ForEach-Object {
    $line = $_.ToString().Trim()
    $v = $line
    $i = $line.IndexOf("=")
    if($i -gt 0){ $v = $line.Substring($i + 1).Trim() }
    if($v -like "*.boot_discovery.json" -and (Test-Path -LiteralPath $v -PathType Leaf)){ $v }
  })
  if($m.Count -eq 0){ throw "BOOT_DISCOVERY_REPORT_NOT_FOUND" }
  return $m[$m.Count - 1]
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$createdDirs = New-Object System.Collections.Generic.List[string]
try {
  # ---- Base path: read-only discovery, no ESP mount. Must never throw and
  # must always produce a well-formed, honest artifact, whatever this host
  # actually supports or whether this shell is elevated.
  $out = @(& (Join-Path $RepoRoot "scripts\validator_boot_target_discover.ps1") -RepoRoot $RepoRoot)
  $reportPath = Get-DiscoveryReport $out
  $createdDirs.Add((Split-Path -Parent $reportPath))
  $report = Get-Content -Raw -LiteralPath $reportPath -Encoding UTF8 | ConvertFrom-Json
  $errs = @($report.discovery_errors)

  if([string]$report.schema -ne "clarity.boot_target_discovery.v1"){ throw "WRONG_SCHEMA" }
  if([string]::IsNullOrWhiteSpace([string]$report.run_id)){ throw "MISSING_RUN_ID" }

  $validFirmware = @("UEFI","Legacy_BIOS","unknown")
  if($validFirmware -notcontains [string]$report.firmware_type){ throw ("UNEXPECTED_FIRMWARE_TYPE: " + $report.firmware_type) }
  $validSecureBoot = @("enabled","disabled","unsupported","unknown")
  if($validSecureBoot -notcontains [string]$report.secure_boot_state){ throw ("UNEXPECTED_SECURE_BOOT_STATE: " + $report.secure_boot_state) }

  # Cross-check against independent host signals so the report cannot
  # silently disagree with what the OS itself publishes.
  if($env:firmware_type -ieq "UEFI" -and [string]$report.firmware_type -ne "UEFI"){ throw ("FIRMWARE_TYPE_DISAGREES_WITH_ENV: " + $report.firmware_type) }
  try {
    $sbReg = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State" -Name "UEFISecureBootEnabled" -ErrorAction Stop
    $expectSb = if([int]$sbReg.UEFISecureBootEnabled -eq 1){ "enabled" } else { "disabled" }
    if([string]$report.secure_boot_state -ne $expectSb){ throw ("SECURE_BOOT_DISAGREES_WITH_REGISTRY: report=" + $report.secure_boot_state + " registry=" + $expectSb) }
  } catch [System.Management.Automation.ItemNotFoundException] {} catch [System.Management.Automation.PSArgumentException] {}

  # Honesty invariants: incomplete discovery must be explained; complete means no errors.
  if([bool]$report.discovery_complete -ne ($errs.Count -eq 0)){ throw "DISCOVERY_COMPLETE_INCONSISTENT_WITH_ERRORS" }
  if([string]::IsNullOrEmpty([string]$report.bootmgr_path) -and $errs.Count -eq 0){ throw "BOOTMGR_PATH_MISSING_WITHOUT_EXPLANATION" }
  if(-not $isElevated -and [string]::IsNullOrEmpty([string]$report.bootmgr_path) -and ($errs -notcontains "BCDEDIT_REQUIRES_ELEVATION")){ throw "UNELEVATED_BCD_FAILURE_NOT_EXPLAINED" }
  if($isElevated -and [string]::IsNullOrEmpty([string]$report.bootmgr_path)){ throw ("ELEVATED_BOOTMGR_PATH_NOT_DISCOVERED: " + ($errs -join ",")) }

  if([bool]$report.esp_mount_attempted -ne $false){ throw "MOUNT_SHOULD_NOT_BE_ATTEMPTED_BY_DEFAULT" }
  if([bool]$report.esp_mount_succeeded -ne $false){ throw "MOUNT_SHOULD_NOT_HAVE_SUCCEEDED" }
  if($null -ne $report.boot_file_sha256){ throw "HASH_SHOULD_BE_NULL_WITHOUT_MOUNT" }

  Write-Host ("Boot discovery (no-mount): firmware=" + $report.firmware_type + " (" + $report.firmware_type_source + ") secure_boot=" + $report.secure_boot_state + " (" + $report.secure_boot_source + ") bootmgr_path=" + $report.bootmgr_path + " esp_count=" + $report.esp_partition_count + " complete=" + $report.discovery_complete + " elevated=" + $isElevated) -ForegroundColor Cyan
  if($errs.Count -gt 0){ Write-Host ("  discovery_errors: " + ($errs -join ", ")) -ForegroundColor Yellow }

  # ---- Optional elevated path: only exercised when this shell is Administrator.
  if($isElevated){
    $tempBefore = @(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter "clarity_esp_mount_*" -ErrorAction SilentlyContinue)

    $out2 = @(& (Join-Path $RepoRoot "scripts\validator_boot_target_discover.ps1") -RepoRoot $RepoRoot -MountEspForHash)
    $reportPath2 = Get-DiscoveryReport $out2
    $createdDirs.Add((Split-Path -Parent $reportPath2))
    $report2 = Get-Content -Raw -LiteralPath $reportPath2 -Encoding UTF8 | ConvertFrom-Json

    if([bool]$report2.esp_mount_attempted -ne $true){ throw "ELEVATED_MOUNT_SHOULD_BE_ATTEMPTED" }
    if([bool]$report2.esp_mount_succeeded){
      if([string]$report2.boot_file_sha256 -notmatch '^[0-9a-f]{64}$'){ throw "MOUNT_SUCCEEDED_BUT_HASH_NOT_SHA256_HEX" }
      Write-Host ("Boot discovery (elevated mount): boot_file_sha256=" + $report2.boot_file_sha256) -ForegroundColor Cyan
    } else {
      Write-Host ("Elevated mount attempted but did not succeed (errors: " + (@($report2.discovery_errors) -join ",") + ")") -ForegroundColor Yellow
    }

    $tempAfter = @(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter "clarity_esp_mount_*" -ErrorAction SilentlyContinue)
    if($tempAfter.Count -ne $tempBefore.Count){ throw "ESP_MOUNT_TEMP_DIR_LEAKED" }
  } else {
    Write-Host "Not running elevated -- BCD path and ESP mount need Administrator; skipped (expected, reported honestly as BCDEDIT_REQUIRES_ELEVATION)." -ForegroundColor Yellow
  }

  Write-Host "BOOT_TARGET_DISCOVERY_TEST_OK" -ForegroundColor Green
  Write-Output "CLARITY_TIER2_BOOT_DISCOVERY_OK"
}
finally {
  foreach($d in $createdDirs){ if(Test-Path -LiteralPath $d -PathType Container){ Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }
}
