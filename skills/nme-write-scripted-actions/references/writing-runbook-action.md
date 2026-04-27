# Writing an Azure Automation Runbook Scripted Action

Use `executionEnvironment: AzureAutomation` for scripts that need to call Azure APIs, manage
AVD resources, move session hosts, update tags, or do anything that requires Azure PowerShell
cmdlets. The runbook runs in NME's Azure Automation account — not on a VM.

## Key Facts

- **Already authenticated** — NME's service principal context is active. Never call
  `Connect-AzAccount`. Use `Get-AzContext` to inspect the current subscription.
- **Az modules available** — All standard Az.* modules are pre-installed in the Automation account.
- **Other PS Modules in gallery** - Other required powershell modules can be installed from the powershell gallery
- **Not VM-bound** — The script has no local Windows context. Use `Invoke-AzVMRunCommand` to
  execute anything on a VM.
- **Timeout** — 90 minutes max (set `executionTimeout: 90` in the API payload).
- **Output** — `Write-Output` appears in the NME job log. `Write-Warning` logs but does not fail
  the job. `throw` fails the job immediately.
- **Execution Context** - Azure runbook scripts always run individually and are not combined with other scripts

## Script Header

```powershell
#description: Brief description of what this script does
#tags: Tag1, Tag2, etc.
```


## Variables Block

Declares user-facing parameters shown in the NME UI (and passed via `paramsBindings` via API):

```powershell
<#variables:
{
  "ParamName": {
    "Description": "What this parameter does",
    "DisplayName": "Label in UI"
  }
}
#>
```

The variables/parameters defined in the json are injected as PowerShell variables (`$ParamName`) by NME before the script runs.
For API execution, supply them via `paramsBindings`.

Azure Automation (runbook) scripts do NOT need a `param()` block. 


## Built-in Context Variables

Available without declaring them:

```
$AzureSubscriptionId      Current subscription ID
$AzureSubscriptionName    Current subscription name
$AzureResourceGroupName   Resource group (when run in host pool context)
$AzureVMName              VM name (when run in host pool/VM context)
$HostPoolId               Host pool ARM resource ID (AVD ARM only)
$HostPoolName             Host pool name
$SATrigger                What triggered the script
$SecureVars.VarName       Secure variables from Key Vault
```

## Running Commands on VMs

Use `Invoke-AzVMRunCommand` to execute PowerShell inside a VM:

```powershell
$result = Invoke-AzVMRunCommand `
    -ResourceGroupName $vmRG `
    -VMName            $vmName `
    -CommandId         'RunPowerShellScript' `
    -ScriptPath        '.\my-script.ps1'   # write to a file first, then pass path

$stdout = $result.Value | Where-Object Code -eq 'ComponentStatus/StdOut/succeeded' |
    Select-Object -ExpandProperty Message
$stderr = $result.Value | Where-Object Code -eq 'ComponentStatus/StdErr/succeeded' |
    Select-Object -ExpandProperty Message
```

**Important**: The VM must be running when `Invoke-AzVMRunCommand` is called — it will throw
`OperationNotAllowed` if the VM is stopped/deallocated. Return the VM to whatever power state it was in after running the script.

## Heredoc Escaping Rules (Critical)

When building an inner script string with `@"..."@` to pass to `Invoke-AzVMRunCommand`:

- Variables you want resolved in the **outer** (runbook) scope: use `$var` normally
- Variables you want resolved in the **inner** (VM) scope: prefix with backtick `` `$var ``
- **Do NOT use backtick line continuation (`` ` ``) inside a heredoc** — it gets mangled when
  written to a file via `Out-File`. Collapse multi-line `Start-Process` or similar calls to a
  single line inside the heredoc.

```powershell
# CORRECT — $RegistrationToken resolved in runbook; $r resolved in VM
$innerScript = @"
`$r = Start-Process msiexec.exe -ArgumentList "/i ""msi"" REGISTRATIONTOKEN=$RegistrationToken" -Wait -PassThru
"@

# WRONG — backtick line continuation inside heredoc
$innerScript = @"
`$r = Start-Process msiexec.exe `
    -ArgumentList "/i ""msi""" `   # This breaks when written to file
    -Wait -PassThru
"@
```

## Error Handling

```powershell
$ErrorActionPreference = 'Stop'   # top of script — unhandled errors fail the job

throw "Descriptive error message"  # fails job, appears in NME job output
Write-Warning "Non-fatal issue"    # logged, job continues
Write-Error "..." -ErrorAction Continue  # logged, continues (not recommended)
```

## Template

```powershell
#description: What this script does
#tags: Tag1, Tag2

<#variables:
{
  "MyParam": {
    "Description": "Description of the parameter",
    "DisplayName": "My Parameter"
  }
}
#>

$ErrorActionPreference = 'Stop'

Write-Output "=== Starting: $($MyParam) ==="

# ... script body ...

Write-Output "=== Done ==="
```
