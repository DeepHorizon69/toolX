BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1')
    $script:masLauncher = Join-Path $script:RepositoryRoot 'Scripts/Tinkerer/Launch-MAS.ps1'
}

Describe 'MAS launcher' {
    BeforeEach {
        $script:originalSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
        $script:ToolkitConfirmActions = $false
        Mock Write-Host {}
        Mock Read-Host { 'yes' }
        Mock Invoke-RestMethod { throw 'Unexpected download attempt in test.' }
    }
    AfterEach {
        [Net.ServicePointManager]::SecurityProtocol = $script:originalSecurityProtocol
        $script:ToolkitConfirmActions = $true
    }

    It 'cancels before downloading unless the exact confirmation is supplied: <Answer>' -TestCases @(
        @{ Answer = '' }, @{ Answer = 'no' }, @{ Answer = 'YES' }, @{ Answer = ' yes ' }
    ) {
        param($Answer)
        Mock Read-Host { $Answer }
        & $script:masLauncher
        Should -Invoke Read-Host -Times 1 -Exactly
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'reports a failed download without running a payload' {
        Mock Invoke-RestMethod { throw 'Fixture network failure' }
        { & $script:masLauncher } | Should -Throw '*Fixture network failure*'
    }

    It 'rejects an empty download' {
        Mock Invoke-RestMethod { '   ' }
        { & $script:masLauncher } | Should -Throw '*MAS launcher was empty*'
    }

    It 'runs only the downloaded fixture without arguments and removes its temporary file' {
        Mock Invoke-RestMethod { '[pscustomobject]@{ Path = $PSCommandPath; ArgumentCount = $args.Count }' }
        $result = & $script:masLauncher
        $result.ArgumentCount | Should -Be 0
        [IO.Path]::GetFileName($result.Path) | Should -Match '^mas-[a-f0-9]{32}\.ps1$'
        Test-Path -LiteralPath $result.Path | Should -BeFalse
        Should -Invoke Read-Host -Times 1 -Exactly
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://get.activated.win' -and $ErrorAction -eq 'Stop' }
    }

    It 'removes the temporary file when the payload throws and preserves the error' {
        Mock Invoke-RestMethod { 'Write-Output $PSCommandPath; throw "Fixture payload failure"' }
        $payloadOutput = New-Object 'Collections.Generic.List[string]'
        { & $script:masLauncher | ForEach-Object { $payloadOutput.Add([string]$_) } } | Should -Throw '*Fixture payload failure*'
        $payloadOutput.Count | Should -Be 1
        Test-Path -LiteralPath $payloadOutput[0] | Should -BeFalse
    }
}

Describe 'Packaged MAS entry' {
    It 'is discoverable with administrator metadata in source and portable catalogs' {
        foreach ($root in @($script:RepositoryRoot, (Join-Path $script:RepositoryRoot 'dist'))) {
            $script:ToolkitRoot = $root
            $entries = @(Get-ToolkitCustomScript | Where-Object id -eq 'custom/tinkerer/launch-mas.ps1')
            $entries.Count | Should -Be 1
            $entries[0].name | Should -Be 'Microsoft Activation Scripts (MAS)'
            $entries[0].requiresAdmin | Should -BeTrue
            $entries[0].available | Should -BeTrue
            $entries[0].enabled | Should -BeTrue
        }
    }

    It 'ships identical source and portable launcher files and metadata' {
        foreach ($suffix in @('', '.json')) {
            $source = Join-Path $script:RepositoryRoot ('Scripts/Tinkerer/Launch-MAS.ps1' + $suffix)
            $portable = Join-Path $script:RepositoryRoot ('dist/Scripts/Tinkerer/Launch-MAS.ps1' + $suffix)
            (Get-FileHash -LiteralPath $source).Hash | Should -Be (Get-FileHash -LiteralPath $portable).Hash
        }
    }
}
