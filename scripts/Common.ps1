#Requires -Version 7.4
Set-StrictMode -Version Latest

function Throw-AgySetupError {
    param([string]$Kind, [string]$Message)
    $exception = [ArgumentException]::new($Message)
    $exception.Data['AgyErrorKind'] = $Kind
    throw $exception
}

function Resolve-AgyExecutable {
    param([string]$CliPath)
    if ($CliPath) {
        $item = Get-Item -LiteralPath $CliPath -Force -ErrorAction SilentlyContinue
        if ($item -isnot [IO.FileInfo] -or $item.Extension -ine '.exe') {
            Throw-AgySetupError 'invalid_cli_path' "CLI path must name an existing Windows executable: $CliPath"
        }
        return $item.FullName
    }
    $candidate = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    $command = Get-Command agy.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) { return $command.Source }
    Throw-AgySetupError 'cli_missing' "Official Antigravity CLI was not found at '$candidate' or on PATH. Install it from https://antigravity.google/docs/getting-started?tab=cli."
}

function Resolve-AgyWorkspace {
    param([string]$Workspace)
    $item = Get-Item -LiteralPath $Workspace -Force -ErrorAction SilentlyContinue
    if ($item -isnot [IO.DirectoryInfo]) {
        Throw-AgySetupError 'invalid_workspace' "Workspace must name an existing filesystem directory: $Workspace"
    }
    return $item.FullName
}

function ConvertTo-AgyTimeoutSeconds {
    param([string]$Timeout)
    if ($Timeout -notmatch '^([0-9]+(?:\.[0-9]+)?)(s|m|h)$') { throw 'Timeout must be a positive duration such as 30s, 5m or 1h.' }
    $factor = @{s=1; m=60; h=3600}[$Matches[2]]
    $seconds = [double]::Parse($Matches[1], [cultureinfo]::InvariantCulture) * $factor
    if ($seconds -lt 0.1 -or $seconds -gt 86400) { throw 'Timeout must be between 0.1 seconds and 24 hours.' }
    return $seconds
}

function Import-AgyWindowsProcess {
    if (-not ('AntigravityForCodex.WindowsProcess' -as [type])) {
        Add-Type -LiteralPath (Join-Path $PSScriptRoot 'WindowsProcess.cs')
    }
}

function Write-AgyJsonFile {
    param([string]$Path, $Value)
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = ConvertTo-Json -InputObject $Value -Depth 20
        [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        try { [IO.File]::Move($temporary, $Path, $true) } catch {
            if (-not [IO.File]::Exists($Path)) { throw }
            Import-AgyWindowsProcess
            [AntigravityForCodex.WindowsProcess]::ReplaceOpenFile($temporary, $Path)
        }
    } finally {
        [IO.File]::Delete($temporary)
    }
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
    $encoding = [Text.UTF8Encoding]::new($false)
    $output = @(
        @{name='events.jsonl'; lines=[Collections.Generic.List[string]]::new(); task=$null; writer=$null; reader=$null}
        @{name='stderr.txt'; lines=[Collections.Generic.List[string]]::new(); task=$null; writer=$null; reader=$null}
    )
    $logErrors = [Collections.Generic.List[string]]::new()
    $process = $null
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $stopRequestedAt = $null
    $timedOut = $false
    $cancelled = $false
    $failure = $null
    $exitCode = $null
    try {
        if ($RunDirectory) {
            foreach ($stream in $output) {
                try {
                    $stream.writer = [IO.StreamWriter]::new((Join-Path $RunDirectory $stream.name), $false, $encoding)
                    $stream.writer.AutoFlush = $true
                } catch {
                    $logErrors.Add("$($stream.name): $($_.Exception.Message)")
                }
            }
        }
        Import-AgyWindowsProcess
        $process = [AntigravityForCodex.WindowsProcess]::Start($FilePath, $ArgumentList, $Workspace)
        if ($RunDirectory) {
            try {
                Write-AgyJsonFile (Join-Path $RunDirectory 'process.json') @{
                    pid=$process.Id; executable=$FilePath; started_at=[DateTimeOffset]::UtcNow.ToString('o')
                }
            } catch {
                $logErrors.Add("process.json: $($_.Exception.Message)")
            }
        }
        $output[0].reader = $process.StandardOutput
        $output[1].reader = $process.StandardError
        foreach ($stream in $output) { $stream.task = $stream.reader.ReadLineAsync() }
        $inputTask = $process.SendInputAsync($InputLine)

        while ($true) {
            if ($inputTask -and $inputTask.IsCompleted) {
                try { $inputTask.GetAwaiter().GetResult() | Out-Null } catch {
                    if ($null -eq $stopRequestedAt) { $failure = $_.Exception.Message }
                }
                $inputTask = $null
            }
            foreach ($stream in $output) {
                if (-not $stream.task -or -not $stream.task.IsCompleted) { continue }
                $line = $stream.task.GetAwaiter().GetResult()
                $stream.task = $null
                if ($null -eq $line) { continue }
                $stream.lines.Add($line)
                if ($stream.writer) {
                    try { $stream.writer.WriteLine($line) } catch {
                        $logErrors.Add("$($stream.name): $($_.Exception.Message)")
                        try { $stream.writer.Dispose() } catch { }
                        $stream.writer = $null
                    }
                }
                $stream.task = $stream.reader.ReadLineAsync()
            }

            if ($process.HasExited -and -not $output[0].task -and -not $output[1].task) { break }
            if ($null -eq $stopRequestedAt) {
                $cancelled = [bool]($CancelFile -and (Test-Path -LiteralPath $CancelFile -PathType Leaf))
                $timedOut = -not $cancelled -and $timer.Elapsed.TotalSeconds -ge $TimeoutSeconds
                if ($cancelled -or $timedOut) {
                    $process.StopTree()
                    $stopRequestedAt = $timer.Elapsed.TotalSeconds
                }
            } elseif ($timer.Elapsed.TotalSeconds -ge $stopRequestedAt + 2) {
                break
            }

            # Drain buffered output without adding one delay per event.
            if (($output[0].task -and $output[0].task.IsCompleted) -or
                ($output[1].task -and $output[1].task.IsCompleted)) { continue }
            [Threading.Thread]::Sleep(20)
        }
    } catch {
        $failure = $_.Exception.Message
    } finally {
        if ($process) {
            try {
                $process.StopTree()
                if ($process.WaitForExit(2000)) { $exitCode = $process.ExitCode }
                elseif (-not $failure) { $failure = 'The CLI did not exit after its job was closed.' }
            } catch {
                if (-not $failure) { $failure = $_.Exception.Message }
            } finally {
                try { $process.Dispose() } catch {
                    if (-not $failure) { $failure = $_.Exception.Message }
                }
            }
        }
        foreach ($stream in $output) {
            if ($stream.writer) {
                try { $stream.writer.Dispose() } catch { $logErrors.Add("$($stream.name): $($_.Exception.Message)") }
            }
        }
        $timer.Stop()
    }
    return [pscustomobject]@{
        stdout=$output[0].lines.ToArray(); stderr=$output[1].lines.ToArray(); exit_code=$exitCode
        timed_out=$timedOut; cancelled=$cancelled; process_error=$failure; log_errors=$logErrors.ToArray()
        elapsed_seconds=$timer.Elapsed.TotalSeconds
    }
}

function Get-AgyErrorMessage {
    param($ErrorValue)
    if ($ErrorValue -is [string]) { return $ErrorValue }
    if ($ErrorValue -is [System.Collections.IDictionary] -and $ErrorValue['message'] -is [string]) {
        return $ErrorValue['message']
    }
}

function Get-AgyFailureKind {
    param($ErrorValue)
    if ($ErrorValue -is [System.Collections.IDictionary]) {
        foreach ($code in @($ErrorValue['type'], $ErrorValue['code'], $ErrorValue['status'])) {
            switch ($code) {
                { $_ -in @('UNAUTHENTICATED', 'AUTHENTICATION_REQUIRED', '401') } { return 'authentication_required' }
                { $_ -in @('RESOURCE_EXHAUSTED', 'RATE_LIMITED', 'QUOTA_EXCEEDED', '429') } { return 'quota_or_rate_limit' }
                { $_ -in @('MODEL_NOT_FOUND', 'MODEL_UNAVAILABLE', 'INVALID_MODEL') } { return 'model_unavailable' }
                { $_ -in @('TIMEOUT', 'DEADLINE_EXCEEDED') } { return 'timeout' }
            }
        }
    }
    $message = Get-AgyErrorMessage $ErrorValue
    switch -Regex ($message) {
        '^\s*(?:(?:error|fatal):\s*)?(?:authentication required|not authenticated|sign[ -]?in required|login required|UNAUTHENTICATED)\b' { return 'authentication_required' }
        '^\s*(?:(?:error|fatal):\s*)?(?:RESOURCE_EXHAUSTED|quota exceeded|rate limit exceeded|too many requests|HTTP 429)\b' { return 'quota_or_rate_limit' }
        '^\s*(?:(?:error|fatal):\s*)?(?:invalid (?:requested )?model|unknown model|model\b.{0,80}\b(?:not found|not recognized|unavailable))\b' { return 'model_unavailable' }
        '^\s*(?:(?:error|fatal):\s*)?(?:DEADLINE_EXCEEDED|context deadline exceeded|turn timed out|print timeout exceeded)\b' { return 'timeout' }
    }
}

function Test-AgyPermissionDenial {
    param($ErrorValue)
    if ($ErrorValue -is [System.Collections.IDictionary] -and (
        $ErrorValue['type'] -in @('PERMISSION_DENIED', 'APPROVAL_REQUIRED', 'SOFT_DENIED') -or
        $ErrorValue['code'] -in @('PERMISSION_DENIED', 'APPROVAL_REQUIRED', 'SOFT_DENIED')
    )) { return $true }
    $message = Get-AgyErrorMessage $ErrorValue
    return $message -match '^\s*(?:(?:error|warning):\s*)?(?:tool execution denied by policy\b|permission denied\b|soft[- ]denied\b|approval required\s*\.?\s*$)'
}

function ConvertFrom-AgyRun {
    param([Parameter(Mandatory)]$ProcessResult, [Parameter(Mandatory)][string]$RequestedModel, [string]$RequestedConversation)
    $reportedModel = $null
    $conversation = $RequestedConversation
    $conversationMismatch = $false
    $terminal = $null
    $initSeen = $false
    $resultSeen = $false
    $protocolError = $null
    $toolErrors = [Collections.Generic.List[object]]::new()
    $permissionDenied = $false
    foreach ($line in $ProcessResult.stdout) {
        try { $event = ConvertFrom-Json -InputObject $line -AsHashtable -ErrorAction Stop } catch { continue }
        if ($event -isnot [System.Collections.IDictionary]) { continue }

        $eventName = $event['event']
        if ($eventName -cin @('init', 'result')) {
            $payload = $event[$eventName]
            if ($payload -isnot [System.Collections.IDictionary]) {
                $protocolError = "CLI emitted a malformed $eventName event."
                continue
            }
            foreach ($candidate in @($event['conversation_id'], $payload['conversation_id'])) {
                if ($null -eq $candidate -or ($candidate -is [string] -and $candidate.Length -eq 0)) { continue }
                if ($candidate -isnot [string] -or [string]::IsNullOrWhiteSpace($candidate)) {
                    $protocolError = "CLI emitted an invalid conversation ID in $eventName."
                } elseif ($conversation -and $conversation -cne $candidate) {
                    $conversationMismatch = $true
                } else {
                    $conversation = $candidate
                }
            }
            if ($eventName -ceq 'init') {
                if ($initSeen) {
                    $protocolError = 'CLI emitted more than one init event.'
                } elseif ($null -ne $payload['model'] -and $payload['model'] -isnot [string]) {
                    $protocolError = 'CLI emitted an invalid model in the init event.'
                } else {
                    $reportedModel = $payload['model']
                }
                $initSeen = $true
            } else {
                if ($resultSeen) {
                    $protocolError = 'CLI emitted more than one terminal result for one request.'
                } elseif ($payload['status'] -isnot [string] -or [string]::IsNullOrWhiteSpace($payload['status'])) {
                    $protocolError = 'CLI terminal result is missing a valid status.'
                } elseif ($payload['status'] -ceq 'SUCCESS' -and $payload['response'] -isnot [string]) {
                    $protocolError = 'CLI reported success without a text response.'
                } else {
                    $terminal = $payload
                }
                $resultSeen = $true
            }
        } elseif ($eventName -ceq 'step_update' -and $event['step_update'] -is [System.Collections.IDictionary]) {
            $tool = $event['step_update']['tool_info']
            if ($tool -is [System.Collections.IDictionary] -and $tool['error']) {
                $toolErrors.Add(@{tool=$tool['name']; error=$tool['error']})
                if (Test-AgyPermissionDenial $tool['error']) { $permissionDenied = $true }
            }
        }
    }
    foreach ($line in $ProcessResult.stderr) {
        if (Test-AgyPermissionDenial $line) { $permissionDenied = $true }
    }

    $status = 'ERROR'
    $errorKind = $null
    $message = $null
    if ($ProcessResult.cancelled) { $status='CANCELLED'; $errorKind='cancelled'; $message='This run was cancelled.' }
    elseif ($ProcessResult.timed_out) { $status='TIMEOUT'; $errorKind='timeout'; $message='The run exceeded its wall-clock limit.' }
    elseif ($conversationMismatch) { $errorKind='conversation_mismatch'; $message='CLI reported conflicting conversation IDs.' }
    elseif ($reportedModel -and $reportedModel -cne $RequestedModel) { $errorKind='model_mismatch'; $message='CLI reported a different model from the requested model.' }
    elseif ($protocolError) { $errorKind='protocol_error'; $message=$protocolError }
    elseif ($ProcessResult.process_error -and ($null -eq $ProcessResult.exit_code -or ($terminal -and $terminal['status'] -ceq 'SUCCESS'))) {
        $errorKind='process'; $message=$ProcessResult.process_error
    }
    elseif (-not $terminal -or $ProcessResult.exit_code -ne 0 -or $terminal['status'] -cne 'SUCCESS') {
        if ($terminal -and $terminal['status'] -cin @('CANCELED','CANCELLED','INTERRUPTED')) {
            $status='CANCELLED'; $errorKind='cancelled'; $message='The CLI cancelled this run.'
        } elseif ($terminal -and $terminal['status'] -ceq 'TIMEOUT') {
            $status='TIMEOUT'; $errorKind='timeout'; $message='The CLI timed out this run.'
        } else {
            $errorKind = if ($terminal) { 'cli_error' } elseif ($ProcessResult.process_error) { 'process' } else { 'missing_result' }
            $terminalError = if ($terminal) { $terminal['error'] }
            $message = Get-AgyErrorMessage $terminalError
            $specialized = Get-AgyFailureKind $terminalError
            # A terminal error is authoritative. Only look for explicit diagnostics if it gave no error details.
            if (-not $terminalError) {
                foreach ($line in $ProcessResult.stderr) {
                    $specialized = Get-AgyFailureKind $line
                    if ($specialized) { $message = $line; break }
                }
            }
            if ($specialized) { $errorKind = $specialized }
            if ($errorKind -eq 'timeout') { $status = 'TIMEOUT' }
            if (-not $message) {
                $message = if ($terminal) { 'CLI did not complete successfully.' }
                elseif ($ProcessResult.process_error) { $ProcessResult.process_error }
                else { 'CLI did not emit a terminal result event; inspect the logs.' }
            }
        }
    }
    elseif ($permissionDenied) { $status='PARTIAL'; $errorKind='permission_denied'; $message='At least one tool action was denied; inspect the task outcome before continuing.' }
    else { $status='SUCCESS' }

    return [ordered]@{
        status=$status; error_kind=$errorKind; error=$message
        requested_model=$RequestedModel; reported_model=$reportedModel
        model_verified=($reportedModel -ceq $RequestedModel)
        response=$(if ($terminal -and $terminal['response'] -is [string]) { $terminal['response'] } else { $null })
        conversation_id=$(if (-not $conversationMismatch -and $conversation) { $conversation } else { $null })
        cli_status=$(if ($terminal) { $terminal['status'] } else { $null })
        exit_code=$ProcessResult.exit_code; elapsed_seconds=$ProcessResult.elapsed_seconds
        process_error=$ProcessResult.process_error
        usage=$(if ($terminal) { $terminal['usage'] } else { $null })
        permission_denied=$permissionDenied; tool_errors=$toolErrors.ToArray()
    }
}
