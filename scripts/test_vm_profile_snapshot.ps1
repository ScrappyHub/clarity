param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $RepoRoot "scripts\lib\canon.ps1")

function Get-Report([object[]]$Output){
  $m=@($Output|%{$v=$_.ToString().Trim();if($v -like '*.vm_compatibility.json' -and(Test-Path -LiteralPath $v -PathType Leaf)){$v}})
  if($m.Count -eq 0){throw 'VM_COMPATIBILITY_REPORT_NOT_FOUND'}
  $m[$m.Count-1]
}

$root=Join-Path ([IO.Path]::GetTempPath()) ("clarity-vm-profile-test-"+[Guid]::NewGuid().ToString("N"))
$profilePath=Join-Path $RepoRoot "vm_profiles\protected_review_hyperv.v1.json"
$reports=New-Object System.Collections.Generic.List[string]
try {
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  $profile=Get-Content -Raw -LiteralPath $profilePath|ConvertFrom-Json
  $profileHash=Sha256HexTextNormalized (($profile|ConvertTo-Json -Compress -Depth 20))
  $configHash=Sha256HexTextNormalized (($profile.configuration|ConvertTo-Json -Compress -Depth 20))
  $snapshotPath=Join-Path $root 'review.snapshot.json'
  $snapshot=[ordered]@{
    schema='clarity.vm_snapshot.v1'
    snapshot_id='test-saved-checkpoint'
    profile_id=[string]$profile.profile_id
    profile_hash=$profileHash
    created_at_utc=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    checkpoint_type='hyperv_checkpoint'
    state='saved'
    available=$true
    verification_scope='manifest_only'
    guest_image_ref=[string]$profile.guest.image_ref
    configuration_hash=$configHash
    disk_hashes=@([ordered]@{disk_id='os';sha256=('0'*64)})
  }
  WriteUtf8NoBomLf $snapshotPath (($snapshot|ConvertTo-Json -Compress -Depth 10))
  $out=@(& (Join-Path $RepoRoot 'scripts\vm_profile_validate.ps1') -RepoRoot $RepoRoot -ProfilePath $profilePath -Adapter hyperv -SnapshotPath $snapshotPath -ReportRoot (Join-Path $root 'reports'))
  $reportPath=Get-Report $out;$reports.Add($reportPath)
  $report=Get-Content -Raw -LiteralPath $reportPath|ConvertFrom-Json
  if([string]$report.decision -ne 'deferred'){throw 'VALID_SNAPSHOT_MUST_BE_DEFERRED_ON_MANIFEST_ONLY'}
  if([string]$report.snapshot_status -ne 'manifest_verified'){throw 'SNAPSHOT_STATUS_NOT_RECORDED'}
  if(@($report.defer_codes) -notcontains 'SNAPSHOT_CONTENT_NOT_VERIFIED'){throw 'SNAPSHOT_DEFER_REASON_MISSING'}

  $snapshot.profile_hash='bad-profile-hash'
  WriteUtf8NoBomLf $snapshotPath (($snapshot|ConvertTo-Json -Compress -Depth 10))
  $out=@(& (Join-Path $RepoRoot 'scripts\vm_profile_validate.ps1') -RepoRoot $RepoRoot -ProfilePath $profilePath -Adapter hyperv -SnapshotPath $snapshotPath -ReportRoot (Join-Path $root 'reports'))
  $reportPath=Get-Report $out;$reports.Add($reportPath)
  $report=Get-Content -Raw -LiteralPath $reportPath|ConvertFrom-Json
  if([string]$report.decision -ne 'deny' -or @($report.deny_codes) -notcontains 'SNAPSHOT_PROFILE_HASH_MISMATCH'){throw 'SNAPSHOT_TAMPER_NOT_REJECTED'}

  $snapshot.profile_hash=$profileHash;$snapshot.state='running'
  WriteUtf8NoBomLf $snapshotPath (($snapshot|ConvertTo-Json -Compress -Depth 10))
  $out=@(& (Join-Path $RepoRoot 'scripts\vm_profile_validate.ps1') -RepoRoot $RepoRoot -ProfilePath $profilePath -Adapter hyperv -SnapshotPath $snapshotPath -ReportRoot (Join-Path $root 'reports'))
  $reportPath=Get-Report $out;$reports.Add($reportPath)
  $report=Get-Content -Raw -LiteralPath $reportPath|ConvertFrom-Json
  if([string]$report.decision -ne 'deny' -or @($report.deny_codes) -notcontains 'SNAPSHOT_STATE_NOT_ALLOWED'){throw 'RUNNING_SNAPSHOT_NOT_REJECTED'}

  $requiredProfilePath=Join-Path $root 'required-profile.json'
  $profile.snapshot_policy.mode='required'
  WriteUtf8NoBomLf $requiredProfilePath (($profile|ConvertTo-Json -Compress -Depth 20))
  $out=@(& (Join-Path $RepoRoot 'scripts\vm_profile_validate.ps1') -RepoRoot $RepoRoot -ProfilePath $requiredProfilePath -Adapter hyperv -ReportRoot (Join-Path $root 'reports'))
  $reportPath=Get-Report $out;$reports.Add($reportPath)
  $report=Get-Content -Raw -LiteralPath $reportPath|ConvertFrom-Json
  if([string]$report.decision -ne 'deny' -or @($report.deny_codes) -notcontains 'SNAPSHOT_REQUIRED'){throw 'REQUIRED_SNAPSHOT_NOT_ENFORCED'}
  Write-Host 'VM_PROFILE_SNAPSHOT_TEST_OK' -ForegroundColor Green
}
finally {
  foreach($p in $reports){if(Test-Path -LiteralPath $p -PathType Leaf){Remove-Item -LiteralPath $p -Force}}
  if(Test-Path -LiteralPath $root -PathType Container){Remove-Item -LiteralPath $root -Recurse -Force}
}
