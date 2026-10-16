# Troubleshooting

Inspect the relevant run's `result.json`, `stderr.txt`, and `events.jsonl`. Do not print or upload authentication tokens.

| Symptom | Resolution |
|---|---|
| CLI executable not found | Run the information script with `-Action Doctor`. Install the official CLI or supply its executable through `-CliPath`. |
| An existing terminal cannot resolve `agy` | The scripts check the standard installation path directly; they do not require a refreshed `PATH` when that installation exists. |
| Authentication required | Complete the official interactive sign-in on the same Windows host, then repeat the query. A GUI login is not guaranteed to be shared by every CLI version. |
| Model unavailable | Query the current model list and verify the complete ID. Do not silently replace a user-selected model. |
| Quota exhausted or request rate limited | Retain the error and current quota information. Avoid unbounded retries. Select another permitted model only when the task and authorization allow it. |
| Quota output cannot be parsed | Treat quota as unknown. Inspect `usage_raw` and update the parser if the official output format has changed. |
| Permission denial with process exit code 0 | Treat the result as `PARTIAL`. Identify the omitted operation and complete verification through an already authorized route. |
| Timeout or cancellation | Inspect partial changes and the explicit conversation ID before deciding whether to resume. No rollback is implied. |
| Missing terminal result | Preserve the original events. Do not substitute the last text fragment for a complete result. |
| Skill missing in an existing chat | Refresh the skill list or restart Codex. Confirm that the installation location is scanned and that only one copy is enabled. |
| Invocation from WSL, a remote host, or a cloud session | Use the authenticated Windows host. This project does not route requests across machines or copy credentials. |

Official references: [Installation and authentication](https://antigravity.google/docs/cli/install/), [Headless mode](https://antigravity.google/docs/cli/headless/), and [Codex skills](https://developers.openai.com/codex/skills/).
