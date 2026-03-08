param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function EnsureDir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ throw "ENSURE_DIR_EMPTY" }
  if(-not (Test-Path -LiteralPath $p -PathType Container)){
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }
}
function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)){
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $t = $Text.Replace("`r`n","`n").Replace("`r","`n")
  if(-not $t.EndsWith("`n")){ $t = $t + "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllBytes($Path,$enc.GetBytes($t))
}
function Parse-GatePs1([string]$Path){
  $tok=$null
  $err=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err)
  $errs=@(@($err))
  if($errs -and $errs.Count -gt 0){
    $msg = ($errs | ForEach-Object { $_.ToString() }) -join "`n"
    throw ("PARSEGATE_FAIL: " + $Path + "`n" + $msg)
  }
}

$ScriptsDir = Join-Path $RepoRoot "scripts"
EnsureDir $ScriptsDir
$mkPath = Join-Path $ScriptsDir "make_packet.ps1"

$M = New-Object System.Collections.Generic.List[string]

[void]$M.Add("param(")
[void]$M.Add("  [Parameter(Mandatory=`$true)][string]`$RuntimeRoot,")
[void]$M.Add("  [Parameter(Mandatory=`$true)][string]`$Tenant,")
[void]$M.Add("  [Parameter(Mandatory=`$true)][string]`$Principal,")
[void]$M.Add("  [Parameter(Mandatory=`$true)][string]`$ProducerInstance,")
[void]$M.Add("  [Parameter(Mandatory=`$true)][string]`$EventType,")
[void]$M.Add("  [Parameter(Mandatory=`$true)][string]`$ContentRef,")
[void]$M.Add("  [Parameter(Mandatory=`$true)][ValidateSet(`"evidence`",`"deterministic`")][string]`$Strength")
[void]$M.Add(")")
[void]$M.Add("Set-StrictMode -Version Latest")
[void]$M.Add("`$ErrorActionPreference = `"Stop`"")
[void]$M.Add(". `"`$PSScriptRoot\lib\canon.ps1`"")
[void]$M.Add("function UtcNow(){ (Get-Date).ToUniversalTime().ToString(`"yyyy-MM-ddTHH:mm:ssZ`") }")
[void]$M.Add("")
[void]$M.Add("`$KeyBase = Join-Path `$RuntimeRoot `"keys\clarity_dev_ed25519`"")
[void]$M.Add("`$Allowed = Join-Path `$RuntimeRoot `"keys\allowed_signers`"")
[void]$M.Add("if(-not (Test-Path -LiteralPath `$KeyBase -PathType Leaf)){ throw (`"Missing key: `"+`$KeyBase) }")
[void]$M.Add("if(-not (Test-Path -LiteralPath (`$KeyBase + `.pub`) -PathType Leaf)){ throw (`"Missing pubkey: `"+(`$KeyBase + `.pub`)) }")
[void]$M.Add("if(-not (Test-Path -LiteralPath `$Allowed -PathType Leaf)){ throw (`"Missing allowed_signers: `"+`$Allowed) }")
[void]$M.Add("")
[void]$M.Add("`$outbox = Join-Path `$RuntimeRoot `"outbox`"")
[void]$M.Add("EnsureDir `$outbox")
[void]$M.Add("`$tmp = Join-Path `$outbox (`"tmp_`" + [Guid]::NewGuid().ToString(`"N`"))")
[void]$M.Add("EnsureDir `$tmp")
[void]$M.Add("EnsureDir (Join-Path `$tmp `"payload`")")
[void]$M.Add("EnsureDir (Join-Path `$tmp `"signatures`")")
[void]$M.Add("")
[void]$M.Add("`$eventTime = UtcNow")
[void]$M.Add("`$createdAt = UtcNow")
[void]$M.Add("")
[void]$M.Add("`$commitObj = [ordered]@{")
[void]$M.Add("  schema=`"commitment.v1`"")
[void]$M.Add("  producer=`"clarity`"")
[void]$M.Add("  producer_instance=`$ProducerInstance")
[void]$M.Add("  tenant=`$Tenant")
[void]$M.Add("  principal=`$Principal")
[void]$M.Add("  event_type=`$EventType")
[void]$M.Add("  event_time_utc=`$eventTime")
[void]$M.Add("  prev_links=@()")
[void]$M.Add("  content_ref=`$ContentRef")
[void]$M.Add("  strength=`$Strength")
[void]$M.Add("}")
[void]$M.Add("`$commitPath = Join-Path `$tmp `"payload\commit.payload.json`"")
[void]$M.Add("`$commitJson = (`$commitObj | ConvertTo-Json -Compress)")
[void]$M.Add("Write-Utf8NoBomLf `$commitPath `$commitJson")
[void]$M.Add("`$commitHash = Sha256HexTextNormalized `$commitJson")
[void]$M.Add("Write-Utf8NoBomLf (Join-Path `$tmp `"payload\commit_hash.txt`") (`$commitHash + ``n)")
[void]$M.Add("")
[void]$M.Add("`$p1 = Join-Path `$tmp `"payload\commit.payload.json`"")
[void]$M.Add("`$p2 = Join-Path `$tmp `"payload\commit_hash.txt`"")
[void]$M.Add("`$fi1 = Get-Item -LiteralPath `$p1")
[void]$M.Add("`$fi2 = Get-Item -LiteralPath `$p2")
[void]$M.Add("`$h1 = Sha256HexFile `$fi1.FullName")
[void]$M.Add("`$h2 = Sha256HexFile `$fi2.FullName")
[void]$M.Add("`$filesArr = @(")
[void]$M.Add("  [ordered]@{ path=`"payload/commit.payload.json`"; bytes=[int]`$fi1.Length; sha256=`$h1 },")
[void]$M.Add("  [ordered]@{ path=`"payload/commit_hash.txt`"; bytes=[int]`$fi2.Length; sha256=`$h2 }")
[void]$M.Add(")")
[void]$M.Add("`$manObj = [ordered]@{")
[void]$M.Add("  schema=`"packet_manifest.v1`"")
[void]$M.Add("  producer=`"clarity`"")
[void]$M.Add("  producer_instance=`$ProducerInstance")
[void]$M.Add("  created_at_utc=`$createdAt")
[void]$M.Add("  files=`$filesArr")
[void]$M.Add("}")
[void]$M.Add("`$manJson = (`$manObj | ConvertTo-Json -Compress)")
[void]$M.Add("Write-Utf8NoBomLf (Join-Path `$tmp `"manifest.json`") `$manJson")
[void]$M.Add("`$packetId = Sha256HexTextNormalized `$manJson")
[void]$M.Add("Write-Utf8NoBomLf (Join-Path `$tmp `"packet_id.txt`") (`$packetId + ``n)")
[void]$M.Add("")
[void]$M.Add("`$ingObj = [ordered]@{")
[void]$M.Add("  schema=`"nfl.ingest.v1`"")
[void]$M.Add("  packet_id=`$packetId")
[void]$M.Add("  commit_hash=`$commitHash")
[void]$M.Add("  producer=`"clarity`"")
[void]$M.Add("  producer_instance=`$ProducerInstance")
[void]$M.Add("  tenant=`$Tenant")
[void]$M.Add("  principal=`$Principal")
[void]$M.Add("  event_type=`$EventType")
[void]$M.Add("  event_time_utc=`$eventTime")
[void]$M.Add("  prev_links=@()")
[void]$M.Add("  payload_mode=`"pointer_only`"")
[void]$M.Add("  payload_ref=`$ContentRef")
[void]$M.Add("  producer_key_id=`"clarity-dev-ed25519`"")
[void]$M.Add("  producer_sig_ref=`"signatures/ingest.sig`"")
[void]$M.Add("}")
[void]$M.Add("`$ingJson = (`$ingObj | ConvertTo-Json -Compress)")
[void]$M.Add("Write-Utf8NoBomLf (Join-Path `$tmp `"payload\nfl.ingest.json`") `$ingJson")
[void]$M.Add("`$ingHash = Sha256HexTextNormalized `$ingJson")
[void]$M.Add("")
[void]$M.Add("`$msg = Join-Path `$env:TEMP (`"clarity_signmsg_`" + [Guid]::NewGuid().ToString(`"N`") + `".txt`")")
[void]$M.Add("Write-Utf8NoBomLf `$msg ((`$commitHash + ``n + `$packetId + ``n + `$ingHash + ``n))")
[void]$M.Add("`$arg = (`"-Y sign -f `"`"`$KeyBase`"`" -n nfl.ingest.v1 -I `"`"`$Principal`"`" `"`"`$msg`"`"`")")
[void]$M.Add("`$sp = Start-Process -FilePath `"ssh-keygen.exe`" -ArgumentList `$arg -Wait -PassThru -NoNewWindow")
[void]$M.Add("if(`$sp.ExitCode -ne 0){ throw (`"ssh-keygen sign failed exit_code=`" + `$sp.ExitCode) }")
[void]$M.Add("Copy-Item -LiteralPath (`$msg + `".sig`") -Destination (Join-Path `$tmp `"signatures\ingest.sig`") -Force")
[void]$M.Add("Remove-Item -LiteralPath (`$msg + `".sig`") -Force -ErrorAction SilentlyContinue")
[void]$M.Add("Remove-Item -LiteralPath `$msg -Force -ErrorAction SilentlyContinue")
[void]$M.Add("")
[void]$M.Add("`$files = @(Get-ChildItem -LiteralPath `$tmp -Recurse -File | Where-Object { `$_.Name -ne `"sha256sums.txt`" })")
[void]$M.Add("`$rows = New-Object System.Collections.Generic.List[string]")
[void]$M.Add("foreach(`$f in `$files){")
[void]$M.Add("  `$rel = `$f.FullName.Substring(`$tmp.Length).TrimStart(`"\\`")")
[void]$M.Add("  `$rel = `$rel -replace `"\\`",`"/`"")
[void]$M.Add("  `$h = Sha256HexFile `$f.FullName")
[void]$M.Add("  [void]`$rows.Add((`"{0}  {1}`" -f `$h,`$rel))")
[void]$M.Add("}")
[void]$M.Add("`$sorted = @(`$rows.ToArray() | Sort-Object)")
[void]$M.Add("Write-Utf8NoBomLf (Join-Path `$tmp `"sha256sums.txt`") ((`$sorted -join ``n) + ``n)")
[void]$M.Add("")
[void]$M.Add("`$final = Join-Path `$outbox `$packetId")
[void]$M.Add("if(Test-Path -LiteralPath `$final -PathType Container){ throw (`"Packet already exists: `"+`$final) }")
[void]$M.Add("Move-Item -LiteralPath `$tmp -Destination `$final -Force")
[void]$M.Add("Write-Host (`"PACKET_OK_OPTIONA: `" + `$final) -ForegroundColor Green")
[void]$M.Add("Write-Output `$final")

$mkText = ($M.ToArray() -join "`n") + "`n"
Write-Utf8NoBomLf $mkPath $mkText
Parse-GatePs1 $mkPath
Write-Host ("PATCH_OK: overwrote " + $mkPath) -ForegroundColor Green
