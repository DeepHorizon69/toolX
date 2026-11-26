BeforeAll { . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1') }

Describe 'Diagnostic partial results and bounded queries' {
    It 'queries only the selected specification providers for <Scope>' -ForEach @(
        @{ Scope = 'Full'; Sections = @('Windows','Computer','Processor','Memory','Graphics','Board','BIOS','Disk','Partition','Volume','Adapter','Battery'); Classes = @('Win32_OperatingSystem','Win32_ComputerSystem','Win32_Processor','Win32_PhysicalMemory','Win32_VideoController','Win32_BaseBoard','Win32_BIOS','Win32_DiskDrive','Win32_DiskPartition','Win32_LogicalDisk','Win32_NetworkAdapter','Win32_Battery') },
        @{ Scope = 'Hardware'; Sections = @('Computer','Processor','Memory','Graphics','Board','Disk','Adapter','Battery'); Classes = @('Win32_ComputerSystem','Win32_Processor','Win32_PhysicalMemory','Win32_VideoController','Win32_BaseBoard','Win32_DiskDrive','Win32_NetworkAdapter','Win32_Battery') },
        @{ Scope = 'Firmware'; Sections = @('Board','BIOS'); Classes = @('Win32_BaseBoard','Win32_BIOS') },
        @{ Scope = 'Windows'; Sections = @('Windows','Computer'); Classes = @('Win32_OperatingSystem','Win32_ComputerSystem') },
        @{ Scope = 'Storage'; Sections = @('Disk','Partition','Volume'); Classes = @('Win32_DiskDrive','Win32_DiskPartition','Win32_LogicalDisk') },
        @{ Scope = 'Network'; Sections = @('Adapter'); Classes = @('Win32_NetworkAdapter') }
    ) {
        Mock 'CimCmdlets\Get-CimInstance' {
            param($ClassName)
            if ($ClassName -eq 'Win32_Battery') { return @() }
            [pscustomobject]@{ Name = 'Fixture hardware'; Manufacturer = 'Fixture'; Model = 'Test' }
        }
        $command = Get-TestCommand 'system.full-specs'
        $values = ConvertTo-ToolkitParameterMap $command @{ scope = $Scope }
        $result = @(Invoke-ToolkitPowerShellAction $command.targetId $values)
        @($result.Section | Select-Object -Unique) | Should -Be $Sections
        Should -Invoke 'CimCmdlets\Get-CimInstance' -Times $Classes.Count -Exactly
        Should -Invoke 'CimCmdlets\Get-CimInstance' -Times 0 -Exactly -ParameterFilter { $ClassName -notin $Classes }
        Should -Invoke 'CimCmdlets\Get-CimInstance' -Times $Classes.Count -Exactly -ParameterFilter { $OperationTimeoutSec -eq 10 }
    }
    It 'defaults omitted and blank scope to Full and rejects unknown scopes' {
        $command = Get-TestCommand 'system.full-specs'
        (ConvertTo-ToolkitParameterMap $command @{}).scope | Should -Be 'Full'
        (ConvertTo-ToolkitParameterMap $command @{ scope = '' }).scope | Should -Be 'Full'
        { ConvertTo-ToolkitParameterMap $command @{ scope = 'Other' } } | Should -Throw
        { Get-ToolkitFullSpecification -Scope 'Other' } | Should -Throw
        Mock Get-ToolkitFullSpecification {}
        Invoke-ToolkitSystemAction 'system.full-specs'
        Should -Invoke Get-ToolkitFullSpecification -Times 1 -Exactly -ParameterFilter { $Scope -eq 'Full' }
    }
    It 'preserves another selected section when a firmware provider fails' {
        Mock 'CimCmdlets\Get-CimInstance' {
            param($ClassName)
            if ($ClassName -eq 'Win32_BIOS') { throw 'BIOS access denied' }
            [pscustomobject]@{ Manufacturer = 'Fixture'; Product = 'Test board'; Version = '1' }
        }
        $result = @(Get-ToolkitFullSpecification -Scope Firmware)
        @($result | Where-Object { $_.Section -eq 'Board' -and $_.Status -eq 'Reported' }).Count | Should -BeGreaterThan 0
        ($result | Where-Object Section -eq 'BIOS').Value | Should -Match 'access denied'
        Should -Invoke 'CimCmdlets\Get-CimInstance' -Times 2 -Exactly
    }
    It 'retains successful specification sections if a provider fails' {
        Mock 'CimCmdlets\Get-CimInstance' {
            param($ClassName)
            if ($ClassName -eq 'Win32_OperatingSystem') { throw 'Access denied to this provider' }
            if ($ClassName -eq 'Win32_Battery') { return @() }
            return [pscustomobject]@{ Name = 'Fixture hardware'; Manufacturer = 'Fixture'; Model = 'Test'; Capacity = 1024 }
        }
        $result = @(Get-ToolkitFullSpecification)
        @($result | Where-Object { $_.Section -eq 'Windows' -and $_.Status -eq 'Unavailable' }).Count | Should -Be 1
        @($result | Where-Object { $_.Section -eq 'Processor' -and $_.Status -eq 'Reported' }).Count | Should -BeGreaterThan 0
        @($result | Where-Object Field -in @('SerialNumber','UUID','SID')).Count | Should -Be 0
    }
    It 'reports no battery without querying missing firmware classes' {
        Mock 'CimCmdlets\Get-CimInstance' { @() }
        (Get-ToolkitBatteryHealth).Status | Should -Be 'Unavailable'
        Should -Invoke 'CimCmdlets\Get-CimInstance' -Times 1
    }
    It 'bounds each event query and preserves permission failure detail' {
        Mock Get-WinEvent { throw 'Event access denied' }
        $result = @(Invoke-ToolkitTroubleshootingAction 'troubleshooting.events' @{ hours = 24 })
        $result.Count | Should -Be 2
        $result[0].Detail | Should -Match 'denied'
        Should -Invoke Get-WinEvent -Times 2 -ParameterFilter { $MaxEvents -eq 50 -and $FilterHashtable.Level.Count -eq 2 }
    }
    It 'filters third-party drivers by default and includes Microsoft when scope is All' {
        Mock 'CimCmdlets\Get-CimInstance' {
            @(
                [pscustomobject]@{ DeviceName = 'Inbox Disk'; DriverProviderName = 'Microsoft'; DriverVersion = '10.0'; DriverDate = $null; InfName = 'disk.inf'; Signer = 'Microsoft Windows' },
                [pscustomobject]@{ DeviceName = 'Vendor NIC'; DriverProviderName = 'Realtek'; DriverVersion = '2.1'; DriverDate = $null; InfName = 'rt.inf'; Signer = 'Realtek' }
            )
        }
        $thirdParty = @(Invoke-ToolkitSystemAction 'system.drivers' (ConvertTo-ToolkitParameterMap (Get-TestCommand 'system.drivers') @{}))
        $thirdParty.Count | Should -Be 1
        $thirdParty[0].DeviceName | Should -Be 'Vendor NIC'
        $allDrivers = @(Invoke-ToolkitSystemAction 'system.drivers' (ConvertTo-ToolkitParameterMap (Get-TestCommand 'system.drivers') @{ scope = 'All' }))
        $allDrivers.Count | Should -Be 2
    }
    It 'returns largest files in descending order without modifying files' {
        $scanRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path (Join-Path $scanRoot 'sub') -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $scanRoot 'small.bin'), (New-Object byte[] 128))
        [IO.File]::WriteAllBytes((Join-Path $scanRoot 'sub\big.bin'), (New-Object byte[] 2048))
        $values = ConvertTo-ToolkitParameterMap (Get-TestCommand 'storage.large-files') @{ path = $scanRoot; top = 1 }
        $results = @(Invoke-ToolkitStorageAction 'storage.large-files' $values)
        $results.Count | Should -Be 1
        $results[0].Path | Should -Match 'big\.bin$'
    }
    It 'validates boot-history and certificate lookback bounds and handles missing events' {
        { ConvertTo-ToolkitParameterMap (Get-TestCommand 'troubleshooting.boot-history') @{ days = 31 } } | Should -Throw
        { ConvertTo-ToolkitParameterMap (Get-TestCommand 'security.certificates') @{ days = 366 } } | Should -Throw
        Mock Get-WinEvent { throw 'No events were found' }
        $boot = @(Invoke-ToolkitTroubleshootingAction 'troubleshooting.boot-history' @{ days = 7 })
        $boot[0].BootHistory | Should -Be 'Unavailable'
    }
}
