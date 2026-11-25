#Requires -Version 7.4
[CmdletBinding(DefaultParameterSetName='Text')]
param(
    [Parameter(Mandatory, ParameterSetName='Text')][ValidateNotNullOrEmpty()][string]$Prompt,
    [Parameter(Mandatory, ParameterSetName='File')][string]$PromptFile,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Model,
    [Parameter(Mandatory)][string]$Workspace,
    [ValidateSet('plan','accept-edits')][string]$Mode='plan',
    [string]$Timeout='5m',
    [string]$ConversationId,
    [string]$RecordDirectory,
    [string]$CliPath,
    [Parameter(DontShow)][string[]]$CliPrefixArguments=@()
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$runDirectory=$null
$result=$null
$logErrors=[Collections.Generic.List[string]]::new()
try {
    if (-not $IsWindows) { throw 'This skill targets the logged-in Windows host; do not silently route to a remote or WSL installation.' }
    $executable=Resolve-AgyExecutable $CliPath
    $resolvedWorkspace=Resolve-AgyWorkspace $Workspace
    $seconds=ConvertTo-AgyTimeoutSeconds $Timeout
    if ($PSCmdlet.ParameterSetName -eq 'File') { $Prompt=Get-Content -LiteralPath $PromptFile -Raw -Encoding utf8 }
    if ([string]::IsNullOrWhiteSpace($Prompt)) { throw 'The task prompt is empty.' }
    if ($PSBoundParameters.ContainsKey('ConversationId') -and [string]::IsNullOrWhiteSpace($ConversationId)) {
        throw 'ConversationId must be nonempty when supplied.'
    }
    $recordRoot=Join-Path $resolvedWorkspace 'work\antigravity'
    if ($RecordDirectory) {
        $provider=$null
        $drive=$null
        $recordRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RecordDirectory, [ref]$provider, [ref]$drive)
        if ($provider.Name -ne 'FileSystem') { Throw-AgySetupError 'invalid_record_directory' 'RecordDirectory must be a filesystem path.' }
    }
    $runId=[DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N')
    $runDirectory=Join-Path $recordRoot $runId
    $cancelFile=Join-Path $runDirectory 'cancel'
    $request=[ordered]@{
        run_id=$runId; started_at=[DateTimeOffset]::UtcNow.ToString('o'); workspace=$resolvedWorkspace
        model=$Model; mode=$Mode; conversation_id=$ConversationId; timeout_seconds=$seconds
        prompt_characters=$Prompt.Length
        prompt_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Prompt)))
    }
    try {
        [void][IO.Directory]::CreateDirectory($runDirectory)
        Write-AgyJsonFile (Join-Path $runDirectory 'request.json') $request
        Write-AgyJsonFile (Join-Path $runDirectory 'result.json') @{status='RUNNING'; run_id=$runId; cancel_file=$cancelFile}
    } catch {
        $logErrors.Add($_.Exception.Message)
        Throw-AgySetupError 'log_write_failed' 'Could not initialize local run records.'
    }
    [Console]::Error.WriteLine("Antigravity run: $runDirectory")
    $arguments=@($CliPrefixArguments) + @('--input-format','stream-json','--output-format','stream-json','--model',$Model,'--mode',$Mode,'--print-timeout',$Timeout.ToLowerInvariant())
    if ($ConversationId) { $arguments+=@('--conversation',$ConversationId) }
    $inputLine=@{event='user'; message=@{content=$Prompt}} | ConvertTo-Json -Depth 4 -Compress
    $processResult=Invoke-AgyProcess -FilePath $executable -ArgumentList $arguments -Workspace $resolvedWorkspace -InputLine $inputLine -TimeoutSeconds ($seconds+10) -RunDirectory $runDirectory -CancelFile $cancelFile
    $logErrors.AddRange($processResult.log_errors)
    $result=ConvertFrom-AgyRun -ProcessResult $processResult -RequestedModel $Model -RequestedConversation $ConversationId
    $result['run_id']=$runId
    $result['workspace']=$resolvedWorkspace
    $result['mode']=$Mode
    $result['run_directory']=$runDirectory
    $result['logs']=@{events=(Join-Path $runDirectory 'events.jsonl'); stderr=(Join-Path $runDirectory 'stderr.txt')}
} catch {
    $errorKind=if ($_.Exception.Data['AgyErrorKind']) { $_.Exception.Data['AgyErrorKind'] } else { 'setup' }
    $result=[ordered]@{status='ERROR'; error_kind=$errorKind; error=$_.Exception.Message; run_directory=$runDirectory}
} finally {
    if (-not $result) { $result=[ordered]@{status='CANCELLED'; error_kind='interrupted'; run_directory=$runDirectory} }
    $result['finished_at']=[DateTimeOffset]::UtcNow.ToString('o')
    if ($logErrors.Count) {
        $result['log_errors']=$logErrors.ToArray()
        if ($result['status'] -eq 'SUCCESS') {
            $result['status']='ERROR'
            $result['error_kind']='log_write_failed'
            $result['error']='Could not persist all local run records.'
        }
    }
    if ($runDirectory -and [IO.Directory]::Exists($runDirectory)) {
        try { Write-AgyJsonFile (Join-Path $runDirectory 'result.json') $result } catch {
            $logErrors.Add("result.json: $($_.Exception.Message)")
            $result['log_errors']=$logErrors.ToArray()
            if ($result['status'] -eq 'SUCCESS') {
                $result['status']='ERROR'
                $result['error_kind']='log_write_failed'
                $result['error']='Could not persist the final run result.'
            }
        }
    }
}
$result | ConvertTo-Json -Depth 20
if ($result['status'] -eq 'SUCCESS') { exit 0 }
if ($result['status'] -eq 'CANCELLED') { exit 130 }
if ($result['status'] -eq 'TIMEOUT') { exit 124 }
exit 1
