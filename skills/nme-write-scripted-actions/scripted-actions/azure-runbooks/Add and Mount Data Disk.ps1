#description: Adds a managed data disk to the VM in the current script context, then formats and mounts it inside Windows.
#tags: Disk, Storage, AVD

<#variables:
{
  "DiskSizeGB": {
    "Description": "Size of the new data disk in GB",
    "DisplayName": "Disk Size (GB)"
  },
  "DiskSku": {
    "Description": "Storage SKU for the disk: Premium_LRS, StandardSSD_LRS, or Standard_LRS",
    "DisplayName": "Disk SKU"
  },
  "DriveLetter": {
    "Description": "Windows drive letter to assign to the new volume (e.g. F)",
    "DisplayName": "Drive Letter"
  },
  "DriveLabel": {
    "Description": "Volume label for the new drive (e.g. Data)",
    "DisplayName": "Drive Label"
  }
}
#>

$ErrorActionPreference = 'Stop'

Write-Output "=== Starting: Add and Mount Data Disk ==="
Write-Output "VM: $AzureVMName | RG: $AzureResourceGroupName | Subscription: $AzureSubscriptionId"
Write-Output "Disk: ${DiskSizeGB}GB | SKU: $DiskSku | Drive: ${DriveLetter}: | Label: $DriveLabel"

# ── 1. Get the VM ────────────────────────────────────────────────────────────
$vm = Get-AzVM -ResourceGroupName $AzureResourceGroupName -Name $AzureVMName
$location = $vm.Location

# ── 2. Determine next available LUN ──────────────────────────────────────────
$usedLuns = $vm.StorageProfile.DataDisks | Select-Object -ExpandProperty Lun
$lun = 0
while ($usedLuns -contains $lun) { $lun++ }
Write-Output "Using LUN: $lun"

# ── 3. Create the managed disk ───────────────────────────────────────────────
$diskName = "$AzureVMName-datadisk-lun$lun"
Write-Output "Creating managed disk: $diskName"

$diskConfig = New-AzDiskConfig `
    -Location         $location `
    -DiskSizeGB       ([int]$DiskSizeGB) `
    -SkuName          $DiskSku `
    -CreateOption     Empty

$disk = New-AzDisk `
    -ResourceGroupName $AzureResourceGroupName `
    -DiskName          $diskName `
    -Disk              $diskConfig

Write-Output "Disk created: $($disk.Id)"

# ── 4. Attach the disk to the VM ─────────────────────────────────────────────
Write-Output "Attaching disk to VM at LUN $lun..."

$vm = Add-AzVMDataDisk `
    -VM          $vm `
    -Name        $diskName `
    -ManagedDiskId $disk.Id `
    -Lun         $lun `
    -CreateOption Attach `
    -Caching     None

Update-AzVM -ResourceGroupName $AzureResourceGroupName -VM $vm
Write-Output "Disk attached successfully."

# ── 5. Format and mount inside Windows via Run Command ────────────────────────
Write-Output "Formatting and mounting disk inside Windows..."

$innerScript = @"
`$driveLetter = '$DriveLetter'
`$driveLabel  = '$DriveLabel'

# Find the raw (uninitialized) disk — the one with PartitionStyle None
`$rawDisk = Get-Disk | Where-Object PartitionStyle -eq 'RAW' | Select-Object -First 1
if (-not `$rawDisk) {
    throw 'No RAW disk found. The disk may already be initialized or did not attach correctly.'
}

Write-Output "Initializing disk number `$(`$rawDisk.Number)..."
Initialize-Disk -Number `$rawDisk.Number -PartitionStyle GPT -PassThru |
    New-Partition -DriveLetter `$driveLetter -UseMaximumSize |
    Format-Volume -FileSystem NTFS -NewFileSystemLabel `$driveLabel -Confirm:`$false

Write-Output "Drive `${driveLetter}: formatted and mounted with label '`$driveLabel'."
"@

# Write inner script to a temp file and invoke it on the VM
$tmpFile = [System.IO.Path]::GetTempFileName() + '.ps1'
$innerScript | Out-File -FilePath $tmpFile -Encoding utf8

try {
    $result = Invoke-AzVMRunCommand `
        -ResourceGroupName $AzureResourceGroupName `
        -VMName            $AzureVMName `
        -CommandId         'RunPowerShellScript' `
        -ScriptPath        $tmpFile

    $stdout = $result.Value | Where-Object Code -eq 'ComponentStatus/StdOut/succeeded' |
        Select-Object -ExpandProperty Message
    $stderr = $result.Value | Where-Object Code -eq 'ComponentStatus/StdErr/succeeded' |
        Select-Object -ExpandProperty Message

    if ($stdout) { Write-Output "VM stdout: $stdout" }
    if ($stderr) { Write-Warning "VM stderr: $stderr" }

    if ($stderr -and $stderr -match 'throw|Exception|Error') {
        throw "Inner script reported an error: $stderr"
    }
}
finally {
    Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
}

Write-Output "=== Done: Data disk added and mounted as ${DriveLetter}: ==="
