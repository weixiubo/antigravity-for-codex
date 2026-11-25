---
name: antigravity-for-codex
description: Delegate tasks from Codex to the official Antigravity CLI on Windows. Use for scoped implementation, independent cross-model review, continuation of Antigravity conversations, and Antigravity model or quota queries.
---

# Antigravity Skill for Codex

Codex defines the task, invokes Antigravity, and verifies the result. Antigravity receives the submitted task and the context made available in its workspace. Supply the relevant background explicitly.

## Task selection

Use Antigravity for an authorized delegation or an independent review that benefits from a different provider. Use Codex directly for routine work when delegation adds little value. Codex-native subagents can handle other authorized parts of the task. For planning-only requests, document the allocation and leave execution pending.

Give each delegate a clear objective, working directory, relevant evidence, permitted file changes, and acceptance criteria. Assign separate files or worktrees for concurrent edits. Review a fixed revision. Route requests for standalone Claude Code to that product.

## Prerequisites and model selection

Use PowerShell 7.4 or later on the Windows host where the official `agy` CLI is installed and authenticated. Resolve `$skill` to this skill's installation directory and `$workspace` to the task's absolute working directory.

Query model availability and quota before selecting an Antigravity model.

```powershell
& "$skill/scripts/Get-AntigravityInfo.ps1" -Action All -Workspace $workspace
```

Select a complete ID from `models`. If the requested ID is unavailable, report that condition and wait for a new selection. When selecting a model on the user's behalf, consider its task fit, available quota, and the value of independent evaluation.

## Execute and continue a task

Save substantial task descriptions as UTF-8 files and invoke the runner with the selected model.

```powershell
& "$skill/scripts/Invoke-Antigravity.ps1" -PromptFile $taskFile -Model $modelId -Workspace $workspace -Mode plan
```

Use `-Prompt` for short tasks. Use `plan` for analysis and state that files should remain unmodified. Operating-system controls govern filesystem access. Use `accept-edits` for authorized edits.

Choose `-Timeout` to fit the task. If the host yields before the CLI finishes, continue monitoring the same invocation. The run directory is printed on stderr and the final JSON is returned on stdout. For Git worktrees, set `-RecordDirectory` and keep temporary prompt files in scratch storage outside the worktree.

To cancel a run, create a file named `cancel` in its run directory. To resume a conversation, supply its explicit `-ConversationId` with the same workspace. An interrupted run can retain the ID from its initial event. Send follow-up requests to the same conversation in sequence.

## Verify results

Inspect the final status, `requested_model`, `reported_model`, and `model_verified`. Use CLI metadata to verify the model. Check the result against the task criteria and independently verify any findings, file changes, or tests.

`SUCCESS` indicates that the runner accepted the CLI result. `PARTIAL` indicates a detected tool permission denial. For partial, failed, timed-out, or cancelled runs, inspect the recorded events and workspace before deciding whether to resume or retry. Retain the official CLI's permission controls.

## Check quota

Use `Get-AntigravityInfo.ps1 -Action Usage` for quota-only requests. Report the account-level quota windows and reset times returned by the CLI. Report an unavailable quota as unknown.

Quota windows can be shared across sessions. Use reported token counters for task-level accounting and account snapshots for remaining quota. Resumed conversations can report cumulative counters. Reuse a recent snapshot across parallel tasks and refresh it after substantial usage or a rate-limit response.

## References

- [Script reference](docs/script-reference.md)
- [Troubleshooting](references/troubleshooting.md)
