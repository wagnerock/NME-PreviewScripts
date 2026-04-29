#!/usr/bin/env pwsh
# NME REST API helper for scripted actions (PowerShell 7+)
#
# Required environment variables:
#   NME_BASE_URL      https://<nme-instance>
#   NME_CLIENT_ID     OAuth2 client/app ID
#   NME_CLIENT_SECRET OAuth2 client secret
#   NME_TENANT_ID     Entra tenant ID
#   NME_SCOPE         api://<nme-app-id>/.default

param(
    [Parameter(Position=0)]
    [string]$Command = 'help',
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$RemainingArgs = @()
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Validate environment
# ---------------------------------------------------------------------------
$required = @('NME_BASE_URL','NME_CLIENT_ID','NME_CLIENT_SECRET','NME_TENANT_ID','NME_SCOPE')
$missing  = $required | Where-Object { -not [Environment]::GetEnvironmentVariable($_) }
if ($missing) {
    Write-Error "Missing required environment variables: $($missing -join ', ')"
    exit 1
}

$baseUrl      = $env:NME_BASE_URL
$clientId     = $env:NME_CLIENT_ID
$clientSecret = $env:NME_CLIENT_SECRET
$tenantId     = $env:NME_TENANT_ID
$scope        = $env:NME_SCOPE

# ---------------------------------------------------------------------------
# Token
# ---------------------------------------------------------------------------
$tokenResponse = Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
    -ContentType 'application/x-www-form-urlencoded' `
    -Body @{
        grant_type    = 'client_credentials'
        client_id     = $clientId
        client_secret = $clientSecret
        scope         = $scope
    }

$token = $tokenResponse.access_token
if (-not $token) {
    Write-Error "Failed to obtain access token. Check NME_CLIENT_ID, NME_CLIENT_SECRET, NME_TENANT_ID, NME_SCOPE."
    exit 1
}

$authHeader = @{ Authorization = "Bearer $token" }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-AllActions {
    Invoke-RestMethod -Uri "$baseUrl/api/v1/scripted-actions" -Headers $authHeader
}

function Test-ApiError {
    param([object]$Response, [string]$Operation)
    $msg = $Response.errorMessage
    if (-not $msg) { return }
    if ($msg -eq 'GithubSha') {
        Write-Error "Scripted action is synced from GitHub and cannot be modified via the API."
        Write-Host "GITHUB_SYNCED"
        exit 2
    }
    Write-Error "${Operation} failed: $msg"
    exit 1
}

function Get-ScriptHeader {
    param([string]$Content, [string]$Key)
    if ($Content -match "(?m)^#${Key}:\s*(.+)") { return $Matches[1].Trim() }
    return $null
}

function Get-EnvFromScript {
    param([string]$Content, [string]$ScriptFile)
    $h = Get-ScriptHeader $Content 'execution environment'
    if ($h) { return $h }
    switch (Split-Path (Split-Path $ScriptFile -Parent) -Leaf) {
        'windows-scripts' { return 'CustomScript' }
        'azure-runbooks'  { return 'AzureAutomation' }
        default           { return 'AzureAutomation' }
    }
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
switch ($Command) {

    # ---- list [filter] -------------------------------------------------------
    'list' {
        $filter  = if ($RemainingArgs.Count -gt 0) { $RemainingArgs[0] } else { '' }
        $actions = Get-AllActions
        if ($filter) {
            $actions = $actions | Where-Object { $_.name -like "*$filter*" }
        }
        $actions | Select-Object id, name, executionEnvironment, executionMode, tags | Format-Table -AutoSize
    }

    # ---- get <id> ------------------------------------------------------------
    # Note: GET /api/v1/scripted-actions/{id} returns 405 — always list+filter
    'get' {
        if (-not $RemainingArgs) { throw "Usage: get <id>" }
        $id = [int]$RemainingArgs[0]
        Get-AllActions | Where-Object { $_.id -eq $id } | ConvertTo-Json -Depth 10
    }

    # ---- create <file.ps1> [options] -----------------------------------------
    'create' {
        if (-not $RemainingArgs) { throw "Usage: create <script.ps1> [options]" }
        $scriptFile = $RemainingArgs[0]
        $rest       = @($RemainingArgs[1..($RemainingArgs.Count-1)])

        $content = Get-Content $scriptFile -Raw
        $name    = [System.IO.Path]::GetFileNameWithoutExtension($scriptFile)
        $env_    = Get-EnvFromScript $content $scriptFile
        $mode    = (Get-ScriptHeader $content 'execution mode') ?? 'Individual'
        $tagsRaw = Get-ScriptHeader $content 'tags'
        $tags    = if ($tagsRaw) { $tagsRaw -split ',\s*' } else { @() }
        $desc    = (Get-ScriptHeader $content 'description') ?? ''

        for ($i = 0; $i -lt $rest.Count; $i++) {
            switch ($rest[$i]) {
                '--name' { $name = $rest[++$i] }
                '--env'  { $env_ = $rest[++$i] }
                '--mode' { $mode = $rest[++$i] }
                '--tags' { $tags = $rest[++$i] -split ',\s*' }
                '--desc' { $desc = $rest[++$i] }
            }
        }

        $body = @{
            name                 = $name
            script               = $content
            executionEnvironment = $env_
            executionMode        = $mode
            tags                 = $tags
            description          = $desc
        }
        # executionTimeout only valid for AzureAutomation + Individual
        if ($env_ -eq 'AzureAutomation' -and $mode -eq 'Individual') {
            $body['executionTimeout'] = 90
        }

        $response = Invoke-RestMethod -Method Post -Uri "$baseUrl/api/v1/scripted-actions" `
            -Headers $authHeader -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 5)
        Test-ApiError $response 'Create scripted action'
        $response | ConvertTo-Json -Depth 10
    }

    # ---- update <id> <file.ps1> [options] ------------------------------------
    'update' {
        if ($RemainingArgs.Count -lt 2) { throw "Usage: update <id> <script.ps1>" }
        $id         = [int]$RemainingArgs[0]
        $scriptFile = $RemainingArgs[1]
        $rest       = @($RemainingArgs[2..($RemainingArgs.Count-1)])

        $current = Get-AllActions | Where-Object { $_.id -eq $id }
        if (-not $current) {
            Write-Error "Scripted action $id not found."
            exit 1
        }

        $name    = $current.name
        $env_    = $current.executionEnvironment
        $mode    = $current.executionMode
        $timeout = $current.executionTimeout
        $tags    = @($current.tags)
        $desc    = if ($current.description) { $current.description } else { '' }

        # Override from script file headers (take precedence over NME metadata)
        $content    = Get-Content $scriptFile -Raw
        $headerEnv  = Get-ScriptHeader $content 'execution environment'
        $headerMode = Get-ScriptHeader $content 'execution mode'
        $headerTags = Get-ScriptHeader $content 'tags'
        $headerDesc = Get-ScriptHeader $content 'description'

        if ($headerEnv) {
            $env_ = $headerEnv
        } else {
            switch (Split-Path (Split-Path $scriptFile -Parent) -Leaf) {
                'windows-scripts' { $env_ = 'CustomScript' }
                'azure-runbooks'  { $env_ = 'AzureAutomation' }
            }
        }
        if ($headerMode) { $mode = $headerMode }
        if ($headerDesc) { $desc = $headerDesc }
        if ($headerTags) { $tags = $headerTags -split ',\s*' }

        # CLI flag overrides (highest precedence)
        for ($i = 0; $i -lt $rest.Count; $i++) {
            switch ($rest[$i]) {
                '--name' { $name = $rest[++$i] }
                '--env'  { $env_ = $rest[++$i] }
                '--mode' { $mode = $rest[++$i] }
                '--tags' { $tags = $rest[++$i] -split ',\s*' }
                '--desc' { $desc = $rest[++$i] }
            }
        }

        $body = @{
            name                 = $name
            script               = $content
            executionEnvironment = $env_
            executionMode        = $mode
            tags                 = $tags
            description          = $desc
        }
        if ($env_ -eq 'AzureAutomation' -and $mode -eq 'Individual') {
            $body['executionTimeout'] = $timeout
        }

        $response = Invoke-RestMethod -Method Patch -Uri "$baseUrl/api/v1/scripted-actions/$id" `
            -Headers $authHeader -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 5)
        if ($response.errorMessage -eq 'GithubSha') {
            Write-Error "Scripted action $id is synced from GitHub and cannot be modified via the API."
            Write-Host "GITHUB_SYNCED"
            exit 2
        }
        # NME bug: if a CustomScript record has executionTimeout set in the DB, the PATCH API
        # rejects all updates with an "Execution timeout" validation error even when executionTimeout
        # is not included in the request. Workaround: delete the corrupted record and recreate it.
        if ($response.errorMessage -and $response.errorMessage -match 'execution timeout') {
            Write-Warning "PATCH rejected due to NME executionTimeout bug on record $id. Falling back to delete + create..."
            $delResponse = Invoke-RestMethod -Method Delete -Uri "$baseUrl/api/v1/scripted-actions/$id" `
                -Headers $authHeader -ContentType 'application/json' -Body '{"force":true}'
            Test-ApiError $delResponse 'Delete (executionTimeout fallback)'
            # NME may take a moment to free the name after delete completes — retry up to 3 times
            $createResponse = $null
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                Start-Sleep -Seconds 2
                $createResponse = Invoke-RestMethod -Method Post -Uri "$baseUrl/api/v1/scripted-actions" `
                    -Headers $authHeader -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 5)
                if (-not $createResponse.errorMessage) {
                    $createResponse | ConvertTo-Json -Depth 10
                    exit 0
                }
                Write-Warning "  Attempt $attempt failed: $($createResponse.errorMessage)"
            }
            Test-ApiError $createResponse 'Create (executionTimeout fallback)'
        }
        Test-ApiError $response 'Update scripted action'
        $response | ConvertTo-Json -Depth 10
    }

    # ---- delete <id> ---------------------------------------------------------
    'delete' {
        if (-not $RemainingArgs) { throw "Usage: delete <id>" }
        $id = $RemainingArgs[0]
        # NOTE: Content-Type header + {"force":true} body are both required
        $response = Invoke-RestMethod -Method Delete -Uri "$baseUrl/api/v1/scripted-actions/$id" `
            -Headers $authHeader -ContentType 'application/json' -Body '{"force":true}'
        Test-ApiError $response 'Delete scripted action'
        $response | ConvertTo-Json -Depth 10
    }

    # ---- execute <id> --sub <subId> [--param key=value ...] ------------------
    # Execute on Azure Automation (runbook) scripted actions
    'execute' {
        if (-not $RemainingArgs) { throw "Usage: execute <id> --sub <subscriptionId>" }
        $id   = $RemainingArgs[0]
        $rest = @($RemainingArgs[1..($RemainingArgs.Count-1)])

        $sub    = ''
        $wait   = 90
        $params = @{}

        for ($i = 0; $i -lt $rest.Count; $i++) {
            switch ($rest[$i]) {
                '--sub'  { $sub  = $rest[++$i] }
                '--wait' { $wait = [int]$rest[++$i] }
                '--param' {
                    $kv = $rest[++$i]; $k = $kv.Split('=')[0]; $v = $kv.Substring($k.Length + 1)
                    $params[$k] = @{ value = $v; isSecure = $false }
                }
                '--secure-param' {
                    $kv = $rest[++$i]; $k = $kv.Split('=')[0]; $v = $kv.Substring($k.Length + 1)
                    $params[$k] = @{ value = $v; isSecure = $true }
                }
            }
        }

        if (-not $sub) {
            Write-Error "--sub <subscriptionId> is required for execute."
            exit 1
        }

        $body = @{
            subscriptionId = $sub
            adConfigId     = $null
            minutesToWait  = $wait
            paramsBindings = $params
        } | ConvertTo-Json -Depth 5

        $response = Invoke-RestMethod -Method Post -Uri "$baseUrl/api/v1/scripted-actions/$id/execution" `
            -Headers $authHeader -ContentType 'application/json' -Body $body
        Test-ApiError $response 'Execute scripted action'
        $response | ConvertTo-Json -Depth 10
    }

    # ---- execute-on-hostpool <id> [options] ----------------------------------
    # Execute on CustomScript (Windows) scripted actions in a host pool context
    # Host FQDNs are required (e.g., AD-HP-e43a.entse4.local, not AD-HP-e43a)
    'execute-on-hostpool' {
        if (-not $RemainingArgs) {
            Write-Error "Scripted action ID required.`nUsage: execute-on-hostpool <id> --sub <subscriptionId> --rg <resourceGroup> --hostpool <hostPoolName> [--host <fqdn> ...]"
            exit 1
        }
        $id   = $RemainingArgs[0]
        $rest = @($RemainingArgs[1..($RemainingArgs.Count-1)])

        $sub       = ''
        $rg        = ''
        $hostpool  = ''
        $hosts     = [System.Collections.Generic.List[string]]::new()
        $params    = @{}
        $restart   = $true
        $exclude   = $false
        $parallel  = 5
        $failCount = 1
        $drain     = $false

        for ($i = 0; $i -lt $rest.Count; $i++) {
            switch ($rest[$i]) {
                '--sub'                 { $sub       = $rest[++$i] }
                '--rg'                  { $rg        = $rest[++$i] }
                '--hostpool'            { $hostpool  = $rest[++$i] }
                '--host'                { $hosts.Add($rest[++$i]) }
                '--no-restart'          { $restart   = $false }
                '--exclude-not-running' { $exclude   = $true }
                '--parallelism'         { $parallel  = [int]$rest[++$i] }
                '--fail-count'          { $failCount = [int]$rest[++$i] }
                '--drain'               { $drain     = $true }
                '--param' {
                    $kv = $rest[++$i]; $k = $kv.Split('=')[0]; $v = $kv.Substring($k.Length + 1)
                    $params[$k] = @{ value = $v; isSecure = $false }
                }
                '--secure-param' {
                    $kv = $rest[++$i]; $k = $kv.Split('=')[0]; $v = $kv.Substring($k.Length + 1)
                    $params[$k] = @{ value = $v; isSecure = $true }
                }
            }
        }

        if (-not $sub)      { $sub      = Read-Host 'Enter subscription ID' }
        if (-not $rg)       { $rg       = Read-Host 'Enter resource group' }
        if (-not $hostpool) { $hostpool = Read-Host 'Enter host pool name' }
        if ($hosts.Count -eq 0) {
            $input = Read-Host 'Enter host FQDN(s) (comma-separated, e.g., AD-HP-e43a.entse4.local)'
            $input -split ',\s*' | Where-Object { $_ } | ForEach-Object { $hosts.Add($_.Trim()) }
        }

        if (-not $sub -or -not $rg -or -not $hostpool) {
            Write-Error "subscription ID, resource group, and host pool name are required.`nProvide them via flags: --sub <subscriptionId> --rg <resourceGroup> --hostpool <hostPoolName>"
            exit 1
        }

        # Validate host FQDN format
        $invalid = $hosts | Where-Object { -not $_.Contains('.') }
        if ($invalid) {
            Write-Error "Host name(s) must be a full FQDN (e.g., AD-HP-e43a.entse4.local), not just the VM name.`nInvalid: $($invalid -join ', ')"
            exit 1
        }

        $body = @{
            jobPayload = @{
                config = @{
                    activeDirectoryId = $null
                    scriptedActions   = @(
                        @{
                            type        = 'Action'
                            id          = [int]$id
                            params      = $params
                            groupParams = @{}
                        }
                    )
                }
                bulkJobParams = @{
                    restartVms                 = $restart
                    excludeNotRunning          = $exclude
                    sessionHostsToProcessNames = $hosts.ToArray()
                    enableDrainMode            = $drain
                    taskParallelism            = $parallel
                    countFailedTaskToStopWork  = $failCount
                    minutesBeforeRemove        = $null
                    message                    = $null
                }
            }
            failurePolicy = $null
        } | ConvertTo-Json -Depth 10

        $response = Invoke-RestMethod -Method Post `
            -Uri "$baseUrl/api/v1/arm/hostpool/$sub/$rg/$hostpool/script-execution" `
            -Headers $authHeader -ContentType 'application/json' -Body $body

        $response | ConvertTo-Json -Depth 10

        if ($response.errorMessage) {
            Write-Error "Job creation failed: $($response.errorMessage)"
            exit 1
        }

        $jobId = $response.job.id
        if ($jobId) {
            Write-Host ""
            Write-Host "Job $jobId created successfully."
            Write-Host ""
            Write-Host "NOTE: Script output is not available via the NME API for Windows (CustomScript) actions."
            Write-Host "      To view results, either:"
            Write-Host "        1. Check the NME portal — open the job and expand 'VM Extension Details'"
            Write-Host "        2. Retrieve the Custom Script Extension result via Azure CLI:"
            Write-Host "           az vm extension show --resource-group <rg> --vm-name <vm> \"
            Write-Host "             --name CustomScriptExtension --query 'instanceView.statuses'"
        }
    }

    # ---- job <jobId> ---------------------------------------------------------
    'job' {
        if (-not $RemainingArgs) { throw "Usage: job <jobId>" }
        $id = $RemainingArgs[0]
        Invoke-RestMethod -Uri "$baseUrl/api/v1/job/$id" -Headers $authHeader | ConvertTo-Json -Depth 10
    }

    # ---- job-output <jobId> --------------------------------------------------
    'job-output' {
        if (-not $RemainingArgs) { throw "Usage: job-output <jobId>" }
        $id    = $RemainingArgs[0]
        $tasks = Invoke-RestMethod -Uri "$baseUrl/api/v1/job/$id/tasks" -Headers $authHeader

        $failed = @($tasks | Where-Object { $_.status -eq 'Failed' })
        if ($failed.Count -gt 0) {
            Write-Warning "Job has $($failed.Count) failed task(s). For Windows (CustomScript) scripted actions, full logs are stored locally on the VM at: C:\Windows\Temp\NMWLogs\ScriptedActions\"
            Write-Host ""
        }

        foreach ($t in $tasks) {
            if ($t.resultPlain) {
                Write-Output "[$($t.status)] $($t.name)"
                Write-Output $t.resultPlain
            }
        }
    }

    # ---- hosts <subscriptionId> <resourceGroup> <hostPoolName> ---------------
    # List hosts in a host pool with their FQDNs
    'hosts' {
        if ($RemainingArgs.Count -lt 3) { throw "Usage: hosts <subscriptionId> <resourceGroup> <hostPoolName>" }
        $sub      = $RemainingArgs[0]
        $rg       = $RemainingArgs[1]
        $hostpool = $RemainingArgs[2]
        $result   = Invoke-RestMethod -Uri "$baseUrl/api/v1/arm/hostpool/$sub/$rg/$hostpool/host" -Headers $authHeader
        $result | Select-Object hostName, powerState, status | Format-Table -AutoSize
    }

    # ---- help ----------------------------------------------------------------
    default {
        Write-Output @"
Usage: pwsh nme-api.ps1 <command> [args]

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
"@
    }
}
