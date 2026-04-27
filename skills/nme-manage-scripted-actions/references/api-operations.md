# NME Scripted Actions API Reference

## Authentication

OAuth2 client credentials flow. Token is valid for ~1 hour.

```bash
TOKEN=$(curl -s -X POST \
  "https://login.microsoftonline.com/${NME_TENANT_ID}/oauth2/v2.0/token" \
  -d "grant_type=client_credentials&client_id=${NME_CLIENT_ID}&client_secret=${NME_CLIENT_SECRET}&scope=${NME_SCOPE}" \
  | jq -r '.access_token')
```

All requests: `-H "Authorization: Bearer $TOKEN"`

## Base URL

`${NME_BASE_URL}/api/v1/scripted-actions`

---

## CRUD Endpoints

### List All

```
GET /api/v1/scripted-actions
```

Returns an array directly: `[ {id, name, script, executionMode, executionEnvironment, executionTimeout, tags, description}, ... ]`

**Note**: There is no working GET-by-ID endpoint — `GET /api/v1/scripted-actions/{id}` returns
**405 Method Not Allowed**. Always fetch the full list and filter by ID:

```bash
curl -s -H "Authorization: Bearer $TOKEN" "${NME_BASE_URL}/api/v1/scripted-actions" \
  | jq --argjson id 102 '.[] | select(.id == $id)'
```

### Create

```
POST /api/v1/scripted-actions
Content-Type: application/json
```

```json
{
  "name": "Script Display Name",
  "description": "What it does",
  "script": "<full PowerShell script>",
  "executionMode": "Individual",
  "executionEnvironment": "AzureAutomation",
  "executionTimeout": 90,
  "tags": ["Tag1", "Tag2"]
}
```

**Field rules:**
- `executionEnvironment`: `"AzureAutomation"` or `"CustomScript"`
- `executionMode`: `"Combined"`, `"Individual"`, `"IndividualWithRestart"`
- `executionTimeout`: integer minutes (10–180). **Only valid for AzureAutomation + Individual.**
  Must be `0` for CustomScript or Combined/IndividualWithRestart modes.
- Use `jq -n --arg script "$SCRIPT" ...` to safely escape the PowerShell script — never manually
  JSON-encode a script string.

Returns: `{ payload: {id, name, ...}, job: {id, status} }`

### Update

```
PATCH /api/v1/scripted-actions/{id}
Content-Type: application/json
```

Same body as Create. All fields are replaced — fetch current values first if you only want to
update the script body.

Returns: `{ payload: {id, name, ...}, job: {id, status} }`

### Delete

```
DELETE /api/v1/scripted-actions/{id}
Content-Type: application/json

{"force": true}
```

**Both** the `Content-Type: application/json` header AND the `{"force": true}` body are required:
- Missing header → 415 Unsupported Media Type
- Empty/missing body → 400 "A non-empty request body is required"
- Body without `force` field → 400 "The Force field is required"

Returns: `{ job: {id, status: "Completed"} }`

---

## Execution

### Execute Runbook (not host-pool bound)

```
POST /api/v1/scripted-actions/{id}/execution
Content-Type: application/json
```

```json
{
  "subscriptionId": "00000000-0000-0000-0000-000000000000",
  "adConfigId": null,
  "minutesToWait": 90,
  "paramsBindings": {
    "ParamName": { "value": "param-value", "isSecure": false },
    "SecureParam": { "value": "secret-variable-name", "isSecure": true }
  }
}
```

**Field rules:**
- `subscriptionId`: **required** — the Azure subscription to run against
- `minutesToWait`: integer, **10–180** — required, not optional
- `paramsBindings`: each value is `{"value": "string", "isSecure": bool}`. `isSecure: true` means
  the value is a Key Vault secure variable name, not the actual value.

Returns: `{ id: <jobId>, jobType: "RunAzureRunbook", jobStatus: "Pending", ... }`

### Execute on Host Pool (host-pool bound, no paramsBindings)

```
POST /api/v1/arm/hostpool/{sub}/{rg}/{hp}/script-execution
```

Used when the script is run in a host pool context (CustomScript or runbook attached to a pool).
Does **not** support `paramsBindings` — use the runbook execution endpoint above if you need
runtime parameters.

**Request body:**
```json
{
  "jobPayload": {
    "config": {
      "activeDirectoryId": null,
      "scriptedActions": [
        {
          "type": "Action",
          "id": 123,
          "params": {},
          "groupParams": {}
        }
      ]
    },
    "bulkJobParams": {
      "restartVms": true,
      "excludeNotRunning": false,
      "sessionHostsToProcessNames": ["host-fqdn.domain.com"],
      "enableDrainMode": false,
      "taskParallelism": 5,
      "countFailedTaskToStopWork": 1,
      "minutesBeforeRemove": null,
      "message": null
    }
  },
  "failurePolicy": null
}
```

**Important notes:**
- Host names in `sessionHostsToProcessNames` must be FQDNs (e.g., `AD-HP-e43a.entse4.local`)
- The scripted action must be associated with the host pool (via onCreate/onStart lifecycle events)
  or the hosts will be filtered out as "unassociated"
- `sessionHostsToProcessNames: null` runs on all hosts in the pool

---

## Job Polling

```
GET /api/v1/job/{jobId}
```

Returns: `{ id, jobType, jobStatus, jobCategory, ... }`

Job status lifecycle: `Pending` → `Running` → `Completed` | `Failed`

```
GET /api/v1/job/{jobId}/tasks
```

Returns array of task objects with `name`, `status`, `resultPlain` (the script stdout/stderr).

**Note on CustomScript logs**: For Windows (CustomScript) scripted actions, the full script
output is written to a transcript log on the VM at
`C:\Windows\Temp\NMWLogs\ScriptedActions\<script-name>-<timestamp>.log`. The API's `job-output`
only shows what was written to stdout during execution. To retrieve the full transcript, you can:

1. Use the NME UI to upload logs to an Azure storage account
2. Access the VM directly and read the log file
3. Create a separate scripted action to upload logs to storage

To extract runbook output from a failed job:
```bash
curl -s -H "Authorization: Bearer $TOKEN" "${NME_BASE_URL}/api/v1/job/${JOB_ID}/tasks" \
  | jq -r '.[] | select(.status == "Failed") | .resultPlain'
```

---

## Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| 405 on GET `/{id}` | Single-item GET not supported | Use list + filter |
| 415 on DELETE | Missing `Content-Type: application/json` | Add header |
| 400 "non-empty body required" | DELETE sent without body | Add `-d '{}'` |
| 400 "Force field required" | DELETE body missing `force` | Use `-d '{"force": true}'` |
| 400 "MinutesToWait must be between 10 and 180" | Missing or out-of-range `minutesToWait` | Set to integer 10–180 |
| 400 "SubscriptionId required" | Missing `subscriptionId` in execute body | Add subscription ID |
| 400 "Parameter 'X' not found in param block" | CustomScript with variables but no `param()` | Add matching `param()` block |
| Job fails instantly | Script parse error or wrong execution environment | Check script syntax; verify AzureAutomation scripts don't use CustomScript context |
