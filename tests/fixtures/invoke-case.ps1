param([Parameter(Mandatory)][string]$CaseFile)
$case=Get-Content -LiteralPath $CaseFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
$entry=$case.entry
$arguments=$case.parameters
if ($case.caller_directory) { Set-Location -LiteralPath $case.caller_directory }
& $entry @arguments
exit $LASTEXITCODE
