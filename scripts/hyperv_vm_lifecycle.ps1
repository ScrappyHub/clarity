param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$ProfilePath,
  [Parameter(Mandatory=$false)][string]$WorkRoot = ""
)

# Disposable Hyper-V review-VM lifecycle (Step 11): probe -> provision ->
# read-back verify -> start -> stop -> teardown, fail-closed at every gate.
# Provisions an isolation shell only (no guest image exists yet), so the
# honest ceiling is A1_HOST_OBSERVED: the evidence proves isolation
# configuration and lifecycle, not guest content or guest measurement.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\canon.ps1"

function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }

if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){ throw ("MISSING_REPO_ROOT: " + $RepoRoot) }
if(-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)){ throw ("MISSING_PROFILE: " + $ProfilePath) }

$runId = [Guid]::NewGuid().ToString("N")
$phases = New-Object System.Collections.Generic.List[object]
function Add-Phase([string]$Name,[string]$Status,[string]$Detail){
  $phases.Add([ordered]@{ name = $Name; status = $Status; detail = $Detail; at_utc = (UtcNow) })
}

$status = "failed"
$reasons = New-Object System.Collections.Generic.List[string]
$probe = [ordered]@{ module_present = $false; elevated = $false; vmms_running = $false }
$validation = $null
$vmName = $null
$vmId = $null
$workDir = $null
$readback = $null
$configChecks = @()
$bootEvidence = [ordered]@{ reached_running = $false; returned_to_off = $false; scope = "firmware_only_no_guest_image" }
$teardown = [ordered]@{ attempted = $false; vm_removed = $false; files_removed = $false }
$contamination = [ordered]@{ switches_unchanged = $null; other_vms_unchanged = $null }
$switchesBefore = $null
$vmsBefore = $null

try {
  # ---- 1. Profile validation (existing engine) ----
  $PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source
  $validatorArgs = @("-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",(Join-Path $PSScriptRoot "vm_profile_validate.ps1"),"-RepoRoot",$RepoRoot,"-ProfilePath",$ProfilePath,"-Adapter","hyperv")
  $vout = @(& $PSExe @validatorArgs)
  $vmatch = @($vout | ForEach-Object { $l = $_.ToString().Trim(); if($l -like "*.vm_compatibility.json" -and (Test-Path -LiteralPath $l -PathType Leaf)){ $l } })
  if($vmatch.Count -eq 0){ throw "MISSING_VM_COMPATIBILITY_REPORT" }
  $validation = Get-Content -Raw -LiteralPath $vmatch[$vmatch.Count - 1] -Encoding UTF8 | ConvertFrom-Json
  Add-Phase "profile_validation" "done" ("decision=" + $validation.decision)

  if([string]$validation.decision -eq "deny"){
    $status = "refused"
    foreach($c in @($validation.deny_codes)){ $reasons.Add([string]$c) }
    Add-Phase "isolation_gate" "refused" "profile denied"
  }
  else {
    # ---- 2. Isolation gate: only environmental / guest-image defers may pass.
    # Any defer that concerns isolation configuration refuses provisioning.
    $tolerated = @("GUEST_IMAGE_DIGEST_UNRESOLVED","GUEST_MEASUREMENT_UNAVAILABLE","HYPERV_UNAVAILABLE","SECURE_BOOT_UNOBSERVED")
    $blocking = @(@($validation.defer_codes) | Where-Object { $tolerated -notcontains [string]$_ })
    if($blocking.Count -gt 0){
      $status = "refused"
      foreach($c in $blocking){ $reasons.Add([string]$c) }
      Add-Phase "isolation_gate" "refused" ("blocking defer codes: " + ($blocking -join ","))
    }
    else {
      Add-Phase "isolation_gate" "passed" "no isolation-configuration defers"

      # ---- 3. Host capability probe ----
      $probe.module_present = [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)
      try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $probe.elevated = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
      } catch {}
      try { $probe.vmms_running = ((Get-Service -Name vmms -ErrorAction Stop).Status -eq "Running") } catch {}

      if(-not $probe.module_present){ $reasons.Add("HYPERV_MODULE_ABSENT") }
      if(-not $probe.elevated){ $reasons.Add("HYPERV_REQUIRES_ELEVATION") }
      if(-not $probe.vmms_running){ $reasons.Add("HYPERV_SERVICE_NOT_RUNNING") }

      if($reasons.Count -gt 0){
        $status = "deferred"
        Add-Phase "host_probe" "deferred" ($reasons -join ",")
      }
      else {
        Add-Phase "host_probe" "passed" "module present, elevated, vmms running"

        $prof = Get-Content -Raw -LiteralPath $ProfilePath -Encoding UTF8 | ConvertFrom-Json
        $vcpu = [int]$prof.resources.vcpu
        $memMb = [int]$prof.resources.memory_mb
        $diskGb = [int]$prof.resources.disk_gb

        $switchesBefore = @(Get-VMSwitch -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name } | Sort-Object)
        $vmsBefore = @(Get-VM -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Id } | Sort-Object)

        # ---- 4. Provision (disposable, no NIC, no checkpoints, no integration services) ----
        if([string]::IsNullOrWhiteSpace($WorkRoot)){ $WorkRoot = Join-Path $RepoRoot ("reports\hyperv_lifecycle\" + $runId) }
        $workDir = Join-Path $WorkRoot "vm"
        EnsureDir $workDir
        $vhdPath = Join-Path $workDir "disk.vhdx"
        $vmName = "clarity-review-" + $runId.Substring(0,12)

        $vm = New-VM -Name $vmName -Generation 2 -MemoryStartupBytes ([int64]$memMb * 1MB) -NewVHDPath $vhdPath -NewVHDSizeBytes ([int64]$diskGb * 1GB)
        $vmId = [string]$vm.Id
        Add-Phase "provision" "created" ("vm=" + $vmName)

        Get-VMNetworkAdapter -VM $vm | Remove-VMNetworkAdapter
        Set-VM -VM $vm -ProcessorCount $vcpu -StaticMemory -CheckpointType Disabled -AutomaticStartAction Nothing -AutomaticStopAction TurnOff
        Set-VMFirmware -VM $vm -EnableSecureBoot On
        Get-VMIntegrationService -VM $vm | Disable-VMIntegrationService
        Add-Phase "provision" "configured" "nic removed, static memory, checkpoints disabled, secure boot on, integration services disabled"

        # ---- 5. Read-back verification against the profile (never trust the setter) ----
        $vmR = Get-VM -Id $vm.Id
        $procR = Get-VMProcessor -VM $vmR
        $memR = Get-VMMemory -VM $vmR
        $nicCount = @(Get-VMNetworkAdapter -VM $vmR).Count
        $fwR = Get-VMFirmware -VM $vmR
        $svcEnabled = @(Get-VMIntegrationService -VM $vmR | Where-Object { $_.Enabled }).Count
        $vhdR = Get-VHD -Path $vhdPath

        $readback = [ordered]@{
          vcpu = [int]$procR.Count
          memory_startup_mb = [int64]($memR.Startup / 1MB)
          dynamic_memory = [bool]$memR.DynamicMemoryEnabled
          network_adapter_count = $nicCount
          secure_boot = [string]$fwR.SecureBoot
          generation = [int]$vmR.Generation
          integration_services_enabled = $svcEnabled
          disk_virtual_gb = [int64]($vhdR.Size / 1GB)
          checkpoint_type = [string]$vmR.CheckpointType
        }
        $configChecks = @(
          [ordered]@{ check = "vcpu_matches_profile";   ok = ($readback.vcpu -eq $vcpu) },
          [ordered]@{ check = "memory_matches_profile"; ok = ($readback.memory_startup_mb -eq $memMb) },
          [ordered]@{ check = "dynamic_memory_off";     ok = (-not $readback.dynamic_memory) },
          [ordered]@{ check = "no_network_adapters";    ok = ($readback.network_adapter_count -eq 0) },
          [ordered]@{ check = "secure_boot_on";         ok = ($readback.secure_boot -eq "On") },
          [ordered]@{ check = "generation_2_uefi";      ok = ($readback.generation -eq 2) },
          [ordered]@{ check = "no_integration_services"; ok = ($readback.integration_services_enabled -eq 0) },
          [ordered]@{ check = "disk_matches_profile";   ok = ($readback.disk_virtual_gb -eq $diskGb) },
          [ordered]@{ check = "checkpoints_disabled";   ok = ($readback.checkpoint_type -eq "Disabled") }
        )
        $failedChecks = @($configChecks | Where-Object { -not $_.ok } | ForEach-Object { $_.check })
        if($failedChecks.Count -gt 0){
          foreach($c in $failedChecks){ $reasons.Add("CONFIG_READBACK_MISMATCH:" + $c) }
          $status = "failed"
          Add-Phase "readback" "mismatch" ($failedChecks -join ",")
        }
        else {
          Add-Phase "readback" "verified" "all configuration checks match the profile"

          # ---- 6. Start (firmware-level only) and stop ----
          Start-VM -VM $vmR
          $deadline = (Get-Date).AddSeconds(30)
          while((Get-Date) -lt $deadline){
            if([string](Get-VM -Id $vm.Id).State -eq "Running"){ $bootEvidence.reached_running = $true; break }
            Start-Sleep -Milliseconds 500
          }
          Add-Phase "start" ($(if($bootEvidence.reached_running){ "running" } else { "timeout" })) "firmware-level boot; no guest image"
          if(-not $bootEvidence.reached_running){ $reasons.Add("VM_DID_NOT_REACH_RUNNING") }

          Stop-VM -VM (Get-VM -Id $vm.Id) -TurnOff -Force
          $deadline = (Get-Date).AddSeconds(30)
          while((Get-Date) -lt $deadline){
            if([string](Get-VM -Id $vm.Id).State -eq "Off"){ $bootEvidence.returned_to_off = $true; break }
            Start-Sleep -Milliseconds 500
          }
          Add-Phase "stop" ($(if($bootEvidence.returned_to_off){ "off" } else { "timeout" })) "turned off"
          if(-not $bootEvidence.returned_to_off){ $reasons.Add("VM_DID_NOT_RETURN_TO_OFF") }

          if($reasons.Count -eq 0){ $status = "completed" } else { $status = "failed" }
        }
      }
    }
  }
}
catch {
  $status = "failed"
  $reasons.Add("LIFECYCLE_EXCEPTION: " + $_.Exception.Message)
  Add-Phase "exception" "failed" $_.Exception.Message
}
finally {
  # ---- 7. Teardown: always, and only the VM this run created ----
  if($vmId){
    $teardown.attempted = $true
    try {
      $mine = Get-VM -Id $vmId -ErrorAction SilentlyContinue
      if($mine){
        if([string]$mine.State -ne "Off"){ Stop-VM -VM $mine -TurnOff -Force -ErrorAction SilentlyContinue }
        Remove-VM -VM (Get-VM -Id $vmId) -Force -ErrorAction Stop
      }
    } catch { $reasons.Add("TEARDOWN_VM_REMOVE_FAILED: " + $_.Exception.Message) }
    $teardown.vm_removed = (-not [bool](Get-VM -Id $vmId -ErrorAction SilentlyContinue))
  }
  if($workDir -and (Test-Path -LiteralPath $workDir)){
    try { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction Stop } catch { $reasons.Add("TEARDOWN_FILES_REMOVE_FAILED: " + $_.Exception.Message) }
    $teardown.files_removed = (-not (Test-Path -LiteralPath $workDir))
  }
  elseif($vmId){ $teardown.files_removed = $true }

  if($null -ne $switchesBefore){
    $switchesAfter = @(Get-VMSwitch -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name } | Sort-Object)
    $vmsAfter = @(Get-VM -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Id } | Sort-Object)
    $contamination.switches_unchanged = ((Compare-Object $switchesBefore $switchesAfter -SyncWindow 0) -eq $null)
    $contamination.other_vms_unchanged = ((Compare-Object $vmsBefore $vmsAfter -SyncWindow 0) -eq $null)
  }
  if($status -eq "completed"){
    if(-not $teardown.vm_removed -or -not $teardown.files_removed){ $status = "failed"; $reasons.Add("TEARDOWN_NOT_VERIFIED") }
    if(($contamination.switches_unchanged -ne $true) -or ($contamination.other_vms_unchanged -ne $true)){ $status = "failed"; $reasons.Add("HOST_CONTAMINATION_DETECTED") }
  }
}

$reportDir = Join-Path $RepoRoot ("reports\hyperv_lifecycle\" + $runId)
EnsureDir $reportDir
$outPath = Join-Path $reportDir ($runId + ".lifecycle.json")
$obj = [ordered]@{
  schema = "clarity.hyperv_lifecycle.v1"
  run_id = $runId
  created_at_utc = UtcNow
  assurance = "A1_HOST_OBSERVED"
  scope_note = "isolation shell only; no guest image, no guest measurement"
  status = $status
  reason_codes = @($reasons.ToArray())
  profile_path = $ProfilePath
  profile_id = if($validation){ [string]$validation.profile_id } else { $null }
  profile_hash = if($validation){ [string]$validation.profile_hash } else { $null }
  configuration_hash = if($validation){ [string]$validation.configuration_hash } else { $null }
  profile_decision = if($validation){ [string]$validation.decision } else { $null }
  host_probe = $probe
  vm_name = $vmName
  vm_id = $vmId
  readback = $readback
  config_checks = @($configChecks)
  boot = $bootEvidence
  teardown = $teardown
  host_contamination = $contamination
  phases = @($phases.ToArray())
}
WriteUtf8NoBomLf $outPath (($obj | ConvertTo-Json -Compress -Depth 8))
Write-Host ("HYPERV_LIFECYCLE_" + $status.ToUpperInvariant() + ": " + $outPath) -ForegroundColor Green
Write-Output ("HYPERV_LIFECYCLE_REPORT=" + $outPath)
Write-Output ("HYPERV_LIFECYCLE_STATUS=" + $status)
Write-Output "CLARITY_HYPERV_LIFECYCLE_OK"
