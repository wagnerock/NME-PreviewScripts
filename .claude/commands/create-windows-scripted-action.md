# Create Windows Scripted Action

Create a new NME Windows scripted action PowerShell script based on the user's description.

## What is a Windows Scripted Action

A Windows scripted action runs on an Azure VM via a custom script extension, as the SYSTEM user. It is non-interactive and cannot prompt for user input. It runs in the context of a single VM (or each VM in a host pool individually).

## Output location

Save the file to `scripted-actions/windows-scripts/<Human Readable Name>.ps1`. Use a human-readable, title-case name with spaces — not PowerShell kebab-case. Example: `Windows Localization - Japan.ps1`.

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

# ... script body ...

### End Script ###
```

Rules:
- The `#description:` line is always required.
- The `#tags:` line is optional but recommended.
- The `<# Notes: #>` block is optional but should be included when the script has meaningful caveats, requirements, or behavior worth explaining.
- The `<# Variables: #>` block is only needed if the script accepts runtime parameters. Omit it entirely if there are no parameters.
- The `### End Script ###` footer is always included.

## Predefined variables (do not redeclare these)

These are injected by NME before the script body runs. Use them freely without declaring them:

- `$AzureSubscriptionId` — always available
- `$AzureSubscriptionName` — always available
- `$AzureVMName` — name of the target VM
- `$AzureResourceGroupName` — resource group of the VM
- `$AzureRegionName` — Azure region of the VM
- `$HostPoolId` — full resource ID of the host pool
- `$HostPoolName` — name of the host pool
- `$ADUsername` / `$ADPassword` — available if AD credentials are passed at runtime
- `$DesktopUser` — UPN of user associated with a personal desktop VM

## Session host vs VM name

The AVD session host name is not the same as the VM name. The VM name is the portion before the first `.` in the session host name. The VM also has a tag `NMW_VM_FQDN` whose value equals the session host name.

## Sensitive data

Never hardcode passwords, API keys, or secrets. Instruct the user to create a **Secure Variable** in NME for each sensitive value, then access it in the script via:

```powershell
$SecureVars["VariableName"]
```

## After writing the script

Tell the user:
1. This is a **Windows Script** and should be run against a VM (or via Hosts → Run Script on a host pool).
2. Which Secure Variables to create in NME, if any.
3. Any caveats — e.g. whether a reboot is required, or whether the change only takes effect after the user signs out.
