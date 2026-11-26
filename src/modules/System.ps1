function Invoke-ToolkitSystemAction {
    param([string]$TargetId, [hashtable]$Values = @{})
    switch ($TargetId) {
        'system.full-specs' {
            $scope = 'Full'
            if ($Values -and $Values.ContainsKey('scope')) { $scope = $Values.scope }
            Get-ToolkitFullSpecification -Scope $scope
        }
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
        'system.activation' {
            $statusMap = @{ 0 = 'Unlicensed'; 1 = 'Licensed'; 2 = 'OOBGrace'; 3 = 'OOTGrace'; 4 = 'NonGenuineGrace'; 5 = 'Notification'; 6 = 'ExtendedGrace' }
            $products = @(CimCmdlets\Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -OperationTimeoutSec 15)
            if (-not $products.Count) { return 'No Windows licensing product record was reported.' }
            foreach ($product in $products) {
                $statusName = $statusMap[[int]$product.LicenseStatus]
                if (-not $statusName) { $statusName = [string]$product.LicenseStatus }
                [pscustomobject]@{
                    Name = $product.Name; Description = $product.Description
                    PartialProductKey = $product.PartialProductKey; LicenseStatus = $statusName
                    GracePeriodMinutes = $product.GracePeriodRemaining
                }
            }
        }
        'system.drivers' {
            $scope = 'ThirdParty'
            if ($Values -and $Values.ContainsKey('scope')) { $scope = $Values.scope }
            $drivers = @(CimCmdlets\Get-CimInstance Win32_PnPSignedDriver -OperationTimeoutSec 15 | Where-Object { -not [string]::IsNullOrWhiteSpace($_.DeviceName) })
            if ($scope -eq 'ThirdParty') {
                $drivers = @($drivers | Where-Object { $_.DriverProviderName -ne 'Microsoft' -and $_.Signer -notlike 'Microsoft Windows*' })
            }
            $drivers | Sort-Object DeviceName | Select-Object -First 200 DeviceName,DriverProviderName,DriverVersion,DriverDate,InfName,Signer
        }
        'system.installed-apps' {
            $roots = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
            )
            $seen = @{}; $apps = New-Object 'Collections.Generic.List[object]'
            foreach ($root in $roots) {
                foreach ($entry in (Get-ItemProperty -Path $root -ErrorAction SilentlyContinue)) {
                    if ([string]::IsNullOrWhiteSpace($entry.DisplayName) -or $entry.SystemComponent -eq 1) { continue }
                    $key = "$($entry.DisplayName)|$($entry.DisplayVersion)"
                    if ($seen.ContainsKey($key)) { continue }
                    $seen[$key] = $true
                    $apps.Add([pscustomobject]@{
                        DisplayName = $entry.DisplayName; DisplayVersion = $entry.DisplayVersion
                        Publisher = $entry.Publisher; InstallDate = $entry.InstallDate
                    })
                }
            }
            $apps | Sort-Object DisplayName | Select-Object -First 300
        }
        'system.power-plans' {
            $powercfg = Get-ToolkitWindowsExecutable 'powercfg.exe'
            '--- Power schemes ---'
            & $powercfg /list 2>&1 | ForEach-Object { [string]$_ }
            ''
            '--- Available sleep states ---'
            & $powercfg /availablesleepstates 2>&1 | ForEach-Object { [string]$_ }
        }
        default { throw 'Unknown system operation.' }
    }
}
