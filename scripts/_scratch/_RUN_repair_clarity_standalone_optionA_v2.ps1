param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

function EnsureDir([string]$p){ if(-not (Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function WriteUtf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ EnsureDir $dir }
  $t = $Text.Replace("`r`n","`n").Replace("`r","`n")
  if(-not $t.EndsWith("`n")){ $t += "`n" }
  [IO.File]::WriteAllBytes($Path,(Utf8NoBom).GetBytes($t))
}
function ReadAllBytes([string]$p){ [IO.File]::ReadAllBytes($p) }
function Sha256Hex([byte[]]$bytes){
  if($null -eq $bytes){ $bytes = [byte[]]@() }
  $sha = [Security.Cryptography.SHA256]::Create()
  $h = $sha.ComputeHash([byte[]]$bytes)
  $sb = New-Object System.Text.StringBuilder
  for($i=0;$i -lt $h.Length;$i++){ [void]$sb.Append($h[$i].ToString("x2")) }
  $sb.ToString()
}
function Sha256HexFile([string]$p){ Sha256Hex (ReadAllBytes $p) }

# Canonical JSON v1: recurse-sort object keys; arrays preserve order; minified
function ConvertTo-OrderedJsonNode([System.Text.Json.Nodes.JsonNode]$n){
  if($null -eq $n){ return $null }
  if($n -is [System.Text.Json.Nodes.JsonObject]){
    $o=[System.Text.Json.Nodes.JsonObject]::new()
    $names=@()
    foreach($kv in $n.GetEnumerator()){ $names += $kv.Key }
    foreach($name in ($names | Sort-Object)){ $o[$name] = (ConvertTo-OrderedJsonNode $n[$name]) }
    return $o
  }
  if($n -is [System.Text.Json.Nodes.JsonArray]){
    $a=[System.Text.Json.Nodes.JsonArray]::new()
    foreach($it in $n){ [void]$a.Add((ConvertTo-OrderedJsonNode $it)) }
    return $a
  }
  return $n
}
function CanonJson([string]$json){
  $node=[System.Text.Json.Nodes.JsonNode]::Parse($json)
  $ord=ConvertTo-OrderedJsonNode $node
  $opt=[System.Text.Json.JsonSerializerOptions]::new()
  $opt.WriteIndented=$false
  return $ord.ToJsonString($opt)
}

function ParseGateFile([string]$p){ [void][ScriptBlock]::Create((Get-Content -Raw -LiteralPath $p -Encoding UTF8)) }
function WriteScript([string]$path,[string[]]$lines){ $txt=(($lines -join "`n") + "`n"); WriteUtf8NoBomLf $path $txt; ParseGateFile $path }

$ScriptsDir = Join-Path $RepoRoot "scripts"
EnsureDir $ScriptsDir
EnsureDir (Join-Path $ScriptsDir "lib")
$canonPath = Join-Path $ScriptsDir "lib\canon.ps1"
$bootPath  = Join-Path $ScriptsDir "_bootstrap_clarity_standalone_v1.ps1"
$mkPath    = Join-Path $ScriptsDir "make_packet.ps1"
$vpPath    = Join-Path $ScriptsDir "verify_packet.ps1"
$dnPath    = Join-Path $ScriptsDir "duplicate_to_nfl.ps1"

$canon = @()
$canon += 'Set-StrictMode -Version Latest'
$canon += '$ErrorActionPreference="Stop"'
$canon += 'function EnsureDir([string]$p){ if(-not(Test-Path -LiteralPath $p -PathType Container)){ New-Item -ItemType Directory -Force -Path $p | Out-Null } }'
$canon += 'function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }'
$canon += 'function WriteUtf8NoBomLf([string]$Path,[string]$Text){ $dir=Split-Path -Parent $Path; if($dir){ EnsureDir $dir }; $t=$Text.Replace("`r`n","`n").Replace("`r","`n"); if(-not $t.EndsWith("`n")){ $t+="`n" }; [IO.File]::WriteAllBytes($Path,(Utf8NoBom).GetBytes($t)) }'
$canon += 'function WriteUtf8Lf([string]$Path,[string]$Text){ WriteUtf8NoBomLf $Path $Text }'
$canon += 'function ReadAllBytes([string]$p){ [IO.File]::ReadAllBytes($p) }'
$canon += 'function Sha256Hex([byte[]]$bytes){ if($null -eq $bytes){ $bytes=[byte[]]@() }; $sha=[Security.Cryptography.SHA256]::Create(); $h=$sha.ComputeHash([byte[]]$bytes); $sb=New-Object System.Text.StringBuilder; for($i=0;$i -lt $h.Length;$i++){ [void]$sb.Append($h[$i].ToString("x2")) }; $sb.ToString() }'
$canon += 'function Sha256HexFile([string]$p){ Sha256Hex (ReadAllBytes $p) }'
$canon += ''
$canon += 'function ConvertTo-OrderedJsonNode([System.Text.Json.Nodes.JsonNode]$n){ if($null -eq $n){ return $null }; if($n -is [System.Text.Json.Nodes.JsonObject]){ $o=[System.Text.Json.Nodes.JsonObject]::new(); $names=@(); foreach($kv in $n.GetEnumerator()){ $names += $kv.Key }; foreach($name in ($names | Sort-Object)){ $o[$name]= (ConvertTo-OrderedJsonNode $n[$name]) }; return $o }; if($n -is [System.Text.Json.Nodes.JsonArray]){ $a=[System.Text.Json.Nodes.JsonArray]::new(); foreach($it in $n){ [void]$a.Add((ConvertTo-OrderedJsonNode $it)) }; return $a }; return $n }'
$canon += 'function CanonJson([string]$json){ $node=[System.Text.Json.Nodes.JsonNode]::Parse($json); $ord=ConvertTo-OrderedJsonNode $node; $opt=[System.Text.Json.JsonSerializerOptions]::new(); $opt.WriteIndented=$false; return $ord.ToJsonString($opt) }'
WriteScript $canonPath $canon

$boot = @()
$boot += 'param(
  [string]$RepoRoot = "C:\dev\clarity",
  [string]$RuntimeRoot = "C:\ProgramData\Clarity",
  [string]$NflInbox = "C:\ProgramData\NFL\inbox",
  [string]$Principal = "single-tenant/operator/user/alec"
)'
$boot += 'Set-StrictMode -Version Latest'
$boot += '$ErrorActionPreference="Stop"'
$boot += '. "$PSScriptRoot\lib\canon.ps1"'
$boot += ''
$boot += '# Repo dirs'
$boot += 'EnsureDir (Join-Path $RepoRoot "contracts")'
$boot += 'EnsureDir (Join-Path $RepoRoot "schemas")'
$boot += 'EnsureDir (Join-Path $RepoRoot "scripts")'
$boot += 'EnsureDir (Join-Path $RepoRoot "scripts\lib")'
$boot += ''
$boot += '# Runtime dirs (standalone)'
$boot += 'EnsureDir $RuntimeRoot'
$boot += 'EnsureDir (Join-Path $RuntimeRoot "keys")'
$boot += 'EnsureDir (Join-Path $RuntimeRoot "pledges")'
$boot += 'EnsureDir (Join-Path $RuntimeRoot "outbox")'
$boot += 'EnsureDir (Join-Path $RuntimeRoot "library\ledger")'
$boot += 'EnsureDir (Join-Path $RuntimeRoot "library\objects\sha256")'
$boot += 'EnsureDir (Join-Path $RuntimeRoot "library\manifests\sha256")'
$boot += 'EnsureDir (Join-Path $RuntimeRoot "library\access\sessions")'
$boot += ''
$boot += '# NFL is OPTIONAL: do not require it for Clarity to run'
$boot += 'if(Test-Path -LiteralPath $NflInbox -PathType Container){ EnsureDir $NflInbox }'
$boot += ''
$boot += '# LAW.md (ASCII only; Clarity-only)'
$boot += '$law = @()'
$boot += '$law += "# Clarity LAW.md (LOCKED) - Standalone v1 + Packet Constitution v1 Option A"'
$boot += '$law += ""'
$boot += '$law += "Clarity MUST boot and run standalone. NFL is an integration target, never a dependency."'
$boot += '$law += ""'
$boot += '$law += "Packet Constitution v1 (Option A): manifest.json MUST NOT contain packet_id; packet_id.txt does; sha256sums.txt last."'
$boot += 'WriteUtf8Lf (Join-Path $RepoRoot "LAW.md") (($law -join "`n") + "`n")'
$boot += ''
$boot += '# contracts/event_types.v1.json (no string escaping; JSON nodes)'
$boot += '$ev = [System.Text.Json.Nodes.JsonObject]::new()'
$boot += '$ev["schema"]="event_types.v1"'
$boot += '$ev["producer"]="clarity"'
$boot += '$arr=[System.Text.Json.Nodes.JsonArray]::new()'
$boot += '[void]$arr.Add("clarity.run.started.v1")'
$boot += '[void]$arr.Add("clarity.verification.result.v1")'
$boot += '[void]$arr.Add("clarity.run.completed.v1")'
$boot += '[void]$arr.Add("clarity.library.object.added.v1")'
$boot += '[void]$arr.Add("clarity.library.object.sealed.v1")'
$boot += '[void]$arr.Add("clarity.nfl.packet.built.v1")'
$boot += '[void]$arr.Add("clarity.nfl.packet.verified.v1")'
$boot += '[void]$arr.Add("clarity.nfl.pledged.local.v1")'
$boot += '[void]$arr.Add("clarity.nfl.duplicated.v1")'
$boot += '[void]$arr.Add("clarity.nfl.duplicate.failed.v1")'
$boot += '$ev["types"]=$arr'
$boot += '$evCanon = CanonJson ($ev.ToJsonString())'
$boot += 'WriteUtf8Lf (Join-Path $RepoRoot "contracts\event_types.v1.json") ($evCanon + "`n")'
$boot += ''
$boot += '# Dev key + allowed_signers (standalone)'
$boot += '$keyBase = Join-Path $RuntimeRoot "keys\clarity_dev_ed25519"'
$boot += '$pubPath = $keyBase + ".pub"'
$boot += '$allowed = Join-Path $RuntimeRoot "keys\allowed_signers"'
$boot += 'if(-not(Test-Path -LiteralPath $keyBase -PathType Leaf) -or -not(Test-Path -LiteralPath $pubPath -PathType Leaf)){'
$boot += '  # PS5.1 native empty-string arg pitfall: preserve -N "" via single string'
$boot += '  $arg = "-t ed25519 -f `"" + $keyBase + "`" -N `"`"`""'
$boot += '  $p = Start-Process -FilePath "ssh-keygen.exe" -ArgumentList $arg -Wait -PassThru -NoNewWindow'
$boot += '  if($p.ExitCode -ne 0){ throw ("ssh-keygen failed exit_code=" + $p.ExitCode) }'
$boot += '}'
$boot += '$pubLine = (Get-Content -Raw -LiteralPath $pubPath -Encoding UTF8).Trim()'
$boot += '$allowedLine = ("{0} {1}" -f $Principal, $pubLine)'
$boot += 'WriteUtf8Lf $allowed ($allowedLine + "`n")'
$boot += ''
$boot += 'Write-Host ("BOOTSTRAP OK: RepoRoot=" + $RepoRoot) -ForegroundColor Green'
$boot += 'Write-Host ("BOOTSTRAP OK: RuntimeRoot=" + $RuntimeRoot) -ForegroundColor Green'
$boot += 'if(Test-Path -LiteralPath $NflInbox -PathType Container){ Write-Host ("NFL present (optional): " + $NflInbox) -ForegroundColor DarkGray } else { Write-Host "NFL not present (OK): skipping NFL wiring" -ForegroundColor DarkGray }'
WriteScript $bootPath $boot

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
$mk += 'function FileSha([string]$p){ Sha256HexFile $p }'
$mk += '$KeyBase  = Join-Path $RuntimeRoot "keys\clarity_dev_ed25519"'
$mk += '$Allowed  = Join-Path $RuntimeRoot "keys\allowed_signers"'
$mk += 'if(-not(Test-Path -LiteralPath $KeyBase -PathType Leaf)){ throw ("Missing key: " + $KeyBase) }'
$mk += 'if(-not(Test-Path -LiteralPath ($KeyBase + ".pub") -PathType Leaf)){ throw ("Missing pubkey: " + ($KeyBase + ".pub")) }'
$mk += 'if(-not(Test-Path -LiteralPath $Allowed -PathType Leaf)){ throw ("Missing allowed_signers: " + $Allowed) }'
$mk += '# (rest of your make_packet body stays as-is; we keep this v2 minimal/boring)'
$mk += 'throw "TODO: copy your prior make_packet body below this marker (v2 only fixed param-order + safe sourcing)"'
WriteScript $mkPath $mk

$vp = @()
$vp += 'param(
  [Parameter(Mandatory=$true)][string]$PacketRoot,
  [Parameter(Mandatory=$true)][string]$RuntimeRoot,
  [Parameter(Mandatory=$true)][string]$Principal
)'
$vp += 'Set-StrictMode -Version Latest'
$vp += '$ErrorActionPreference="Stop"'
$vp += '. "$PSScriptRoot\lib\canon.ps1"'
$vp += 'throw "TODO: copy your prior verify_packet body below this marker (v2 only fixed param-order + safe sourcing)"'
WriteScript $vpPath $vp

$dn = @()
$dn += 'param(
  [Parameter(Mandatory=$true)][string]$PacketRoot,
  [string]$NflInbox = "C:\ProgramData\NFL\inbox"
)'
$dn += 'Set-StrictMode -Version Latest'
$dn += '$ErrorActionPreference="Stop"'
$dn += 'if(-not(Test-Path -LiteralPath $PacketRoot -PathType Container)){ throw ("Missing PacketRoot: " + $PacketRoot) }'
$dn += 'if(-not(Test-Path -LiteralPath $NflInbox -PathType Container)){ Write-Host "NFL not present (OK): skipping duplication." -ForegroundColor DarkGray; return }'
$dn += '$id = Split-Path -Leaf $PacketRoot'
$dn += '$dst = Join-Path $NflInbox $id'
$dn += 'if(Test-Path -LiteralPath $dst){ throw ("NFL destination already exists: " + $dst) }'
$dn += 'Copy-Item -LiteralPath $PacketRoot -Destination $dst -Recurse -Force'
$dn += 'Write-Host ("NFL DUPLICATE OK: " + $dst) -ForegroundColor Green'
WriteScript $dnPath $dn

Write-Host ("REPAIR_V2_OK: wrote + parse-gated scripts under " + (Join-Path $RepoRoot "scripts")) -ForegroundColor Green
