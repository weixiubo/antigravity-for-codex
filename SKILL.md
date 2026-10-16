---
name: antigravity-helper
description: Coordinate Codex native subagents, the official Antigravity CLI on Windows, or both for parallel investigation, bounded delegation, and independent cross-model review. Use for collaboration planning, execution, Antigravity assistance, and quota checks when collaboration provides a clear benefit. Complete routine small tasks directly. Antigravity execution requires a locally installed and authenticated Windows CLI.
---

# Antigravity Helper

Select an execution path for a local task: the main agent, Codex native subagents, Antigravity, or a combination. This skill is self-contained and does not require changes to global `AGENTS.md` instructions.

## Task routing

Respect the user's requested provider, task scope, and authorization. When useful collaboration is authorized, use the available native subagent tools or the Antigravity scripts without requiring the user to select a route for every task. For planning-only requests, describe the allocation without starting workers.

| Task characteristics | Preferred execution path |
|---|---|
| Small task, sequential dependency chain, or high handoff cost | Main agent |
| Independent project investigations or implementation branches requiring frequent coordination | Codex native subagents |
| Cross-vendor review, requested Gemini/Claude assistance through Antigravity, or a self-contained task | Antigravity |
| Implementation that also requires an independent review | Native subagents for independent implementation branches; Antigravity for review of a fixed revision |

These preferences do not impose capability limits. Choose according to the actual tools, task dependencies, handoff cost, and available quota. A request for the standalone Claude Code product must not be silently redirected to Claude through Antigravity.

The main agent owns task allocation and final acceptance. Give each worker the objective, necessary context, workspace, permitted file changes, constraints, and acceptance criteria. Native subagents receive context through their host's supported mechanism; Antigravity does not inherit the main conversation.

Assign disjoint file ownership before parallel edits. Run dependent steps in order. Review a fixed revision and recheck affected conclusions after changes. Do not launch duplicate work merely to obtain a vote. Workers must not delegate recursively, create scheduled tasks, or send messages unless the task explicitly requires those actions.

If native subagent tools are unavailable, complete the work in the main agent or select Antigravity when appropriate. Do not create user-visible chats or recursively launch Codex CLI processes as substitutes for native subagent tools. Preserve the host's model and concurrency settings.

## Antigravity prerequisites

Use PowerShell 7.4 or later on the Windows host where the official `agy` CLI is installed and authenticated. Locate the adjacent `scripts` directory from this skill's actual path. Do not assume a particular username, current directory, or globally available `agy` command.

Native-subagent-only tasks do not require an Antigravity query. When selecting Antigravity for a new task, query its current capabilities:

```powershell
& "$skill/scripts/Get-AntigravityInfo.ps1" -Action All -Workspace $workspace
```

Here `$skill` is the installed skill directory and `$workspace` is the task's absolute working directory. Select a complete ID from `models`; do not infer availability from examples or previous sessions. A user-selected model that is unavailable must be reported as unavailable, without silent substitution.

For unspecified models, prefer a suitable current Flash model for routine work, a suitable Claude model for cross-vendor review, and a stronger model only when task difficulty warrants it. Consider current quota and documented capabilities rather than treating a model family or version as permanently superior.

## Task execution

Write substantial task descriptions to a UTF-8 file in the task workspace and invoke:

```powershell
& "$skill/scripts/Invoke-Antigravity.ps1" -PromptFile $taskFile -Model $modelId -Workspace $workspace -Mode plan
```

`-Prompt` accepts text directly and is mutually exclusive with `-PromptFile`. `Model` and `Workspace` are required. Use `plan` for analysis with an explicit instruction not to modify project files; this is an agent mode, not an operating-system sandbox. Use `accept-edits` for file changes within the user's authorized scope.

The default timeout is five minutes; set `-Timeout` to a suitable duration when required. Preserve and wait on an existing running invocation rather than submitting it again because an outer tool yielded early. Use the host's normal execution-session controls to observe progress.

The script returns final JSON on stdout and prints the run directory on stderr. Each run has a unique directory under `work/antigravity` in the selected workspace; `-RecordDirectory` selects another record root. Read `result.json`, `events.jsonl`, and `stderr.txt` when needed. To cancel, create an empty file named `cancel` in that run directory. Do not terminate other processes by application name.

Start a new Antigravity conversation by default. To resume, provide the explicit `-ConversationId` from this task's result and retain the corresponding workspace. Do not use the CLI's implicit most-recent-conversation option.

## Result acceptance

`SUCCESS` means that the CLI completed, not that the task passed acceptance. Check `requested_model`, `reported_model`, and `model_verified`, then inspect the actual answer or file changes. Missing model metadata must not be replaced by the model's self-description.

`PARTIAL` indicates a detected tool-permission denial. `ERROR`, `TIMEOUT`, and `CANCELLED` must not be reported as complete work. Inspect logs and existing changes before deciding whether to resume or retry. The scripts neither retry nor substitute models automatically.

The main agent validates review findings, examines file differences, and runs relevant checks. Do not modify tests to conceal a failed implementation. For independent review, provide original evidence and acceptance criteria without supplying a preferred conclusion. Retain the CLI's permission controls; do not enable global permission bypass as an error-recovery step.

## Quota interpretation

Use `Get-AntigravityInfo.ps1 -Action Usage` for quota-only requests. It reads CLI status without asking a model to answer. The output includes account-level model groups, remaining percentages, and reset timestamps when exposed by the CLI.

The GUI, CLI, and other sessions may share the same account limits. A change in remaining percentage is not a precise charge attributable to this run. The `usage` field in task results contains CLI-reported token counters; resumed conversations may return cumulative counters. Do not sum cumulative snapshots or convert token counts directly to quota percentages or billed currency.

Query once at the beginning of an Antigravity task, and refresh after substantial additional work or a rate-limit signal. Share a timestamped snapshot with cooperating workers instead of querying separately in every subagent. Report unavailable quota information as unknown, not zero.

## Operational scope

Use the caller's existing official CLI authentication. Do not read or distribute credential files. This skill does not manage account pools, rotate accounts, install or upgrade the CLI, bridge remote hosts, or expose an API proxy. Use the service only with access and usage permitted by its provider.

For failures, consult [Troubleshooting](references/troubleshooting.md). The complete script interface is documented in [Script reference](docs/script-reference.md).
