# Antigravity Helper

[简体中文](README.zh-CN.md)

A Codex skill for coordinating native subagents and the official Antigravity CLI on Windows. It provides task-routing instructions, current model and quota queries, and a PowerShell runner with structured results, isolated run records, timeouts, and cancellation.

## Capabilities

- Select the main agent, native Codex subagents, Antigravity, or a combination according to task requirements.
- Query the model IDs and quota information exposed by the installed `agy` CLI.
- Send UTF-8 task descriptions through NDJSON standard input rather than shell interpolation.
- Preserve explicit conversation IDs for continuation.
- Record CLI events, diagnostics, and final results for independent verification.
- Report missing results, model mismatches, nonzero exits, timeouts, cancellation, and detected permission denials.

The project does not provide model access, redistribute the Antigravity executable, or implement account pooling. Claude access through Antigravity is distinct from the standalone Claude Code product, which is not integrated here.

## Requirements

| Component | Requirement |
|---|---|
| Operating system | Windows 10 or Windows 11 |
| Runtime | PowerShell 7.4 or later (`pwsh`) |
| External agent | Official Antigravity CLI, installed and authenticated |
| Host | A local Codex environment supporting user skills |
| Tests only | Python 3.10 or later; no third-party Python packages |

The initial live integration was verified with Antigravity CLI 1.3.5. CLI output formats and available models can change independently of this project. The runner's `plan` mode is not an operating-system sandbox.

## Installation

Install and authenticate the CLI using the [official Antigravity instructions](https://antigravity.google/docs/cli/install/). Then clone and install this skill from PowerShell:

```powershell
git clone https://github.com/weixiubo/antigravity-helper.git
Set-Location antigravity-helper
pwsh -NoProfile -File ./Install-Skill.ps1
```

The installer copies the runtime files to `$CODEX_HOME/skills/antigravity-helper`, or `$HOME/.codex/skills/antigravity-helper` when `CODEX_HOME` is unset. It does not change `AGENTS.md`, account settings, or the CLI installation. Existing destinations are left intact unless `-Replace` is supplied; replacements create a sibling ZIP backup before updating packaged files. Other files in the destination are preserved.

For a custom destination:

```powershell
pwsh -NoProfile -File ./Install-Skill.ps1 -Destination 'C:\Tools\codex-skills\antigravity-helper'
```

A custom destination must be configured as a discoverable skill location in the host. Refresh the skill list or restart Codex if the new skill is not visible. Only install one discoverable copy with this skill name.

## Usage in Codex

Invoke the skill explicitly:

```text
Use $antigravity-helper to obtain an independent review of this change and verify the findings.
```

Automatic selection is enabled. Codex can select the skill for useful parallel investigation, bounded delegation, or cross-model review. Selection depends on the host and task; it is not guaranteed for every prompt. Native subagents remain subject to the tools and permissions provided by the host.

## Direct script usage

These examples run from the repository root in PowerShell 7.4 or later:

```powershell
$workspace = (Get-Location).Path
$info = & ./scripts/Get-AntigravityInfo.ps1 -Action All -Workspace $workspace |
    ConvertFrom-Json
if ($info.status -ne 'SUCCESS') { throw 'Inspect the query result before selecting a model.' }
$info.models | Format-Table id, name
$info.quota | Format-Table group, window, remaining, resets_at
```

Choose an ID returned by the query, then submit a task:

```powershell
$modelId = Read-Host 'Model ID from the current list'
$run = & ./scripts/Invoke-Antigravity.ps1 `
    -Prompt 'Explain the purpose of this project. Do not change files.' `
    -Model $modelId -Workspace $workspace -Mode plan | ConvertFrom-Json
$run | Select-Object status, reported_model, model_verified, response, run_directory
```

For a file-editing task, supply a UTF-8 task file and `-Mode accept-edits`. Review the returned status and independently verify the produced changes before accepting the task.

See [Script reference](docs/script-reference.md) for parameters, result fields, continuation, and cancellation.

## Validation

Run the offline test suite:

```powershell
python -m unittest discover -s tests -v
```

The tests use a local fixture process and do not require a Google account or consume model quota. They cover process I/O, result classification, timeouts, cancellation, concurrent runs, and installation. GitHub Actions runs the same suite on Windows.

Offline tests validate the integration machinery. Actual model availability, authentication, quota, and output quality require a live check with the user's own account. See [Testing](docs/testing.md).

## Data handling and service access

Task content is sent to the service selected by the official CLI. Local run records can contain task content, file paths, and model responses. Do not publish these records without reviewing them. See [Security and data handling](SECURITY.md).

This is an independent community project, not an OpenAI or Google product. The MIT license covers this repository's code and documentation; it does not grant service access or override [Antigravity's terms](https://antigravity.google/terms).

## Contributing and license

See [Contributing](CONTRIBUTING.md) for development and review requirements. This project is distributed under the [MIT License](LICENSE).
