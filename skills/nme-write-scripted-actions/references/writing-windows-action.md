# Writing a Windows Scripted Action

Use windows scripted actions for scripts that run directly on a session host VM —
configuring Windows settings, reading event logs, installing software, checking local state.

## Key Facts

- **Runs as LocalSystem** — full admin access to the VM, but no user context.
- **Delivered via Azure Custom Script Extension** — NME copies the script to the cssa storage 
account. NME installs the Custom Sript Extension, which contains a wrapper powershell script that 
retrieves and executes the script from the cssa storage account.
- **90-minute hard timeout** — the Custom Script Extension enforces this; not configurable.
- **No Azure context** — cannot call Az PowerShell cmdlets. To interact with Azure from the VM,
  use `az` CLI (if installed) or REST calls with a managed identity token.
- **`executionTimeout` must be `0`** in the API payload for CustomScript scripts.

## Script Header


```powershell
#description: Brief description
#execution mode: Individual
#tags: Tag1, Tag2
```
Execution modes: `Combined`, `Individual`, `IndividualWithRestart`


## Variables Block + `param()` Requirement

**Critical**: When creating Windows Scripted Actions via the NME REST API with a `#variables` block,
the script **must also include a matching `param()` block** or NME will reject it with
`"Parameter 'X' is not found in 'param' block"`.

```powershell
#description: Configure something on the VM
#execution mode: Individual
#tags: Windows, Config

<#variables:
{
  "TargetPath": {
    "Description": "Path to configure",
    "DisplayName": "Target Path"
  }
}
#>

param(
    [string]$TargetPath
)

$ErrorActionPreference = 'Stop'
# ... script body ...
```

## Built-in Context Variables

Injected by NME:
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

## Accessing Secure Variables

```powershell
$SecureVars.MySecretVariable  # stored in Azure Key Vault, managed via NME
```

## Common Patterns

### Check and configure a local setting
```powershell
$ErrorActionPreference = 'Stop'

$value = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\...' -Name 'Setting' -ErrorAction SilentlyContinue
if ($value -ne 'Expected') {
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\...' -Name 'Setting' -Value 'Expected'
    Write-Output "Setting updated."
} else {
    Write-Output "Setting already correct."
}
```

### Read event logs
```powershell
$events = Get-WinEvent -LogName 'Microsoft-Windows-GroupPolicy/Operational' `
    -FilterXPath '*[System[EventID=5016]]' -MaxEvents 20 -ErrorAction SilentlyContinue
foreach ($e in $events) {
    Write-Output "$($e.TimeCreated): $($e.Message)"
}
```

### Install software (MSI)
```powershell
$msi = 'C:\Temp\installer.msi'
$log = 'C:\Temp\install.log'
$r = Start-Process msiexec.exe -ArgumentList "/i ""$msi"" /quiet /qn /norestart /l* $log" -Wait -PassThru
Write-Output "Exit code: $($r.ExitCode)"
if ($r.ExitCode -ne 0) {
    $tail = Get-Content $log -Tail 20 -ErrorAction SilentlyContinue
    Write-Output $tail
    throw "Installation failed (exit code $($r.ExitCode))."
}
```

## Transcript Logging

Always use `Start-Transcript` at the top of the script to capture all output to a file.
Use the standard NME log directory: `C:\Windows\Temp\NMWLogs\ScriptedActions\`

Name the transcript file after the script so logs are easy to identify:

```powershell
$logDir = 'C:\Windows\Temp\NMWLogs\ScriptedActions'
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
Start-Transcript -Path "$logDir\MyScriptName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log" -Append
```

Call `Stop-Transcript` at the end (or let the script exit — PowerShell stops the transcript
automatically, but calling it explicitly ensures the file is flushed before any post-script
cleanup runs).

Transcript logs persist on the VM and are invaluable for debugging — the NME job output only
shows what was written to stdout during the run, while the transcript captures everything
including errors that occur before `Write-Output` can fire.

## Error Handling

Same as runbooks:
- `throw` fails the job
- `Write-Warning` logs and continues
- Use `$ErrorActionPreference = 'Stop'` at top for unhandled exceptions

## Template

```powershell
#description: What this script does on the VM
#execution mode: Individual
#tags: Windows, Tag2

<#variables:
{
  "MyParam": {
    "Description": "What this parameter does",
    "DisplayName": "My Parameter"
  }
}
#>

param(
    [string]$MyParam
)

$ErrorActionPreference = 'Stop'

$logDir = 'C:\Windows\Temp\NMWLogs\ScriptedActions'
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
Start-Transcript -Path "$logDir\MyScriptName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log" -Append

Write-Output "Running on: $env:COMPUTERNAME"
Write-Output "Parameter: $MyParam"

# ... script body ...

Write-Output "Done."
Stop-Transcript
```
