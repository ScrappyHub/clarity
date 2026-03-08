param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

function WriteUtf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $t = $Text.Replace("`r`n","`n").Replace("`r","`n")
  if(-not $t.EndsWith("`n")){ $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllBytes($Path,$enc.GetBytes($t))
}
function ParseGateFile([string]$p){ [void][ScriptBlock]::Create((Get-Content -Raw -LiteralPath $p -Encoding UTF8)) }

$runner = Join-Path $RepoRoot "scripts\_scratch\_RUN_repair_clarity_standalone_optionA_v1.ps1"
if(-not (Test-Path -LiteralPath $runner -PathType Leaf)){ throw ("MISSING_RUNNER: " + $runner) }
$raw = Get-Content -Raw -LiteralPath $runner -Encoding UTF8

# Replace the entire contracts/event_types block in the bootstrap generator with a safe builder (no nested quotes).
$start = $raw.IndexOf('# contracts/event_types.v1.json')
if($start -lt 0){ throw "ANCHOR_MISSING: event_types header" }
$end = $raw.IndexOf('# Dev key + allowed_signers', $start)
if($end -lt 0){ throw "ANCHOR_MISSING: Dev key header" }

$before = $raw.Substring(0,$start)
$after  = $raw.Substring($end)

$mid = @()
$mid += '# contracts/event_types.v1.json (safe; no nested quotes)'
$mid += '$boot += '''
$mid += '$boot += "' + '$evLines = @()'
$mid += '$boot += "' + '$evLines += ' + '{' + '"'
$mid += '$boot += "' + '$evLines += (''  ""schema"": ""event_types.v1"",'')'
$mid += '$boot += "' + '$evLines += (''  ""producer"": ""clarity"",'')'
$mid += '$boot += "' + '$evLines += (''  ""types"": ['')'
$mid += '$boot += "' + '$evLines += (''    ""clarity.run.started.v1"",'')'
$mid += '$boot += "' + '$evLines += (''    ""clarity.verification.result.v1"",'')'
$mid += '$boot += "' + '$evLines += (''    ""clarity.run.completed.v1"",'')'
$mid += '$boot += "' + '$evLines += (''    ""clarity.library.object.added.v1"",'')'
$mid += '$boot += "' + '$evLines += (''    ""clarity.library.object.sealed.v1"",'')'
$mid += '$boot += "' + '$evLines += (''    ""clarity.nfl.packet.built.v1"",'')'
$mid += '$boot += "' + '$evLines += (''    ""clarity.nfl.packet.verified.v1"",'')'
$mid += '$boot += "' + '$evLines += (''    ""clarity.nfl.pledged.local.v1"",'')'
$mid += '$boot += "' + '$evLines += (''    ""clarity.nfl.duplicated.v1"",'')'
$mid += '$boot += "' + '$evLines += (''    ""clarity.nfl.duplicate.failed.v1""'')'
$mid += '$boot += "' + '$evLines += "  ]"'
$mid += '$boot += "' + '$evLines += "}"'
$mid += '$boot += "' + 'WriteUtf8Lf (Join-Path $RepoRoot ""contracts\event_types.v1.json"") (($evLines -join ""`n"") + ""`n"")'
$mid += '$boot += '''

$midText = (($mid -join "`n") + "`n")
$fixed = $before + $midText + $after
if($fixed -eq $raw){ throw "NO_CHANGE" }

$bak = $runner + ".bak_" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
[IO.File]::Copy($runner,$bak,$true)
WriteUtf8NoBomLf $runner $fixed
ParseGateFile $runner
Write-Host ("PATCH_OK: runner event_types block fixed. backup=" + $bak) -ForegroundColor Green
