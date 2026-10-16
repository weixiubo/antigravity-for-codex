# Testing

## Offline validation

Run the suite from the repository root:

```powershell
python -m unittest discover -s tests -v
```

Requirements are Windows, PowerShell 7.4 or later on `PATH`, and Python 3.10 or later. The suite uses only the Python standard library and local PowerShell fixture processes. It does not use a Google account or call a model service.

The suite covers Unicode, multiline and long input, prompt files, process failures, missing results, model mismatches, permission denials, authentication and quota errors, timeouts, cancellation, concurrent run records, information queries, and installation behavior.

Artifacts are written beneath `.test-output` and are excluded from version control. `ANTIGRAVITY_HELPER_TEST_ROOT` may select another artifact root. Test results contain local paths and should be reviewed before sharing.

## Live validation

Live validation requires an installed, authenticated official CLI and consumes the account's normal quota. Query current models and quota before selecting a model. Run a bounded task in a disposable workspace and verify the reported model and returned status.

For editing tests, prepare assertions before delegating the change, record the test-file hash, allow edits only to the target implementation, and run the tests independently afterward. A model's statement that tests passed is not test evidence.

For continuation, use the exact returned conversation ID and ask a question about the previous turn without repeating its answer. Inspect the returned ID and response. For discovery, start a fresh Codex session in a separate workspace and verify that the skill is available without a global `AGENTS.md` entry.

Do not commit live event logs, account identifiers, quota snapshots, or credential files. An offline pass confirms wrapper behavior; it does not confirm current provider availability or task quality.
