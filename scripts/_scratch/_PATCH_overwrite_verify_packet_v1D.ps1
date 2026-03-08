param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

$vp = Join-Path (Join-Path $RepoRoot "scripts") "verify_packet.ps1"
$lib = Join-Path (Join-Path $RepoRoot "scripts") "lib\canon.ps1"
if(-not (Test-Path -LiteralPath $lib -PathType Leaf)){ throw ("Missing lib: " + $lib) }

function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $lf = $Text.Replace("`r`n","`n").Replace("`r","`n")
  if(-not $lf.EndsWith("`n")){ $lf += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllBytes($Path, $enc.GetBytes($lf))
}

function Parse-GatePs1([string]$Path){
  $tok=$null; $err=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err)
  $e=@(@($err))
  if($e -and $e.Count -gt 0){
    $msg = ($e | ForEach-Object { $_.ToString() }) -join "`n"
    throw ("PARSEGATE_FAIL: " + $Path + "`n" + $msg)
  }
}

$L = New-Object System.Collections.Generic.List[string]

# --- overwrite verify_packet.ps1 (v1D) ---
[void]$L.Add('param(')
[void]$L.Add('  [Parameter(Mandatory=$true)][string]$PacketRoot,')
[void]$L.Add('  [Parameter(Mandatory=$true)][string]$RuntimeRoot,')
[void]$L.Add('  [Parameter(Mandatory=$true)][string]$Principal')
[void]$L.Add(')')
[void]$L.Add('Set-StrictMode -Version Latest')
[void]$L.Add('$ErrorActionPreference="Stop"')
[void]$L.Add('. "$PSScriptRoot\lib\canon.ps1"')
[void]$L.Add('')
[void]$L.Add('Write-Host "CLARITY_VERIFY_SENTINEL_V1D" -ForegroundColor DarkGray')
[void]$L.Add('function STEP([string]$s){ Write-Host ("STEP: " + $s) -ForegroundColor DarkGray }')
[void]$L.Add('')
[void]$L.Add('function Invoke-SshKeygenTimeout([string[]]$Args,[int]$TimeoutMs){')
[void]$L.Add('  $psi = New-Object System.Diagnostics.ProcessStartInfo')
[void]$L.Add('  $psi.FileName = "ssh-keygen.exe"')
[void]$L.Add('  $psi.Arguments = ($Args -join " ")')
[void]$L.Add('  $psi.UseShellExecute = $false')
[void]$L.Add('  $psi.RedirectStandardOutput = $true')
[void]$L.Add('  $psi.RedirectStandardError  = $true')
[void]$L.Add('  $p = New-Object System.Diagnostics.Process')
[void]$L.Add('  $p.StartInfo = $psi')
[void]$L.Add('  [void]$p.Start()')
[void]$L.Add('  if(-not $p.WaitForExit($TimeoutMs)){ try{ $p.Kill() } catch {}; throw ("SSH_KEYGEN_TIMEOUT_MS=" + $TimeoutMs) }')
[void]$L.Add('  $stdout = $p.StandardOutput.ReadToEnd()')
[void]$L.Add('  $stderr = $p.StandardError.ReadToEnd()')
[void]$L.Add('  return [ordered]@{ exit=[int]$p.ExitCode; stdout=$stdout; stderr=$stderr }')
[void]$L.Add('}')
[void]$L.Add('')
[void]$L.Add('STEP "inputs"')
[void]$L.Add('if(-not (Test-Path -LiteralPath $PacketRoot -PathType Container)){ throw ("Missing PacketRoot: " + $PacketRoot) }')
[void]$L.Add('if(-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)){ throw ("Missing RuntimeRoot: " + $RuntimeRoot) }')
[void]$L.Add('')
[void]$L.Add('$Allowed = Join-Path $RuntimeRoot "keys\allowed_signers"')
[void]$L.Add('if(-not (Test-Path -LiteralPath $Allowed -PathType Leaf)){ throw ("Missing allowed_signers: " + $Allowed) }')
[void]$L.Add('')
[void]$L.Add('$leaf = Split-Path -Leaf $PacketRoot')
[void]$L.Add('if([string]::IsNullOrWhiteSpace($leaf)){ throw "EMPTY_PACKET_LEAF" }')
[void]$L.Add('')
[void]$L.Add('STEP "read:manifest"')
[void]$L.Add('$manPath = Join-Path $PacketRoot "manifest.json"')
[void]$L.Add('if(-not (Test-Path -LiteralPath $manPath -PathType Leaf)){ throw ("Missing manifest.json: " + $manPath) }')
[void]$L.Add('$manJson = (Get-Content -Raw -LiteralPath $manPath -Encoding UTF8)')
[void]$L.Add('$packetId = Sha256HexTextNormalized $manJson')
[void]$L.Add('if($packetId -ne $leaf){ throw ("PACKET_DIRNAME_MISMATCH dir=" + $leaf + " computed=" + $packetId) }')
[void]$L.Add('')
[void]$L.Add('STEP "read:packet_id.txt"')
[void]$L.Add('$pidPath = Join-Path $PacketRoot "packet_id.txt"')
[void]$L.Add('if(-not (Test-Path -LiteralPath $pidPath -PathType Leaf)){ throw ("Missing packet_id.txt: " + $pidPath) }')
[void]$L.Add('$pidTxt = (Get-Content -Raw -LiteralPath $pidPath -Encoding UTF8).Trim()')
[void]$L.Add('if($pidTxt -ne $packetId){ throw ("PACKET_ID_TXT_MISMATCH txt=" + $pidTxt + " computed=" + $packetId) }')
[void]$L.Add('')
[void]$L.Add('STEP "sha256sums"')
[void]$L.Add('$sumPath = Join-Path $PacketRoot "sha256sums.txt"')
[void]$L.Add('if(-not (Test-Path -LiteralPath $sumPath -PathType Leaf)){ throw ("Missing sha256sums.txt: " + $sumPath) }')
[void]$L.Add('$sumLines = @((Get-Content -LiteralPath $sumPath -Encoding UTF8) | ForEach-Object { $_.Trim() } | Where-Object { $_ })')
[void]$L.Add('foreach($line in $sumLines){')
[void]$L.Add('  # format: "<hex>␠␠<path>"')
[void]$L.Add('  $idx = $line.IndexOf("  ")')
[void]$L.Add('  if($idx -lt 0){ throw ("BAD_SHA256SUMS_LINE_NO_DOUBLESPACE: " + $line) }')
[void]$L.Add('  $hex = $line.Substring(0,$idx).Trim()')
[void]$L.Add('  $rel = $line.Substring($idx+2).Trim()')
[void]$L.Add('  if($rel -match "^\s*$"){ throw ("BAD_SHA256SUMS_EMPTY_PATH: " + $line) }')
[void]$L.Add('  $relFs = $rel.Replace("/","\")')
[void]$L.Add('  $abs = Join-Path $PacketRoot $relFs')
[void]$L.Add('  if(-not (Test-Path -LiteralPath $abs -PathType Leaf)){ throw ("SHA256SUMS_MISSING_FILE: " + $rel) }')
[void]$L.Add('  $h = Sha256HexFile $abs')
[void]$L.Add('  if($h -ne $hex){ throw ("SHA256SUM_MISMATCH file=" + $rel + " expected=" + $hex + " got=" + $h) }')
[void]$L.Add('}')
[void]$L.Add('')
[void]$L.Add('STEP "read:commit+ingest"')
[void]$L.Add('$commitHashPath = Join-Path $PacketRoot "payload\commit_hash.txt"')
[void]$L.Add('$ingPath = Join-Path $PacketRoot "payload\nfl.ingest.json"')
[void]$L.Add('if(-not (Test-Path -LiteralPath $commitHashPath -PathType Leaf)){ throw ("Missing commit_hash.txt: " + $commitHashPath) }')
[void]$L.Add('if(-not (Test-Path -LiteralPath $ingPath -PathType Leaf)){ throw ("Missing nfl.ingest.json: " + $ingPath) }')
[void]$L.Add('$commitHash = (Get-Content -Raw -LiteralPath $commitHashPath -Encoding UTF8).Trim()')
[void]$L.Add('$ingJson = (Get-Content -Raw -LiteralPath $ingPath -Encoding UTF8)')
[void]$L.Add('$ingHash = Sha256HexTextNormalized $ingJson')
[void]$L.Add('')
[void]$L.Add('STEP "sig:verify"')
[void]$L.Add('$sigPath = Join-Path $PacketRoot "signatures\ingest.sig"')
[void]$L.Add('if(-not (Test-Path -LiteralPath $sigPath -PathType Leaf)){ throw ("Missing signature: " + $sigPath) }')
[void]$L.Add('$msg = Join-Path $env:TEMP ("clarity_verifymsg_" + [Guid]::NewGuid().ToString("N") + ".txt")')
[void]$L.Add('WriteUtf8NoBomLf $msg ($commitHash + "`n" + $packetId + "`n" + $ingHash + "`n")')
[void]$L.Add('try{')
[void]$L.Add('  $args = @("-Y","verify","-f","`"" + $Allowed + "`"","-I","`"" + $Principal + "`"","-n","nfl.ingest.v1","-s","`"" + $sigPath + "`"","`"" + $msg + "`"")')
[void]$L.Add('  $res = Invoke-SshKeygenTimeout $args 15000')
[void]$L.Add('  if($res.exit -ne 0){ throw ("SSHKEYGEN_VERIFY_EXIT_NONZERO=" + $res.exit + "`nSTDOUT:`n" + $res.stdout + "`nSTDERR:`n" + $res.stderr) }')
[void]$L.Add('} finally {')
[void]$L.Add('  Remove-Item -LiteralPath $msg -Force -ErrorAction SilentlyContinue')
[void]$L.Add('}')
[void]$L.Add('')
[void]$L.Add('STEP "ok"')
[void]$L.Add('Write-Host ("VERIFY_OK_OPTIONA: " + $PacketRoot) -ForegroundColor Green')
# --- end file ---

$txt = ($L.ToArray() -join "`n") + "`n"
Write-Utf8NoBomLf $vp $txt
Parse-GatePs1 $vp
Write-Host ("PATCH_OK: overwrote " + $vp) -ForegroundColor Green
