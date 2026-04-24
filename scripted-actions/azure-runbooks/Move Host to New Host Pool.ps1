#description: Moves an AVD session host from its current host pool to a target host pool by re-registering the RDAgent
#execution mode: Individual
#tags: Nerdio, AVD, Host Pool, Migration

<#
Notes:

Removes the specified VM from its current host pool and re-registers it with a target host pool
by downloading fresh RDAgent MSIs from the Microsoft CDN, uninstalling existing components,
reinstalling the BootLoader (no token), then reinstalling the Agent with the target pool's
registration token. Also updates the NMW_ARM_HOST_POOL Azure VM tag to point to the target pool.

Requirements:
- The target host pool must exist and be accessible to the NME service principal
- The VM must have internet access to reach query.prod.cms.rt.microsoft.com (Microsoft CDN)
- No active user sessions should be present; the script will warn if sessions exist
- Run as an Azure Runbook scripted action (not bound to a specific host pool)

Compatibility checks (run before any changes are made, unless SkipCompatibilityChecks=true):
- Host pool type must match: both Pooled or both Personal
- Domain join type must match: inferred from session host FQDNs (AD-joined hosts have a domain
  suffix, e.g. vmname.domain.com; Entra ID joined hosts register with no domain suffix).
  Requires at least one existing session host in the target pool to compare against. If the
  target pool is empty the domain check is skipped with a warning.

Idempotency:
- If the VM has already been removed from the source host pool (e.g. a prior partial run),
  the removal step is skipped and the script continues with re-registration.
- If the VM is deallocated, it is started automatically, the RDAgent is re-registered,
  and then it is deallocated again.

Limitations:
- Target host pool must be ARM-based (Spring 2020 AVD). Not compatible with v1 / Fall 2019 WVD.

#>

<#variables:
{
  "AzureVMName": {
    "Description": "Name of the Azure VM to move (session host display name, not FQDN)",
    "DisplayName": "VM Name"
  },
  "SourceHostPoolResourceId": {
    "Description": "Full Azure Resource ID of the source host pool the VM is currently registered to. Example: /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.DesktopVirtualization/hostPools/my-source-pool",
    "DisplayName": "Source Host Pool Resource ID"
  },
  "TargetHostPoolResourceId": {
    "Description": "Full Azure Resource ID of the target host pool. Example: /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.DesktopVirtualization/hostPools/my-pool",
    "DisplayName": "Target Host Pool Resource ID"
  },
  "SkipCompatibilityChecks": {
    "Description": "Set to 'true' to skip host pool type and domain join validation. Useful when moving to an empty target pool where domain type cannot be inferred. Default: false.",
    "DisplayName": "Skip Compatibility Checks"
  }
}
#>

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1. Resolve source and target host pools
# ---------------------------------------------------------------------------
Write-Output "=== Resolving host pools ==="
$SourceHostPool = Get-AzResource -ResourceId $SourceHostPoolResourceId
$SourceRG       = $SourceHostPool.ResourceGroupName
$SourceHPName   = $SourceHostPool.Name
Write-Output "Source : $SourceHPName (RG: $SourceRG)"

$TargetHostPool = Get-AzResource -ResourceId $TargetHostPoolResourceId
$TargetRG       = $TargetHostPool.ResourceGroupName
$TargetHPName   = $TargetHostPool.Name
Write-Output "Target : $TargetHPName (RG: $TargetRG)"

if ($SourceHPName -eq $TargetHPName -and $SourceRG -eq $TargetRG) {
    throw "Source and target host pools are the same. Nothing to do."
}

$SourceHPConfig = Get-AzWvdHostPool -ResourceGroupName $SourceRG -HostPoolName $SourceHPName
$TargetHPConfig = Get-AzWvdHostPool -ResourceGroupName $TargetRG -HostPoolName $TargetHPName
Write-Output "Source pool type: $($SourceHPConfig.HostPoolType)"
Write-Output "Target pool type: $($TargetHPConfig.HostPoolType)"

# ---------------------------------------------------------------------------
# 2. Get the VM
# ---------------------------------------------------------------------------
Write-Output "=== Getting VM: $AzureVMName ==="
$VM = Get-AzVM -Name $AzureVMName
if (-not $VM) {
    throw "VM '$AzureVMName' not found in the current subscription."
}
$VMResourceGroup = $VM.ResourceGroupName
Write-Output "VM found in resource group: $VMResourceGroup"

# ---------------------------------------------------------------------------
# 3. Find the session host entry in the source host pool (do not remove yet)
# ---------------------------------------------------------------------------
Write-Output "=== Locating session host in source host pool ==="
$SessionHosts = Get-AzWvdSessionHost -HostPoolName $SourceHPName -ResourceGroupName $SourceRG -ErrorAction SilentlyContinue
$SessionHost  = $SessionHosts | Where-Object { $_.Name -match [regex]::Escape($AzureVMName) }

if ($SessionHost) {
    $SessionHostShortName = ($SessionHost.Name -split '/')[1]
    Write-Output "Found session host: $SessionHostShortName"

    $ActiveSessions = Get-AzWvdUserSession -HostPoolName $SourceHPName -ResourceGroupName $SourceRG `
        -SessionHostName $SessionHostShortName -ErrorAction SilentlyContinue
    if ($ActiveSessions) {
        Write-Warning "Session host has $($ActiveSessions.Count) active user session(s). Proceeding anyway."
    }

    $AssignedUser = $SessionHost.AssignedUser
    if ($AssignedUser) { Write-Output "Assigned user: $AssignedUser" }
} else {
    Write-Output "Session host not found in '$SourceHPName' — may have been removed in a prior run. Continuing."
    $AssignedUser = $null
}

# ---------------------------------------------------------------------------
# 4. Compatibility checks (skipped if SkipCompatibilityChecks=true)
# ---------------------------------------------------------------------------
if ($SkipCompatibilityChecks -ne 'true') {
    Write-Output "=== Running compatibility checks ==="

    # 4a. Host pool type must match (Personal vs Pooled)
    if ($SourceHPConfig.HostPoolType -ne $TargetHPConfig.HostPoolType) {
        throw "Host pool type mismatch: source is '$($SourceHPConfig.HostPoolType)', target is '$($TargetHPConfig.HostPoolType)'. " +
              "Set SkipCompatibilityChecks=true to override."
    }
    Write-Output "Host pool type: both are '$($SourceHPConfig.HostPoolType)'. OK."

    # 4b. Domain join type — inferred from session host FQDN suffixes.
    #     AD-joined hosts register with a domain suffix: vmname.domain.com
    #     Entra ID joined hosts register with no domain suffix: vmname
    if ($SessionHost) {
        $SourceFQDN   = ($SessionHost.Name -split '/')[1]
        $SourceDomain = if ($SourceFQDN -match '\.') { $SourceFQDN.Substring($SourceFQDN.IndexOf('.') + 1) } else { '' }
        $SourceLabel  = if ($SourceDomain) { "AD ('$SourceDomain')" } else { 'Entra ID (no AD domain)' }

        # Find an existing session host in the target pool (excluding the VM being moved)
        $TargetSH = Get-AzWvdSessionHost -HostPoolName $TargetHPName -ResourceGroupName $TargetRG `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch [regex]::Escape($AzureVMName) } |
            Select-Object -First 1

        if ($TargetSH) {
            $TargetFQDN   = ($TargetSH.Name -split '/')[1]
            $TargetDomain = if ($TargetFQDN -match '\.') { $TargetFQDN.Substring($TargetFQDN.IndexOf('.') + 1) } else { '' }
            $TargetLabel  = if ($TargetDomain) { "AD ('$TargetDomain')" } else { 'Entra ID (no AD domain)' }

            if ($SourceDomain -ne $TargetDomain) {
                throw "Domain join type mismatch: source VM is $SourceLabel joined, target pool hosts are $TargetLabel joined. " +
                      "Set SkipCompatibilityChecks=true to override."
            }
            Write-Output "Domain join type: source=$SourceLabel, target=$TargetLabel. OK."
        } else {
            Write-Warning "Target pool '$TargetHPName' has no existing session hosts — cannot validate domain join type. Skipping domain check."
        }
    } else {
        Write-Warning "Source session host not found in '$SourceHPName' (may have been removed in a prior run) — cannot validate domain join type. Skipping domain check."
    }

    Write-Output "Compatibility checks passed."
} else {
    Write-Output "SkipCompatibilityChecks=true — skipping host pool type and domain join validation."
}

# ---------------------------------------------------------------------------
# 5. Remove session host from source host pool (if still present)
# ---------------------------------------------------------------------------
if ($SessionHost) {
    Write-Output "=== Removing session host from source host pool ==="
    Remove-AzWvdSessionHost -ResourceGroupName $SourceRG -HostPoolName $SourceHPName `
        -Name $SessionHostShortName -Force
    Write-Output "Session host removed from '$SourceHPName'."
}

# ---------------------------------------------------------------------------
# 6. Get or create a registration token for the TARGET host pool
# ---------------------------------------------------------------------------
Write-Output "=== Getting registration token for target host pool ==="
$RegInfo = Get-AzWvdRegistrationInfo -ResourceGroupName $TargetRG -HostPoolName $TargetHPName

if (-not $RegInfo.Token) {
    Write-Output "No active token — generating a new one (24-hour expiry)"
    $RegInfo = New-AzWvdRegistrationInfo `
        -ResourceGroupName $TargetRG `
        -HostPoolName      $TargetHPName `
        -ExpirationTime    $((Get-Date).ToUniversalTime().AddDays(1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'))
}
$RegistrationToken = $RegInfo.Token
Write-Output "Registration token obtained."

# ---------------------------------------------------------------------------
# 7. Ensure VM is running (start it if deallocated; track if we started it)
# ---------------------------------------------------------------------------
Write-Output "=== Checking VM power state ==="
$VMStatus   = Get-AzVM -Name $AzureVMName -ResourceGroupName $VMResourceGroup -Status
$PowerState = ($VMStatus.Statuses | Where-Object Code -like 'PowerState/*').Code
Write-Output "Current power state: $PowerState"

$StartedByScript = $false
if ($PowerState -ne 'PowerState/running') {
    Write-Output "VM is not running — starting it now..."
    Start-AzVM -ResourceGroupName $VMResourceGroup -Name $AzureVMName | Out-Null
    Write-Output "VM started."
    $StartedByScript = $true
}

# ---------------------------------------------------------------------------
# 8. Re-register the RDAgent on the VM via RunCommand
#    Uninstall existing components, download fresh MSIs from Microsoft CDN,
#    install BootLoader (no token), then Agent with the new registration token.
# ---------------------------------------------------------------------------
Write-Output "=== Re-registering RDAgent on $AzureVMName ==="

$ReregisterScript = @"
`$ErrorActionPreference = 'Stop'
`$tempFolder = [environment]::GetEnvironmentVariable('TEMP', 'Machine')
`$logsPath = "`$tempFolder\NMWLogs\WVDApps"
if (-not (Test-Path `$logsPath)) { New-Item -Path `$logsPath -ItemType Directory -Force | Out-Null }

Write-Output "=== Uninstalling existing RD components ==="
`$RDPrograms = Get-WmiObject Win32_Product | Where-Object Name -match 'Remote Desktop Services Infrastructure Agent|Remote Desktop Agent Boot Loader'
foreach (`$p in `$RDPrograms) {
    Write-Output "Uninstalling: `$(`$p.Name)"
    `$r = Start-Process msiexec.exe -ArgumentList "/x `$(`$p.IdentifyingNumber) /quiet /qn /norestart /passive /l* `$logsPath\uninstall.log" -Wait -PassThru
    Write-Output "  Exit code: `$(`$r.ExitCode)"
}

Write-Output "=== Downloading fresh MSIs from Microsoft CDN ==="
[System.Net.ServicePointManager]::SecurityProtocol = 'Tls12'
`$agentMsi = "`$tempFolder\RDAgent.msi"
`$blMsi    = "`$tempFolder\RDAgentBootLoader.msi"
Invoke-WebRequest -Uri 'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv' -UseBasicParsing -OutFile `$agentMsi
Write-Output "Agent MSI downloaded."
Invoke-WebRequest -Uri 'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH' -UseBasicParsing -OutFile `$blMsi
Write-Output "BootLoader MSI downloaded."

Write-Output "=== Installing BootLoader (no token) ==="
`$r = Start-Process msiexec.exe -ArgumentList "/i ""`$blMsi"" /quiet /qn /norestart /passive /l* `$logsPath\bl-install.log" -Wait -PassThru
Write-Output "BootLoader install exit code: `$(`$r.ExitCode)"
if (`$r.ExitCode -ne 0) { throw "BootLoader installation failed (exit code `$(`$r.ExitCode))." }

Write-Output "=== Installing Agent with registration token ==="
`$r = Start-Process msiexec.exe -ArgumentList "/i ""`$agentMsi"" /quiet /qn /norestart /passive REGISTRATIONTOKEN=$RegistrationToken /l* `$logsPath\agent-install.log" -Wait -PassThru
Write-Output "Agent install exit code: `$(`$r.ExitCode)"
if (`$r.ExitCode -ne 0) {
    `$log = Get-Content `$logsPath\agent-install.log -ErrorAction SilentlyContinue | Select-Object -Last 30
    Write-Output `$log
    throw "Agent installation failed (exit code `$(`$r.ExitCode))."
}
Write-Output "RDAgent registration complete."
"@

$ScriptFile = ".\Reregister-AVDAgent-$AzureVMName.ps1"
$ReregisterScript | Out-File $ScriptFile

$RunCommand = Invoke-AzVMRunCommand `
    -ResourceGroupName $VMResourceGroup `
    -VMName            $AzureVMName `
    -CommandId         'RunPowerShellScript' `
    -ScriptPath        $ScriptFile

Write-Output "--- RunCommand stdout ---"
$RunCommand.Value | Where-Object Code -eq 'ComponentStatus/StdOut/succeeded' |
    Select-Object -ExpandProperty Message

$StdErr = $RunCommand.Value | Where-Object Code -eq 'ComponentStatus/StdErr/succeeded' |
    Select-Object -ExpandProperty Message
if ($StdErr) {
    throw "RunCommand reported errors:`n$StdErr"
}

# ---------------------------------------------------------------------------
# 9. Update the NMW_ARM_HOST_POOL tag to point to the target host pool.
#    This tag uses the format: {subscriptionId}/{resourceGroup}/{hostPoolName}
#    Only this specific tag is updated — other tags (e.g. NMW_VM_FQDN) are
#    left unchanged as they reflect the VM itself, not its host pool assignment.
# ---------------------------------------------------------------------------
Write-Output "=== Updating VM tags ==="
$VMFull = Get-AzVM -Name $AzureVMName -ResourceGroupName $VMResourceGroup
$Tags   = $VMFull.Tags

if ($Tags -and $Tags.Count -gt 0) {
    $SourceHPTagValue = "$($SourceHostPool.SubscriptionId)/$SourceRG/$SourceHPName"
    $TargetHPTagValue = "$($TargetHostPool.SubscriptionId)/$TargetRG/$TargetHPName"

    $HPTag = 'NMW_ARM_HOST_POOL'
    if ($Tags.ContainsKey($HPTag)) {
        $current = $Tags[$HPTag]
        if ($current -eq $SourceHPTagValue) {
            $Tags[$HPTag] = $TargetHPTagValue
            Update-AzTag -ResourceId $VM.Id -Tag $Tags -Operation Replace | Out-Null
            Write-Output "Updated '$HPTag': '$current' -> '$TargetHPTagValue'"
        } else {
            Write-Output "'$HPTag' value is '$current' — does not match expected source '$SourceHPTagValue'. Skipping tag update."
        }
    } else {
        Write-Output "Tag '$HPTag' not found on VM — no tag changes needed."
    }
} else {
    Write-Output "VM has no tags — skipping tag update."
}

# ---------------------------------------------------------------------------
# 10. Wait for the RDAgent to register with the target host pool before
#     stopping or restarting. Registration is asynchronous — the MSI install
#     completes but the broker handshake takes ~60-90s.
# ---------------------------------------------------------------------------
Write-Output "=== Waiting 120s for RDAgent to register with target host pool ==="
Start-Sleep -Seconds 120

# ---------------------------------------------------------------------------
# 11. Restart the VM (or deallocate if we started it just for re-registration)
# ---------------------------------------------------------------------------
if ($StartedByScript) {
    Write-Output "=== VM was started by this script — deallocating it again ==="
    Stop-AzVM -ResourceGroupName $VMResourceGroup -Name $AzureVMName -Force | Out-Null
    Write-Output "VM deallocated."
} else {
    Write-Output "=== Restarting VM so agent picks up new host pool ==="
    Restart-AzVM -ResourceGroupName $VMResourceGroup -Name $AzureVMName | Out-Null
    Write-Output "VM restarted."
}

# ---------------------------------------------------------------------------
# 12. Re-assign user if this was a personal host pool
# ---------------------------------------------------------------------------
if ($SourceHPConfig.HostPoolType -eq 'Personal' -and $AssignedUser) {
    Write-Output "=== Re-assigning user '$AssignedUser' in target host pool (Personal pool) ==="
    Start-Sleep -Seconds 30
    $NewSessionHost = Get-AzWvdSessionHost -HostPoolName $TargetHPName -ResourceGroupName $TargetRG |
        Where-Object { $_.Name -match [regex]::Escape($AzureVMName) }
    if ($NewSessionHost) {
        $NewSHShortName = ($NewSessionHost.Name -split '/')[1]
        Update-AzWvdSessionHost `
            -HostPoolName      $TargetHPName `
            -ResourceGroupName $TargetRG `
            -Name              $NewSHShortName `
            -AssignedUser      $AssignedUser
        Write-Output "User '$AssignedUser' re-assigned to '$NewSHShortName' in '$TargetHPName'."
    } else {
        Write-Warning "Session host '$AzureVMName' not yet visible in '$TargetHPName' after 30s. Re-assign '$AssignedUser' manually."
    }
}

Write-Output "=== Done. '$AzureVMName' moved to host pool '$TargetHPName'. ==="
