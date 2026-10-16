param([string]$p, [Parameter(ValueFromRemainingArguments)][string[]]$Extra)
$ErrorActionPreference='Stop'
$mode=$env:FAKE_AGY_MODE
if ($Extra -contains '--version') { '1.3.5-fixture'; exit 0 }
if ($p -eq 'models' -or $Extra -contains 'models') { "fixture-model`tFixture Model"; exit 0 }
if ($p -eq '/usage' -or $Extra -contains '/usage') {
    if ($mode -eq 'usage-unknown') { 'Quota service unavailable'; exit 0 }
    "Fixture Models`tFive Hour Limit Remaining`t75%`t2030-01-01T00:00:00Z"
    exit 0
}
$inputText=[Console]::In.ReadLine()
$inputObject=$inputText | ConvertFrom-Json
$selected=$Extra[[Array]::IndexOf($Extra,'--model')+1]
if ($env:FAKE_PID_FILE) { [IO.File]::WriteAllText($env:FAKE_PID_FILE, [string]$PID) }
if ($mode -eq 'hang') { Start-Sleep -Seconds 60; exit 0 }
$reported=if ($mode -eq 'mismatch') { 'other-model' } else { $selected }
@{event='init';conversation_id='fixture-conversation';init=@{model=$reported}} | ConvertTo-Json -Depth 4 -Compress
if ($mode -eq 'missing') { exit 0 }
if ($mode -eq 'denied') { [Console]::Error.WriteLine('Tool execution denied by policy: run_command') }
if ($mode -eq 'tool-denied') {
    @{event='step_update';step_update=@{tool_info=@{name='run_command';error=@{type='PERMISSION_DENIED';message='approval required'}}}} | ConvertTo-Json -Depth 6 -Compress
}
if ($mode -eq 'noise') { 'a non-JSON progress line' }
$terminal=@{event='result';result=@{status='SUCCESS';response=$inputObject.message.content;conversation_id='fixture-conversation';usage=@{input_tokens=1;output_tokens=1}}}
if ($mode -eq 'auth') { $terminal.result.status='ERROR'; $terminal.result.error='authentication required' }
if ($mode -eq 'quota') { $terminal.result.status='ERROR'; $terminal.result.error='RESOURCE_EXHAUSTED: quota exceeded' }
$terminal | ConvertTo-Json -Depth 5 -Compress
if ($mode -eq 'nonzero') { exit 7 }
