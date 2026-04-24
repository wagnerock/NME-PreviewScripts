#description: Outputs runtime parameters and predefined variables to verify parameter passing works correctly in Windows scripted actions.
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

Write-Output "=== Runtime Parameters ==="
Write-Output "StringParam:   $StringParam"
Write-Output "NumberParam:   $NumberParam"
Write-Output "OptionalParam: $OptionalParam"

Write-Output ""
Write-Output "=== Predefined Variables ==="
Write-Output "AzureVMName:            $AzureVMName"
Write-Output "AzureResourceGroupName: $AzureResourceGroupName"
Write-Output "AzureRegionName:        $AzureRegionName"
Write-Output "AzureSubscriptionId:    $AzureSubscriptionId"
Write-Output "AzureSubscriptionName:  $AzureSubscriptionName"
Write-Output "HostPoolName:           $HostPoolName"

### End Script ###
