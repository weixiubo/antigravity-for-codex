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
try {
    if (-not $IsWindows) { throw 'This skill targets the logged-in Windows host; do not silently route to a remote or WSL installation.' }
    $executable=Resolve-AgyExecutable $CliPath
    $resolvedWorkspace=(Resolve-Path -LiteralPath $Workspace).Path
    if (-not (Test-Path -LiteralPath $resolvedWorkspace -PathType Container)) { throw 'Workspace must be an existing directory.' }
    $seconds=ConvertTo-AgyTimeoutSeconds $Timeout
    if ($PSCmdlet.ParameterSetName -eq 'File') { $Prompt=Get-Content -LiteralPath $PromptFile -Raw -Encoding utf8 }
    if ([string]::IsNullOrWhiteSpace($Prompt)) { throw 'The task prompt is empty.' }
    $recordRoot=if ($RecordDirectory) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RecordDirectory) } else { Join-Path $resolvedWorkspace 'work\antigravity' }
    $runId=[DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N')
    $runDirectory=Join-Path $recordRoot $runId
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    $cancelFile=Join-Path $runDirectory 'cancel'
    $request=[ordered]@{
        run_id=$runId; started_at=[DateTimeOffset]::UtcNow.ToString('o'); workspace=$resolvedWorkspace
        model=$Model; mode=$Mode; conversation_id=$ConversationId; timeout_seconds=$seconds
        prompt_characters=$Prompt.Length
        prompt_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Prompt)))
    }
    $request | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runDirectory 'request.json') -Encoding utf8
    @{status='RUNNING'; run_id=$runId; cancel_file=$cancelFile} | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $runDirectory 'result.json') -Encoding utf8
    [Console]::Error.WriteLine("Antigravity run: $runDirectory")
    $arguments=@($CliPrefixArguments) + @('--input-format','stream-json','--output-format','stream-json','--model',$Model,'--mode',$Mode,'--print-timeout',"$([math]::Ceiling($seconds))s")
    if ($ConversationId) { $arguments+=@('--conversation',$ConversationId) }
    $inputLine=@{event='user'; message=@{content=$Prompt}} | ConvertTo-Json -Depth 4 -Compress
    $processResult=Invoke-AgyProcess -FilePath $executable -ArgumentList $arguments -Workspace $resolvedWorkspace -InputLine $inputLine -TimeoutSeconds ($seconds+10) -RunDirectory $runDirectory -CancelFile $cancelFile
    $result=ConvertFrom-AgyRun -ProcessResult $processResult -RequestedModel $Model
    $result['run_id']=$runId
    $result['workspace']=$resolvedWorkspace
    $result['mode']=$Mode
    $result['run_directory']=$runDirectory
    $result['logs']=@{events=(Join-Path $runDirectory 'events.jsonl'); stderr=(Join-Path $runDirectory 'stderr.txt')}
} catch {
    $result=[ordered]@{status='ERROR'; error_kind='setup'; error=$_.Exception.Message; run_directory=$runDirectory}
} finally {
    if (-not $result) { $result=[ordered]@{status='CANCELLED'; error_kind='interrupted'; run_directory=$runDirectory} }
    $result['finished_at']=[DateTimeOffset]::UtcNow.ToString('o')
    if ($runDirectory) { $result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $runDirectory 'result.json') -Encoding utf8 }
}
$result | ConvertTo-Json -Depth 20
if ($result['status'] -eq 'SUCCESS') { exit 0 }
if ($result['status'] -eq 'CANCELLED') { exit 130 }
if ($result['status'] -eq 'TIMEOUT') { exit 124 }
exit 1
