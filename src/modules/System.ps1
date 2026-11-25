function Invoke-ToolkitSystemAction {
    param([string]$TargetId)
    switch ($TargetId) {
        'system.full-specs' { Get-ToolkitFullSpecification }
        'system.os' { Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 15 | Select-Object Caption,Version,BuildNumber,OSArchitecture,WindowsDirectory }
        'system.computer' { Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 15 | Select-Object Manufacturer,Model,TotalPhysicalMemory,DomainRole }
        'system.updates' { Microsoft.PowerShell.Management\Get-HotFix | Select-Object HotFixID,Description,InstalledOn }
        'system.uptime' {
            $boot = (Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 15).LastBootUpTime
            [pscustomobject]@{ LastBoot = $boot; Uptime = ((Get-Date) - $boot) }
        }
        'system.environment' {
            [pscustomobject]@{
                WindowsDirectory = $env:SystemRoot; ProgramFiles = $env:ProgramFiles
                LocalApplicationData = [Environment]::GetFolderPath('LocalApplicationData')
                PowerShellVersion = $PSVersionTable.PSVersion.ToString(); RuntimeVersion = [Environment]::Version.ToString()
                Is64BitOS = [Environment]::Is64BitOperatingSystem; Is64BitProcess = [Environment]::Is64BitProcess
            }
        }
        'system.locale' { Get-Culture; Get-UICulture; Get-TimeZone }
        default { throw 'Unknown system operation.' }
    }
}
