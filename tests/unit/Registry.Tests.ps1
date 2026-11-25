BeforeAll { . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1') }

Describe 'Built-in catalog safety' {
    BeforeEach { $registry = [IO.File]::ReadAllText((Join-Path $script:RepositoryRoot 'src/config/commands.json')) | ConvertFrom-Json }
    It 'validates all 66 reviewed operations' {
        { Test-ToolkitRegistry $registry } | Should -Not -Throw
        $registry.commands.Count | Should -Be 66
    }
    It 'rejects duplicate identifiers' {
        $registry.commands[1].id = $registry.commands[0].id
        { Test-ToolkitRegistry $registry } | Should -Throw '*duplicate*'
    }
    It 'rejects unknown fields and executable targets' {
        $registry.commands[0] | Add-Member -NotePropertyName expression -NotePropertyValue 'malicious'
        { Test-ToolkitRegistry $registry } | Should -Throw '*Unknown field*'
    }
    It 'rejects unknown dispatch targets' {
        $registry.commands[0].targetId = 'unregistered.function'
        { Test-ToolkitRegistry $registry } | Should -Throw '*Unknown target*'
    }
    It 'cannot downgrade target risk or privilege requirements' {
        ($registry.commands | Where-Object id -eq 'repair.winsock').requiresAdmin = $false
        { Test-ToolkitRegistry $registry } | Should -Throw '*policy mismatch*'
    }
    It 'cannot remove typed confirmation' {
        ($registry.commands | Where-Object id -eq 'repair.winsock').confirmation = 'None'
        { Test-ToolkitRegistry $registry } | Should -Throw '*typed confirmation*'
    }
    It 'rejects malformed parameter definitions' {
        ($registry.commands | Where-Object id -eq 'network.port').parameters[1].minimum = 70000
        { Test-ToolkitRegistry $registry } | Should -Throw '*range*'
    }
    It 'ranks exact identifiers ahead of partial text matches' {
        $results = @(Find-ToolkitCommand $registry.commands 'network.ping')
        $results[0].id | Should -Be 'network.ping'
    }
    It 'treats regex syntax as literal search text' {
        @(Find-ToolkitCommand $registry.commands '.*').Count | Should -Be 0
    }
    It 'finds names, categories and keywords without case sensitivity' {
        @(Find-ToolkitCommand $registry.commands 'ICMP').Count | Should -BeGreaterThan 0
        @(Find-ToolkitCommand $registry.commands 'hardware diagnostics').Count | Should -Be 7
    }
}

Describe 'Parameter validation' {
    It 'accepts IPv6 and hostnames' {
        $definition = (Get-TestCommand 'network.ping').parameters[0]
        Test-ToolkitParameter $definition '::1' | Should -Be '::1'
        Test-ToolkitParameter $definition 'host.example' | Should -Be 'host.example'
    }
    It 'rejects option and shell-like host input' {
        $definition = (Get-TestCommand 'network.ping').parameters[0]
        foreach ($value in @('-n','host;whoami','a..b',"host`nvalue")) { { Test-ToolkitParameter $definition $value } | Should -Throw }
    }
    It 'enforces the TCP port range' {
        $definition = (Get-TestCommand 'network.port').parameters[1]
        Test-ToolkitParameter $definition '65535' | Should -Be 65535
        foreach ($value in @('0','65536','abc')) { { Test-ToolkitParameter $definition $value } | Should -Throw }
    }
    It 'rejects unknown arguments' {
        { ConvertTo-ToolkitParameterMap (Get-TestCommand 'network.ping') @{ host = 'localhost'; command = 'bad' } } | Should -Throw '*Unexpected parameter*'
    }
    It 'enforces record types and checksum length' {
        { Test-ToolkitParameter (Get-TestCommand 'network.dns').parameters[1] 'ANY' } | Should -Throw
        { Test-ToolkitParameter (Get-TestCommand 'storage.hash').parameters[1] 'abc' } | Should -Throw
    }
    It 'rejects network paths and alternate data streams' {
        { Test-ToolkitLocalPath '\\server\share\file' } | Should -Throw
        { Test-ToolkitLocalPath 'C:\file:stream' } | Should -Throw
    }
    It 'quotes trailing backslashes and embedded quotes for Windows argv' {
        ConvertTo-ToolkitArgument 'C:\folder\' | Should -Be '"C:\folder\\"'
        ConvertTo-ToolkitArgument 'a"b' | Should -Be '"a\"b"'
    }
    It 'strips terminal escape sequences and control characters' {
        ConvertTo-ToolkitSafeText ([char]27 + '[31mhello' + [char]0) | Should -Be 'hello'
    }
}
