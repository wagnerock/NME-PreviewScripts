# Create Azure Runbook Scripted Action

Create a new NME Azure Runbook scripted action PowerShell script based on the user's description.

## What is an Azure Runbook Scripted Action

An Azure Runbook scripted action runs in an Azure Automation account, not on a VM. It is non-interactive and cannot prompt for user input. NME handles Azure authentication before the script body runs — no `Connect-AzAccount` is needed. The runbook runs with the same Azure permissions that NME has. Use `Az` PowerShell modules; never use `AzureRM`.

## Execution contexts

A runbook can be invoked in two ways — determine which applies and note it for the user:

1. **Against a VM** — triggered from a VM or host pool in NME. VM-specific predefined variables are available (`$AzureVMName`, `$AzureResourceGroupName`, etc.).
2. **From the Scripted Actions section** — triggered via Run Now or Schedule in the Scripted Actions → Azure Runbooks UI. VM-specific variables are **not** available. Any host pool or VM info must be passed as runtime parameters.

## Output location

Save the file to `scripted-actions/azure-runbooks/<Human Readable Name>.ps1`. Use a human-readable, title-case name with spaces — not PowerShell kebab-case. Example: `Move Host to New Host Pool.ps1`.

## Required script structure

```powershell
#description: <clear description of what the script does>
#tags: <comma-separated tags>

<# Notes:
<expanded explanation of what the script does, requirements, caveats, behavior>
#>

<# Variables:
{
  "ParameterName": {
    "Description": "What this parameter is for",
    "IsRequired": true,
    "DefaultValue": ""
  }
}
#>

$ErrorActionPreference = 'Stop'

# Set subscription context
Set-AzContext -SubscriptionId $AzureSubscriptionId

# ... script body ...

### End Script ###
```

Rules:
- The `#description:` line is always required.
- The `#tags:` line is optional but recommended.
- The `<# Notes: #>` block is optional but should be included when the script has meaningful caveats, requirements, or behavior worth explaining.
- The `<# Variables: #>` block is only needed if the script accepts runtime parameters. Omit it entirely if there are no parameters.
- Always include `$ErrorActionPreference = 'Stop'` at the top of the script body.
- Always call `Set-AzContext -SubscriptionId $AzureSubscriptionId` early in the script.
- The `### End Script ###` footer is always included.

## Predefined variables (do not redeclare these)

These are injected by NME before the script body runs:

**Always available:**
- `$AzureSubscriptionId`
- `$AzureSubscriptionName`

**Available when run against a VM:**
- `$AzureVMName`
- `$AzureResourceGroupName`
- `$AzureRegionName`
- `$HostPoolId`
- `$HostPoolName`

**Conditionally available:**
- `$ADUsername` / `$ADPassword` — if AD credentials are passed at runtime
- `$DesktopUser` — UPN of user associated with a personal desktop VM

When the script runs from the Scripted Actions section (not against a VM), any required host pool or VM info must be declared as runtime parameters in the `<# Variables: #>` block.

## Session host vs VM name

The AVD session host name is not the same as the VM name. The VM name is the portion before the first `.` in the session host name. The VM also has a tag `NMW_VM_FQDN` whose value equals the session host name.

## Sensitive data

Never hardcode passwords, API keys, or secrets. Instruct the user to create a **Secure Variable** in NME for each sensitive value, then access it in the script via:

```powershell
$SecureVars["VariableName"]
```

## PowerShell modules

- Use `Az` modules for all Azure resource operations.
- Use `Microsoft.Graph` / `MgGraph` for Azure AD / Entra ID data.
- Never use `AzureRM`.

## After writing the script

Tell the user:
1. This is an **Azure Runbook** scripted action.
2. Which execution context to use: against a VM, or from the Scripted Actions section.
3. Which Secure Variables to create in NME, if any.
4. Any other prerequisites (RBAC permissions, required resources, etc.).
