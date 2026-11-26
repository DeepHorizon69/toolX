function ConvertFrom-ToolkitEdidText {
    param([AllowNull()][object]$Bytes)
    if ($null -eq $Bytes) { return '' }
    return ((-join ($Bytes | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ })).Trim())
}

function Invoke-ToolkitHardwareAction {
    param([string]$TargetId)
    switch ($TargetId) {
        'hardware.cpu' { Get-CimInstance Win32_Processor -OperationTimeoutSec 15 | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed }
        'hardware.memory' { Get-CimInstance Win32_PhysicalMemory -OperationTimeoutSec 15 | Select-Object DeviceLocator,Capacity,Speed,Manufacturer,PartNumber }
        'hardware.gpu' { Get-CimInstance Win32_VideoController -OperationTimeoutSec 15 | Select-Object Name,DriverVersion,VideoModeDescription }
        'hardware.board' { Get-CimInstance Win32_BaseBoard -OperationTimeoutSec 15 | Select-Object Manufacturer,Product,Version }
        'hardware.bios' { Get-CimInstance Win32_BIOS -OperationTimeoutSec 15 | Select-Object Manufacturer,SMBIOSBIOSVersion,ReleaseDate }
        'hardware.disks' { Get-CimInstance Win32_DiskDrive -OperationTimeoutSec 15 | Select-Object Index,Model,InterfaceType,Size,Status }
        'hardware.disk-health' {
            foreach ($disk in (Storage\Get-PhysicalDisk)) {
                $disk | Select-Object FriendlyName,MediaType,HealthStatus,OperationalStatus,Size
                try {
                    $counter = $disk | Storage\Get-StorageReliabilityCounter -ErrorAction Stop
                    if ($null -eq $counter) { 'Reliability counters are unavailable for this device.' }
                    else { $counter | Select-Object Temperature,Wear,PowerOnHours,ReadErrorsTotal,WriteErrorsTotal }
                }
                catch { "Reliability counters unavailable: $($_.Exception.Message)" }
            }
        }
        'hardware.usb' {
            CimCmdlets\Get-CimInstance Win32_PnPEntity -Filter "DeviceID LIKE 'USB%'" -OperationTimeoutSec 15 |
                Sort-Object Name |
                Select-Object -First 200 Name,Manufacturer,Status,PNPClass,DeviceID
        }
        'hardware.monitors' {
            try {
                $monitors = @(CimCmdlets\Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorID -OperationTimeoutSec 10 -ErrorAction Stop)
                if (-not $monitors.Count) { 'No WMI monitor EDID records were reported.' }
                foreach ($monitor in $monitors) {
                    [pscustomobject]@{
                        Manufacturer = (ConvertFrom-ToolkitEdidText $monitor.ManufacturerName)
                        Model = (ConvertFrom-ToolkitEdidText $monitor.UserFriendlyName)
                        Serial = (ConvertFrom-ToolkitEdidText $monitor.SerialNumberID)
                        YearOfManufacture = $monitor.YearOfManufacture
                        WeekOfManufacture = $monitor.WeekOfManufacture
                    }
                }
            }
            catch { [pscustomobject]@{ MonitorEDID = 'Unavailable'; Detail = $_.Exception.Message } }
            CimCmdlets\Get-CimInstance Win32_VideoController -OperationTimeoutSec 10 | Select-Object Name,CurrentHorizontalResolution,CurrentVerticalResolution,CurrentRefreshRate
        }
        'hardware.tpm' {
            $secureBoot = 'Unavailable'
            try { $secureBoot = [string](Confirm-SecureBootUEFI) }
            catch { $secureBoot = $_.Exception.Message }
            try {
                $tpm = Get-Tpm -ErrorAction Stop
                [pscustomobject]@{
                    SecureBoot = $secureBoot
                    TpmPresent = $tpm.TpmPresent; TpmReady = $tpm.TpmReady
                    TpmEnabled = $tpm.TpmEnabled; TpmActivated = $tpm.TpmActivated
                    ManufacturerIdTxt = $tpm.ManufacturerIdTxt; ManagedAuthLevel = $tpm.ManagedAuthLevel
                }
            }
            catch { [pscustomobject]@{ SecureBoot = $secureBoot; TpmStatus = 'Unavailable'; Detail = $_.Exception.Message } }
        }
        default { throw 'Unknown hardware operation.' }
    }
}
