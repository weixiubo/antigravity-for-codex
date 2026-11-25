# Security and data handling

## Trust boundaries

The scripts start the official Antigravity CLI with the current user's operating-system permissions. Windows Job Objects govern process lifetime. Agent instructions such as `plan` and file ownership guide execution. Operating-system permissions govern filesystem access.

Run tasks in workspaces whose contents and tool configuration are appropriate for the intended operation. Verify returned results and repository instructions against the authorized task scope.

## Authentication and external services

The official CLI manages authentication. This project does not read credential files, implement OAuth, proxy model endpoints, or rotate accounts. Service eligibility, quotas, and permitted usage remain governed by the provider's terms and account configuration. The open-source license does not grant access to any external service.

## Local records

The wrapper stores run records in the selected workspace or record directory. Records can contain source excerpts, task content, absolute paths, model responses, and diagnostics. The CLI submits task data to its configured service and can maintain its own state separately.

The default run directory is excluded from this repository's version control. Set `-RecordDirectory` outside other Git worktrees to keep local records out of their diffs. Review and redact diagnostics before sharing them.

## Reporting a vulnerability

Do not publish credentials or private task data in a public issue. Use GitHub's private vulnerability reporting option when it is available. Otherwise, open a minimal issue requesting a private reporting channel without including exploit details or sensitive data.
