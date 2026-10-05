param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$false)][switch]$MountEspForHash,
  [Parameter(Mandatory=$false)][string]$BaselinePath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\canon.ps1"

function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }

if(-not (Test-Path -LiteralPath $RepoRoot -PathType Container)){ throw ("MISSING_REPO_ROOT: " + $RepoRoot) }

$runId = [Guid]::NewGuid().ToString("N")
$errors = New-Object System.Collections.Generic.List[string]

function Add-DiscoveryError([string]$Code){ if(-not $errors.Contains($Code)){ $errors.Add($Code) } }

# ---- Firmware type (read-only; no elevation required) ----
# Primary: the Windows-provided firmware_type environment variable.
# Fallback: the PEFirmwareType registry value (often absent on installed systems).
$firmwareType = "unknown"
$firmwareTypeSource = $null
$fwEnv = [string]$env:firmware_type
if($fwEnv){
  if($fwEnv -ieq "UEFI"){ $firmwareType = "UEFI"; $firmwareTypeSource = "env:firmware_type" }
  elseif(($fwEnv -ieq "Legacy") -or ($fwEnv -ieq "BIOS")){ $firmwareType = "Legacy_BIOS"; $firmwareTypeSource = "env:firmware_type" }
}
if($firmwareType -eq "unknown"){
  try {
    $fwRaw = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "PEFirmwareType" -ErrorAction Stop).PEFirmwareType
    if([int]$fwRaw -eq 1){ $firmwareType = "Legacy_BIOS"; $firmwareTypeSource = "registry:PEFirmwareType" }
    elseif([int]$fwRaw -eq 2){ $firmwareType = "UEFI"; $firmwareTypeSource = "registry:PEFirmwareType" }
  } catch {}
}
if($firmwareType -eq "unknown"){ Add-DiscoveryError "FIRMWARE_TYPE_UNAVAILABLE" }

# ---- Secure Boot state (read-only) ----
# Confirm-SecureBootUEFI needs elevation on most hosts, and a failure there is
# NOT the same as "unsupported". Only a genuine platform-not-supported
# exception is reported as unsupported; otherwise fall back to the registry
# value Windows publishes (readable without elevation), else stay unknown.
$secureBootState = "unknown"
$secureBootSource = $null
try {
  if(Get-Command Confirm-SecureBootUEFI -ErrorAction SilentlyContinue){
    $sb = Confirm-SecureBootUEFI -ErrorAction Stop
    $secureBootState = if([bool]$sb){ "enabled" } else { "disabled" }
    $secureBootSource = "Confirm-SecureBootUEFI"
  }
} catch {
  $sbMsg = [string]$_.Exception.Message
  if(($_.Exception -is [System.PlatformNotSupportedException]) -or ($sbMsg -match "(?i)not supported")){
    $secureBootState = "unsupported"
    $secureBootSource = "Confirm-SecureBootUEFI"
  }
}
if($secureBootState -eq "unknown"){
  try {
    $sbReg = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State" -Name "UEFISecureBootEnabled" -ErrorAction Stop
    $secureBootState = if([int]$sbReg.UEFISecureBootEnabled -eq 1){ "enabled" } else { "disabled" }
    $secureBootSource = "registry:UEFISecureBootEnabled"
  } catch {}
}
if($secureBootState -eq "unknown"){ Add-DiscoveryError "SECURE_BOOT_STATE_UNAVAILABLE" }

# ---- BCD discovery (read-only; bcdedit /enum REQUIRES elevation on this
# class of host -- an unelevated call fails with "Access is denied") ----
function Get-BcdValue([object[]]$Lines,[string]$Key){
  foreach($l in $Lines){
    $s = [string]$l
    if($s -match ('(?im)^\s*' + [regex]::Escape($Key) + '\s+(.+?)\s*$')){ return $Matches[1] }
  }
  return $null
}

function Invoke-BcdEnum([string]$Id){
  $res = [pscustomobject]@{ Ok = $false; Lines = @(); AccessDenied = $false }
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $lines = @(& bcdedit.exe /enum $Id 2>&1 | ForEach-Object { [string]$_ })
    $res.Lines = $lines
    if($LASTEXITCODE -eq 0){ $res.Ok = $true }
    elseif((($lines -join "`n") -match "(?i)access is denied|could not be opened")){ $res.AccessDenied = $true }
  } catch {}
  finally { $ErrorActionPreference = $prevEap }
  return $res
}

$bootmgrPath = $null; $bootmgrDevice = $null
$bm = Invoke-BcdEnum "{bootmgr}"
if($bm.Ok){
  $bootmgrPath = Get-BcdValue $bm.Lines "path"
  $bootmgrDevice = Get-BcdValue $bm.Lines "device"
  if(-not $bootmgrPath){ Add-DiscoveryError "BCDEDIT_BOOTMGR_PATH_NOT_PARSED" }
}
elseif($bm.AccessDenied){ Add-DiscoveryError "BCDEDIT_REQUIRES_ELEVATION" }
else { Add-DiscoveryError "BCDEDIT_BOOTMGR_ENUM_FAILED" }

$currentPath = $null; $currentDevice = $null
$cur = Invoke-BcdEnum "{current}"
if($cur.Ok){
  $currentPath = Get-BcdValue $cur.Lines "path"
  $currentDevice = Get-BcdValue $cur.Lines "device"
}
elseif($cur.AccessDenied){ Add-DiscoveryError "BCDEDIT_REQUIRES_ELEVATION" }
else { Add-DiscoveryError "BCDEDIT_CURRENT_ENUM_FAILED" }

# ---- ESP enumeration (read-only; Get-Partition) ----
$espCount = 0
try {
  $ESP_GPT_TYPE = "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
  $espParts = @(Get-Partition -ErrorAction Stop | Where-Object { $_.GptType -eq $ESP_GPT_TYPE })
  $espCount = $espParts.Count
} catch { $errors.Add("ESP_ENUMERATION_FAILED") }

# ---- Optional: mount the ESP read-only, hash the resolved boot-manager
# file, optionally verify it against a baseline via the already-proven
# validator_handoff_target.ps1 (Step 8) -- then unmount. Off by default:
# this is the only step that touches boot-partition access paths, and it
# requires elevation. It never writes to the ESP, and the mount point is
# always removed, even on failure.
$espMountAttempted = $false
$espMountSucceeded = $false
$bootFileFullPath = $null
$bootFileSha256 = $null
$handoffVerdict = $null
$handoffReportPath = $null
$espMountMethod = $null

if($MountEspForHash){
  $espMountAttempted = $true
  $isElevated = $false
  try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { $isElevated = $false }

  if(-not $isElevated){
    $errors.Add("MOUNT_REQUIRES_ELEVATION")
  }
  elseif($espCount -ne 1){
    $errors.Add("MOUNT_SKIPPED_AMBIGUOUS_ESP_COUNT")
  }
  elseif(-not $bootmgrPath){
    $errors.Add("MOUNT_SKIPPED_NO_BOOTMGR_PATH")
  }
  else {
    $mountPoint = Join-Path $env:TEMP ("clarity_esp_mount_" + $runId)
    New-Item -ItemType Directory -Force -Path $mountPoint | Out-Null
    $mounted = $false
    $mountVia = $null        # "access_path" | "drive_letter"
    $mountLetter = $null
    $mountFailures = New-Object System.Collections.Generic.List[string]
    try {
      # Method 1: add the ESP as an access path in a fresh empty folder
      # (Storage module). Removed in finally.
      try {
        $espPart = $espParts[0]
        Add-PartitionAccessPath -DiskNumber $espPart.DiskNumber -PartitionNumber $espPart.PartitionNumber `
          -AccessPath $mountPoint -ErrorAction Stop
        $mounted = $true; $mountVia = "access_path"
      } catch { $mountFailures.Add("ACCESS_PATH: " + $_.Exception.Message) }

      # Method 2 (fallback): mountvol <free drive letter>: /S
      if(-not $mounted){
        $used = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.ToUpper() })
        $free = @([char[]]"STUVWXYZ" | Where-Object { $used -notcontains [string]$_ })
        if($free.Count -gt 0){
          $mountLetter = [string]$free[0]
          $prevEapMv = $ErrorActionPreference; $ErrorActionPreference = "Continue"
          try { $mvOut = & mountvol.exe ($mountLetter + ":") /S 2>&1 | ForEach-Object { "$_" }; $mvCode = $LASTEXITCODE }
          finally { $ErrorActionPreference = $prevEapMv }
          if($mvCode -eq 0){ $mounted = $true; $mountVia = "drive_letter" }
          else { $mountFailures.Add("MOUNTVOL: " + ($mvOut -join " ")); $mountLetter = $null }
        } else { $mountFailures.Add("MOUNTVOL: no free drive letter") }
      }
      if(-not $mounted){ throw ("ESP_MOUNT_FAILED [" + ($mountFailures -join " | ") + "]") }
      $espMountSucceeded = $true
      $espMountMethod = $mountVia
      $mountRoot = if($mountVia -eq "drive_letter"){ $mountLetter + ":\" } else { $mountPoint }

      $candidate = Join-Path $mountRoot ($bootmgrPath.TrimStart('\'))
      if(Test-Path -LiteralPath $candidate -PathType Leaf){
        $bootFileFullPath = (Resolve-Path -LiteralPath $candidate).ProviderPath
        $bootFileSha256 = Sha256HexFile $bootFileFullPath

        if($BaselinePath){
          $htOut = @(& (Join-Path $RepoRoot "scripts\validator_handoff_target.ps1") `
            -RepoRoot $RepoRoot -TargetPath $bootFileFullPath -BaselinePath $BaselinePath)
          $reportLine = @($htOut | Where-Object { $_ -like "HANDOFF_TARGET_REPORT=*" })
          $verdictLine = @($htOut | Where-Object { $_ -like "HANDOFF_TARGET_VERDICT=*" })
          if($reportLine.Count -gt 0){ $handoffReportPath = $reportLine[0].Substring("HANDOFF_TARGET_REPORT=".Length) }
          if($verdictLine.Count -gt 0){ $handoffVerdict = $verdictLine[0].Substring("HANDOFF_TARGET_VERDICT=".Length) }
        }
      } else {
        $errors.Add("BOOTMGR_FILE_NOT_FOUND_ON_MOUNTED_ESP")
      }
    }
    catch {
      $errors.Add("ESP_MOUNT_OR_HASH_FAILED: " + $_.Exception.Message)
    }
    finally {
      if($mounted){
        try {
          if($mountVia -eq "access_path"){
            Remove-PartitionAccessPath -DiskNumber $espPart.DiskNumber -PartitionNumber $espPart.PartitionNumber `
              -AccessPath $mountPoint -ErrorAction Stop
          } else {
            $prevEapMv = $ErrorActionPreference; $ErrorActionPreference = "Continue"
            try { & mountvol.exe ($mountLetter + ":") /D 2>&1 | Out-Null; $mvCode = $LASTEXITCODE }
            finally { $ErrorActionPreference = $prevEapMv }
            if($mvCode -ne 0){ throw "mountvol /D failed" }
          }
          $mounted = $false
        } catch { $errors.Add("ESP_UNMOUNT_FAILED: " + $_.Exception.Message) }
      }
      # Never recurse into the mount folder: if the ESP is still attached,
      # leave the folder alone rather than risk touching boot-partition data.
      # Non-recursive delete only succeeds on an empty (unmounted) folder.
      if(-not $mounted){
        try { if(Test-Path -LiteralPath $mountPoint -PathType Container){ [System.IO.Directory]::Delete($mountPoint, $false) } } catch {}
      }
    }
  }
}

$discoveryComplete = ($errors.Count -eq 0)

$reportDir = Join-Path $RepoRoot ("reports\validator_boot_discovery\" + $runId)
EnsureDir $reportDir
$outPath = Join-Path $reportDir ($runId + ".boot_discovery.json")
$obj = [ordered]@{
  schema = "clarity.boot_target_discovery.v1"
  run_id = $runId
  created_at_utc = UtcNow
  firmware_type = $firmwareType
  firmware_type_source = $firmwareTypeSource
  secure_boot_state = $secureBootState
  secure_boot_source = $secureBootSource
  bootmgr_path = $bootmgrPath
  bootmgr_device = $bootmgrDevice
  current_loader_path = $currentPath
  current_loader_device = $currentDevice
  esp_partition_count = $espCount
  esp_mount_attempted = $espMountAttempted
  esp_mount_succeeded = $espMountSucceeded
  esp_mount_method = $espMountMethod
  boot_file_full_path = $bootFileFullPath
  boot_file_sha256 = $bootFileSha256
  handoff_target_verdict = $handoffVerdict
  handoff_target_report_path = $handoffReportPath
  discovery_complete = $discoveryComplete
  discovery_errors = @($errors.ToArray())
}
WriteUtf8NoBomLf $outPath (($obj | ConvertTo-Json -Compress -Depth 6))
Write-Host ("VALIDATOR_BOOT_DISCOVERY_OK: " + $outPath) -ForegroundColor Green
Write-Output ("BOOT_DISCOVERY_REPORT=" + $outPath)
Write-Output "CLARITY_BOOT_DISCOVERY_OK"
