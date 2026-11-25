BeforeAll { . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1'); $script:ToolkitVersion = '0.2.0' }

Describe 'Scheduled task construction without registration' {
    BeforeEach {
        Mock Test-ToolkitProtectedPath {}
        $script:taskAcl = New-Object PSObject
        $script:taskAcl | Add-Member -MemberType ScriptMethod -Name SetSecurityDescriptor -Value { param($Sddl,$Flags) }
        $script:folderStub = New-Object PSObject
        $script:folderStub | Add-Member -MemberType ScriptMethod -Name GetTask -Value { param($Name) return $script:taskAcl }
        Mock Get-ToolkitTaskFolder { $script:folderStub }
        Mock Register-ScheduledTask {}
        Mock Enable-ScheduledTask {}
        Mock Remove-ToolkitManagedTask {}
    }
    It 'uses S4U highest privileges, a pinned file and disabled registration before applying ACLs' {
        $job = New-ToolkitManagedJob Defender Realtime ([pscustomobject]@{ Disabled = $false }) ([pscustomobject]@{ Disabled = $true }) ([DateTimeOffset]::UtcNow.AddMinutes(30))
        Register-ToolkitManagedTask $job
        Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter {
            $Principal.LogonType.ToString() -in @('S4U','2') -and $Principal.RunLevel.ToString() -in @('Highest','1') -and
            -not $Settings.Enabled -and $Settings.StartWhenAvailable -and $Trigger.Count -eq 2 -and
            $Action.Arguments -match '-File' -and $Action.Arguments -notmatch 'ExecutionPolicy|EncodedCommand|Bypass'
        }
        Should -Invoke Enable-ScheduledTask -Times 1
    }
    It 'does not wake the PC, run on startup or replay missed power actions' {
        $job = New-ToolkitManagedJob Power Local ([pscustomobject]@{}) ([pscustomobject]@{}) ([DateTimeOffset]::UtcNow.AddMinutes(30))
        $job.PowerAction = 'Shutdown'; $job.BootId = 'test-boot'
        Register-ToolkitManagedTask $job
        Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter { -not $Settings.WakeToRun -and -not $Settings.StartWhenAvailable -and $Trigger.Count -eq 1 }
    }
    It 'removes the registered task if ACL application fails' {
        $script:taskAcl | Add-Member -MemberType ScriptMethod -Name SetSecurityDescriptor -Value { throw 'ACL denied' } -Force
        $job = New-ToolkitManagedJob Defender Realtime ([pscustomobject]@{ Disabled = $false }) ([pscustomobject]@{ Disabled = $true }) ([DateTimeOffset]::UtcNow.AddMinutes(30))
        { Register-ToolkitManagedTask $job } | Should -Throw '*ACL denied*'
        Should -Invoke Remove-ToolkitManagedTask -Times 1
        Should -Invoke Enable-ScheduledTask -Times 0
    }
    It 'cannot register a manual-mode job without a deadline' {
        $job = New-ToolkitManagedJob Defender Realtime ([pscustomobject]@{ Disabled = $false }) ([pscustomobject]@{ Disabled = $true }) $null
        { Register-ToolkitManagedTask $job } | Should -Throw '*deadline*'
        Should -Invoke Register-ScheduledTask -Times 0
    }
}

Describe 'Extended registry execution gates' {
    It 'routes every new dangerous operation through confirmation and elevation' {
        foreach ($id in @('security.firewall-control','security.defender-control','updates.suspend','power.countdown','power.force-restart')) {
            $command = Get-TestCommand $id
            $command.requiresAdmin | Should -BeTrue
            $command.confirmation | Should -Be 'TypeCommandId'
            { Start-ToolkitExecution $command @{} } | Should -Throw '*read-only*'
        }
    }
    It 'does not force restart if its worker confirmation is declined' {
        Mock Test-ToolkitAdministrator { $true }
        Mock Get-ToolkitCapability { [pscustomobject]@{ Available = $true; Reason = '' } }
        Mock Read-Host { '' }
        Mock Write-Host {}
        Mock Invoke-ToolkitPowerRequest {}
        Invoke-ToolkitConsoleWorker 'power.force-restart' ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}'))) | Should -Be 1223
        Should -Invoke Invoke-ToolkitPowerRequest -Times 0
    }
    It 'uses a bounded recent-event query and explicit connectivity target parameters' {
        $eventCommand = Get-TestCommand 'troubleshooting.events'
        $eventCommand.parameters[0].maximum | Should -Be 168
        { ConvertTo-ToolkitParameterMap (Get-TestCommand 'troubleshooting.connectivity') @{} } | Should -Throw '*required*'
    }
}
