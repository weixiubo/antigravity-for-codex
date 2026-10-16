# Contributing

Contributions should improve task handoff, execution reliability, reproducibility, or documentation clarity without changing unrelated host configuration.

## Development

Use Windows with PowerShell 7.4 or later and Python 3.10 or later. Run `python -m unittest discover -s tests -v` before submitting a change. Add focused behavioral tests when changing process handling, result classification, or installation behavior.

Tests must run from the repository without relying on an installed user skill or a paid model account. Keep fixtures independent of machine-specific paths. Live checks are optional unless needed to validate a protocol change; report the CLI version, task, and observed result without publishing private logs.

## Pull requests

Describe the problem, resulting behavior, and relevant validation. Keep changes focused and document any change to parameters or JSON fields. Public documentation must address users or contributors directly and must not contain conversational history, drafting notes, self-evaluation, or unfinished sections. Keep the English and Simplified Chinese README files consistent.

Do not add automatic credential extraction, account rotation, global permission bypass, or unrequested modifications to `AGENTS.md`. Changes must preserve explicit model selection, run isolation, and honest reporting of incomplete results.

## Issues

Include the operating system, PowerShell version, CLI version, reproduction steps, and a redacted error excerpt. Remove usernames, private paths, task content, account identifiers, and tokens before attaching diagnostics. Do not attach complete live run directories without reviewing every file.

Contributions are provided under the repository's MIT License.
