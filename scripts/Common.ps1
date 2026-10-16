#Requires -Version 7.4
Set-StrictMode -Version Latest

function Resolve-AgyExecutable {
    param([string]$CliPath)
    if ($CliPath) { return (Resolve-Path -LiteralPath $CliPath -ErrorAction Stop).Path }
    $candidate = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    $command = Get-Command agy -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    throw 'Official Antigravity CLI is missing. Install it from https://antigravity.google/docs/cli/install/.'
}

function ConvertTo-AgyTimeoutSeconds {
    param([string]$Timeout)
    if ($Timeout -notmatch '^(\d+(?:\.\d+)?)(s|m|h)$') { throw 'Timeout must be a positive duration such as 30s, 5m or 1h.' }
    $factor = @{s=1; m=60; h=3600}[$Matches[2]]
    $seconds = [double]::Parse($Matches[1], [cultureinfo]::InvariantCulture) * $factor
    if ($seconds -lt 0.1 -or $seconds -gt 86400) { throw 'Timeout must be between 0.1 seconds and 24 hours.' }
    return $seconds
}

function Invoke-AgyProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$Workspace,
        [AllowNull()][string]$InputLine,
        [double]$TimeoutSeconds = 300,
        [string]$RunDirectory,
        [string]$CancelFile
    )
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.WorkingDirectory = $Workspace
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardInputEncoding = $encoding
    $start.StandardOutputEncoding = $encoding
    $start.StandardErrorEncoding = $encoding
    foreach ($argument in $ArgumentList) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $stdout = [Collections.Generic.List[string]]::new()
    $stderr = [Collections.Generic.List[string]]::new()
    $outWriter = $null
    $errWriter = $null
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $started = $false
    $timedOut = $false
    $cancelled = $false
    $failure = $null
    $exitCode = $null
    try {
        if ($RunDirectory) {
            $outWriter = [IO.StreamWriter]::new((Join-Path $RunDirectory 'events.jsonl'), $false, $encoding)
            $errWriter = [IO.StreamWriter]::new((Join-Path $RunDirectory 'stderr.txt'), $false, $encoding)
            $outWriter.AutoFlush = $true
            $errWriter.AutoFlush = $true
        }
        $started = $process.Start()
        if ($RunDirectory) {
            @{pid=$process.Id; executable=$FilePath; started_at=[DateTimeOffset]::UtcNow.ToString('o')} |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RunDirectory 'process.json') -Encoding utf8
        }
        $outTask = $process.StandardOutput.ReadLineAsync()
        $errTask = $process.StandardError.ReadLineAsync()
        $inputTask = $null
        if ($null -ne $InputLine -and $InputLine.Length -gt 0) {
            $inputTask = $process.StandardInput.WriteLineAsync($InputLine)
        } else { $process.StandardInput.Close() }
        while ($true) {
            if ($inputTask -and $inputTask.IsCompleted) {
                try { [void]$inputTask.GetAwaiter().GetResult() } catch { $failure = $_.Exception.Message }
                $process.StandardInput.Close()
                $inputTask = $null
            }
            if ($outTask -and $outTask.IsCompleted) {
                $line = $outTask.GetAwaiter().GetResult()
                if ($null -eq $line) { $outTask = $null }
                else {
                    $stdout.Add($line)
                    if ($outWriter) { $outWriter.WriteLine($line) }
                    $outTask = $process.StandardOutput.ReadLineAsync()
                }
            }
            if ($errTask -and $errTask.IsCompleted) {
                $line = $errTask.GetAwaiter().GetResult()
                if ($null -eq $line) { $errTask = $null }
                else {
                    $stderr.Add($line)
                    if ($errWriter) { $errWriter.WriteLine($line) }
                    $errTask = $process.StandardError.ReadLineAsync()
                }
            }
            if ($process.HasExited -and -not $outTask -and -not $errTask) { break }
            if ($CancelFile -and (Test-Path -LiteralPath $CancelFile)) { $cancelled = $true; break }
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { $timedOut = $true; break }
            # Drain already available lines without adding one delay per event.
            if (($outTask -and $outTask.IsCompleted) -or ($errTask -and $errTask.IsCompleted)) { continue }
            [Threading.Thread]::Sleep(20)
        }
    } catch {
        $failure = $_.Exception.Message
    } finally {
        if ($started) {
            if (-not $process.HasExited) { $process.Kill($true) }
            $process.WaitForExit()
            $exitCode = $process.ExitCode
        }
        if ($outWriter) { $outWriter.Dispose() }
        if ($errWriter) { $errWriter.Dispose() }
        $process.Dispose()
        $timer.Stop()
    }
    return [pscustomobject]@{
        stdout=$stdout.ToArray(); stderr=$stderr.ToArray(); exit_code=$exitCode
        timed_out=$timedOut; cancelled=$cancelled; process_error=$failure
        elapsed_seconds=$timer.Elapsed.TotalSeconds
    }
}

function ConvertFrom-AgyRun {
    param([Parameter(Mandatory)]$ProcessResult, [Parameter(Mandatory)][string]$RequestedModel)
    $initial = @{}
    $terminal = $null
    $toolErrors = [Collections.Generic.List[object]]::new()
    $permissionDenied = $false
    $permissionPattern = '(?i)(soft[- ]denied|permission[_ ]denied|permission.{0,50}(denied|required)|tool.{0,80}(denied|requires approval)|approval.{0,50}(required|denied)|denied by policy)'
    foreach ($line in $ProcessResult.stdout) {
        try { $event = ConvertFrom-Json -InputObject $line -AsHashtable -ErrorAction Stop } catch { continue }
        if ($event -isnot [System.Collections.IDictionary]) { continue }
        if ($event['event'] -eq 'init' -and $event['init']) { $initial = $event['init'] }
        if ($event['event'] -eq 'result' -and $event['result']) { $terminal = $event['result'] }
        if ($event['event'] -eq 'step_update' -and $event['step_update']) {
            $tool = $event['step_update']['tool_info']
            if ($tool -and $tool['error']) {
                $toolErrors.Add(@{tool=$tool['name']; error=$tool['error']})
                if (($tool['error'] | ConvertTo-Json -Depth 10 -Compress) -match $permissionPattern) { $permissionDenied = $true }
            }
        }
    }
    $diagnostics = $ProcessResult.stderr -join "`n"
    if ($diagnostics -match $permissionPattern) { $permissionDenied = $true }
    $status = 'ERROR'
    $errorKind = $null
    $message = $null
    if ($ProcessResult.cancelled) { $status='CANCELLED'; $errorKind='cancelled'; $message='This run was cancelled.' }
    elseif ($ProcessResult.timed_out) { $status='TIMEOUT'; $errorKind='timeout'; $message='The run exceeded its wall-clock limit.' }
    elseif ($ProcessResult.process_error) { $errorKind='process'; $message=$ProcessResult.process_error }
    elseif (-not $terminal) { $errorKind='missing_result'; $message='CLI did not emit a terminal result event; inspect the logs.' }
    elseif ($initial['model'] -and $initial['model'] -ne $RequestedModel) { $errorKind='model_mismatch'; $message='CLI reported a different model from the requested model.' }
    elseif ($ProcessResult.exit_code -ne 0 -or $terminal['status'] -ne 'SUCCESS') {
        $errorKind='cli_error'
        $message = if ($terminal['error']) { [string]$terminal['error'] } else { 'CLI did not complete successfully.' }
        if ($terminal['status'] -in @('CANCELED','CANCELLED','INTERRUPTED')) { $status='CANCELLED'; $errorKind='cancelled' }
    }
    elseif ($permissionDenied) { $status='PARTIAL'; $errorKind='permission_denied'; $message='At least one tool action was denied; inspect the task outcome before continuing.' }
    else { $status='SUCCESS' }
    if ($status -ne 'SUCCESS' -and $status -ne 'PARTIAL') {
        $failureText = "$message`n$diagnostics"
        if ($failureText -match '(?i)authentication required|not authenticated|sign.?in required|login required') { $errorKind='authentication_required' }
        elseif ($failureText -match '(?i)quota|rate.?limit|resource.?exhausted|\b429\b') { $errorKind='quota_or_rate_limit' }
        elseif ($failureText -match '(?i)invalid model|model.{0,60}(not found|not recognized|unavailable)') { $errorKind='model_unavailable' }
    }
    return [ordered]@{
        status=$status; error_kind=$errorKind; error=$message
        requested_model=$RequestedModel; reported_model=$initial['model']
        model_verified=($initial['model'] -eq $RequestedModel)
        response=$(if ($terminal) { $terminal['response'] } else { $null })
        conversation_id=$(if ($terminal) { $terminal['conversation_id'] } else { $null })
        cli_status=$(if ($terminal) { $terminal['status'] } else { $null })
        exit_code=$ProcessResult.exit_code; elapsed_seconds=$ProcessResult.elapsed_seconds
        usage=$(if ($terminal) { $terminal['usage'] } else { $null })
        permission_denied=$permissionDenied; tool_errors=$toolErrors.ToArray()
    }
}
