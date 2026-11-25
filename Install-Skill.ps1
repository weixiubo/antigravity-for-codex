#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param([string]$Destination, [switch]$Replace)
$ErrorActionPreference = 'Stop'

function Resolve-InstallParent {
    param([IO.DirectoryInfo]$Directory)
    if (-not $Directory.Parent) { return $Directory.FullName }
    $physicalParent = Resolve-InstallParent $Directory.Parent
    $candidate = [IO.DirectoryInfo]::new([IO.Path]::Combine($physicalParent, $Directory.Name))
    if ($candidate.Attributes -ne -1 -and ($candidate.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        $resolved = $candidate.ResolveLinkTarget($true)
        if ($resolved -isnot [IO.DirectoryInfo] -or -not $resolved.Exists) {
            throw "Cannot resolve the destination's parent directory: $($candidate.FullName)"
        }
        return $resolved.FullName
    }
    return $candidate.FullName
}

function Test-InstallTarget {
    param([string]$Target, [switch]$AllowReplace)
    $directory = [IO.DirectoryInfo]::new($Target)
    if ($directory.Attributes -ne -1 -and ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "The installation destination must be a real directory: $Target"
    }
    if ([IO.File]::Exists($Target)) { throw "The installation destination is a file: $Target" }
    if (-not $directory.Exists) { return $false }
    if (-not $AllowReplace) { throw 'The destination already exists. Use -Replace to back it up and update packaged files.' }

    $manifest = Join-Path $Target 'SKILL.md'
    if (-not [IO.File]::Exists($manifest) -or ([IO.File]::GetAttributes($manifest) -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The existing destination is not an antigravity-for-codex installation.'
    }
    $frontMatter = [regex]::Match([IO.File]::ReadAllText($manifest), '(?s)\A---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\z)')
    $names = [regex]::Matches($frontMatter.Groups[1].Value, '(?m)^name:[ \t]*([^\r\n]*)')
    if ($names.Count -ne 1) { throw 'The existing destination is not an antigravity-for-codex installation.' }
    $name = ($names[0].Groups[1].Value -replace '[ \t]+#.*$', '').Trim()
    if ($name -cnotin @('antigravity-for-codex', '"antigravity-for-codex"', "'antigravity-for-codex'")) {
        throw 'The existing destination is not an antigravity-for-codex installation.'
    }
    return $true
}

function Copy-InstallTree {
    param([IO.DirectoryInfo]$Source, [IO.DirectoryInfo]$Staged)
    [void][IO.Directory]::CreateDirectory($Staged.FullName)
    foreach ($item in $Source.EnumerateFileSystemInfos()) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Cannot back up a reparse point inside the installation: $($item.FullName)"
        }
        $targetItem = [IO.Path]::Combine($Staged.FullName, $item.Name)
        if ($item -is [IO.DirectoryInfo]) {
            Copy-InstallTree $item ([IO.DirectoryInfo]::new($targetItem))
            [IO.File]::SetAttributes($targetItem, $item.Attributes)
        } else {
            [IO.File]::Copy($item.FullName, $targetItem)
        }
    }
}

function Publish-InstallTree {
    param([string]$Staged, [string]$Target, [string]$Previous, [string]$Backup, [switch]$Existing)
    if ($Existing) { [IO.Directory]::Move($Target, $Previous) }
    try {
        [IO.Directory]::Move($Staged, $Target)
    } catch {
        $publishFailure = $_
        if ($Existing) {
            try { [IO.Directory]::Move($Previous, $Target) } catch {
                throw "Could not publish the installation or restore its previous directory. Recover the previous installation at '$Previous' or from '$Backup'. Publish error: $($publishFailure.Exception.Message) Restore error: $($_.Exception.Message)"
            }
        }
        throw $publishFailure
    }
}

if (-not $IsWindows) { throw 'This distribution supports Windows only.' }
if (-not $Destination) {
    $codexRoot = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $Destination = Join-Path $codexRoot 'skills\antigravity-for-codex'
}
$provider = $null
$drive = $null
$requested = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination, [ref]$provider, [ref]$drive)
if ($provider.Name -ne 'FileSystem') { throw 'The destination must be a filesystem path.' }
$requested = [IO.DirectoryInfo]::new([IO.Path]::TrimEndingDirectorySeparator($requested))
if ($requested.Name -ine 'antigravity-for-codex') { throw 'The destination directory must be named antigravity-for-codex.' }
$targetParent = Resolve-InstallParent $requested.Parent
$target = [IO.Path]::Combine($targetParent, $requested.Name)
$physicalSource = Resolve-InstallParent ([IO.DirectoryInfo]::new($PSScriptRoot))
if ($target -ieq $physicalSource -or $target.StartsWith("$physicalSource\", [StringComparison]::OrdinalIgnoreCase) -or
    $physicalSource.StartsWith("$target\", [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The installation and distribution directories must be separate.'
}

$files = @('SKILL.md','LICENSE','agents/openai.yaml','references/troubleshooting.md',
    'docs/script-reference.md','scripts/Common.ps1','scripts/Get-AntigravityInfo.ps1',
    'scripts/Invoke-Antigravity.ps1','scripts/WindowsProcess.cs')
foreach ($relative in $files) {
    if (-not [IO.File]::Exists((Join-Path $PSScriptRoot $relative))) { throw "Missing distribution file: $relative" }
}

if ($WhatIfPreference) { [void](Test-InstallTarget $target -AllowReplace:$Replace) }
if (-not $PSCmdlet.ShouldProcess($target, 'Install Antigravity Skill for Codex runtime files')) { return }
$targetHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($target.ToUpperInvariant())))
$mutex = [Threading.Mutex]::new($false, "Global\AntigravityForCodex.Install.$targetHash")
$locked = $false
$transaction = $null
$previous = $null
$published = $false
$backup = $null
$cleanupWarning = $null
try {
    try { $locked = $mutex.WaitOne([TimeSpan]::FromSeconds(30)) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw "Another installation is still updating '$target'." }
    $exists = Test-InstallTarget $target -AllowReplace:$Replace
    [void][IO.Directory]::CreateDirectory($targetParent)

    $transactionName = '.antigravity-for-codex-update-' + [guid]::NewGuid().ToString('N')
    $parentInfo = [IO.DirectoryInfo]::new($targetParent)
    # Keep the staged and previous copies outside the discoverable skills directory when feasible.
    $transactionParent = if ($parentInfo.Name -ieq 'skills' -and $parentInfo.Parent) { $parentInfo.Parent.FullName } else { $targetParent }
    try {
        $transaction = [IO.Directory]::CreateDirectory([IO.Path]::Combine($transactionParent, $transactionName)).FullName
    } catch [UnauthorizedAccessException] {
        $transactionParent = $targetParent
        $transaction = [IO.Directory]::CreateDirectory([IO.Path]::Combine($transactionParent, $transactionName)).FullName
    }
    $staged = Join-Path $transaction 'antigravity-for-codex'
    $previous = Join-Path $transaction 'previous'
    if ($exists) {
        Copy-InstallTree ([IO.DirectoryInfo]::new($target)) ([IO.DirectoryInfo]::new($staged))
        $backup = "$target.backup-$([DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N')).zip"
        $stagedArchive = Join-Path $transaction 'backup.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($staged, $stagedArchive, [IO.Compression.CompressionLevel]::Optimal, $true)
        [IO.File]::Move($stagedArchive, $backup)
    }
    foreach ($relative in $files) {
        $source = Join-Path $PSScriptRoot $relative
        $destinationFile = Join-Path $staged $relative
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destinationFile))
        [IO.File]::Copy($source, $destinationFile, $true)
        if ((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $destinationFile).Hash) {
            throw "Staged file verification failed: $relative"
        }
    }
    Publish-InstallTree -Staged $staged -Target $target -Previous $previous -Backup $backup -Existing:$exists
    $published = $true
} finally {
    if ($transaction -and ($published -or -not [IO.Directory]::Exists($previous))) {
        $directory = [IO.DirectoryInfo]::new($transaction)
        if ($directory.Parent.FullName -ieq $transactionParent -and $directory.Name -ceq $transactionName -and
            -not ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            try { [IO.Directory]::Delete($directory.FullName, $true) } catch {
                $cleanupWarning = "Could not remove staging directory '$transaction': $($_.Exception.Message)"
                [Console]::Error.WriteLine($cleanupWarning)
            }
        }
    }
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
$result = [ordered]@{status='SUCCESS'; destination=$target; backup=$backup; files=$files; agents_md_modified=$false}
if ($cleanupWarning) { $result['cleanup_warning'] = $cleanupWarning }
$result | ConvertTo-Json -Depth 4
