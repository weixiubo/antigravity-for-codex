# Script reference

All entry points require Windows and PowerShell 7.4 or later. Commands use literal filesystem paths and launch the official CLI as a child process. They do not install the CLI or modify its authentication settings.

## Information queries

```powershell
./scripts/Get-AntigravityInfo.ps1 -Action All -Workspace 'C:\Projects\example'
```

| Parameter | Default | Description |
|---|---|---|
| `Action` | `All` | `Doctor`, `Models`, `Usage`, or `All` |
| `Workspace` | Current directory | Existing directory used as the CLI working directory |
| `CliPath` | Automatic discovery | Explicit executable path for a custom official installation |
| `Timeout` | `45s` | Per-query deadline; a five-second process grace period is added |

Executable discovery checks `%LOCALAPPDATA%\agy\bin\agy.exe` before searching `PATH`. `Doctor` queries the version; it does not verify that model access is authorized. `Models` runs `agy models`. `Usage` runs the CLI's `/usage` command without a model task.

The JSON response contains `status`, `checked_at`, `executable`, and the requested data. `models` contains objects with `id` and `name`. `quota` contains `group`, `window`, `remaining`, and `resets_at`. The original CLI text is retained as `models_raw` or `usage_raw`.

A failed query or unrecognized model/quota output produces `status=ERROR`, an `errors` entry, and exit code 1. An unavailable quota must not be interpreted as zero remaining allowance. Successful queries exit with code 0.

## Task execution

```powershell
./scripts/Invoke-Antigravity.ps1 -PromptFile './task.txt' `
    -Model $modelId -Workspace 'C:\Projects\example' -Mode accept-edits
```

| Parameter | Required | Default | Description |
|---|---|---|---|
| `Prompt` | One input form | — | Task text supplied directly |
| `PromptFile` | One input form | — | UTF-8 file containing the task text |
| `Model` | Yes | — | Complete ID from the current model query |
| `Workspace` | Yes | — | Existing working directory |
| `Mode` | No | `plan` | `plan` or `accept-edits` |
| `Timeout` | No | `5m` | Requested CLI timeout; a ten-second process grace period is added |
| `ConversationId` | No | New conversation | Explicit ID to resume |
| `RecordDirectory` | No | `<workspace>/work/antigravity` | Root directory for unique run records |
| `CliPath` | No | Automatic discovery | Explicit executable path |

`Prompt` and `PromptFile` are mutually exclusive. Durations use `s`, `m`, or `h`, such as `30s`, `5m`, or `1h`, and must be between 0.1 seconds and 24 hours. A relative `RecordDirectory` is resolved against the caller's current directory.

The task is encoded as a single NDJSON user message on stdin. The runner captures stream-json events and stderr concurrently. It supplies the requested model explicitly and does not retry or fall back to another model.

The advanced `CliPrefixArguments` parameter supports process fixtures and custom launchers. It is not needed when using the official executable. Information queries expose the same parameter for offline testing.

## Results and exit codes

| Status | Exit code | Meaning |
|---|---|---|
| `SUCCESS` | 0 | A successful terminal result was received with no detected failure |
| `PARTIAL` | 1 | A tool-permission denial was detected despite CLI completion |
| `ERROR` | 1 | Setup failure, process failure, model mismatch, CLI error, or missing terminal result |
| `TIMEOUT` | 124 | The process exceeded the wall-clock limit |
| `CANCELLED` | 130 | Cancellation was requested through the run's cancellation file |

The response includes the run status, requested and reported model, `model_verified`, response text, conversation ID, CLI status, exit code, elapsed time, CLI-reported usage, detected tool errors, workspace, and log paths. Setup errors can return a smaller response before a run directory exists.

Missing reported-model metadata yields `model_verified=false`; it does not by itself invalidate a completed answer. A reported model that differs from the requested model is an error. Error classification is best-effort and preserves the underlying diagnostic files.

Permission-denial detection uses structured tool errors and known diagnostic patterns. It is not a comprehensive authorization audit. `SUCCESS` does not establish that the requested task was correct, complete, or within every expected boundary; inspect the answer, file changes, and relevant checks.

## Run records

Each invocation creates a timestamp-and-UUID directory containing:

| File | Content |
|---|---|
| `request.json` | Model, mode, workspace, requested timeout, prompt length, and prompt hash |
| `process.json` | Child PID, executable path, and start time |
| `events.jsonl` | CLI stdout events, including any non-JSON lines |
| `stderr.txt` | CLI diagnostics |
| `result.json` | `RUNNING` during execution; final structured result after completion |

The prompt body is not copied into `request.json`, but CLI output and other logs may contain task text or sensitive project content. The scripts do not automatically remove run records.

## Continuation

```powershell
./scripts/Invoke-Antigravity.ps1 -Prompt 'Continue the previous review.' `
    -Model $run.requested_model -Workspace $run.workspace `
    -ConversationId $run.conversation_id
```

Use the ID returned for the intended task. Do not infer a conversation from the most recent process. Resumed usage counters may be cumulative; do not sum successive cumulative snapshots.

## Cancellation and partial changes

In another terminal, create the cancellation marker for the relevant run:

```powershell
New-Item -ItemType File -Path (Join-Path $runDirectory 'cancel')
```

The runner ends its child process tree and retains the recorded output. Cancellation and timeout do not roll back file changes or guarantee that an already accepted remote operation has been undone. Inspect the workspace before resuming or repeating a task.

## Installation updates and removal

`Install-Skill.ps1 -Replace` creates a sibling ZIP backup and updates the packaged runtime files. Other files in an existing valid installation are preserved. Backups are ZIP files so that the host does not discover them as duplicate skill directories.

To remove the skill, remove its installation directory and refresh the host's skill list. The installer does not add an `AGENTS.md` entry, so no global instruction edit is required. Removing the skill does not remove the Antigravity CLI, account authentication, or project run records.
