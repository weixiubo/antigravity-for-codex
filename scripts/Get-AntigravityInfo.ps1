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
    $resolvedWorkspace=(Resolve-Path -LiteralPath $Workspace).Path
    $seconds=ConvertTo-AgyTimeoutSeconds $Timeout
    $info['executable']=$executable
    $commands=[ordered]@{}
    if ($Action -in @('All','Doctor')) { $commands['version']=@('--version') }
    if ($Action -in @('All','Models')) { $commands['models']=@('models') }
    if ($Action -in @('All','Usage')) { $commands['usage']=@('-p','/usage','--print-timeout',"$([math]::Ceiling($seconds))s") }
    $errors=@()
    foreach ($entry in $commands.GetEnumerator()) {
        $processResult=Invoke-AgyProcess -FilePath $executable -ArgumentList (@($CliPrefixArguments) + @($entry.Value)) -Workspace $resolvedWorkspace -TimeoutSeconds ($seconds+5)
        $raw=$processResult.stdout -join "`n"
        if ($processResult.exit_code -ne 0 -or $processResult.timed_out -or $processResult.process_error) {
            $errors+=@{query=$entry.Key; exit_code=$processResult.exit_code; timed_out=$processResult.timed_out; error=$processResult.process_error; diagnostics=($processResult.stderr -join "`n")}
            $info['status']='ERROR'
        }
        switch ($entry.Key) {
            'version' { $info['version']=$raw.Trim() }
            'models' {
                $models=@(foreach ($line in $processResult.stdout) {
                    if ($line -match '^([A-Za-z0-9][A-Za-z0-9._:/-]*)\t+(.+)$') { @{id=$Matches[1];name=$Matches[2]} }
                })
                $info['models']=$models
                $info['models_raw']=$raw
                if ($models.Count -eq 0) { $info['status']='ERROR'; $errors+=@{query='models'; error='No model IDs parsed; inspect models_raw rather than guessing IDs.'} }
            }
            'usage' {
                $info['quota']=@(foreach ($line in $processResult.stdout) {
                    $columns=$line -split "`t"
                    if ($columns.Count -ge 4) { @{group=$columns[0];window=$columns[1];remaining=$columns[2];resets_at=$columns[3]} }
                })
                $info['usage_raw']=$raw
                if ($info['quota'].Count -eq 0) {
                    $info['status']='ERROR'
                    $errors+=@{query='usage'; error='No quota windows parsed; quota is unknown. Inspect usage_raw.'}
                }
            }
        }
    }
    $info['errors']=$errors
} catch { $info['status']='ERROR'; $info['error']=$_.Exception.Message }
$info | ConvertTo-Json -Depth 10
if ($info['status'] -ne 'SUCCESS') { exit 1 }
