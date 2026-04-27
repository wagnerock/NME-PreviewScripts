# NME Scripted Actions CLI Reference

All commands are dispatched through the bundled helper script:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/nme-api.sh" <command> [args]
```

---

## `list [filter]`

List all scripted actions, optionally filtered by name substring.

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/nme-api.sh" list [filter]
```

Output: table of id, name, environment, mode, tags.

---

## `show <id>`

Show full details of a scripted action by ID, including its script body.

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/nme-api.sh" get <id>
```

Note: `GET /api/v1/scripted-actions/{id}` returns 405. The helper uses the list endpoint and filters by ID.

---

## `create <file.ps1> [options]`

Create a new scripted action from a PowerShell file.

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/nme-api.sh" create <file.ps1> \
  [--name "Name"] \
  [--env AzureAutomation|CustomScript] \
  [--mode Individual|Combined|IndividualWithRestart] \
  [--tags "tag1,tag2"] \
  [--desc "description"]
```

Defaults: `--env AzureAutomation`, `--mode Individual`. Parses `#description`, `#execution mode`,
and `#tags` from script header comments if present and no explicit flag overrides them.

---

## `update <id> <file.ps1>`

Update an existing scripted action's script body. Preserves name, environment, mode, tags, and
description from the current NME record unless additional options are passed.

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/nme-api.sh" update <id> <file.ps1>
```

---

## `delete <id>`

Delete a scripted action by ID.

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/nme-api.sh" delete <id>
```

Internally sends `{"force": true}` with `Content-Type: application/json` — both are required by the API.

---

## `execute <id> --sub <subscriptionId> [--param key=value ...]`

Execute an Azure Automation runbook scripted action directly (not tied to a host pool or VM).
`--sub` is required. `--param` may be repeated for each runtime parameter.

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/nme-api.sh" execute <id> \
  --sub <subscriptionId> \
  --param VMName=myvm \
  --param Token=abc
```

Returns a job object. Poll with `job <jobId>`.

---

## `job <jobId>`

Get status of an async NME job.

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/nme-api.sh" job <jobId>
```

Job status lifecycle: `Pending` → `Running` → `Completed` | `Failed`

---

## `job-output <jobId>`

Get the full output/log of a completed or failed NME job.

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/nme-api.sh" job-output <jobId>
```
