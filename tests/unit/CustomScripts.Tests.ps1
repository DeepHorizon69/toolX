BeforeAll { . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1') }

Describe 'Drop-in discovery' {
    BeforeEach {
        $script:ToolkitRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $scriptRoot = Join-Path $script:ToolkitRoot 'Scripts'
        New-Item -ItemType Directory -Path $scriptRoot -Force | Out-Null
    }
    It 'returns an empty catalog when no folder exists' {
        $script:ToolkitRoot = Join-Path $TestDrive 'absent'
        @(Get-ToolkitCustomScript).Count | Should -Be 0
    }
    It 'discovers three supported formats without executing them' {
        foreach ($extension in @('ps1','bat','cmd')) { Set-Content -LiteralPath (Join-Path $scriptRoot "sample.$extension") -Value 'THIS MUST NEVER EXECUTE' }
        @(Get-ToolkitCustomScript).Count | Should -Be 3
        @(Get-ToolkitCustomScript | Where-Object risk -ne 'HighRisk').Count | Should -Be 0
    }
    It 'ignores support folders, unsupported files and deeper files' {
        New-Item -ItemType Directory -Path (Join-Path $scriptRoot 'Tool/_support') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $scriptRoot 'Tool/run.ps1') -Value ''
        Set-Content -LiteralPath (Join-Path $scriptRoot 'Tool/_support/helper.ps1') -Value ''
        Set-Content -LiteralPath (Join-Path $scriptRoot 'ignored.exe') -Value ''
        @(Get-ToolkitCustomScript).Count | Should -Be 1
    }
    It 'loads optional metadata without allowing command strings' {
        $file = Join-Path $scriptRoot 'test.cmd'
        Set-Content -LiteralPath $file -Value ''
        Set-Content -LiteralPath ($file + '.json') -Value '{"schemaVersion":1,"name":"Friendly","requiresAdmin":true}'
        $entry = @(Get-ToolkitCustomScript)[0]
        $entry.name | Should -Be 'Friendly'
        $entry.requiresAdmin | Should -BeTrue
        Set-Content -LiteralPath ($file + '.json') -Value '{"schemaVersion":1,"command":"anything"}'
        @(Get-ToolkitCustomScript)[0].available | Should -BeFalse
    }
    It 'does not ignore malformed or disabled metadata' {
        $file = Join-Path $scriptRoot 'test.ps1'
        Set-Content -LiteralPath $file -Value ''
        Set-Content -LiteralPath ($file + '.json') -Value '{bad json'
        @(Get-ToolkitCustomScript)[0].available | Should -BeFalse
        Set-Content -LiteralPath ($file + '.json') -Value '{"schemaVersion":1,"enabled":false}'
        @(Get-ToolkitCustomScript)[0].unavailableReason | Should -Match 'Disabled'
    }
    It 'rejects string values for administrator booleans' {
        $file = Join-Path $scriptRoot 'test.ps1'
        Set-Content -LiteralPath $file -Value ''
        Set-Content -LiteralPath ($file + '.json') -Value '{"schemaVersion":1,"requiresAdmin":"false"}'
        @(Get-ToolkitCustomScript)[0].available | Should -BeFalse
    }
    It 'distinguishes identical friendly names with stable paths' {
        foreach ($name in @('One','Two')) {
            New-Item -ItemType Directory -Path (Join-Path $scriptRoot $name) | Out-Null
            Set-Content -LiteralPath (Join-Path $scriptRoot "$name/run.ps1") -Value ''
        }
        $entries = @(Get-ToolkitCustomScript)
        $entries.Count | Should -Be 2
        $entries[0].id | Should -Not -Be $entries[1].id
    }
    It 'rejects parent traversal and hidden support entrypoints' {
        { Resolve-ToolkitCustomScript 'custom/../bad.ps1' } | Should -Throw
        { Resolve-ToolkitCustomScript 'custom/_support/helper.ps1' } | Should -Throw
        { Resolve-ToolkitCustomScript 'custom/one/two/run.ps1' } | Should -Throw
    }
    It 'reports a deleted script instead of using cached metadata' {
        Set-Content -LiteralPath (Join-Path $scriptRoot 'test.ps1') -Value ''
        $entry = @(Get-ToolkitCustomScript)[0]
        Remove-Item -LiteralPath $entry.path
        { Resolve-ToolkitCustomScript $entry.id } | Should -Throw
    }
    It 'enforces the 500 entry limit with an incomplete-catalog notice' {
        for ($index = 0; $index -lt 501; $index++) { [IO.File]::WriteAllText((Join-Path $scriptRoot "s$index.ps1"), '') }
        @(Get-ToolkitCustomScript).Count | Should -Be 500
        $script:ToolkitCustomNotice | Should -Match 'incomplete'
    }
}
