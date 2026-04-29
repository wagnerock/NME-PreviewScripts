#description: Enables AVD Login Diagnostics for a host pool.
#tags: Diagnostics, AVD, Login, GPO, FSLogix

<#notes:
Creates or updates a shared Data Collection Rule (dcr-nme-login-diagnostics) in the workspace
resource group that collects GP processing events (4001, 4005, 4016, 4018, 5016, 5018, 5312,
5313, 8001, 6003-6007, 7016, 7017), FSLogix profile events (14, 25, 26, 57, 72, 73), and
User Profile Service events (1, 2, 67) from session host VMs.

Associates the DCR to all session hosts in the target host pool. Runs a parallel VM run command
on powered-on hosts to ensure GP, FSLogix, and User Profile Service event logs are enabled and
sized to 20 MB. Deploys or updates the shared "AVD Login Diagnostics" workbook in the workspace
resource group.

Run this script once per host pool. Re-running on the same host pool is safe (idempotent). The
DCR and workbook are shared — running on a second host pool associates its VMs to the same DCR
and updates the same workbook without creating duplicates.

Workspace is auto-discovered from host pool diagnostic settings, with a fallback to the AVD
Insights DCR (microsoft-avdi-*) in the subscription.
#>

<#variables:
{
  "HostPoolResourceGroupName": {
    "Description": "Resource group containing the AVD host pool",
    "DisplayName": "Host Pool Resource Group"
  },
  "HostPoolName": {
    "Description": "Name of the AVD host pool to enable login diagnostics on",
    "DisplayName": "Host Pool Name"
  }
}
#>

$ErrorActionPreference = 'Stop'
$subscriptionId = (Get-AzContext).Subscription.Id

Write-Output "==========================================="
Write-Output "AVD Login Diagnostics - Setup"
Write-Output "Host Pool : $HostPoolName"
Write-Output "RG        : $HostPoolResourceGroupName"
Write-Output "==========================================="

try {

# ===========================================================================
# 1. Discover the Log Analytics Workspace
#    Priority: host pool diagnostic settings → AVDI DCR → fail with guidance
# ===========================================================================

Write-Output "`n[1/6] Discovering Log Analytics workspace..."

$WorkspaceResourceId = $null

# Try host pool diagnostic settings first
$hostPoolId = (Get-AzResource `
    -ResourceGroupName $HostPoolResourceGroupName `
    -ResourceType "Microsoft.DesktopVirtualization/hostpools" `
    -Name $HostPoolName -ErrorAction SilentlyContinue).ResourceId

if ($hostPoolId) {
    $diagSettings = Get-AzDiagnosticSetting -ResourceId $hostPoolId -ErrorAction SilentlyContinue
    $WorkspaceResourceId = ($diagSettings | Where-Object { $_.WorkspaceId } | Select-Object -First 1).WorkspaceId
}

# Fallback: find the AVD Insights DCR and read its workspace destination
if (-not $WorkspaceResourceId) {
    Write-Output "  No diagnostic settings on host pool. Searching for AVD Insights DCR..."
    $avdiDcr = Get-AzResource -ResourceType "Microsoft.Insights/dataCollectionRules" |
        Where-Object { $_.Name -like "microsoft-avdi-*" } |
        Select-Object -First 1

    if ($avdiDcr) {
        $avdiDcrDetail = Get-AzResource -ResourceId $avdiDcr.ResourceId -ExpandProperties
        $WorkspaceResourceId = $avdiDcrDetail.Properties.destinations.logAnalytics[0].workspaceResourceId
        Write-Output "  Found workspace via AVD Insights DCR: $($avdiDcr.Name)"
    }
}

if (-not $WorkspaceResourceId) {
    throw "Could not discover a Log Analytics workspace. Either configure AVD Insights diagnostics on the host pool, or ensure an AVD Insights DCR (microsoft-avdi-*) exists in this subscription."
}

$workspace    = Get-AzResource -ResourceId $WorkspaceResourceId
$workspaceRg  = $workspace.ResourceGroupName
$workspaceLoc = $workspace.Location
Write-Output "  Workspace : $($workspace.Name) ($workspaceLoc) in $workspaceRg"

# ===========================================================================
# 2. Get session hosts and their VMs
# ===========================================================================

Write-Output "`n[2/6] Enumerating session hosts..."

$sessionHosts = Get-AzWvdSessionHost `
    -ResourceGroupName $HostPoolResourceGroupName `
    -HostPoolName $HostPoolName -ErrorAction SilentlyContinue

if (-not $sessionHosts -or $sessionHosts.Count -eq 0) {
    throw "No session hosts found in host pool '$HostPoolName'. Ensure at least one session host exists before running setup."
}

$vms = @()
foreach ($sh in $sessionHosts) {
    $shName = ($sh.Name -split '/')[-1]          # e.g. "AD-HP-b20e.entse4.local"
    $vmName = $shName -split '\.' | Select-Object -First 1
    $vm = Get-AzVM -ResourceGroupName $HostPoolResourceGroupName -Name $vmName -ErrorAction SilentlyContinue
    if (-not $vm) {
        # VM may be in a different RG (NME creates session hosts in shared RGs)
        $vm = Get-AzVM | Where-Object { $_.Name -eq $vmName } | Select-Object -First 1
    }
    if ($vm) {
        $vmStatus   = Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Status
        $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like 'PowerState/*' }).DisplayStatus
        $vms += [PSCustomObject]@{
            Name            = $vm.Name
            Id              = $vm.Id
            Rg              = $vm.ResourceGroupName
            Location        = $vm.Location
            Running         = ($powerState -eq 'VM running')
            SessionHostName = $shName
            WasDrainMode    = (-not $sh.AllowNewSession)
        }
        Write-Output "  $($vm.Name) — $powerState"
    } else {
        Write-Warning "  Could not find VM for session host: $($sh.Name)"
    }
}

if ($vms.Count -eq 0) { throw "No VMs found for session hosts." }

# ===========================================================================
# 3. Create or update the shared DCR
#    Name is fixed (dcr-nme-login-diagnostics) — shared across all host pools.
#    Placed in the workspace RG so it lives alongside the workspace.
# ===========================================================================

Write-Output "`n[3/6] Creating/updating shared Data Collection Rule..."

$dcrName   = "dcr-nme-login-diagnostics"
$dcrRg     = $workspaceRg
$dcrResId  = "/subscriptions/$subscriptionId/resourceGroups/$dcrRg/providers/Microsoft.Insights/dataCollectionRules/$dcrName"
$dcrApi    = "2022-06-01"

$dcrBody = @{
    location = $workspaceLoc
    tags = @{
        Purpose   = "AVD Login Diagnostics"
        Owner     = "NME Scripted Action"
        ManagedBy = "Enable-LoginDiagnostics"
    }
    properties = @{
        description = "Collects GP and FSLogix login-time events from AVD session hosts for the Login Diagnostics workbook."
        dataSources = @{
            windowsEventLogs = @(
                @{
                    name    = "GPOOperational"
                    streams = @("Microsoft-Event")
                    xPathQueries = @(
                        # GP processing lifecycle + CSE timing + logon scripts + applied GPOs + CSE errors/timeouts
                        "Microsoft-Windows-GroupPolicy/Operational!*[System[(EventID=4001 or EventID=4005 or EventID=4016 or EventID=4018 or EventID=5016 or EventID=5018 or EventID=5312 or EventID=5313 or EventID=8001 or EventID=6003 or EventID=6004 or EventID=6005 or EventID=6006 or EventID=6007 or EventID=7016 or EventID=7017)]]"
                    )
                },
                @{
                    name    = "FSLogixOperational"
                    streams = @("Microsoft-Event")
                    xPathQueries = @(
                        # Profile load start/complete, container attach, disk attach, errors
                        "Microsoft-FSLogix-Apps/Operational!*[System[(EventID=25 or EventID=26 or EventID=14 or EventID=57 or EventID=72 or EventID=73)]]"
                    )
                },
                @{
                    name    = "UserProfileService"
                    streams = @("Microsoft-Event")
                    xPathQueries = @(
                        # Profile load/unload + roaming profile errors
                        "Microsoft-Windows-User Profile Service/Operational!*[System[(EventID=1 or EventID=2 or EventID=67)]]"
                    )
                }
            )
        }
        destinations = @{
            logAnalytics = @(
                @{
                    workspaceResourceId = $WorkspaceResourceId
                    name                = "LoginDiagnosticsWorkspace"
                }
            )
        }
        dataFlows = @(
            @{
                streams      = @("Microsoft-Event")
                destinations = @("LoginDiagnosticsWorkspace")
            }
        )
    }
} | ConvertTo-Json -Depth 10

$dcrResponse = Invoke-AzRestMethod -Method PUT -Path "${dcrResId}?api-version=$dcrApi" -Payload $dcrBody

if ($dcrResponse.StatusCode -notin @(200, 201)) {
    throw "DCR create/update failed. Status=$($dcrResponse.StatusCode) Body=$($dcrResponse.Content)"
}

$dcrId = ($dcrResponse.Content | ConvertFrom-Json).id
Write-Output "  DCR '$dcrName' ready (RG: $dcrRg)"

# ===========================================================================
# 4. Associate DCR to every VM in this host pool
#    Idempotent — PUT with same association name is a no-op if already current.
# ===========================================================================

Write-Output "`n[4/6] Associating DCR to session host VMs..."

foreach ($vm in $vms) {
    $assocName = "login-diagnostics"
    $assocPath = "$($vm.Id)/providers/Microsoft.Insights/dataCollectionRuleAssociations/${assocName}?api-version=$dcrApi"
    $assocBody = @{ properties = @{ dataCollectionRuleId = $dcrId } } | ConvertTo-Json -Depth 3
    $r = Invoke-AzRestMethod -Method PUT -Path $assocPath -Payload $assocBody
    if ($r.StatusCode -in @(200, 201)) {
        Write-Output "  Associated: $($vm.Name)"
    } else {
        Write-Warning "  Association failed for $($vm.Name): $($r.StatusCode)"
    }
}

# ===========================================================================
# 5. Host-level event log configuration via parallel VM Run Commands
#    - Enable GP Operational, FSLogix, and User Profile Service logs if disabled
#    - Increase max log size to 20 MB (default 4 MB can fill quickly)
#    Only runs on VMs that are currently powered on. Skipped VMs will be
#    configured automatically the next time this script is run while running.
# ===========================================================================

Write-Output "`n[5/6] Configuring event logs on session hosts (parallel)..."

# Script that runs inside each VM
$vmConfigScript = @'
$ErrorActionPreference = 'Continue'
$results = @()

function Set-EventLog {
    param($LogName, $MinSizeMB = 20)
    $log = Get-WinEvent -ListLog $LogName -ErrorAction SilentlyContinue
    if (-not $log) { return "NOT FOUND: $LogName" }
    $changed = @()
    if (-not $log.IsEnabled) {
        $log.IsEnabled = $true
        $log.SaveChanges()
        $changed += "enabled"
    }
    if ($log.MaximumSizeInBytes -lt ($MinSizeMB * 1MB)) {
        $log.MaximumSizeInBytes = $MinSizeMB * 1MB
        $log.SaveChanges()
        $changed += "resized to ${MinSizeMB}MB"
    }
    $status = if ($changed) { $changed -join ', ' } else { "ok" }
    return "${LogName}: $status (size=$([math]::Round($log.MaximumSizeInBytes/1MB,0))MB, enabled=$($log.IsEnabled))"
}

$results += Set-EventLog "Microsoft-Windows-GroupPolicy/Operational"
$results += Set-EventLog "Microsoft-Windows-User Profile Service/Operational"

# FSLogix log channel name varies across versions — discover it
$fslLog = Get-WinEvent -ListLog *FSLogix* -ErrorAction SilentlyContinue |
          Where-Object LogName -match 'Operational' |
          Select-Object -First 1
if ($fslLog) {
    $results += Set-EventLog $fslLog.LogName
} else {
    $results += "FSLogix/Operational: NOT FOUND (FSLogix may not be installed)"
}

$results | ForEach-Object { Write-Output "  $_" }
'@

$startedVms = @()
$stoppedVms  = $vms | Where-Object { -not $_.Running }

# Set drain mode on all stopped VMs before starting them
foreach ($vm in $stoppedVms) {
    Write-Output "  Setting drain mode: $($vm.Name)"
    Update-AzWvdSessionHost `
        -ResourceGroupName $HostPoolResourceGroupName `
        -HostPoolName      $HostPoolName `
        -Name              $vm.SessionHostName `
        -AllowNewSession:$false | Out-Null
}

# Start stopped VMs in parallel
$startJobs = @{}
foreach ($vm in $stoppedVms) {
    Write-Output "  Starting VM: $($vm.Name)"
    $startJobs[$vm.Name] = Start-AzVM -ResourceGroupName $vm.Rg -Name $vm.Name -AsJob
    $startedVms += $vm
}

if ($startJobs.Count -gt 0) {
    Write-Output "  Waiting for $($startJobs.Count) VM(s) to reach running state..."
    $startJobs.Values | Wait-Job -Timeout 600 | Out-Null
    foreach ($vmName in $startJobs.Keys) {
        $j = $startJobs[$vmName]
        if ($j.State -ne 'Completed') { Write-Warning "  $vmName start may not have completed (state: $($j.State))" }
        Remove-Job $j -Force
    }
    Start-Sleep -Seconds 20  # allow VM agent to initialize before sending run command
}

# Run event log config on all VMs in parallel
$jobs = @{}
foreach ($vm in $vms) {
    Write-Output "  Starting run command: $($vm.Name)"
    $job = Invoke-AzVMRunCommand `
        -ResourceGroupName $vm.Rg `
        -VMName            $vm.Name `
        -CommandId         'RunPowerShellScript' `
        -ScriptString      $vmConfigScript `
        -AsJob
    $jobs[$vm.Name] = $job
}

# Wait for all run command jobs and collect output
if ($jobs.Count -gt 0) {
    Write-Output "  Waiting for $($jobs.Count) run command job(s)..."
    $jobs.Values | Wait-Job -Timeout 300 | Out-Null

    foreach ($vmName in $jobs.Keys) {
        $job = $jobs[$vmName]
        if ($job.State -eq 'Completed') {
            $result = Receive-Job $job
            Write-Output "  $vmName results:"
            $result.Value[0].Message -split "`n" | ForEach-Object { Write-Output "    $_" }
        } else {
            Write-Warning "  $vmName run command did not complete (state: $($job.State))"
        }
        Remove-Job $job -Force
    }
}

# Deallocate VMs we started and restore drain mode
if ($startedVms.Count -gt 0) {
    Write-Output "  Deallocating $($startedVms.Count) VM(s) started for setup..."
    $stopJobs = @{}
    foreach ($vm in $startedVms) {
        $stopJobs[$vm.Name] = Stop-AzVM -ResourceGroupName $vm.Rg -Name $vm.Name -Force -AsJob
    }
    $stopJobs.Values | Wait-Job -Timeout 300 | Out-Null
    $stopJobs.Values | Remove-Job -Force

    foreach ($vm in $startedVms) {
        if (-not $vm.WasDrainMode) {
            Update-AzWvdSessionHost `
                -ResourceGroupName $HostPoolResourceGroupName `
                -HostPoolName      $HostPoolName `
                -Name              $vm.SessionHostName `
                -AllowNewSession:$true | Out-Null
            Write-Output "  Drain mode cleared: $($vm.Name)"
        } else {
            Write-Output "  $($vm.Name) was already in drain mode — left enabled"
        }
    }
}

# ===========================================================================
# 6. Deploy / update the shared workbook
#    Searches workspace RG for an existing workbook tagged Purpose=AVD Login Diagnostics.
#    Updates it if found; creates new if not.
# ===========================================================================

Write-Output "`n[6/6] Deploying Login Diagnostics workbook..."

$existingWb = Get-AzResource `
    -ResourceGroupName $workspaceRg `
    -ResourceType      "microsoft.insights/workbooks" `
    -ErrorAction SilentlyContinue |
    Where-Object { $_.Tags['Purpose'] -eq 'AVD Login Diagnostics' } |
    Select-Object -First 1

$workbookGuid = if ($existingWb) { $existingWb.Name } else { [guid]::NewGuid().ToString() }
$workbookAction = if ($existingWb) { "Updating" } else { "Creating" }
Write-Output "  $workbookAction workbook (GUID: $workbookGuid)"

# Embed workbook content — workspace resource ID injected at runtime
$workbookStaticJson = '{"version":"Notebook/1.0","items":[{"type":1,"content":{"json":"## AVD Login Performance by Phase\n\nSelect a host pool and optionally a specific user to diagnose slow login complaints. Each bar = one login session; segments show time in each phase.\n\n**Data sources:** WVD Insights (WVDConnections, WVDCheckpoints) + Login Diagnostics DCR (GP Event 8001, Script Event 5018). Group Policy and Logon Scripts phases require the Login Diagnostics scripted action deployed on the host pool. They show 0 for Entra ID-native users (no on-prem AD)."},"name":"text-header"},{"type":9,"content":{"version":"KqlParameterItem/1.0","parameters":[{"id":"p001","version":"KqlParameterItem/1.0","name":"TimeRange","type":4,"isRequired":true,"value":{"durationMs":86400000},"typeSettings":{"allowCustom":true,"selectableValues":[{"label":"Last hour","durationMs":3600000},{"label":"Last 4 hours","durationMs":14400000},{"label":"Last 12 hours","durationMs":43200000},{"label":"Last 24 hours","durationMs":86400000},{"label":"Last 2 days","durationMs":172800000},{"label":"Last 7 days","durationMs":604800000}]}},{"id":"p002","version":"KqlParameterItem/1.0","name":"HostPool","label":"Host Pool","type":2,"isRequired":true,"query":"WVDConnections\n| extend HostPool = tolower(tostring(split(_ResourceId, \"/\")[-1]))\n| distinct HostPool\n| sort by HostPool asc","queryType":0,"resourceType":"microsoft.operationalinsights/workspaces","timeContextFromParameter":"TimeRange"},{"id":"p003","version":"KqlParameterItem/1.0","name":"User","label":"User","type":2,"isRequired":true,"query":"WVDConnections\n| extend HostPool = tolower(tostring(split(_ResourceId, \"/\")[-1]))\n| where HostPool == tolower(\"{HostPool}\")\n| distinct UserName\n| sort by UserName asc","queryType":0,"resourceType":"microsoft.operationalinsights/workspaces","timeContextFromParameter":"TimeRange","defaultValue":"value:All","typeSettings":{"additionalResourceOptions":["value:All"],"showDefault":false}},{"id":"p004","version":"KqlParameterItem/1.0","name":"ConnectionType","label":"Connection Type","type":2,"isRequired":true,"jsonData":"[{\"value\":\"new\",\"label\":\"Full logins\"},{\"value\":\"reconnect\",\"label\":\"Reconnects\"},{\"value\":\"all\",\"label\":\"All\"}]","value":"new","typeSettings":{"additionalResourceOptions":[],"showDefault":false}}],"style":"pills","queryType":0,"resourceType":"microsoft.operationalinsights/workspaces"},"name":"parameters"},{"type":3,"content":{"version":"KqlItem/1.0","query":"let _hp = tolower(\"{HostPool}\");\nlet _user = \"{User}\";\nlet ConnectionBase = WVDConnections\n| extend HostPool = tolower(tostring(split(_ResourceId, \"/\")[-1]))\n| where HostPool == _hp\n| where _user == \"All\" or UserName == _user\n| where State in (\"Started\", \"Connected\")\n| summarize\n    StartTime = minif(TimeGenerated, State == \"Started\"),\n    Computer = any(SessionHostName),\n    UserName = any(UserName)\n    by CorrelationId\n| where isnotnull(StartTime);\nlet Checkpoints = WVDCheckpoints\n| where ActivityType == \"Connection\"\n| summarize\n    // For VM cold starts, LoadBalancedNewConnection fires twice:\n    // first when broker assigns the (not-yet-running) VM, second when it is ready.\n    FirstLB        = minif(TimeGenerated, Name == \"LoadBalancedNewConnection\"),\n    SecondLB       = maxif(TimeGenerated, Name == \"LoadBalancedNewConnection\"),\n    TransportConn  = minif(TimeGenerated, Name == \"TransportConnected\"),\n    FirstFrame     = minif(TimeGenerated, Name == \"FirstGraphicsFrame\"),\n    LoadBalanceOutcome = anyif(tostring(parse_json(Parameters).LoadBalanceOutcome), Name == \"LoadBalancedNewConnection\"),\n    HasVMStarting  = countif(Name == \"VMStarting\") > 0,\n    OnConnected    = minif(TimeGenerated, Name == \"OnConnected\")\n    by CorrelationId;\nlet LogonDelay = WVDCheckpoints\n| where Name == \"LogonDelay\"\n| extend p = parse_json(Parameters)\n| summarize arg_min(TimeGenerated, *) by CorrelationId\n| project CorrelationId,\n    Auth_ms    = coalesce(toreal(p.AuthenticateUser), 0.0),\n    FSLogix_ms = coalesce(toreal(p.WinLogon_Logon_frxsvc), 0.0)\n               + coalesce(toreal(p.WinLogon_Logon_frxmid), 0.0)\n               + coalesce(toreal(p.WinLogon_Logon_Profiles), 0.0),\n    TermSrv_ms = coalesce(toreal(p.WinLogon_Logon_TermSrv), 0.0),\n    // SessionEnv + SENS only \u2014 StartShell is logon script time, captured via Event 5018\n    Other_ms   = coalesce(toreal(p.WinLogon_Logon_SessionEnv), 0.0)\n               + coalesce(toreal(p.WinLogon_Logon_Sens), 0.0),\n    NetworkProv_ms = coalesce(toreal(p.WinLogon_Logon_NetworkProviders), 0.0),\n    HasLogonDelay = true;\nlet GPEvents = Event\n| where Source == \"Microsoft-Windows-GroupPolicy\" and EventID == 8001\n| extend xd = parse_xml(EventData)\n| where tostring(xd.DataItem.EventData.[\"Data\"][3][\"#text\"]) == \"0\"\n| extend GP_sec = toreal(xd.DataItem.EventData.[\"Data\"][0][\"#text\"])\n| extend RawUser = tolower(tostring(xd.DataItem.EventData.[\"Data\"][2][\"#text\"]))\n| extend SAM = extract(@\"([^/\\\\]+)$\", 1, RawUser)\n| extend Host = tolower(tostring(split(Computer, \".\")[0]))\n| project GPTime = TimeGenerated, Host, SAM, GP_sec;\nlet ScriptEvents = Event\n| where Source == \"Microsoft-Windows-GroupPolicy\" and EventID == 5018\n| extend xd = parse_xml(EventData)\n| where toint(xd.DataItem.EventData.[\"Data\"][3][\"#text\"]) == 1\n| extend Script_sec = toreal(xd.DataItem.EventData.[\"Data\"][0][\"#text\"])\n| extend RawUser = tolower(tostring(xd.DataItem.EventData.[\"Data\"][2][\"#text\"]))\n| extend SAM = extract(@\"([^/\\\\]+)$\", 1, RawUser)\n| extend Host = tolower(tostring(split(Computer, \".\")[0]))\n| project ScriptTime = TimeGenerated, Host, SAM, Script_sec;\nlet FSL25 = Event\n| where Source has \"FSLogix\" and EventID == 25\n| extend xd = parse_xml(EventData)\n| extend SAM = tolower(tostring(xd.DataItem.EventData.[\"Data\"][3][\"#text\"]))\n| extend Host = tolower(tostring(split(Computer, \".\")[0]))\n| project FSLTime = TimeGenerated, Host, SAM;\nlet Sessions = ConnectionBase\n| join kind=leftouter Checkpoints on CorrelationId\n| join kind=leftouter LogonDelay on CorrelationId\n| extend Host = tolower(tostring(split(Computer, \".\")[0]))\n| extend UPNPrefix = tolower(tostring(split(UserName, \"@\")[0]))\n| extend HasVMStarting = coalesce(HasVMStarting, false);\nlet WithGP = Sessions\n| join kind=leftouter (GPEvents) on $left.Host == $right.Host and $left.UPNPrefix == $right.SAM\n| where isnull(GPTime) or (GPTime between (StartTime .. datetime_add(''minute'', 10, StartTime)))\n| summarize GP_sec = max(GP_sec),\n    StartTime = any(StartTime), Computer = any(Computer), UserName = any(UserName),\n    Host = any(Host), UPNPrefix = any(UPNPrefix),\n    FirstLB = any(FirstLB), SecondLB = any(SecondLB), TransportConn = any(TransportConn), FirstFrame = any(FirstFrame),\n    LoadBalanceOutcome = any(LoadBalanceOutcome), HasVMStarting = any(HasVMStarting), HasLogonDelay = any(HasLogonDelay),\n    Auth_ms = any(Auth_ms), FSLogix_ms = any(FSLogix_ms), TermSrv_ms = any(TermSrv_ms), Other_ms = any(Other_ms), NetworkProv_ms = any(NetworkProv_ms), OnConnected = any(OnConnected)\n    by CorrelationId;\nlet WithAll = WithGP\n| join kind=leftouter (ScriptEvents) on $left.Host == $right.Host and $left.UPNPrefix == $right.SAM\n| where isnull(ScriptTime) or (ScriptTime between (StartTime .. datetime_add(''minute'', 10, StartTime)))\n| summarize Script_sec = sum(Script_sec),\n    GP_sec = any(GP_sec), StartTime = any(StartTime), Computer = any(Computer), UserName = any(UserName),\n    HasLogonDelay = any(HasLogonDelay), HasVMStarting = any(HasVMStarting), LoadBalanceOutcome = any(LoadBalanceOutcome),\n    FirstLB = any(FirstLB), SecondLB = any(SecondLB), TransportConn = any(TransportConn), FirstFrame = any(FirstFrame),\n    Auth_ms = any(Auth_ms), FSLogix_ms = any(FSLogix_ms), TermSrv_ms = any(TermSrv_ms), Other_ms = any(Other_ms), NetworkProv_ms = any(NetworkProv_ms),\n    Host = any(Host), UPNPrefix = any(UPNPrefix), OnConnected = any(OnConnected)\n    by CorrelationId;\nlet WithFSL = WithAll\n| join kind=leftouter FSL25 on $left.Host == $right.Host and $left.UPNPrefix == $right.SAM\n| where isnull(FSLTime) or (isnotnull(OnConnected) and FSLTime between (OnConnected .. datetime_add(''minute'', 3, OnConnected)))\n| summarize\n    FSLTime = min(FSLTime),\n    Script_sec = any(Script_sec), GP_sec = any(GP_sec),\n    StartTime = any(StartTime), Computer = any(Computer), UserName = any(UserName),\n    HasLogonDelay = any(HasLogonDelay), HasVMStarting = any(HasVMStarting), LoadBalanceOutcome = any(LoadBalanceOutcome),\n    FirstLB = any(FirstLB), SecondLB = any(SecondLB), TransportConn = any(TransportConn), FirstFrame = any(FirstFrame),\n    Host = any(Host), UPNPrefix = any(UPNPrefix),\n    Auth_ms = any(Auth_ms), FSLogix_ms = any(FSLogix_ms), TermSrv_ms = any(TermSrv_ms), Other_ms = any(Other_ms),\n    NetworkProv_ms = any(NetworkProv_ms), OnConnected = any(OnConnected)\n    by CorrelationId;\nlet Phased = WithFSL\n| extend\n    // P1: connection start \u2192 first load balance decision (broker overhead)\n    P1_Broker    = round(datetime_diff(''millisecond'', coalesce(FirstLB, TransportConn, FirstFrame, StartTime), StartTime) / 1000.0, 1),\n    // P2: VM startup \u2014 only non-zero on cold starts (VMStarting checkpoint fired).\n    // Measured as gap between first LB (VM assigned, not running) and second LB (VM ready).\n    P2_VMStartup = round(iff(HasVMStarting == true and SecondLB > FirstLB,\n                      datetime_diff(''millisecond'', SecondLB, FirstLB) / 1000.0, 0.0), 1),\n    // P3: RDP handshake \u2014 transport established to first pixel.\n    // Fall back to SecondLB as start point if no TransportConnected (common on cold starts).\n    P3_RDP       = round(\n                      iff(isnotnull(FirstFrame),\n                          datetime_diff(''millisecond'', FirstFrame,\n                              coalesce(TransportConn, SecondLB, FirstLB)) / 1000.0,\n                      iff(HasVMStarting == true and isnotnull(OnConnected) and isnotnull(SecondLB),\n                          datetime_diff(''millisecond'', OnConnected, SecondLB) / 1000.0,\n                          0.0)), 1),\n    P4_Auth      = round(coalesce(Auth_ms, 0.0) / 1000.0, 1),\n    P5_FSLogix   = round(coalesce(\n        iff(FSLogix_ms > 0, FSLogix_ms, real(null)),\n        iff(isnotnull(OnConnected) and isnotnull(FSLTime),\n            toreal(datetime_diff(''millisecond'', FSLTime, OnConnected)), real(null)),\n        0.0) / 1000.0, 1),\n    P6_TermSrv   = round(coalesce(TermSrv_ms, 0.0) / 1000.0, 1),\n    P7_GP        = round(coalesce(GP_sec, 0.0), 1),\n    P8_Scripts   = round(coalesce(Script_sec, 0.0), 1),\n    // Other = SessionEnv + SENS only (StartShell excluded \u2014 it duplicates P8_Scripts)\n    P9_Other     = round(coalesce(Other_ms, 0.0) / 1000.0, 1),\n    P10_NetProv  = round(coalesce(NetworkProv_ms, 0.0) / 1000.0, 1)\n| extend Total = round(P1_Broker + P2_VMStartup + P3_RDP + P4_Auth + P5_FSLogix + P6_TermSrv + P7_GP + P8_Scripts + P9_Other + P10_NetProv, 1)\n| extend SessionType = case(\n    HasVMStarting == true and HasLogonDelay == true,  \"New Session with VM Cold Start\",\n    HasVMStarting == true,                            \"New Session with VM Cold Start (no detail)\",\n    HasLogonDelay == true,                            \"New Session\",\n    LoadBalanceOutcome == \"NewSession\",               \"New Session (no detail)\",\n                                                      \"Reconnect\")\n| project StartTime, CorrelationId, UserName, Computer, LoadBalanceOutcome, SessionType, HasVMStarting,\n    Total, P1_Broker, P2_VMStartup, P3_RDP, P4_Auth, P5_FSLogix, P6_TermSrv, P7_GP, P8_Scripts, P9_Other, P10_NetProv;\nlet Filtered = Phased\n| where case(\n    \"{ConnectionType}\" == \"all\", true,\n    \"{ConnectionType}\" == \"new\", LoadBalanceOutcome in (\"NewSession\", \"Pending\"),\n    LoadBalanceOutcome == \"Disconnected\");\nFiltered\n| extend SessionLabel = format_datetime(StartTime, ''MM-dd HH:mm'')\n| mv-expand Phase = pack_array(\n    pack(\"N\", \"1-Broker & LB\",       \"S\", P1_Broker),\n    pack(\"N\", \"2-VM Startup\",         \"S\", P2_VMStartup),\n    pack(\"N\", \"3-RDP Handshake\",      \"S\", P3_RDP),\n    pack(\"N\", \"4-Authentication\",     \"S\", P4_Auth),\n    pack(\"N\", \"5-FSLogix Profile\",    \"S\", P5_FSLogix),\n    pack(\"N\", \"6-Terminal Services\",  \"S\", P6_TermSrv),\n    pack(\"N\", \"7-Group Policy\",       \"S\", P7_GP),\n    pack(\"N\", \"8-Logon Scripts\",      \"S\", P8_Scripts),\n    pack(\"N\", \"9-Other Logon\",        \"S\", P9_Other),\n    pack(\"N\", \"10-Net Providers\",      \"S\", P10_NetProv))\n| extend PhaseName = tostring(Phase.N), PhaseDuration = toreal(Phase.S)\n| project StartTime, SessionLabel, UserName, Computer, PhaseName, PhaseDuration, Total\n| order by StartTime asc, PhaseName asc","size":0,"title":"Login Duration by Phase \u2014 {HostPool}","timeContextFromParameter":"TimeRange","queryType":0,"resourceType":"microsoft.operationalinsights/workspaces","visualization":"barchart","chartSettings":{"xAxis":"SessionLabel","group":"PhaseName","yAxis":["PhaseDuration"],"ySettings":{"numberFormatSettings":{"unit":24,"options":{"style":"decimal","useGrouping":true}}},"seriesLabelSettings":[{"seriesName":"1-Broker & LB","color":"blue"},{"seriesName":"2-VM Startup","color":"purple"},{"seriesName":"3-RDP Handshake","color":"turquoise"},{"seriesName":"4-Authentication","color":"green"},{"seriesName":"5-FSLogix Profile","color":"yellow"},{"seriesName":"6-Terminal Services","color":"orange"},{"seriesName":"7-Group Policy","color":"red"},{"seriesName":"8-Logon Scripts","color":"redBright"},{"seriesName":"9-Other Logon","color":"gray"},{"seriesName":"10-Net Providers","color":"teal"}],"createOtherGroup":0}},"name":"chart-phases"},{"type":3,"content":{"version":"KqlItem/1.0","query":"let _hp = tolower(\"{HostPool}\");\nlet _user = \"{User}\";\nlet ConnectionBase = WVDConnections\n| extend HostPool = tolower(tostring(split(_ResourceId, \"/\")[-1]))\n| where HostPool == _hp\n| where _user == \"All\" or UserName == _user\n| where State in (\"Started\", \"Connected\")\n| summarize\n    StartTime = minif(TimeGenerated, State == \"Started\"),\n    Computer = any(SessionHostName),\n    UserName = any(UserName)\n    by CorrelationId\n| where isnotnull(StartTime);\nlet Checkpoints = WVDCheckpoints\n| where ActivityType == \"Connection\"\n| summarize\n    // For VM cold starts, LoadBalancedNewConnection fires twice:\n    // first when broker assigns the (not-yet-running) VM, second when it is ready.\n    FirstLB        = minif(TimeGenerated, Name == \"LoadBalancedNewConnection\"),\n    SecondLB       = maxif(TimeGenerated, Name == \"LoadBalancedNewConnection\"),\n    TransportConn  = minif(TimeGenerated, Name == \"TransportConnected\"),\n    FirstFrame     = minif(TimeGenerated, Name == \"FirstGraphicsFrame\"),\n    LoadBalanceOutcome = anyif(tostring(parse_json(Parameters).LoadBalanceOutcome), Name == \"LoadBalancedNewConnection\"),\n    HasVMStarting  = countif(Name == \"VMStarting\") > 0,\n    OnConnected    = minif(TimeGenerated, Name == \"OnConnected\")\n    by CorrelationId;\nlet LogonDelay = WVDCheckpoints\n| where Name == \"LogonDelay\"\n| extend p = parse_json(Parameters)\n| summarize arg_min(TimeGenerated, *) by CorrelationId\n| project CorrelationId,\n    Auth_ms    = coalesce(toreal(p.AuthenticateUser), 0.0),\n    FSLogix_ms = coalesce(toreal(p.WinLogon_Logon_frxsvc), 0.0)\n               + coalesce(toreal(p.WinLogon_Logon_frxmid), 0.0)\n               + coalesce(toreal(p.WinLogon_Logon_Profiles), 0.0),\n    TermSrv_ms = coalesce(toreal(p.WinLogon_Logon_TermSrv), 0.0),\n    // SessionEnv + SENS only \u2014 StartShell is logon script time, captured via Event 5018\n    Other_ms   = coalesce(toreal(p.WinLogon_Logon_SessionEnv), 0.0)\n               + coalesce(toreal(p.WinLogon_Logon_Sens), 0.0),\n    NetworkProv_ms = coalesce(toreal(p.WinLogon_Logon_NetworkProviders), 0.0),\n    HasLogonDelay = true;\nlet GPEvents = Event\n| where Source == \"Microsoft-Windows-GroupPolicy\" and EventID == 8001\n| extend xd = parse_xml(EventData)\n| where tostring(xd.DataItem.EventData.[\"Data\"][3][\"#text\"]) == \"0\"\n| extend GP_sec = toreal(xd.DataItem.EventData.[\"Data\"][0][\"#text\"])\n| extend RawUser = tolower(tostring(xd.DataItem.EventData.[\"Data\"][2][\"#text\"]))\n| extend SAM = extract(@\"([^/\\\\]+)$\", 1, RawUser)\n| extend Host = tolower(tostring(split(Computer, \".\")[0]))\n| project GPTime = TimeGenerated, Host, SAM, GP_sec;\nlet ScriptEvents = Event\n| where Source == \"Microsoft-Windows-GroupPolicy\" and EventID == 5018\n| extend xd = parse_xml(EventData)\n| where toint(xd.DataItem.EventData.[\"Data\"][3][\"#text\"]) == 1\n| extend Script_sec = toreal(xd.DataItem.EventData.[\"Data\"][0][\"#text\"])\n| extend RawUser = tolower(tostring(xd.DataItem.EventData.[\"Data\"][2][\"#text\"]))\n| extend SAM = extract(@\"([^/\\\\]+)$\", 1, RawUser)\n| extend Host = tolower(tostring(split(Computer, \".\")[0]))\n| project ScriptTime = TimeGenerated, Host, SAM, Script_sec;\nlet FSL25 = Event\n| where Source has \"FSLogix\" and EventID == 25\n| extend xd = parse_xml(EventData)\n| extend SAM = tolower(tostring(xd.DataItem.EventData.[\"Data\"][3][\"#text\"]))\n| extend Host = tolower(tostring(split(Computer, \".\")[0]))\n| project FSLTime = TimeGenerated, Host, SAM;\nlet Sessions = ConnectionBase\n| join kind=leftouter Checkpoints on CorrelationId\n| join kind=leftouter LogonDelay on CorrelationId\n| extend Host = tolower(tostring(split(Computer, \".\")[0]))\n| extend UPNPrefix = tolower(tostring(split(UserName, \"@\")[0]))\n| extend HasVMStarting = coalesce(HasVMStarting, false);\nlet WithGP = Sessions\n| join kind=leftouter (GPEvents) on $left.Host == $right.Host and $left.UPNPrefix == $right.SAM\n| where isnull(GPTime) or (GPTime between (StartTime .. datetime_add(''minute'', 10, StartTime)))\n| summarize GP_sec = max(GP_sec),\n    StartTime = any(StartTime), Computer = any(Computer), UserName = any(UserName),\n    Host = any(Host), UPNPrefix = any(UPNPrefix),\n    FirstLB = any(FirstLB), SecondLB = any(SecondLB), TransportConn = any(TransportConn), FirstFrame = any(FirstFrame),\n    LoadBalanceOutcome = any(LoadBalanceOutcome), HasVMStarting = any(HasVMStarting), HasLogonDelay = any(HasLogonDelay),\n    Auth_ms = any(Auth_ms), FSLogix_ms = any(FSLogix_ms), TermSrv_ms = any(TermSrv_ms), Other_ms = any(Other_ms), NetworkProv_ms = any(NetworkProv_ms), OnConnected = any(OnConnected)\n    by CorrelationId;\nlet WithAll = WithGP\n| join kind=leftouter (ScriptEvents) on $left.Host == $right.Host and $left.UPNPrefix == $right.SAM\n| where isnull(ScriptTime) or (ScriptTime between (StartTime .. datetime_add(''minute'', 10, StartTime)))\n| summarize Script_sec = sum(Script_sec),\n    GP_sec = any(GP_sec), StartTime = any(StartTime), Computer = any(Computer), UserName = any(UserName),\n    HasLogonDelay = any(HasLogonDelay), HasVMStarting = any(HasVMStarting), LoadBalanceOutcome = any(LoadBalanceOutcome),\n    FirstLB = any(FirstLB), SecondLB = any(SecondLB), TransportConn = any(TransportConn), FirstFrame = any(FirstFrame),\n    Auth_ms = any(Auth_ms), FSLogix_ms = any(FSLogix_ms), TermSrv_ms = any(TermSrv_ms), Other_ms = any(Other_ms), NetworkProv_ms = any(NetworkProv_ms),\n    Host = any(Host), UPNPrefix = any(UPNPrefix), OnConnected = any(OnConnected)\n    by CorrelationId;\nlet WithFSL = WithAll\n| join kind=leftouter FSL25 on $left.Host == $right.Host and $left.UPNPrefix == $right.SAM\n| where isnull(FSLTime) or (isnotnull(OnConnected) and FSLTime between (OnConnected .. datetime_add(''minute'', 3, OnConnected)))\n| summarize\n    FSLTime = min(FSLTime),\n    Script_sec = any(Script_sec), GP_sec = any(GP_sec),\n    StartTime = any(StartTime), Computer = any(Computer), UserName = any(UserName),\n    HasLogonDelay = any(HasLogonDelay), HasVMStarting = any(HasVMStarting), LoadBalanceOutcome = any(LoadBalanceOutcome),\n    FirstLB = any(FirstLB), SecondLB = any(SecondLB), TransportConn = any(TransportConn), FirstFrame = any(FirstFrame),\n    Host = any(Host), UPNPrefix = any(UPNPrefix),\n    Auth_ms = any(Auth_ms), FSLogix_ms = any(FSLogix_ms), TermSrv_ms = any(TermSrv_ms), Other_ms = any(Other_ms),\n    NetworkProv_ms = any(NetworkProv_ms), OnConnected = any(OnConnected)\n    by CorrelationId;\nlet Phased = WithFSL\n| extend\n    // P1: connection start \u2192 first load balance decision (broker overhead)\n    P1_Broker    = round(datetime_diff(''millisecond'', coalesce(FirstLB, TransportConn, FirstFrame, StartTime), StartTime) / 1000.0, 1),\n    // P2: VM startup \u2014 only non-zero on cold starts (VMStarting checkpoint fired).\n    // Measured as gap between first LB (VM assigned, not running) and second LB (VM ready).\n    P2_VMStartup = round(iff(HasVMStarting == true and SecondLB > FirstLB,\n                      datetime_diff(''millisecond'', SecondLB, FirstLB) / 1000.0, 0.0), 1),\n    // P3: RDP handshake \u2014 transport established to first pixel.\n    // Fall back to SecondLB as start point if no TransportConnected (common on cold starts).\n    P3_RDP       = round(\n                      iff(isnotnull(FirstFrame),\n                          datetime_diff(''millisecond'', FirstFrame,\n                              coalesce(TransportConn, SecondLB, FirstLB)) / 1000.0,\n                      iff(HasVMStarting == true and isnotnull(OnConnected) and isnotnull(SecondLB),\n                          datetime_diff(''millisecond'', OnConnected, SecondLB) / 1000.0,\n                          0.0)), 1),\n    P4_Auth      = round(coalesce(Auth_ms, 0.0) / 1000.0, 1),\n    P5_FSLogix   = round(coalesce(\n        iff(FSLogix_ms > 0, FSLogix_ms, real(null)),\n        iff(isnotnull(OnConnected) and isnotnull(FSLTime),\n            toreal(datetime_diff(''millisecond'', FSLTime, OnConnected)), real(null)),\n        0.0) / 1000.0, 1),\n    P6_TermSrv   = round(coalesce(TermSrv_ms, 0.0) / 1000.0, 1),\n    P7_GP        = round(coalesce(GP_sec, 0.0), 1),\n    P8_Scripts   = round(coalesce(Script_sec, 0.0), 1),\n    // Other = SessionEnv + SENS only (StartShell excluded \u2014 it duplicates P8_Scripts)\n    P9_Other     = round(coalesce(Other_ms, 0.0) / 1000.0, 1),\n    P10_NetProv  = round(coalesce(NetworkProv_ms, 0.0) / 1000.0, 1)\n| extend Total = round(P1_Broker + P2_VMStartup + P3_RDP + P4_Auth + P5_FSLogix + P6_TermSrv + P7_GP + P8_Scripts + P9_Other + P10_NetProv, 1)\n| extend SessionType = case(\n    HasVMStarting == true and HasLogonDelay == true,  \"New Session with VM Cold Start\",\n    HasVMStarting == true,                            \"New Session with VM Cold Start (no detail)\",\n    HasLogonDelay == true,                            \"New Session\",\n    LoadBalanceOutcome == \"NewSession\",               \"New Session (no detail)\",\n                                                      \"Reconnect\")\n| project StartTime, CorrelationId, UserName, Computer, LoadBalanceOutcome, SessionType, HasVMStarting,\n    Total, P1_Broker, P2_VMStartup, P3_RDP, P4_Auth, P5_FSLogix, P6_TermSrv, P7_GP, P8_Scripts, P9_Other, P10_NetProv;\nlet Filtered = Phased\n| where case(\n    \"{ConnectionType}\" == \"all\", true,\n    \"{ConnectionType}\" == \"new\", LoadBalanceOutcome in (\"NewSession\", \"Pending\"),\n    LoadBalanceOutcome == \"Disconnected\");\nFiltered\n| extend User = tostring(split(UserName, \"@\")[0])\n| project\n    [''Login Time''] = StartTime,\n    User, Host = Computer,\n    [''Total (s)''] = Total,\n    [''Broker & LB''] = P1_Broker,\n    [''VM Startup''] = P2_VMStartup,\n    [''RDP''] = P3_RDP,\n    [''Auth''] = P4_Auth,\n    [''FSLogix''] = P5_FSLogix,\n    [''Term Svc''] = P6_TermSrv,\n    [''Group Policy''] = P7_GP,\n    [''Scripts''] = P8_Scripts,\n    [''Other''] = P9_Other,\n    [''Net Providers''] = P10_NetProv,\n    [''LB Outcome''] = LoadBalanceOutcome,\n    [''Session Type''] = SessionType\n| order by [''Total (s)''] desc","size":1,"title":"Per-Login Breakdown \u2014 slowest first","timeContextFromParameter":"TimeRange","queryType":0,"resourceType":"microsoft.operationalinsights/workspaces","visualization":"table","gridSettings":{"formatters":[{"columnMatch":"Total \\(s\\)","formatter":8,"formatOptions":{"palette":"greenRed"},"numberFormat":{"unit":0,"options":{"style":"decimal","minimumFractionDigits":1}}},{"columnMatch":"Group Policy|Scripts|FSLogix|Net Providers","formatter":8,"formatOptions":{"palette":"whiteRed"}}],"rowLimit":200,"filter":true}},"name":"table-breakdown"},{"type":1,"content":{"json":"## Group Policy CSE Detail\n\nBreakdown of time spent in each Group Policy Client-Side Extension (CSE) during user logon. Requires Login Diagnostics DCR (Event 5016). User GP only \u2014 Computer GP excluded. CSEs sorted by average elapsed time descending."},"name":"text-cse-header"},{"type":3,"content":{"version":"KqlItem/1.0","query":"let _hp = tolower(\"{HostPool}\");\nlet PoolHosts = WVDConnections\n| extend HostPool = tolower(tostring(split(_ResourceId, \"/\")[-1]))\n| where HostPool == _hp\n| where SessionHostName != \"<>\"\n| extend Host = tolower(tostring(split(SessionHostName, \".\")[0]))\n| distinct Host;\nEvent\n| where Source == \"Microsoft-Windows-GroupPolicy\" and EventID == 5016\n| extend xd = parse_xml(EventData)\n| extend\n    CSE_ms  = toreal(xd.DataItem.EventData.[\"Data\"][0][\"#text\"]),\n    CSEName = tostring(xd.DataItem.EventData.[\"Data\"][2][\"#text\"]),\n    Host    = tolower(tostring(split(Computer, \".\")[0]))\n| join kind=inner PoolHosts on Host\n| summarize\n    Sessions = count(),\n    Avg_ms   = round(avg(CSE_ms), 0),\n    P50_ms   = round(percentile(CSE_ms, 50), 0),\n    P95_ms   = round(percentile(CSE_ms, 95), 0),\n    Max_ms   = round(max(CSE_ms), 0)\n    by CSEName\n| project\n    [''CSE Name''] = CSEName,\n    Sessions,\n    [''Avg (ms)''] = Avg_ms,\n    [''P50 (ms)''] = P50_ms,\n    [''P95 (ms)''] = P95_ms,\n    [''Max (ms)''] = Max_ms\n| order by [''Avg (ms)''] desc","size":1,"title":"Group Policy CSE Timing \u2014 {HostPool}","timeContextFromParameter":"TimeRange","queryType":0,"resourceType":"microsoft.operationalinsights/workspaces","visualization":"table","gridSettings":{"formatters":[{"columnMatch":"Avg \\(ms\\)|P95 \\(ms\\)","formatter":8,"formatOptions":{"palette":"whiteRed"},"numberFormat":{"unit":0,"options":{"style":"decimal","minimumFractionDigits":0}}}],"rowLimit":50,"filter":true}},"name":"table-cse-breakdown"},{"type":1,"content":{"json":"## Group Policy CSE Errors\n\nCSEs that failed or timed out (Events 7016/7017). A timed-out CSE often means a dependency \u2014 file server, DC, or network path \u2014 was unreachable. Cross-reference with the CSE Timing panel to identify which CSE is responsible for large total GP times."},"name":"text-cse-errors-header"},{"type":3,"content":{"version":"KqlItem/1.0","query":"let _hp = tolower(\"{HostPool}\");\nlet PoolHosts = WVDConnections\n| extend HostPool = tolower(tostring(split(_ResourceId, \"/\")[-1]))\n| where HostPool == _hp\n| where SessionHostName != \"<>\"\n| extend Host = tolower(tostring(split(SessionHostName, \".\")[0]))\n| distinct Host;\nEvent\n| where Source == \"Microsoft-Windows-GroupPolicy\" and EventID in (7016, 7017)\n| extend xd = parse_xml(EventData)\n| extend\n    CSEName = tostring(xd.DataItem.EventData.[\"Data\"][1][\"#text\"]),\n    Host    = tolower(tostring(split(Computer, \".\")[0]))\n| join kind=inner PoolHosts on Host\n| project\n    [''Time'']    = TimeGenerated,\n    Host,\n    [''Event'']   = iff(EventID == 7016, \"CSE Failed (7016)\", \"CSE Timed Out (7017)\"),\n    [''CSE'']     = iff(isempty(CSEName), \"(see details)\", CSEName),\n    [''Details''] = RenderedDescription\n| order by [''Time''] desc","size":1,"title":"Group Policy CSE Failures \u2014 {HostPool}","noDataMessage":"No CSE failures or timeouts in this time range.","timeContextFromParameter":"TimeRange","queryType":0,"resourceType":"microsoft.operationalinsights/workspaces","visualization":"table","gridSettings":{"formatters":[{"columnMatch":"Event","formatter":18,"formatOptions":{"thresholdsOptions":"icons","thresholdsGrid":[{"operator":"contains","thresholdValue":"Timed Out","representation":"2","text":"{0}{1}"},{"operator":"Default","thresholdValue":null,"representation":"3","text":"{0}{1}"}]}}],"rowLimit":100,"filter":true}},"name":"table-cse-errors"}],"fallbackResourceIds":["/subscriptions/2b9dd21c-8f1d-44aa-a344-4527243840c7/resourceGroups/nme-standard-1/providers/Microsoft.OperationalInsights/workspaces/nme-st1-law-vhsxofas5fpmu"],"$schema":"https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json"}'
$workbookContent = $workbookStaticJson.Replace('WORKSPACE_RESOURCE_ID_PLACEHOLDER', $WorkspaceResourceId)

$workbookBody = @{
    location = $workspaceLoc
    kind     = "shared"
    tags     = @{
        Purpose   = "AVD Login Diagnostics"
        Owner     = "NME Scripted Action"
        ManagedBy = "Enable-LoginDiagnostics"
    }
    properties = @{
        displayName    = "AVD Login Diagnostics"
        serializedData = $workbookContent
        sourceId       = $WorkspaceResourceId
        category       = "workbook"
        version        = "1.0"
    }
} | ConvertTo-Json -Depth 5

$wbResId = "/subscriptions/$subscriptionId/resourceGroups/$workspaceRg/providers/Microsoft.Insights/workbooks/$workbookGuid"
$wbResponse = Invoke-AzRestMethod -Method PUT -Path "${wbResId}?api-version=2022-04-01" -Payload $workbookBody

if ($wbResponse.StatusCode -in @(200, 201)) {
    Write-Output "  Workbook ready: AVD Login Diagnostics (RG: $workspaceRg)"
} else {
    Write-Warning "  Workbook deployment returned $($wbResponse.StatusCode): $($wbResponse.Content)"
}

# ===========================================================================
# Summary
# ===========================================================================

Write-Output ""
Write-Output "==========================================="
Write-Output "Setup Complete"
Write-Output "==========================================="
Write-Output "Workspace  : $($workspace.Name) ($workspaceRg)"
Write-Output "DCR        : $dcrName ($dcrRg)"
Write-Output "VMs        : $($vms.Count) associated, $($startedVms.Count) started for setup then deallocated"
Write-Output "Workbook   : AVD Login Diagnostics ($workspaceRg)"
Write-Output "Workbook URL: https://portal.azure.com/#resource/subscriptions/$subscriptionId/resourceGroups/$workspaceRg/providers/microsoft.insights/workbooks/$workbookGuid"
Write-Output ""
Write-Output "Events begin flowing within 5-10 minutes."
Write-Output "Trigger a user login to generate GP and FSLogix events."
Write-Output "==========================================="
} catch {
    Write-Error $_.Exception.Message
    throw
}
