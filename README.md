# Antigravity Skill for Codex

[简体中文](README.zh-CN.md)

Delegate tasks from Codex to Antigravity. This Windows skill uses the official Antigravity CLI (`agy`) to run scoped tasks, request independent reviews, and resume conversations from Codex.

## Capabilities

- Look up the model IDs and quota windows available to the authenticated CLI.
- Submit UTF-8 task descriptions and resume conversations by explicit ID.
- Verify the reported model and conversation ID against the request.
- Record each run independently and support timeouts, cancellation, and process-tree cleanup.

Codex defines the task scope and verifies the result. This project is maintained independently. Access to Antigravity and its models depends on the official CLI and your account.

## Requirements

| Component | Requirement |
| --- | --- |
| Operating system | Windows 10 or Windows 11 |
| Runtime | PowerShell 7.4 or later (`pwsh`) |
| Antigravity | Official CLI, installed and authenticated |
| Codex | A local environment that supports user skills |
| Offline tests | Python 3.10 or later, using the standard library |

## Installation

Install and authenticate the CLI using the [Antigravity documentation](https://antigravity.google/docs/getting-started?tab=cli). Run the following commands in PowerShell.

```powershell
git clone https://github.com/weixiubo/antigravity-for-codex.git
Set-Location antigravity-for-codex
pwsh -NoProfile -File ./Install-Skill.ps1
```

The default destination is `$CODEX_HOME/skills/antigravity-for-codex`. When `CODEX_HOME` is unset, the installer uses `%USERPROFILE%\.codex\skills\antigravity-for-codex`.

Use `-Destination` to install to a custom skill location. The destination directory must be named `antigravity-for-codex` and must be discoverable by Codex.

```powershell
pwsh -NoProfile -File ./Install-Skill.ps1 -Destination 'C:\Tools\codex-skills\antigravity-for-codex'
```

Use `-Replace` to update an installation under the current name. The installer verifies the staged files, creates a ZIP backup, and preserves local additions.

### Migrate an existing installation

Install the current skill, then move the former `antigravity-helper` directory out of Codex's skill locations. Keep a backup if you have local additions. Update saved prompts and scripts to use `$antigravity-for-codex` and the new installation path. Start a new Codex session to load the current skill metadata.

## Use in Codex

```text
Use $antigravity-for-codex to delegate a review of the current patch to Antigravity. Verify the findings against the diff.
```

Codex can also select the skill automatically when the task matches its description and the host provides skill discovery.

## Use the scripts directly

Query the model list and quota from the repository root.

```powershell
$workspace = (Get-Location).Path
$info = & ./scripts/Get-AntigravityInfo.ps1 -Action All -Workspace $workspace |
    ConvertFrom-Json
if (-not $info.models) { throw 'Inspect the model query before selecting an ID.' }
$info.models | Format-Table id, name
$info.quota | Format-Table group, window, remaining, resets_at
```

Select a model ID returned by the query.

```powershell
$modelId = Read-Host 'Enter a model ID from the list'
$run = & ./scripts/Invoke-Antigravity.ps1 `
    -Prompt 'Review the current patch for correctness. Do not edit files.' `
    -Model $modelId -Workspace $workspace -Mode plan | ConvertFrom-Json
$run | Select-Object status, reported_model, model_verified, run_directory
```

Use `-PromptFile` for a UTF-8 task description and `-Mode accept-edits` when file edits are authorized. Review the result and verify any changes in the workspace. See the [script reference](docs/script-reference.md) for parameters, conversation continuation, and cancellation.

## Validation

```powershell
python -m unittest discover -s tests -v
```

The offline suite uses local fixtures to verify execution, query parsing, concurrency, and installation. See [testing](docs/testing.md) for live validation.

## Data and license

Antigravity tasks are sent to the service configured in the official CLI. Review and redact local run records before sharing them. See [security and data handling](SECURITY.md).

See the [contribution guide](CONTRIBUTING.md) and the [MIT License](LICENSE). Antigravity service access is governed by the [Antigravity Terms of Service](https://antigravity.google/terms).
