function Get-ToolkitFullSpecification {
    param([ValidateSet('Full','Hardware','Firmware','Windows','Storage','Network')][string]$Scope = 'Full')
    $includedSections = switch ($Scope) {
        'Hardware' { @('Computer','Processor','Memory','Graphics','Board','Disk','Adapter','Battery') }
        'Firmware' { @('Board','BIOS') }
        'Windows' { @('Windows','Computer') }
        'Storage' { @('Disk','Partition','Volume') }
        'Network' { @('Adapter') }
    }
    $sections = @(
        @{ Name = 'Windows'; Class = 'Win32_OperatingSystem'; Fields = @('Caption','Version','BuildNumber','OSArchitecture','LastBootUpTime') },
        @{ Name = 'Computer'; Class = 'Win32_ComputerSystem'; Fields = @('Manufacturer','Model','TotalPhysicalMemory','SystemType') },
        @{ Name = 'Processor'; Class = 'Win32_Processor'; Fields = @('Name','NumberOfCores','NumberOfLogicalProcessors','MaxClockSpeed') },
        @{ Name = 'Memory'; Class = 'Win32_PhysicalMemory'; Fields = @('DeviceLocator','Manufacturer','Capacity','Speed','PartNumber') },
        @{ Name = 'Graphics'; Class = 'Win32_VideoController'; Fields = @('Name','DriverVersion','CurrentHorizontalResolution','CurrentVerticalResolution') },
        @{ Name = 'Board'; Class = 'Win32_BaseBoard'; Fields = @('Manufacturer','Product','Version') },
        @{ Name = 'BIOS'; Class = 'Win32_BIOS'; Fields = @('Manufacturer','SMBIOSBIOSVersion','ReleaseDate') },
        @{ Name = 'Disk'; Class = 'Win32_DiskDrive'; Fields = @('Index','Model','Size','InterfaceType') },
        @{ Name = 'Partition'; Class = 'Win32_DiskPartition'; Fields = @('DeviceID','DiskIndex','Size','Type') },
        @{ Name = 'Volume'; Class = 'Win32_LogicalDisk'; Fields = @('DeviceID','VolumeName','FileSystem','Size','FreeSpace') },
        @{ Name = 'Adapter'; Class = 'Win32_NetworkAdapter'; Fields = @('Name','NetConnectionID','NetEnabled','Speed') }
    )
    foreach ($section in $sections) {
        if ($Scope -ne 'Full' -and $section.Name -notin $includedSections) { continue }
        try {
            $items = @(CimCmdlets\Get-CimInstance -ClassName $section.Class -OperationTimeoutSec 10 -ErrorAction Stop | Select-Object -First 64)
            if (-not $items.Count) { [pscustomobject]@{ Section = $section.Name; Field = ''; Value = 'No data'; Status = 'Unavailable' } }
            for ($deviceIndex = 0; $deviceIndex -lt $items.Count; $deviceIndex++) {
                $item = $items[$deviceIndex]
                foreach ($field in $section.Fields) { [pscustomobject]@{ Section = $section.Name; DeviceIndex = $deviceIndex; Field = $field; Value = $item.$field; Status = 'Reported' } }
            }
        }
        catch { [pscustomobject]@{ Section = $section.Name; Field = ''; Value = $_.Exception.Message; Status = 'Unavailable' } }
    }
    if ($Scope -eq 'Full' -or 'Battery' -in $includedSections) { Get-ToolkitBatteryHealth }
}

function Get-ToolkitBatteryHealth {
    try {
        $batteries = @(CimCmdlets\Get-CimInstance Win32_Battery -OperationTimeoutSec 10 -ErrorAction Stop)
        if (-not $batteries.Count) { return [pscustomobject]@{ Section = 'Battery'; Status = 'Unavailable'; Detail = 'No battery was reported.' } }
        $static = @(CimCmdlets\Get-CimInstance -Namespace root/wmi -ClassName BatteryStaticData -OperationTimeoutSec 10 -ErrorAction Stop)
        $full = @(CimCmdlets\Get-CimInstance -Namespace root/wmi -ClassName BatteryFullChargedCapacity -OperationTimeoutSec 10 -ErrorAction Stop)
        foreach ($battery in $static) {
            $capacity = $full | Where-Object InstanceName -eq $battery.InstanceName | Select-Object -First 1
            $health = $null
            if ($battery.DesignedCapacity -gt 0 -and $null -ne $capacity) { $health = [Math]::Round(100.0 * $capacity.FullChargedCapacity / $battery.DesignedCapacity, 1) }
            [pscustomobject]@{ Section = 'Battery'; DesignCapacity = $battery.DesignedCapacity; FullChargeCapacity = $capacity.FullChargedCapacity; HealthPercent = $health; Status = 'Firmware reported; not a calibrated measurement' }
        }
    }
    catch { [pscustomobject]@{ Section = 'Battery'; Status = 'Unavailable'; Detail = $_.Exception.Message } }
}

function Get-ToolkitUpdateDiagnostic {
    foreach ($name in @('wuauserv','BITS','UsoSvc')) {
        try { Get-Service -Name $name -ErrorAction Stop | Select-Object Name,Status,StartType }
        catch { [pscustomobject]@{ Name = $name; Detail = $_.Exception.Message } }
    }
    [pscustomobject]@{
        ComponentServicingRestart = (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
        WindowsUpdateRestart = (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        Note = 'These are local restart indicators, not a complete update-health diagnosis.'
    }
    try { Get-ToolkitSettingState Updates Automatic } catch { $_.Exception.Message }
    Get-ToolkitManagedSummary | Where-Object Kind -eq 'Updates'
}

function Invoke-ToolkitTroubleshootingAction {
    param([string]$TargetId, [hashtable]$Values)
    switch ($TargetId) {
        'troubleshooting.events' {
            foreach ($log in @('System','Application')) {
                try {
                    Get-WinEvent -FilterHashtable @{ LogName = $log; Level = @(1,2); StartTime = (Get-Date).AddHours(-[int]$Values.hours) } -MaxEvents 50 -ErrorAction Stop | Select-Object TimeCreated,LogName,ProviderName,Id,LevelDisplayName,Message
                }
                catch { [pscustomobject]@{ Log = $log; Detail = $_.Exception.Message } }
            }
        }
        'troubleshooting.devices' { CimCmdlets\Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode<>0' -OperationTimeoutSec 15 | Select-Object Name,PNPClass,ConfigManagerErrorCode,Status }
        'troubleshooting.battery' { Get-ToolkitBatteryHealth }
        'troubleshooting.updates' { Get-ToolkitUpdateDiagnostic }
        'troubleshooting.connectivity' {
            $routes = @(NetTCPIP\Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric)
            if ($routes.Count) {
                $route = $routes[0]
                [pscustomobject]@{ Step = 'Selected IPv4 gateway'; Gateway = $route.NextHop; InterfaceIndex = $route.InterfaceIndex }
                $ping = New-Object Net.NetworkInformation.Ping
                try { $reply = $ping.Send($route.NextHop, 1000); [pscustomobject]@{ Step = 'Gateway ICMP'; Status = $reply.Status; Note = 'ICMP filtering does not prove an outage.' } }
                catch { [pscustomobject]@{ Step = 'Gateway ICMP'; Detail = $_.Exception.Message } }
                finally { $ping.Dispose() }
            }
            else { 'No IPv4 default gateway was reported; IPv6 connectivity may still be available.' }
            try { DnsClient\Resolve-DnsName -Name $Values.host -DnsOnly -QuickTimeout -ErrorAction Stop | Select-Object Name,Type,IPAddress }
            catch { [pscustomobject]@{ Step = 'DNS'; Detail = $_.Exception.Message } }
            try { Invoke-ToolkitNetworkAction 'network.port' $Values }
            catch { [pscustomobject]@{ Step = 'TCP'; Detail = $_.Exception.Message } }
        }
        'troubleshooting.bsod' {
            $minidump = Join-Path $env:SystemRoot 'Minidump'
            if (Test-Path -LiteralPath $minidump -PathType Container) {
                $dumps = @(Get-ChildItem -LiteralPath $minidump -Filter '*.dmp' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 20)
                if ($dumps.Count) {
                    foreach ($dump in $dumps) { [pscustomobject]@{ Source = 'Minidump'; Name = $dump.Name; SizeKiB = [Math]::Round($dump.Length / 1KB, 1); LastWriteTime = $dump.LastWriteTime } }
                }
                else { [pscustomobject]@{ Source = 'Minidump'; Detail = 'No .dmp files found.' } }
            }
            else { [pscustomobject]@{ Source = 'Minidump'; Detail = 'Minidump folder does not exist.' } }
            $fullDump = Join-Path $env:SystemRoot 'MEMORY.DMP'
            if (Test-Path -LiteralPath $fullDump -PathType Leaf) {
                $item = Get-Item -LiteralPath $fullDump -Force -ErrorAction SilentlyContinue
                if ($null -ne $item) { [pscustomobject]@{ Source = 'MEMORY.DMP'; Name = $item.Name; SizeMiB = [Math]::Round($item.Length / 1MB, 1); LastWriteTime = $item.LastWriteTime } }
            }
            try {
                Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = @(1001, 41); StartTime = (Get-Date).AddDays(-30) } -MaxEvents 25 -ErrorAction Stop |
                    Select-Object TimeCreated,Id,ProviderName,LevelDisplayName,Message
            }
            catch { [pscustomobject]@{ Source = 'SystemCrashEvents'; Detail = $_.Exception.Message } }
        }
        'troubleshooting.boot-history' {
            $days = 7; if ($Values -and $Values.ContainsKey('days')) { $days = [int]$Values.days }
            try {
                Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = @(6005,6006,6008,1074,41,42,1); StartTime = (Get-Date).AddDays(-$days) } -MaxEvents 60 -ErrorAction Stop |
                    ForEach-Object {
                        $summary = (([string]$_.Message) -split "`r?`n")[0].Trim()
                        [pscustomobject]@{ TimeCreated = $_.TimeCreated; Id = $_.Id; Provider = $_.ProviderName; Summary = $summary }
                    }
            }
            catch { [pscustomobject]@{ BootHistory = 'Unavailable'; Detail = $_.Exception.Message } }
        }
        'troubleshooting.printers' {
            try { Get-Service -Name 'Spooler' -ErrorAction Stop | Select-Object Name,Status,StartType }
            catch { [pscustomobject]@{ Service = 'Spooler'; Detail = $_.Exception.Message } }
            CimCmdlets\Get-CimInstance Win32_Printer -OperationTimeoutSec 15 | Select-Object Name,PortName,PrinterStatus,WorkOffline,Default
            $jobs = @(CimCmdlets\Get-CimInstance Win32_PrintJob -OperationTimeoutSec 15)
            if ($jobs.Count) { $jobs | Select-Object JobId,Name,Document,JobStatus,TimeSubmitted }
            else { 'No queued print jobs were reported.' }
        }
        default { throw 'Unknown troubleshooting operation.' }
    }
}
