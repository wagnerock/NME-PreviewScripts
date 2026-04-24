# Nerdio Manager for Enterprise (NME) — Scripted Actions Reference

## Overview

Nerdio Manager for Enterprise (NME) is a management portal for Azure AVD, Intune, Windows 365 CloudPC, and other Microsoft technologies. Its **Scripted Actions** feature allows PowerShell scripts to run either on an Azure VM (via a custom script extension) or in an Azure Automation account (as a runbook).

---

## Script Types

| Type | Runs In | Auth | Notes |
|---|---|---|---|
| **Windows Script** | Azure VM (as SYSTEM) | N/A | Custom script extension |
| **Azure Runbook** | Azure Automation Account | Handled by NME | Use `Az` modules, not `AzureRM` |

Both types run **non-interactively** — no user input prompts.

---

## Execution Contexts

### 1. Against a Single VM
- User selects a VM or host pool in NME and chooses **Run Script** (or Hosts → Run Script for all VMs in a pool).
- Both Windows Scripts and Azure Runbooks can run in this context.
- An Azure Runbook running against a VM will have `$AzureVMName` available but still executes in the automation account.

### 2. From the Scripted Actions Section (Runbooks Only)
- User navigates to Scripted Actions → Azure Runbooks and selects **Run now** or **Schedule**.
- VM-specific predefined variables (e.g., `$AzureVMName`, `$AzureResourceGroupName`) are **not** available in this context.

---

## Predefined Variables

| Variable | Available When |
|---|---|
| `$AzureSubscriptionId` | Always |
| `$AzureSubscriptionName` | Always |
| `$HostPoolId` | Script runs against a VM |
| `$HostPoolName` | Script runs against a VM |
| `$AzureResourceGroupName` | Script associated with a VM (not when run from Scripted Actions section) |
| `$AzureRegionName` | Script associated with an AVD host or desktop image VM |
| `$AzureVMName` | Script associated with a VM (not when run from Scripted Actions section) |
| `$ADUsername` | AD credentials option selected at runtime |
| `$ADPassword` | AD credentials option selected at runtime |
| `$DesktopUser` | Script associated with a personal desktop VM (UPN) |

---

## Session Host vs. VM Name

- An AVD session host name is **not** the same as its VM name.
- The VM name is the portion of the session host name **before the first `.`**.
- The VM object has a tag `NMW_VM_FQDN` whose value equals the session host name.

---

## Script Structure

### Required Header

Every scripted action must begin with:

```powershell
#description: Description of what the scripted action does
#tags: Tag1, Tag2
```

### Runtime Parameters

Parameters are declared in a `Variables` comment block using JSON. These do **not** need to repeat predefined variables.

```powershell
<# Variables:
{
  "ParameterName": {
    "Description": "What this parameter does",
    "IsRequired": true,
    "DefaultValue": ""
  }
}
#>
```

### Secure Variables

Sensitive values (passwords, API keys, secrets) must **not** be hardcoded or passed as plain-text runtime parameters. Instead:

1. Create a **Secure Variable** in the NME management console.
2. Access it in the script via the `$SecureVars` hashtable:

```powershell
$apiKey = $SecureVars["MyApiKeyName"]
```

Always advise which Secure Variables need to be created when writing scripts that require sensitive data.

---

## Azure Runbook Notes

- Authentication to Azure is handled by NME before the script body executes — no explicit `Connect-AzAccount` needed.
- Runbooks run with the same Azure permissions that NME itself has.
- Always set the correct subscription context at the start:

```powershell
Set-AzContext -SubscriptionId $AzureSubscriptionId
```

- Use `Az` PowerShell modules. Use `Microsoft.Graph` / `MgGraph` for Azure AD data.

---

## Windows Script Notes

- Runs as the **SYSTEM** user on the target VM.
- Can install modules (e.g., `PSWindowsUpdate`) and make local system changes.

---

## Quick-Reference Checklist for New Scripts

- [ ] `#description:` line at the top
- [ ] Optional `#tags:` line
- [ ] `<# Variables: ... #>` block if accepting runtime parameters
- [ ] Sensitive data referenced via `$SecureVars`, not hardcoded
- [ ] Correct script type declared (Windows Script or Azure Runbook)
- [ ] Correct execution context declared (against VM, or from Scripted Actions section)
- [ ] For runbooks: `Set-AzContext` called early; `Az` modules used (not `AzureRM`)
- [ ] `$ErrorActionPreference = 'Stop'` set for runbooks
