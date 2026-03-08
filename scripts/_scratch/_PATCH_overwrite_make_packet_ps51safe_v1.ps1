param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function EnsureDir([string]$p){
  if ([string]::IsNullOrWhiteSpace($p)) { throw "ENSURE_DIR_EMPTY" }
  if (-not (Test-Path -LiteralPath $p -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }
}
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function NormalizeText([string]$t){
  if ($null -eq $t) { $t = "" }
  $t = $t.Replace("`r`n","`n").Replace("`r","`n")
  if (-not $t.EndsWith("`n")) { $t = $t + "`n" }
  return $t
}
function WriteUtf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if ($dir) { EnsureDir $dir }
  $enc = Utf8NoBom
  $t = NormalizeText $Text
  [IO.File]::WriteAllBytes($Path, $enc.GetBytes($t))
}
function ReadUtf8Text([string]$Path){ [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($Path)) }
function Sha256HexBytes([byte[]]$bytes){
  if ($null -eq $bytes) { $bytes = [byte[]]@() }
  $sha = [Security.Cryptography.SHA256]::Create()
  ($sha.ComputeHash([byte[]]$bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
}
function Sha256HexFile([string]$Path){ Sha256HexBytes ([IO.File]::ReadAllBytes($Path)) }
function Sha256HexTextNormalized([string]$text){
  $enc = Utf8NoBom
  $t = NormalizeText $text
  Sha256HexBytes ($enc.GetBytes($t))
}
function EscapeJson([string]$s){
  if ($null -eq $s) { return "" }
  $s = $s -replace "\\","\\\\"
  $s = $s -replace "`"","\\`""
  $s = $s -replace "`n","\\n"
  $s = $s -replace "`t","\\t"
  return $s
}
function ParseGateFile([string]$p){ [void][ScriptBlock]::Create((Get-Content -Raw -LiteralPath $p -Encoding UTF8)) }

$ScriptsDir = Join-Path $RepoRoot "scripts"
$mkPath = Join-Path $ScriptsDir "make_packet.ps1"
EnsureDir $ScriptsDir

$mk = @()
$mk += 'param(
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$Tenant,
  [Parameter(Mandatory=$true)][string]$Principal,
  [Parameter(Mandatory=$true)][string]$ProducerInstance,
  [Parameter(Mandatory=$true)][string]$EventType,
  [Parameter(Mandatory=$true)][string]$ContentRef,
  [Parameter(Mandatory=$true)][ValidateSet("evidence","deterministic")][string]$Strength
)'
$mk += 'Set-StrictMode -Version Latest'
$mk += '$ErrorActionPreference="Stop"'
$mk += '. "$PSScriptRoot\lib\canon.ps1"'
$mk += 'function UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }'
$mk += 'function ToJson([object]$o){ ($o | ConvertTo-Json -Compress) }'
$mk += 'function WriteJsonCanonical([string]$Path,[object]$o){ $j = ToJson $o; WriteUtf8NoBomLf $Path $j; return $j }'
$mk += 'function FileSha([string]$p){ Sha256HexFile $p }'

$mk += '$KeyBase  = Join-Path $RuntimeRoot "keys\clarity_dev_ed25519"'
$mk += '$Allowed  = Join-Path $RuntimeRoot "keys\allowed_signers"'
$mk += 'if(-not(Test-Path -LiteralPath $KeyBase -PathType Leaf)){ throw ("Missing key: " + $KeyBase) }'
$mk += 'if(-not(Test-Path -LiteralPath ($KeyBase + ".pub") -PathType Leaf)){ throw ("Missing pubkey: " + ($KeyBase + ".pub")) }'
$mk += 'if(-not(Test-Path -LiteralPath $Allowed -PathType Leaf)){ throw ("Missing allowed_signers: " + $Allowed) }'

$mk += '$outbox = Join-Path $RuntimeRoot "outbox"'
$mk += 'EnsureDir $outbox'
$mk += '$tmp = Join-Path $outbox ("tmp_" + [Guid]::NewGuid().ToString("N"))'
$mk += 'EnsureDir $tmp'
$mk += 'EnsureDir (Join-Path $tmp "payload")'
$mk += 'EnsureDir (Join-Path $tmp "signatures")'

$mk += '$eventTime = UtcNow'
$mk += '$createdAt = UtcNow'

$mk += '# 1) commitment'
$mk += '$commitObj = [ordered]@{'
$mk += '  schema="commitment.v1"'
$mk += '  producer="clarity"'
$mk += '  producer_instance=$ProducerInstance'
$mk += '  tenant=$Tenant'
$mk += '  principal=$Principal'
$mk += '  event_type=$EventType'
$mk += '  event_time_utc=$eventTime'
$mk += '  prev_links=@()'
$mk += '  content_ref=$ContentRef'
$mk += '  strength=$Strength'
$mk += '}'
$mk += '$commitPath = Join-Path $tmp "payload\commit.payload.json"'
$mk += '$commitJson = WriteJsonCanonical $commitPath $commitObj'
$mk += '$commitHash = Sha256HexTextNormalized $commitJson'
$mk += 'WriteUtf8NoBomLf (Join-Path $tmp "payload\commit_hash.txt") ($commitHash + "`n")'

$mk += '# 2) manifest WITHOUT packet_id (Option A)'
$mk += '$p1 = Join-Path $tmp "payload\commit.payload.json"'
$mk += '$p2 = Join-Path $tmp "payload\commit_hash.txt"'
$mk += '$fi1 = Get-Item -LiteralPath $p1'
$mk += '$fi2 = Get-Item -LiteralPath $p2'
$mk += '$h1 = FileSha $fi1.FullName'
$mk += '$h2 = FileSha $fi2.FullName'
$mk += '$filesArr = @(
$mk += ')'
$mk += '$manObj = [ordered]@{'
$mk += '  schema="packet_manifest.v1"'
$mk += '  producer="clarity"'
$mk += '  producer_instance=$ProducerInstance'
$mk += '  created_at_utc=$createdAt'
$mk += '  files=$filesArr'
$mk += '}'
$mk += '$manPath = Join-Path $tmp "manifest.json"'
$mk += '$manJson = WriteJsonCanonical $manPath $manObj'
$mk += '$packetId = Sha256HexTextNormalized $manJson'
$mk += 'WriteUtf8NoBomLf (Join-Path $tmp "packet_id.txt") ($packetId + "`n")'

$mk += '# 3) nfl.ingest.json AFTER packetId known (no -replace)'
$mk += '$ingObj = [ordered]@{'
$mk += '  schema="nfl.ingest.v1"'
$mk += '  packet_id=$packetId'
$mk += '  commit_hash=$commitHash'
$mk += '  producer="clarity"'
$mk += '  producer_instance=$ProducerInstance'
$mk += '  tenant=$Tenant'
$mk += '  principal=$Principal'
$mk += '  event_type=$EventType'
$mk += '  event_time_utc=$eventTime'
$mk += '  prev_links=@()'
$mk += '  payload_mode="pointer_only"'
$mk += '  payload_ref=$ContentRef'
$mk += '  producer_key_id="clarity-dev-ed25519"'
$mk += '  producer_sig_ref="signatures/ingest.sig"'
$mk += '}'
$mk += '$ingPath = Join-Path $tmp "payload\nfl.ingest.json"'
$mk += '$ingJson = WriteJsonCanonical $ingPath $ingObj'
$mk += '$ingHash = Sha256HexTextNormalized $ingJson'

$mk += '# 4) detached signature over msg = commit_hash + packet_id + ingest_hash'
$mk += '$msg = Join-Path $env:TEMP ("clarity_signmsg_" + [Guid]::NewGuid().ToString("N") + ".txt")'
$mk += 'WriteUtf8NoBomLf $msg (($commitHash + "`n" + $packetId + "`n" + $ingHash + "`n"))'
$mk += '$arg = "-Y sign -f `"" + $KeyBase + "`" -n nfl.ingest.v1 -I `"" + $Principal + "`" `"" + $msg + "`""'
$mk += '$sp = Start-Process -FilePath "ssh-keygen.exe" -ArgumentList $arg -Wait -PassThru -NoNewWindow'
$mk += 'if($sp.ExitCode -ne 0){ throw ("ssh-keygen sign failed exit_code=" + $sp.ExitCode) }'
$mk += '$sigFrom = $msg + ".sig"'
$mk += '$sigTo   = Join-Path $tmp "signatures\ingest.sig"'
$mk += 'Copy-Item -LiteralPath $sigFrom -Destination $sigTo -Force'
$mk += 'Remove-Item -LiteralPath $sigFrom -Force -ErrorAction SilentlyContinue'
$mk += 'Remove-Item -LiteralPath $msg -Force -ErrorAction SilentlyContinue'

$mk += '# 5) sha256sums LAST over final bytes'
$mk += '$files = @(Get-ChildItem -LiteralPath $tmp -Recurse -File | Where-Object { $_.Name -ne "sha256sums.txt" })'
$mk += '$rows = New-Object System.Collections.Generic.List[string]'
$mk += 'foreach($f in $files){'
$mk += '  $rel = $f.FullName.Substring($tmp.Length).TrimStart("\") -replace "\\","/"'
$mk += '  $h = Sha256HexFile $f.FullName'
$mk += '  [void]$rows.Add(("{0}  {1}" -f $h,$rel))'
$mk += '}'
$mk += '$sorted = @($rows.ToArray() | Sort-Object)'
$mk += 'WriteUtf8NoBomLf (Join-Path $tmp "sha256sums.txt") ((($sorted -join "`n") + "`n"))'

$mk += '# finalize folder name = PacketId'
$mk += '$final = Join-Path $outbox $packetId'
$mk += 'if(Test-Path -LiteralPath $final -PathType Container){ throw ("Packet already exists: " + $final) }'
$mk += 'Move-Item -LiteralPath $tmp -Destination $final -Force'
$mk += 'Write-Host ("PACKET_OK_OPTIONA: " + $final) -ForegroundColor Green'
$mk += 'Write-Output $final'

function WriteScript([string]$Path,[string[]]$Lines){
  $txt = (($Lines -join "`n") + "`n")
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllBytes($Path, $enc.GetBytes(($txt.Replace("`r`n","`n").Replace("`r","`n"))))
  ParseGateFile $Path
}

WriteScript $mkPath $mk
Write-Host ("PATCH_OK: overwrote " + $mkPath) -ForegroundColor Green
