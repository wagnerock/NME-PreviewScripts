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
    (Invoke-RestMethod -Uri "$baseUrl/api/v1/scripted-actions" -Headers $authHeader).payload
}

function Parse-Flags {
    param([string[]]$Args, [hashtable]$Vars)
    for ($i = 0; $i -lt $Args.Count; $i++) {
        if ($Vars.ContainsKey($Args[$i])) {
            $Vars[$Args[$i]] = $Args[++$i]
        }
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

        $name = [System.IO.Path]::GetFileNameWithoutExtension($scriptFile)
        $env_ = 'AzureAutomation'
        $mode = 'Individual'
        $tags = @()
        $desc = ''

        # Parse header comments
        $content = Get-Content $scriptFile -Raw
        if ($content -match '(?m)^#description:\s*(.+)')    { $desc = $Matches[1].Trim() }
        if ($content -match '(?m)^#execution mode:\s*(.+)') { $mode = $Matches[1].Trim() }
        if ($content -match '(?m)^#tags:\s*(.+)')           { $tags = $Matches[1].Trim() -split ',\s*' }

        # Parse CLI flags (override header values)
        for ($i = 0; $i -lt $rest.Count; $i++) {
            switch ($rest[$i]) {
                '--name' { $name = $rest[++$i] }
                '--env'  { $env_ = $rest[++$i] }
                '--mode' { $mode = $rest[++$i] }
                '--tags' { $tags = $rest[++$i] -split ',\s*' }
                '--desc' { $desc = $rest[++$i] }
            }
        }

        $timeout = if ($env_ -eq 'AzureAutomation' -and $mode -eq 'Individual') { 90 } else { 0 }

        $body = @{
            name                 = $name
            script               = $content
            executionEnvironment = $env_
            executionMode        = $mode
            executionTimeout     = $timeout
            tags                 = $tags
            description          = $desc
        } | ConvertTo-Json -Depth 5

        Invoke-RestMethod -Method Post -Uri "$baseUrl/api/v1/scripted-actions" `
            -Headers $authHeader -ContentType 'application/json' -Body $body | ConvertTo-Json -Depth 10
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

        # Parse CLI flags
        for ($i = 0; $i -lt $rest.Count; $i++) {
            switch ($rest[$i]) {
                '--name' { $name = $rest[++$i] }
                '--env'  { $env_ = $rest[++$i] }
                '--mode' { $mode = $rest[++$i] }
                '--tags' { $tags = $rest[++$i] -split ',\s*' }
                '--desc' { $desc = $rest[++$i] }
            }
        }

        $content = Get-Content $scriptFile -Raw

        $body = @{
            name                 = $name
            script               = $content
            executionEnvironment = $env_
            executionMode        = $mode
            executionTimeout     = $timeout
            tags                 = $tags
            description          = $desc
        } | ConvertTo-Json -Depth 5

        Invoke-RestMethod -Method Patch -Uri "$baseUrl/api/v1/scripted-actions/$id" `
            -Headers $authHeader -ContentType 'application/json' -Body $body | ConvertTo-Json -Depth 10
    }

    # ---- delete <id> ---------------------------------------------------------
    'delete' {
        if (-not $RemainingArgs) { throw "Usage: delete <id>" }
        $id = $RemainingArgs[0]
        # NOTE: Content-Type header + {"force":true} body are both required
        Invoke-RestMethod -Method Delete -Uri "$baseUrl/api/v1/scripted-actions/$id" `
            -Headers $authHeader -ContentType 'application/json' -Body '{"force":true}' | ConvertTo-Json -Depth 10
    }

    # ---- execute <id> --sub <subId> [--param key=value ...] ------------------
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
                    $kv = $rest[++$i]
                    $k  = $kv.Split('=')[0]
                    $v  = $kv.Substring($k.Length + 1)
                    $params[$k] = @{ value = $v; isSecure = $false }
                }
                '--secure-param' {
                    $kv = $rest[++$i]
                    $k  = $kv.Split('=')[0]
                    $v  = $kv.Substring($k.Length + 1)
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

        Invoke-RestMethod -Method Post -Uri "$baseUrl/api/v1/scripted-actions/$id/execution" `
            -Headers $authHeader -ContentType 'application/json' -Body $body | ConvertTo-Json -Depth 10
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
        foreach ($t in $tasks) {
            if ($t.resultPlain) {
                Write-Output "[$($t.status)] $($t.name)"
                Write-Output $t.resultPlain
            }
        }
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
