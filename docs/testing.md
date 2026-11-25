# Testing

## Offline validation

Run the suite from the repository root:

```powershell
python -m unittest discover -s tests -v
```

Requirements are Windows, PowerShell 7.4 or later on `PATH`, and Python 3.10 or later. The suite uses only the Python standard library and local PowerShell fixture processes. It does not use a Google account or call a model service.

The suite covers Unicode and long inputs, CLI protocol and conversation validation, diagnostic classification, process-tree cleanup, atomic final results, concurrent runs, query validation, and installation rollback.

Artifacts are written beneath `.test-output` and are excluded from version control. `ANTIGRAVITY_FOR_CODEX_TEST_ROOT` may select another artifact root. Test results contain local paths and should be reviewed before sharing.

## Live validation

Live validation requires an installed, authenticated official CLI and consumes the account's normal quota. Query current models and quota before selecting a model. Run a bounded task in a disposable workspace and verify the reported model and returned status.

For file-editing checks, define assertions in advance. Limit edits to the target implementation, inspect the resulting diff, and run the tests independently.

For continuation, use the exact returned conversation ID and ask a question about the previous turn without repeating its answer. Inspect the returned ID and response. For discovery, start a fresh Codex session in a separate workspace and verify that the skill is available without a global `AGENTS.md` entry.

Keep live run records, account identifiers, quota snapshots, and credential files out of version control. Use the offline suite to validate the wrapper and live checks to validate provider access and task results.
