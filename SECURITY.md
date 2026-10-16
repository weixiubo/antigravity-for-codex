# Security and data handling

## Trust boundaries

The scripts start the official Antigravity CLI with the current user's operating-system permissions. They are not a sandbox. Agent instructions such as `plan` and file-ownership constraints guide execution but do not replace operating-system access controls.

Only run tasks in workspaces whose contents and local tool configuration are appropriate for the intended operation. Model output and repository content can contain untrusted instructions; the main agent remains responsible for accepting results and authorizing actions within the user's task.

## Authentication and external services

The official CLI manages authentication. This project does not read credential files, implement OAuth, proxy model endpoints, or rotate accounts. Service eligibility, quotas, and permitted usage remain governed by the provider's terms and account configuration. The open-source license does not grant access to any external service.

## Local records

Run records may contain source excerpts, task content, absolute paths, model responses, and diagnostic details. They are written to the selected workspace or record directory, not uploaded by the wrapper. The CLI sends task data to its configured service and may maintain its own state separately.

The default run directory is excluded from this repository's version control. That exclusion does not automatically apply to another project's Git configuration. Review that project's ignore rules before running the tool there. Review and redact diagnostics before sharing them.

## Reporting a vulnerability

Do not publish credentials or private task data in a public issue. Use GitHub's private vulnerability reporting option when it is available. Otherwise, open a minimal issue requesting a private reporting channel without including exploit details or sensitive data.
