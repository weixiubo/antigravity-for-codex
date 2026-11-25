#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('All','Doctor','Models','Usage')][string]$Action='All',
    [string]$Workspace=(Get-Location).Path,
    [string]$CliPath,
    [string]$Timeout='45s',
    [Parameter(DontShow)][string[]]$CliPrefixArguments=@()
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$info=[ordered]@{status='SUCCESS'; checked_at=[DateTimeOffset]::UtcNow.ToString('o')}
try {
    if (-not $IsWindows) { throw 'Run this skill on the Windows host where Antigravity is installed and logged in.' }
    $executable=Resolve-AgyExecutable $CliPath
    $resolvedWorkspace=Resolve-AgyWorkspace $Workspace
    $seconds=ConvertTo-AgyTimeoutSeconds $Timeout
    $info['executable']=$executable
    $commands=[ordered]@{}
    if ($Action -in @('All','Doctor')) { $commands['version']=@('--version') }
    if ($Action -in @('All','Models')) { $commands['models']=@('models') }
    if ($Action -in @('All','Usage')) { $commands['usage']=@('-p','/usage','--print-timeout',$Timeout.ToLowerInvariant()) }

    $errors=[Collections.Generic.List[object]]::new()
    foreach ($entry in $commands.GetEnumerator()) {
        $processResult=Invoke-AgyProcess -FilePath $executable -ArgumentList (@($CliPrefixArguments) + @($entry.Value)) -Workspace $resolvedWorkspace -TimeoutSeconds ($seconds+5)
        $raw=$processResult.stdout -join "`n"
        $querySucceeded=$processResult.exit_code -eq 0 -and -not $processResult.timed_out -and -not $processResult.process_error
        if (-not $querySucceeded) {
            $errors.Add(@{query=$entry.Key; exit_code=$processResult.exit_code; timed_out=$processResult.timed_out; error=$processResult.process_error; diagnostics=($processResult.stderr -join "`n")})
        }
        switch ($entry.Key) {
            'version' {
                $info['version']=if ($querySucceeded) { $raw.Trim() } else { '' }
                if ($querySucceeded -and -not $info['version']) {
                    $errors.Add(@{query='version'; error='CLI returned an empty version.'})
                }
            }
            'models' {
                $info['models']=@(
                    if ($querySucceeded) {
                        foreach ($line in $processResult.stdout) {
                            if ($line -match '^([A-Za-z0-9][A-Za-z0-9._:/-]*)\t+(\S[^\t]*)$') {
                                @{id=$Matches[1];name=$Matches[2].TrimEnd()}
                            }
                        }
                    }
                )
                $info['models_raw']=$raw
                if ($querySucceeded -and $info['models'].Count -eq 0) {
                    $errors.Add(@{query='models'; error='No model IDs parsed; inspect models_raw rather than guessing IDs.'})
                }
            }
            'usage' {
                $info['quota']=@(
                    if ($querySucceeded) {
                        foreach ($line in $processResult.stdout) {
                            $columns=$line -split "`t"
                            if ($columns.Count -ne 4 -or [string]::IsNullOrWhiteSpace($columns[0]) -or
                                [string]::IsNullOrWhiteSpace($columns[1]) -or $columns[2] -notmatch '^(?:[0-9]{1,2}|100)%$') { continue }
                            $reset=$columns[3].Trim()
                            $parsedReset=[DateTimeOffset]::MinValue
                            if ($reset -and -not [DateTimeOffset]::TryParse($reset, [cultureinfo]::InvariantCulture,
                                [Globalization.DateTimeStyles]::None, [ref]$parsedReset)) { continue }
                            @{group=$columns[0].Trim();window=$columns[1].Trim();remaining=$columns[2];resets_at=$reset}
                        }
                    }
                )
                $info['usage_raw']=$raw
                if ($querySucceeded -and $info['quota'].Count -eq 0) {
                    $errors.Add(@{query='usage'; error='No valid quota windows parsed; quota is unknown. Inspect usage_raw.'})
                }
            }
        }
    }
    $info['errors']=$errors.ToArray()
    if ($errors.Count) { $info['status']='ERROR' }
} catch {
    $info['status']='ERROR'
    $info['error_kind']=$(if ($_.Exception.Data['AgyErrorKind']) { $_.Exception.Data['AgyErrorKind'] } else { 'setup' })
    $info['error']=$_.Exception.Message
}
$info | ConvertTo-Json -Depth 10
if ($info['status'] -ne 'SUCCESS') { exit 1 }
