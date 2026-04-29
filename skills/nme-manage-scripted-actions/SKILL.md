---
name: nme-manage-scripted-actions
description: >
  Manage scripted actions in Nerdio Manager for Enterprise (NME) via the REST API.
  Supports listing, showing, creating, updating, deleting, and executing scripted actions,
  and polling async job status.
argument-hint: "list [filter] | show <id> | create <file.ps1> | update <id> <file.ps1> | delete <id> | execute <id> [--sub <subId>] [--param key=value ...] | execute-on-hostpool <id> | hosts <subId> <rg> <hp> | job <jobId> | job-output <jobId>"
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
| `get <id>` | Show full details and script body for a scripted action |
| `create <file.ps1> [options]` | Create a new scripted action from a PowerShell file |
| `update <id> <file.ps1>` | Replace script body of an existing scripted action |
| `delete <id>` | Delete a scripted action by ID |
| `execute <id> --sub <subId>` | Execute an Azure Automation runbook scripted action |
| `execute-on-hostpool <id>` | Execute a Windows scripted action on a host pool |
| `hosts <subId> <rg> <hp>` | List hosts in a host pool with their FQDNs |
| `job <jobId>` | Poll status of an async NME job |
| `job-output <jobId>` | Get full output/log of a completed or failed NME job |

For full syntax and flags, see [`references/cli-reference.md`](references/cli-reference.md).
For API details, see [`references/api-operations.md`](references/api-operations.md).

## Upload / Create Workflow

When the user asks to upload or create a scripted action from a `.ps1` file:

1. Derive the intended name from the filename (strip `.ps1`).
2. Run `list "<name>"` to check for an exact name match.
3. **If an exact match exists**, stop and ask the user:
   > A scripted action named **"<name>"** already exists (ID <id>). Overwrite it, or cancel?
   - **Overwrite** → run `update <id> <file.ps1>`
   - **Cancel** → abort
4. **If no exact match**, scan the results for similar names (same key words, slight wording
   differences — e.g. "Enable Login Diagnostics" vs "Enable User Login Diagnostics"). If similar
   names exist, surface them before creating:
   > No exact match for **"<name>"**. Similar actions exist:
   > - **"<similar name>"** (ID <id>)
   > Create new, or update one of these instead?
5. **If no match at all**, run `create <file.ps1>`.

## Update Failure: executionTimeout Bug

If `update` fails with an error containing "Execution timeout", the NME record has a corrupted
`executionTimeout` value that blocks all PATCH operations. The helper script handles this
automatically by deleting the record and recreating it with the same name. This changes the
action's ID — note that if any automations reference the action by ID they will need updating.

## GitHub-Synced Action Handling

When `update` exits with code 2 and stderr contains `GITHUB_SYNCED`, the action is managed by a GitHub integration and cannot be modified via the API.

Inform the user:
> **"<name>"** (ID <id>) is synced from GitHub — it cannot be updated via the API.
> Options:
> 1. **Create with a different name** — upload as a new, unsynced scripted action
> 2. **Abort** — do nothing

- If the user chooses option 1, ask for a new name, then run `create <file.ps1> --name "<new name>"`.
- If the user chooses option 2, stop.
