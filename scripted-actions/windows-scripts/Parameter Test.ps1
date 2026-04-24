#description: Outputs runtime parameters and predefined variables to verify parameter passing works correctly in Windows scripted actions.
#execution mode: Combined
#tags: Test, Debug

<# Variables:
{
  "StringParam": {
    "Description": "A sample string parameter.",
    "IsRequired": true,
    "DefaultValue": ""
  },
  "NumberParam": {
    "Description": "A sample numeric parameter.",
    "IsRequired": false,
    "DefaultValue": "42"
  },
  "OptionalParam": {
    "Description": "An optional parameter to test behavior when left blank.",
    "IsRequired": false,
    "DefaultValue": ""
  }
}
#>

param(
    [string]$StringParam,
    [string]$NumberParam,
    [string]$OptionalParam
)

$ScriptName = 'Parameter Test'
$LogDir = "C:\Windows\Temp\NMWLogs\ScriptedActions\$ScriptName"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
Start-Transcript -Path "$LogDir\$(Get-Date -Format 'yyyyMMdd-HHmmss').txt" -Force

Write-Host "=== Runtime Parameters ==="
Write-Host "StringParam:   $StringParam"
Write-Host "NumberParam:   $NumberParam"
Write-Host "OptionalParam: $OptionalParam"

Write-Host ""
Write-Host "=== Predefined Variables ==="
Write-Host "AzureVMName:            $AzureVMName"
Write-Host "AzureResourceGroupName: $AzureResourceGroupName"
Write-Host "AzureRegionName:        $AzureRegionName"
Write-Host "AzureSubscriptionId:    $AzureSubscriptionId"
Write-Host "AzureSubscriptionName:  $AzureSubscriptionName"
Write-Host "HostPoolName:           $HostPoolName"

Stop-Transcript

### End Script ###
