---
name: nme-manage-scripted-actions
description: >
  Manage scripted actions in Nerdio Manager for Enterprise (NME) via the REST API.
  Supports listing, showing, creating, updating, deleting, and executing scripted actions,
  and polling async job status.
argument-hint: "list [filter] | show <id> | create <file.ps1> | update <id> <file.ps1> | delete <id> | execute <id> [--sub <subId>] [--param key=value ...] | job <jobId> | job-output <jobId>"
allowed-tools: Bash(curl *) Bash(jq *) Bash(bash *) Bash(chmod *) Bash(cat *) Bash(pwsh *)
---

# NME Manage Scripted Actions Skill

Manage scripted actions in a live NME instance via the REST API.

## Required Environment Variables

Check for these before any API operation — if any are missing, report which ones and stop.

```
NME_BASE_URL      https://<nme-instance>                     e.g. https://nme-se-standard.lab.nerdio.net
NME_CLIENT_ID     OAuth2 app/client ID
NME_CLIENT_SECRET OAuth2 client secret
NME_TENANT_ID     Entra tenant ID
NME_SCOPE         api://<nme-app-id>/.default
```

Check: `echo "${NME_BASE_URL:-MISSING} ${NME_CLIENT_ID:-MISSING} ${NME_TENANT_ID:-MISSING}"`

## Helper Script

All API operations go through the bundled helper script. Detect which shell is available first:

```bash
bash --version >/dev/null 2>&1 && echo BASH || echo PWSH
```

- **bash available**: use `nme-api.sh`
  ```bash
  chmod +x "${CLAUDE_SKILL_DIR}/scripts/nme-api.sh"
  bash "${CLAUDE_SKILL_DIR}/scripts/nme-api.sh" <command> [args]
  ```
- **bash not available** (native Windows PowerShell): use `nme-api.ps1`
  ```pwsh
  pwsh "${CLAUDE_SKILL_DIR}/scripts/nme-api.ps1" <command> [args]
  ```

Both scripts accept identical commands and flags.

| Command | Description |
|---------|-------------|
| `list [filter]` | List scripted actions, optionally filtered by name substring |
| `show <id>` | Show full details and script body for a scripted action |
| `create <file.ps1> [options]` | Create a new scripted action from a PowerShell file |
| `update <id> <file.ps1>` | Replace script body of an existing scripted action |
| `delete <id>` | Delete a scripted action by ID |
| `execute <id> --sub <subId> [--param k=v ...]` | Execute a scripted action; returns a job |
| `job <jobId>` | Poll status of an async NME job |
| `job-output <jobId>` | Get full output/log of a completed or failed NME job |

For full syntax and flags, see [`references/cli-reference.md`](references/cli-reference.md).
For API details, see [`references/api-operations.md`](references/api-operations.md).
