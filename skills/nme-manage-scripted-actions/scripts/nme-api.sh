#!/usr/bin/env bash
# NME REST API helper for scripted actions
#
# Required environment variables:
#   NME_BASE_URL      https://<nme-instance>
#   NME_CLIENT_ID     OAuth2 client/app ID
#   NME_CLIENT_SECRET OAuth2 client secret
#   NME_TENANT_ID     Entra tenant ID
#   NME_SCOPE         api://<nme-app-id>/.default

set -euo pipefail

# ---------------------------------------------------------------------------
# Validate environment
# ---------------------------------------------------------------------------
MISSING=()
for var in NME_BASE_URL NME_CLIENT_ID NME_CLIENT_SECRET NME_TENANT_ID NME_SCOPE; do
  [[ -z "${!var:-}" ]] && MISSING+=("$var")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: Missing required environment variables: ${MISSING[*]}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Token
# ---------------------------------------------------------------------------
get_token() {
  curl -s -X POST \
    "https://login.microsoftonline.com/${NME_TENANT_ID}/oauth2/v2.0/token" \
    -d "grant_type=client_credentials&client_id=${NME_CLIENT_ID}&client_secret=${NME_CLIENT_SECRET}&scope=${NME_SCOPE}" \
    | jq -r '.access_token'
}

TOKEN=$(get_token)
if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "ERROR: Failed to obtain access token. Check NME_CLIENT_ID, NME_CLIENT_SECRET, NME_TENANT_ID, NME_SCOPE." >&2
  exit 1
fi

CMD="${1:-help}"
shift || true

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
case "$CMD" in

  # ---- list [filter] -------------------------------------------------------
  list)
    FILTER="${1:-}"
    RESULT=$(curl -s -H "Authorization: Bearer $TOKEN" "${NME_BASE_URL}/api/v1/scripted-actions")
    if [[ -n "$FILTER" ]]; then
      echo "$RESULT" | jq --arg f "$FILTER" \
        '[.[]? | select(.name | ascii_downcase | contains($f | ascii_downcase)) | {id, name, executionEnvironment, executionMode, tags}]'
    else
      echo "$RESULT" | jq '[.[]? | {id, name, executionEnvironment, executionMode, tags}]'
    fi
    ;;

  # ---- get <id> ------------------------------------------------------------
  # Note: GET /api/v1/scripted-actions/{id} returns 405 — always list+filter
  get)
    ID="${1:?Usage: get <id>}"
    curl -s -H "Authorization: Bearer $TOKEN" "${NME_BASE_URL}/api/v1/scripted-actions" \
      | jq --argjson id "$ID" '.[] | select(.id == $id)'
    ;;

  # ---- create <file.ps1> [options] -----------------------------------------
  create)
    SCRIPT_FILE="${1:?Usage: create <script.ps1> [--name ...] [--env ...] [--mode ...] [--tags ...] [--desc ...]}"
    shift
    # Defaults — read from script header comments if present
    NAME="$(basename "$SCRIPT_FILE" .ps1)"
    ENV="AzureAutomation"
    MODE="Individual"
    TAGS="[]"
    DESC=""

    # Parse header metadata from script
    HEADER_DESC=$(grep -m1 '^#description:' "$SCRIPT_FILE" 2>/dev/null | sed 's/^#description:[[:space:]]*//' || true)
    HEADER_MODE=$(grep -m1 '^#execution mode:' "$SCRIPT_FILE" 2>/dev/null | sed 's/^#execution mode:[[:space:]]*//' || true)
    HEADER_TAGS=$(grep -m1 '^#tags:' "$SCRIPT_FILE" 2>/dev/null | sed 's/^#tags:[[:space:]]*//' || true)
    [[ -n "$HEADER_DESC" ]] && DESC="$HEADER_DESC"
    [[ -n "$HEADER_MODE" ]] && MODE="$HEADER_MODE"
    if [[ -n "$HEADER_TAGS" ]]; then
      TAGS=$(echo "$HEADER_TAGS" | jq -R 'split(", ")')
    fi

    # Parse CLI flags (override header values)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --name)  NAME="$2";  shift 2 ;;
        --env)   ENV="$2";   shift 2 ;;
        --mode)  MODE="$2";  shift 2 ;;
        --tags)  TAGS=$(echo "$2" | jq -R 'split(", ")'); shift 2 ;;
        --desc)  DESC="$2";  shift 2 ;;
        *) shift ;;
      esac
    done

    SCRIPT=$(cat "$SCRIPT_FILE")

    # executionTimeout: only valid for AzureAutomation + Individual
    if [[ "$ENV" == "AzureAutomation" && "$MODE" == "Individual" ]]; then
      TIMEOUT=90
      jq -n \
        --arg name "$NAME" \
        --arg script "$SCRIPT" \
        --arg env "$ENV" \
        --arg mode "$MODE" \
        --argjson timeout "$TIMEOUT" \
        --argjson tags "$TAGS" \
        --arg desc "$DESC" \
        '{name: $name, script: $script, executionEnvironment: $env, executionMode: $mode, executionTimeout: $timeout, tags: $tags, description: $desc}'
    else
      jq -n \
        --arg name "$NAME" \
        --arg script "$SCRIPT" \
        --arg env "$ENV" \
        --arg mode "$MODE" \
        --argjson tags "$TAGS" \
        --arg desc "$DESC" \
        '{name: $name, script: $script, executionEnvironment: $env, executionMode: $mode, tags: $tags, description: $desc}'
    fi \
    | curl -s -X POST "${NME_BASE_URL}/api/v1/scripted-actions" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d @-
    ;;

  # ---- update <id> <file.ps1> [options] ------------------------------------
  update)
    ID="${1:?Usage: update <id> <script.ps1>}"
    SCRIPT_FILE="${2:?Usage: update <id> <script.ps1>}"
    shift 2

    # Fetch current metadata from NME
    CURRENT=$(curl -s -H "Authorization: Bearer $TOKEN" "${NME_BASE_URL}/api/v1/scripted-actions" \
      | jq --argjson id "$ID" '.[] | select(.id == $id)')

    if [[ -z "$CURRENT" || "$CURRENT" == "null" ]]; then
      echo "ERROR: Scripted action $ID not found." >&2
      exit 1
    fi

    NAME=$(echo "$CURRENT"    | jq -r '.name')
    ENV=$(echo "$CURRENT"     | jq -r '.executionEnvironment')
    MODE=$(echo "$CURRENT"    | jq -r '.executionMode')
    TIMEOUT=$(echo "$CURRENT" | jq -r '.executionTimeout')
    TAGS=$(echo "$CURRENT"    | jq '[.tags[]?]')
    DESC=$(echo "$CURRENT"    | jq -r '.description // ""')

    # Allow overrides via CLI flags
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --name)  NAME="$2";  shift 2 ;;
        --env)   ENV="$2";   shift 2 ;;
        --mode)  MODE="$2";  shift 2 ;;
        --tags)  TAGS=$(echo "$2" | jq -R 'split(", ")'); shift 2 ;;
        --desc)  DESC="$2";  shift 2 ;;
        *) shift ;;
      esac
    done

    SCRIPT=$(cat "$SCRIPT_FILE")

    jq -n \
      --arg name "$NAME" \
      --arg script "$SCRIPT" \
      --arg env "$ENV" \
      --arg mode "$MODE" \
      --argjson timeout "$TIMEOUT" \
      --argjson tags "$TAGS" \
      --arg desc "$DESC" \
      '{name: $name, script: $script, executionEnvironment: $env, executionMode: $mode, executionTimeout: $timeout, tags: $tags, description: $desc}' \
    | curl -s -X PATCH "${NME_BASE_URL}/api/v1/scripted-actions/${ID}" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d @-
    ;;

  # ---- delete <id> ---------------------------------------------------------
  delete)
    ID="${1:?Usage: delete <id>}"
    # NOTE: requires Content-Type header + {"force":true} body — 415 without header, 400 without body
    curl -s -X DELETE "${NME_BASE_URL}/api/v1/scripted-actions/${ID}" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"force": true}'
    ;;

  # ---- execute <id> --sub <subId> [--param key=value ...] ------------------
  # Execute on Azure Automation (runbook) scripted actions
  execute)
    ID="${1:?Usage: execute <id> --sub <subscriptionId> [--param key=value ...]}"
    shift
    SUB=""
    PARAMS="{}"
    WAIT=90

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --sub)   SUB="$2"; shift 2 ;;
        --wait)  WAIT="$2"; shift 2 ;;
        --param)
          KEY="${2%%=*}"
          VAL="${2#*=}"
          PARAMS=$(echo "$PARAMS" | jq --arg k "$KEY" --arg v "$VAL" '.[$k] = {value: $v, isSecure: false}')
          shift 2
          ;;
        --secure-param)
          KEY="${2%%=*}"
          VAL="${2#*=}"
          PARAMS=$(echo "$PARAMS" | jq --arg k "$KEY" --arg v "$VAL" '.[$k] = {value: $v, isSecure: true}')
          shift 2
          ;;
        *) shift ;;
      esac
    done

    if [[ -z "$SUB" ]]; then
      echo "ERROR: --sub <subscriptionId> is required for execute." >&2
      exit 1
    fi

    jq -n \
      --arg sub "$SUB" \
      --argjson wait "$WAIT" \
      --argjson params "$PARAMS" \
      '{subscriptionId: $sub, adConfigId: null, minutesToWait: $wait, paramsBindings: $params}' \
    | curl -s -X POST "${NME_BASE_URL}/api/v1/scripted-actions/${ID}/execution" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d @-
    ;;

  # ---- execute-on-hostpool <id> [options] ----------------------------------
  # Execute on CustomScript (Windows) scripted actions in a host pool context
  # Host FQDNs are required (e.g., AD-HP-e43a.entse4.local, not AD-HP-e43a)
  execute-on-hostpool)
    ID="${1:-}"
    if [[ -z "$ID" ]]; then
      echo "ERROR: Scripted action ID required." >&2
      echo "Usage: execute-on-hostpool <id> --sub <subscriptionId> --rg <resourceGroup> --hostpool <hostPoolName> [--host <fqdn> ...]" >&2
      exit 1
    fi
    shift

    # Prompt for missing context
    SUB="${SUB:-}"
    RG="${RG:-}"
    HOSTPOOL="${HOSTPOOL:-}"
    HOSTS="[]"
    PARAMS="{}"
    RESTART=true
    EXCLUDE_NOT_RUNNING=false
    PARALLELISM=5
    FAIL_COUNT=1
    DRAIN=false

    # Get context from args or prompt
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --sub)   SUB="$2"; shift 2 ;;
        --rg)    RG="$2"; shift 2 ;;
        --hostpool) HOSTPOOL="$2"; shift 2 ;;
        --host)
          # Host FQDN is required (e.g., AD-HP-e43a.entse4.local)
          HOSTS=$(echo "$HOSTS" | jq --arg h "$2" '. += [$h]')
          shift 2
          ;;
        --no-restart) RESTART=false; shift ;;
        --exclude-not-running) EXCLUDE_NOT_RUNNING=true; shift ;;
        --parallelism) PARALLELISM="$2"; shift 2 ;;
        --fail-count) FAIL_COUNT="$2"; shift 2 ;;
        --drain) DRAIN=true; shift ;;
        *) shift ;;
      esac
    done

    # Prompt for missing values
    if [[ -z "$SUB" ]]; then
      read -r -p "Enter subscription ID: " SUB
    fi
    if [[ -z "$RG" ]]; then
      read -r -p "Enter resource group: " RG
    fi
    if [[ -z "$HOSTPOOL" ]]; then
      read -r -p "Enter host pool name: " HOSTPOOL
    fi
    if [[ "${HOSTS}" == "[]" ]]; then
      read -r -p "Enter host FQDN(s) (comma-separated, e.g., AD-HP-e43a.entse4.local): " HOSTS_INPUT
      HOSTS=$(echo "$HOSTS_INPUT" | tr ',' '\n' | jq -R -s 'split("\n") | map(select(length > 0))')
    fi

    if [[ -z "$SUB" || -z "$RG" || -z "$HOSTPOOL" ]]; then
      echo "ERROR: subscription ID, resource group, and host pool name are required." >&2
      exit 1
    fi

    # Build the request body for host pool script execution
    PAYLOAD=$(jq -n \
      --argjson actionId "$ID" \
      --argjson hosts "$HOSTS" \
      --argjson restart "$RESTART" \
      --argjson exclude "$EXCLUDE_NOT_RUNNING" \
      --argjson parallelism "$PARALLELISM" \
      --argjson failCount "$FAIL_COUNT" \
      --argjson drain "$DRAIN" \
      --argjson params "$PARAMS" \
      '{
        jobPayload: {
          config: {
            activeDirectoryId: null,
            scriptedActions: [
              {
                type: "Action",
                id: $actionId,
                params: $params,
                groupParams: {}
              }
            ]
          },
          bulkJobParams: {
            restartVms: $restart,
            excludeNotRunning: $exclude,
            sessionHostsToProcessNames: $hosts,
            enableDrainMode: $drain,
            taskParallelism: $parallelism,
            countFailedTaskToStopWork: $failCount,
            minutesBeforeRemove: null,
            message: null
          }
        },
        failurePolicy: null
      }')

    RESPONSE=$(echo "$PAYLOAD" | curl -s -X POST "${NME_BASE_URL}/api/v1/arm/hostpool/${SUB}/${RG}/${HOSTPOOL}/script-execution" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d @-)

    echo "$RESPONSE" | jq '.'

    # Check if job was created and warn about log upload for CustomScript
    JOB_ID=$(echo "$RESPONSE" | jq -r '.job.id // empty')
    if [[ -n "$JOB_ID" ]]; then
      echo ""
      echo "Job $JOB_ID created successfully."
      echo ""
      echo "NOTE: For Windows (CustomScript) scripted actions, full logs are stored locally"
      echo "      on the VM at: C:\Windows\Temp\NMWLogs\ScriptedActions\"
      echo "      Use the NME UI to upload logs to a storage account for access."
      echo "      Run 'nme-api.sh job-output $JOB_ID' to view stdout from the execution."
    fi
    ;;
      fi
    fi
    ;;

  # ---- job <jobId> ---------------------------------------------------------
  job)
    ID="${1:?Usage: job <jobId>}"
    curl -s -H "Authorization: Bearer $TOKEN" "${NME_BASE_URL}/api/v1/job/${ID}" | jq '.'
    ;;

  # ---- job-output <jobId> --------------------------------------------------
  job-output)
    ID="${1:?Usage: job-output <jobId>}"
    JOBTASKS=$(curl -s -H "Authorization: Bearer $TOKEN" "${NME_BASE_URL}/api/v1/job/${ID}/tasks")

    # Check if any task failed
    FAILED=$(echo "$JOBTASKS" | jq '[.[] | select(.status == "Failed")] | length')
    if [[ "$FAILED" -gt 0 ]]; then
      echo "WARNING: Job has $FAILED failed task(s). For Windows (CustomScript) scripted actions,"
      echo "         full logs are stored locally on the VM at:"
      echo "         C:\Windows\Temp\NMWLogs\ScriptedActions\"
      echo "         Use the NME UI to upload logs to a storage account for access."
      echo ""
    fi

    echo "$JOBTASKS" | jq -r '.[] | select(.resultPlain != null and .resultPlain != "") | "[\(.status)] \(.name)\n\(.resultPlain)"'
    ;;

  # ---- hosts <subscriptionId> <resourceGroup> <hostPoolName> ---------------
  # List hosts in a host pool with their FQDNs
  hosts)
    SUB="${1:?Usage: hosts <subscriptionId> <resourceGroup> <hostPoolName>}"
    shift
    RG="${1:?Usage: hosts <subscriptionId> <resourceGroup> <hostPoolName>}"
    shift
    HOSTPOOL="${1:?Usage: hosts <subscriptionId> <resourceGroup> <hostPoolName>}"
    shift
    curl -s -H "Authorization: Bearer $TOKEN" "${NME_BASE_URL}/api/v1/arm/hostpool/${SUB}/${RG}/${HOSTPOOL}/host" | jq '.[] | {hostName: .hostName, powerState: .powerState, status: .status}'
    ;;

  # ---- help ----------------------------------------------------------------
  *)
    cat <<'EOF'
Usage: nme-api.sh <command> [args]

Commands:
  list [filter]                    List all scripted actions (optionally filter by name)
  get <id>                         Show full details of a scripted action by ID
  create <file.ps1> [options]      Create a new scripted action from a .ps1 file
  update <id> <file.ps1> [opts]    Update an existing scripted action's script body
  delete <id>                      Delete a scripted action
  execute <id> --sub <subId>       Execute a runbook scripted action
           [--param key=value ...]   Runtime parameters (repeat for each param)
           [--secure-param k=v ...]  Secure runtime parameters
           [--wait <minutes>]        minutesToWait (default: 90, range: 10-180)
  execute-on-hostpool <id>         Execute a Windows scripted action on a host pool
           --sub <subId>           Azure subscription ID
           --rg <resourceGroup>    Resource group containing the host pool
           --hostpool <name>       Host pool name
           --host <fqdn> ...       Specific hosts to run on (FQDN required, e.g., AD-HP-e43a.entse4.local)
           [--no-restart]          Don't restart VMs before running
           [--exclude-not-running] Skip VMs that aren't running
           [--parallelism <n>]     Max concurrent tasks (default: 5)
           [--fail-count <n>]      Fail job after N failures (default: 1)
           [--drain]               Enable drain mode
  hosts <subId> <rg> <hostPool>    List hosts in a host pool with their FQDNs
  job <jobId>                      Get status of an async NME job
  job-output <jobId>               Get full output of a completed/failed job

create/update options:
  --name "Display Name"
  --env  AzureAutomation | CustomScript
  --mode Individual | Combined | IndividualWithRestart
  --tags "Tag1, Tag2"
  --desc "Description"
EOF
    ;;

esac
