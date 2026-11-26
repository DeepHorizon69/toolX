BeforeAll { . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1') }

Describe 'Adaptive specification report' {
    BeforeAll {
        $fixtureRecords = @(
            [pscustomobject]@{ Section = 'Computer'; DeviceIndex = 0; Field = 'Model'; Value = 'FIXTURE_MODEL'; Status = 'Reported' },
            [pscustomobject]@{ Section = 'Computer'; DeviceIndex = 0; Field = 'TotalPhysicalMemory'; Value = 16GB; Status = 'Reported' },
            [pscustomobject]@{ Section = 'Memory'; DeviceIndex = 0; Field = 'DeviceLocator'; Value = 'FIXTURE_SLOT_A'; Status = 'Reported' },
            [pscustomobject]@{ Section = 'Memory'; DeviceIndex = 0; Field = 'Capacity'; Value = 8GB; Status = 'Reported' },
            [pscustomobject]@{ Section = 'Memory'; DeviceIndex = 1; Field = 'DeviceLocator'; Value = 'FIXTURE_SLOT_B'; Status = 'Reported' },
            [pscustomobject]@{ Section = 'Memory'; DeviceIndex = 1; Field = 'Capacity'; Value = 8GB; Status = 'Reported' },
            [pscustomobject]@{ Section = 'BIOS'; Field = ''; Value = 'FIXTURE_ACCESS_DENIED'; Status = 'Unavailable' },
            [pscustomobject]@{ Section = 'Battery'; Status = 'Unavailable'; Detail = 'FIXTURE_NO_BATTERY' }
        )
    }
    It 'preserves device values and failures within <Width> columns' -ForEach @(
        @{ Width = 35 }, @{ Width = 59 }, @{ Width = 79 }, @{ Width = 89 }, @{ Width = 119 }, @{ Width = 149 }, @{ Width = 199 }
    ) {
        $blocks = @(Get-ToolkitSpecificationBlock $fixtureRecords)
        $lines = @(Format-ToolkitSpecificationLayout $blocks $Width -Display)
        @($lines | Where-Object Length -gt $Width).Count | Should -Be 0
        $text = $lines -join "`n"
        foreach ($value in @('FIXTURE_MODEL','FIXTURE_SLOT_A','FIXTURE_SLOT_B','FIXTURE_ACCESS_DENIED','FIXTURE_NO_BATTERY','16 GiB','8 GiB')) { $text | Should -Match ([regex]::Escape($value)) }
        $text | Should -Not -Match 'Section\s*:|Field\s*:|Value\s*:|Reported'
    }
    It 'uses extra columns to reduce vertical output and separates multiple memory devices' {
        $blocks = @(Get-ToolkitSpecificationBlock $fixtureRecords)
        $narrow = @(Format-ToolkitSpecificationLayout $blocks 79)
        $wide = @(Format-ToolkitSpecificationLayout $blocks 149)
        $wide.Count | Should -BeLessThan $narrow.Count
        ($wide -join "`n") | Should -Match '\[Computer\].*\|.*\[Memory 1\].*\|.*\[Memory 2\]'
        @($blocks | Where-Object Section -eq 'Memory').Count | Should -Be 2
    }
    It 'wraps long and Unicode values without dropping their display text' {
        $value = 'LONG_' + ('x' * 150) + [char]0x5de5 + [char]0x5177
        $blocks = @(Get-ToolkitSpecificationBlock @([pscustomobject]@{ Section = 'Graphics'; DeviceIndex = 0; Field = 'Name'; Value = $value; Status = 'Reported' }))
        $lines = @(Format-ToolkitSpecificationLayout $blocks 39 -Display)
        @($lines | Where-Object Length -gt 39).Count | Should -Be 0
        (($lines -join '') -replace '\s','') | Should -Match ([regex]::Escape((ConvertTo-ToolkitDisplayText $value)))
    }
    It 'keeps zero and false values distinct from missing data and formats units and dates' {
        Format-ToolkitSpecificationValue Volume FreeSpace 0 | Should -Be '0 GiB'
        Format-ToolkitSpecificationValue Adapter NetEnabled $false | Should -Be 'No'
        Format-ToolkitSpecificationValue Memory Capacity $null | Should -Be 'Not reported'
        Format-ToolkitSpecificationValue Adapter Speed 1000000000 | Should -Be '1 Gbit/s'
        Format-ToolkitSpecificationValue Processor MaxClockSpeed 3200 | Should -Be '3200 MHz'
        Format-ToolkitSpecificationValue BIOS ReleaseDate ([datetime]'2025-09-12') | Should -Be '2025-09-12 00:00:00'
        Format-ToolkitSpecificationLayout @() 79 | Should -Match 'No specification data'
    }
}

Describe 'Specification result transport' {
    It 'retains a burst larger than the text queue without losing the earliest fields' {
        Mock Invoke-ToolkitPowerShellAction {
            for ($index = 0; $index -lt 700; $index++) { [pscustomobject]@{ Section = 'Fixture'; DeviceIndex = $index; Field = 'Name'; Value = $index; Status = 'Reported' } }
        }
        $queue = New-Object 'Collections.Concurrent.BlockingCollection[string]' 2
        $state = @{ Truncated = $false; Cancelled = $false }
        try {
            Invoke-ToolkitBackgroundAction (Get-TestCommand 'system.full-specs') @{ scope = 'Full' } $queue $state @{ Cancel = $false }
            $state.Status | Should -Be 'Succeeded'
            $state.Specifications.Count | Should -Be 700
            $state.Specifications[0].Value | Should -Be 0
            $state.Specifications[699].Value | Should -Be 699
            $state.Truncated | Should -BeFalse
            $queue.Count | Should -Be 0
        }
        finally { $queue.Dispose() }
    }
    It 'bounds specification records and explicitly marks oversized reports' {
        Mock Invoke-ToolkitPowerShellAction { 1..4100 | ForEach-Object { [pscustomobject]@{ Section = 'Fixture'; Field = 'Name'; Value = $_; Status = 'Reported' } } }
        $queue = New-Object 'Collections.Concurrent.BlockingCollection[string]' 2
        $state = @{ Truncated = $false; Cancelled = $false }
        try {
            Invoke-ToolkitBackgroundAction (Get-TestCommand 'system.full-specs') @{} $queue $state @{}
            $state.Specifications.Count | Should -Be 4096
            $state.Truncated | Should -BeTrue
        }
        finally { $queue.Dispose() }
    }
}

Describe 'Specification result navigation' {
    It 'reflows completed output across widths while keeping keyboard navigation available' {
        $script:ToolkitBasic = $false
        $script:reportWidth = 120; $script:reportKeys = 0
        $script:reportFrames = New-Object 'Collections.Generic.List[object]'
        $queue = New-Object 'Collections.Concurrent.BlockingCollection[string]' 2
        $records = @(
            [pscustomobject]@{ Section = 'Computer'; DeviceIndex = 0; Field = 'Model'; Value = 'VISIBLE_MODEL'; Status = 'Reported' },
            [pscustomobject]@{ Section = 'Processor'; DeviceIndex = 0; Field = 'Name'; Value = 'VISIBLE_CPU'; Status = 'Reported' },
            [pscustomobject]@{ Section = 'BIOS'; DeviceIndex = 0; Field = 'Manufacturer'; Value = 'VISIBLE_BIOS'; Status = 'Reported' }
        )
        Mock Start-ToolkitExecution { [pscustomobject]@{ Queue = $queue; Handle = [pscustomobject]@{ IsCompleted = $true } } }
        Mock Complete-ToolkitExecution { [pscustomobject]@{ Status = 'Succeeded'; Elapsed = [timespan]::Zero; Truncated = $false; Specifications = $records } }
        Mock Get-ToolkitTerminalSize { [pscustomobject]@{ Width = $script:reportWidth; Height = 80; Left = 0; Top = 0 } }
        Mock Update-ToolkitTerminalMode {}
        Mock Show-ToolkitFrame { param($Frame) $script:reportFrames.Add($Frame) }
        Mock Read-ToolkitKey {
            $script:reportKeys++
            if ($script:reportKeys -eq 1) { $script:reportWidth = 150; return [pscustomobject]@{ Key = [ConsoleKey]::End } }
            if ($script:reportKeys -eq 2) { $script:reportWidth = 80; return [pscustomobject]@{ Key = [ConsoleKey]::Home } }
            [pscustomobject]@{ Key = [ConsoleKey]::Escape }
        }
        try {
            Show-ToolkitDiagnostic (Get-TestCommand 'system.full-specs') @{}
            foreach ($width in @(120,150,80)) {
                $frame = @($script:reportFrames | Where-Object { $_.Size.Width -eq $width -and ($_.PlainLines -join ' ') -match 'Succeeded' })[-1]
                $frame | Should -Not -BeNullOrEmpty
                $text = $frame.PlainLines -join "`n"
                foreach ($value in @('VISIBLE_MODEL','VISIBLE_CPU','VISIBLE_BIOS')) { $text | Should -Match $value }
                if ($width -gt 80) { $text | Should -Match '\|' }
                else { ($frame.PlainLines | Where-Object { $_ -match 'VISIBLE_' }) -join '' | Should -Not -Match '\|' }
            }
            $script:reportKeys | Should -Be 3
        }
        finally { $queue.Dispose() }
    }
}
