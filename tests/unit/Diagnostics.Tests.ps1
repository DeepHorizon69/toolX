BeforeAll { . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1') }

Describe 'Diagnostic partial results and bounded queries' {
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
}
