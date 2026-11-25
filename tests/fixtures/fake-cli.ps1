param([string]$p, [Parameter(ValueFromRemainingArguments)][string[]]$Extra)
$ErrorActionPreference='Stop'
$mode=$env:FAKE_AGY_MODE
if ($Extra -contains '--version') { '0.0.0-fixture'; exit 0 }
if ($p -eq 'models' -or $Extra -contains 'models') {
    "fixture-model`tFixture Model"
    if ($mode -eq 'models-failed') { exit 2 }
    exit 0
}
if ($p -eq '/usage' -or $Extra -contains '/usage') {
    switch ($mode) {
        'usage-unknown' { 'Quota service unavailable'; exit 0 }
        'usage-invalid' {
            "Fixture Models`tWeekly Limit Remaining`t101%`tnot-a-date"
            "ERROR`tpermission denied`tunknown`tplaceholder"
            exit 0
        }
    }
    "Fixture Models`tFive Hour Limit Remaining`t75%`t2030-01-01T00:00:00Z"
    exit 0
}
if ($mode -eq 'auth-before-stdin') {
    [Console]::Error.WriteLine('Error: authentication required')
    exit 1
}
$inputText=[Console]::In.ReadLine()
$inputObject=$inputText | ConvertFrom-Json
$selected=$Extra[[Array]::IndexOf($Extra,'--model')+1]
$conversationIndex=[Array]::IndexOf($Extra,'--conversation')
$conversation=if ($conversationIndex -ge 0) { $Extra[$conversationIndex+1] } else { [guid]::NewGuid().ToString() }
if ($mode -eq 'wrong-resume') { $conversation=[guid]::NewGuid().ToString() }
if ($env:FAKE_PID_FILE) { [IO.File]::WriteAllText($env:FAKE_PID_FILE, [string]$PID) }
if ($mode -eq 'hang') { Start-Sleep -Seconds 60; exit 0 }
$reported=if ($mode -eq 'mismatch') { 'other-model' } else { $selected }
$init=@{event='init';conversation_id=$conversation;init=@{model=$reported}}
if ($mode -eq 'invalid-init') { $init.init='invalid' }
$init | ConvertTo-Json -Depth 4 -Compress
switch ($mode) {
    'hang-after-init' { Start-Sleep -Seconds 60; exit 0 }
    'hang-quota-noise' { [Console]::Error.WriteLine('Quota info: 99% remaining'); Start-Sleep -Seconds 60; exit 0 }
    'wait-for-release' {
        $limit=[Diagnostics.Stopwatch]::StartNew()
        while (-not [IO.File]::Exists((Join-Path (Get-Location).Path 'release'))) {
            if ($limit.Elapsed.TotalSeconds -gt 15) { throw 'Fixture was never released.' }
            Start-Sleep -Milliseconds 20
        }
    }
    'missing' { exit 0 }
    'denied' { [Console]::Error.WriteLine('Tool execution denied by policy: run_command') }
    'tool-denied' {
        @{event='step_update';step_update=@{tool_info=@{name='run_command';error=@{type='PERMISSION_DENIED';message='approval required'}}}} | ConvertTo-Json -Depth 6 -Compress
    }
    'noise' { 'a non-JSON progress line'; '{"event":"future_extension","future_extension":"opaque"}' }
    'benign-diagnostics' { [Console]::Error.WriteLine('Approval required: false') }
    'invalid-result' { '{"event":"result","result":"invalid"}'; exit 0 }
}
$terminal=@{event='result';result=@{status='SUCCESS';response=$inputObject.message.content;conversation_id=$conversation;usage=@{input_tokens=1;output_tokens=1}}}
switch ($mode) {
    'auth' { $terminal.result.status='ERROR'; $terminal.result.error='authentication required' }
    'quota' { $terminal.result.status='ERROR'; $terminal.result.error='RESOURCE_EXHAUSTED: quota exceeded' }
    'structured-quota' { $terminal.result.status='ERROR'; $terminal.result.error=@{code=429;message='Resource limit'} }
    'error-noise' {
        $terminal.result.status='ERROR'
        $terminal.result.error='internal server error'
        [Console]::Error.WriteLine('Earlier quota info: 99% remaining')
    }
    'cli-timeout' { $terminal.result.status='TIMEOUT'; $terminal.result.error='Turn timed out' }
    'result-id-mismatch' { $terminal.result.conversation_id=[guid]::NewGuid().ToString() }
    'invalid-response' { $terminal.result.response=@{invalid=$true} }
}
$terminal | ConvertTo-Json -Depth 5 -Compress
if ($mode -eq 'duplicate-result') { $terminal | ConvertTo-Json -Depth 5 -Compress }
if ($mode -eq 'nonzero') { exit 7 }
