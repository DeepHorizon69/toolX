BeforeAll { . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1') }

Describe 'Operation gates and native contracts' {
    BeforeEach { Mock Get-ToolkitWindowsExecutable { param($Name) "C:\Windows\System32\$Name" } }
    It 'does not background modifications or privileged queries' {
        { Start-ToolkitExecution (Get-TestCommand 'repair.winsock') @{} } | Should -Throw '*read-only*'
        { Start-ToolkitExecution (Get-TestCommand 'security.defender') @{} } | Should -Throw '*read-only*'
    }
    It 'always disables DISM Windows Update fallback' {
        $spec = Get-ToolkitNativeSpec 'repair.dism-restore' @{}
        $spec.Arguments | Should -Contain '/LimitAccess'
        $spec.Arguments | Should -Contain '/RestoreHealth'
    }
    It 'never adds CHKDSK repair or online-scan switches' {
        $spec = Get-ToolkitNativeSpec 'repair.chkdsk' @{ drive = 'C' }
        $spec.Arguments.Count | Should -Be 1
        $spec.Arguments[0] | Should -Be 'C:'
    }
    It 'does not permit arbitrary native targets' {
        { Get-ToolkitNativeSpec 'custom.exe' @{} } | Should -Throw
    }
    It 'rejects malformed payloads, object values and oversized data' {
        { ConvertFrom-ToolkitPayload ('x' * 8193) } | Should -Throw
        { ConvertFrom-ToolkitPayload 'invalid' } | Should -Throw
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"anything":{"x":1}}'))
        { ConvertFrom-ToolkitPayload $payload } | Should -Throw '*scalar*'
    }
    It 'bounds queued records and reports dropped output' {
        $queue = New-Object 'Collections.Concurrent.BlockingCollection[string]' 2
        $state = @{ Truncated = $false }
        1..5 | ForEach-Object { Write-ToolkitQueueText $queue $state ('x' * 10000) }
        $queue.Count | Should -Be 2
        $state.Truncated | Should -BeTrue
        ($queue.Take()).Length | Should -Be 4096
        $queue.Dispose()
    }
}

Describe 'Console confirmation' {
    BeforeEach {
        Mock Write-Host {}
        Mock Test-ToolkitAdministrator { $true }
        Mock Get-ToolkitCapability { [pscustomobject]@{ Available = $true; Reason = '' } }
        Mock Get-ToolkitNativeSpec { throw 'A modifying native command must not be dispatched by this test.' }
    }
    It 'does not execute a declined high-risk operation' {
        Mock Read-Host { '' }
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}'))
        Invoke-ToolkitConsoleWorker 'repair.winsock' $payload | Should -Be 1223
        Should -Invoke Get-ToolkitNativeSpec -Times 0
    }
    It 'does not accept an injected confirmation parameter' {
        Mock Read-Host { '' }
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"confirmed":"yes"}'))
        Invoke-ToolkitConsoleWorker 'repair.winsock' $payload | Should -Be 1
        Should -Invoke Get-ToolkitNativeSpec -Times 0
    }
    It 'refuses privileged operations without an elevated token' {
        Mock Test-ToolkitAdministrator { $false }
        Mock Read-Host { '' }
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}'))
        Invoke-ToolkitConsoleWorker 'repair.winsock' $payload | Should -Be 1
        Should -Invoke Get-ToolkitNativeSpec -Times 0
    }
}

Describe 'Restricted cleanup' {
    BeforeEach {
        $cleanupRoot = Join-Path $TestDrive 'Temp'
        New-Item -ItemType Directory -Path $cleanupRoot -Force | Out-Null
        Mock Get-ToolkitTempRoot { $cleanupRoot }
        Mock Remove-Item {}
    }
    It 'requires typed confirmation even if called directly' {
        { Invoke-ToolkitCleanup -Preview @() -Confirmation '' } | Should -Throw
        Should -Invoke Remove-Item -Times 0
    }
    It 'never removes a candidate outside the immediate root' {
        $candidate = [pscustomobject]@{ Path = (Join-Path $TestDrive 'outside.txt'); Length = 0; LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-8) }
        $result = Invoke-ToolkitCleanup -Preview @($candidate) -Confirmation 'repair.temp'
        $result.Status | Should -Be 'Skipped'
        Should -Invoke Remove-Item -Times 0
    }
    It 'skips files changed after their preview' {
        $path = Join-Path $cleanupRoot 'old.txt'
        [IO.File]::WriteAllText($path, 'old')
        [IO.File]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow.AddDays(-8))
        $preview = @(Get-ToolkitCleanupPreview)
        [IO.File]::WriteAllText($path, 'changed')
        (Invoke-ToolkitCleanup $preview 'repair.temp').Status | Should -Be 'Skipped'
        Should -Invoke Remove-Item -Times 0
    }
    It 'dispatches only an unchanged eligible previewed file' {
        $path = Join-Path $cleanupRoot 'old.txt'
        [IO.File]::WriteAllText($path, 'old')
        [IO.File]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow.AddDays(-8))
        $preview = @(Get-ToolkitCleanupPreview)
        (Invoke-ToolkitCleanup $preview 'repair.temp').Status | Should -Be 'Deleted'
        Should -Invoke Remove-Item -Times 1 -ParameterFilter { $LiteralPath -eq $path }
    }
}

Describe 'Extended support and repair contracts' {
    BeforeEach { Mock Get-ToolkitWindowsExecutable { param($Name) "C:\Windows\System32\$Name" } }
    It 'allows powercfg.exe and builds repair.tcpip-reset native spec' {
        Get-ToolkitWindowsExecutable 'powercfg.exe' | Should -Match 'powercfg\.exe$'
        $spec = Get-ToolkitNativeSpec 'repair.tcpip-reset' @{}
        $spec.FileName | Should -Match 'netsh\.exe$'
        ($spec.Arguments -join ' ') | Should -Be 'int ip reset'
    }
    It 'prevents modifying and privileged new targets from running in background' {
        foreach ($id in @('network.dhcp-renew','hardware.tpm','repair.restart-spooler','repair.icon-cache','repair.tcpip-reset')) {
            { Start-ToolkitExecution (Get-TestCommand $id) @{} } | Should -Throw '*read-only*'
        }
    }
    It 'restarts spooler safely using mocked service and file calls' {
        $spoolDir = Join-Path $TestDrive 'spool\PRINTERS'
        New-Item -ItemType Directory -Path $spoolDir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $spoolDir 'stuck.spl'), 'data')
        Mock Test-ToolkitLocalPath { $spoolDir }
        Mock Test-ToolkitNoReparsePoint {}
        Mock Stop-Service {}
        Mock Start-Service {}
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock Remove-Item {}
        $summary = Invoke-ToolkitRepairAction 'repair.restart-spooler'
        $summary.RemovedFiles | Should -Be 1
        $summary.FinalStatus | Should -Be 'Running'
        Should -Invoke Stop-Service -Times 1 -Exactly
        Should -Invoke Start-Service -Times 1 -Exactly
        Should -Invoke Remove-Item -Times 1 -Exactly
    }
}
