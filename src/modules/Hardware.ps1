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
        default { throw 'Unknown hardware operation.' }
    }
}
