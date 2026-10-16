#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param([string]$Destination, [switch]$Replace)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This distribution supports Windows only.' }
if (-not $Destination) {
    $codexRoot = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $Destination = Join-Path $codexRoot 'skills\antigravity-helper'
}
$target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
if ((Split-Path -Leaf $target) -ne 'antigravity-helper') { throw 'The destination directory must be named antigravity-helper.' }
if ($target.TrimEnd('\','/') -eq $PSScriptRoot.TrimEnd('\','/')) { throw 'The source and destination must be different directories.' }
$files = @('SKILL.md','LICENSE','agents/openai.yaml','references/troubleshooting.md',
    'docs/script-reference.md','scripts/Common.ps1','scripts/Get-AntigravityInfo.ps1','scripts/Invoke-Antigravity.ps1')
foreach ($relative in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $relative) -PathType Leaf)) { throw "Missing distribution file: $relative" }
}
$exists = Test-Path -LiteralPath $target
if ($exists) {
    if (-not $Replace) { throw 'The destination already exists. Use -Replace to back it up and update packaged files.' }
    $manifest = Join-Path $target 'SKILL.md'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf) -or
        (Get-Content -LiteralPath $manifest -Raw) -notmatch '(?m)^name:\s*antigravity-helper\s*$') {
        throw 'The existing destination is not an antigravity-helper installation.'
    }
}
if (-not $PSCmdlet.ShouldProcess($target, 'Install Antigravity Helper runtime files')) { return }
$backup = $null
if ($exists) {
    $backup = "$target.backup-$([DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N')).zip"
    Compress-Archive -LiteralPath $target -DestinationPath $backup
}
New-Item -ItemType Directory -Force -Path $target | Out-Null
foreach ($relative in $files) {
    $source = Join-Path $PSScriptRoot $relative
    $destinationFile = Join-Path $target $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationFile) | Out-Null
    Copy-Item -LiteralPath $source -Destination $destinationFile -Force
    if ((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $destinationFile).Hash) {
        throw "Installed file verification failed: $relative"
    }
}
[ordered]@{status='SUCCESS'; destination=$target; backup=$backup; files=$files; agents_md_modified=$false} | ConvertTo-Json -Depth 4
