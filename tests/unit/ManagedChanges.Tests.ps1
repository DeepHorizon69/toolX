BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1')
    $script:ToolkitVersion = '0.2.0'
}

Describe 'Managed setting transactions' {
    BeforeEach {
        $script:jobs = @{}
        $script:setting = [pscustomobject]@{ Disabled = $false }
        Mock Initialize-ToolkitRecovery {}
        Mock Enter-ToolkitManagedLock { New-Object IO.MemoryStream }
        Mock Get-ToolkitManagedJob { @($script:jobs.Values) }
        Mock Save-ToolkitManagedJob { param($Job) Test-ToolkitManagedJob $Job; $script:jobs[$Job.Id] = $Job }
        Mock Get-ToolkitSettingState { $script:setting }
        Mock Set-ToolkitSettingState { param($Kind,$Scope,$State) $script:setting = $State }
        Mock Register-ToolkitManagedTask {}
        Mock Remove-ToolkitManagedTask {}
        Mock Test-ToolkitUpdateEligibility {}
    }
    It 'records timed changes with original state before applying them' {
        Start-ToolkitSettingChange Defender Realtime ([pscustomobject]@{ Disabled = $true }) Timed -Minutes 30
        $job = @($script:jobs.Values)[0]
        $job.Status | Should -Be 'Active'
        $job.Original.Disabled | Should -BeFalse
        $job.Applied.Disabled | Should -BeTrue
        ([DateTimeOffset]::Parse($job.ExpiresUtc) - [DateTimeOffset]::Parse($job.CreatedUtc)).TotalMinutes | Should -BeGreaterThan 29
        Should -Invoke Register-ToolkitManagedTask -Times 1
    }
    It 'keeps manual changes restorable without registering expiry tasks' {
        Start-ToolkitSettingChange Defender Realtime ([pscustomobject]@{ Disabled = $true }) Manual
        @($script:jobs.Values)[0].ExpiresUtc | Should -BeNullOrEmpty
        Should -Invoke Register-ToolkitManagedTask -Times 0
    }
    It 'leaves Windows untouched when recovery preflight fails' {
        Mock Initialize-ToolkitRecovery { throw 'preflight blocked' }
        { Start-ToolkitSettingChange Defender Realtime ([pscustomobject]@{ Disabled = $true }) Timed } | Should -Throw '*preflight*'
        Should -Invoke Set-ToolkitSettingState -Times 0
        $script:jobs.Count | Should -Be 0
    }
    It 'does not apply a change if task registration fails' {
        Mock Register-ToolkitManagedTask { throw 'registration failed' }
        { Start-ToolkitSettingChange Defender Realtime ([pscustomobject]@{ Disabled = $true }) Timed } | Should -Throw '*rolled back*'
        Should -Invoke Set-ToolkitSettingState -Times 0
        @($script:jobs.Values)[0].Status | Should -Be 'Restored'
    }
    It 'rolls back a partially applied operation' {
        $script:setting = [pscustomobject]@{ Private = 'True'; Public = 'False'; Domain = 'NotConfigured' }
        $script:applyCount = 0
        Mock Set-ToolkitSettingState {
            param($Kind,$Scope,$State)
            $script:applyCount++
            if ($script:applyCount -eq 1) { $script:setting = [pscustomobject]@{ Private = 'False'; Public = 'False'; Domain = 'NotConfigured' }; throw 'partial write' }
            $script:setting = $State
        }
        { Start-ToolkitSettingChange Firewall All ([pscustomobject]@{ Private = 'False'; Public = 'False'; Domain = 'False' }) Timed } | Should -Throw '*rolled back*'
        $script:setting.Private | Should -Be 'True'
        $script:setting.Domain | Should -Be 'NotConfigured'
        @($script:jobs.Values)[0].Status | Should -Be 'Restored'
    }
    It 'rejects overlapping changes' {
        Start-ToolkitSettingChange Defender Realtime ([pscustomobject]@{ Disabled = $true }) Manual
        { Start-ToolkitSettingChange Defender Realtime ([pscustomobject]@{ Disabled = $true }) Timed } | Should -Throw '*overlapping*'
        Should -Invoke Set-ToolkitSettingState -Times 1
    }
    It 'does not claim ownership when the requested state already exists' {
        $script:setting = [pscustomobject]@{ Disabled = $true }
        Start-ToolkitSettingChange Defender Realtime ([pscustomobject]@{ Disabled = $true }) Timed
        $script:jobs.Count | Should -Be 0
        Should -Invoke Set-ToolkitSettingState -Times 0
    }
    It 'restores the original state and removes only its task' {
        Start-ToolkitSettingChange Defender Realtime ([pscustomobject]@{ Disabled = $true }) Timed
        $job = @($script:jobs.Values)[0]
        Restore-ToolkitManagedJob $job
        $script:setting.Disabled | Should -BeFalse
        $job.Status | Should -Be 'Restored'
        Should -Invoke Remove-ToolkitManagedTask -Times 1 -ParameterFilter { $Id -eq $job.Id }
    }
    It 'does not overwrite external policy conflicts' {
        $script:setting = [pscustomobject]@{ Private = 'True' }
        Start-ToolkitSettingChange Firewall Private ([pscustomobject]@{ Private = 'False' }) Timed
        $job = @($script:jobs.Values)[0]
        $script:setting = [pscustomobject]@{ Private = 'NotConfigured' }
        { Restore-ToolkitManagedJob $job } | Should -Throw '*differ*'
        $job.Status | Should -Be 'Conflict'
        Should -Invoke Set-ToolkitSettingState -Times 1
        Should -Invoke Remove-ToolkitManagedTask -Times 0
    }
    It 'retains failed restoration records and tasks for retry' {
        Start-ToolkitSettingChange Defender Realtime ([pscustomobject]@{ Disabled = $true }) Timed
        $job = @($script:jobs.Values)[0]
        Mock Set-ToolkitSettingState { throw 'policy blocked restore' }
        { Restore-ToolkitManagedJob $job } | Should -Throw
        $job.Status | Should -Be 'Failed'
        Should -Invoke Remove-ToolkitManagedTask -Times 0
    }
    It 'makes explicit Enable supersede a pending restoration' {
        Start-ToolkitSettingChange Defender Realtime ([pscustomobject]@{ Disabled = $true }) Timed
        Enable-ToolkitProtection Defender Realtime
        @($script:jobs.Values)[0].Status | Should -Be 'Superseded'
        $script:setting.Disabled | Should -BeFalse
        Should -Invoke Remove-ToolkitManagedTask -Times 1
    }
    It 'preserves absent versus existing update policy when restoring' {
        $script:setting = [pscustomobject]@{ Exists = $false; Value = 0; ValueKind = 'None' }
        Start-ToolkitSettingChange Updates Automatic ([pscustomobject]@{ Exists = $true; Value = 1; ValueKind = 'DWord' }) Timed -Months 36
        $job = @($script:jobs.Values)[0]
        $job.Original.Exists | Should -BeFalse
        Restore-ToolkitManagedJob $job
        $script:setting.Exists | Should -BeFalse
        $script:setting.ValueKind | Should -Be 'None'
    }
    It 'rejects invalid update duration before any preflight or write' {
        { Start-ToolkitSettingChange Updates Automatic ([pscustomobject]@{}) Timed -Months 37 } | Should -Throw '*duration*'
        Should -Invoke Initialize-ToolkitRecovery -Times 0
    }
    It 'does not override organization policy eligibility failures' {
        Mock Test-ToolkitUpdateEligibility { throw 'organization managed' }
        { Start-ToolkitSettingChange Updates Automatic ([pscustomobject]@{}) Timed } | Should -Throw '*organization*'
        Should -Invoke Initialize-ToolkitRecovery -Times 0
        Should -Invoke Set-ToolkitSettingState -Times 0
    }
}

Describe 'Defender verification and calendar arithmetic' {
    It 'refuses Tamper Protection bypass and never calls the preference setter' {
        Mock Get-ToolkitDefenderStatus { [pscustomobject]@{ IsTamperProtected = $true } }
        Mock Set-ToolkitDefenderPreference {}
        { Set-ToolkitSettingState Defender Realtime ([pscustomobject]@{ Disabled = $true }) } | Should -Throw '*Tamper Protection*'
        Should -Invoke Set-ToolkitDefenderPreference -Times 0
    }
    It 'detects an ignored Defender preference change' {
        Mock Get-ToolkitDefenderStatus { [pscustomobject]@{ IsTamperProtected = $false } }
        Mock Set-ToolkitDefenderPreference {}
        Mock Get-ToolkitSettingState { [pscustomobject]@{ Disabled = $false } }
        { Set-ToolkitSettingState Defender Realtime ([pscustomobject]@{ Disabled = $true }) } | Should -Throw '*did not retain*'
    }
    It 'uses calendar months at month end and across leap years' {
        (Get-ToolkitChangeDeadline Updates Timed 30 1 ([DateTimeOffset]::Parse('2028-01-31T12:00:00Z'))).ToString('yyyy-MM-dd') | Should -Be '2028-02-29'
        (Get-ToolkitChangeDeadline Updates Timed 30 36 ([DateTimeOffset]::Parse('2028-02-29T12:00:00Z'))).ToString('yyyy-MM-dd') | Should -Be '2031-02-28'
    }
    It 'does not create a deadline for manual security mode' {
        Get-ToolkitChangeDeadline Defender Manual 30 1 | Should -BeNullOrEmpty
    }
    It 'calculates calendar months before converting a local date to UTC' {
        (Get-ToolkitChangeDeadline Updates Timed 30 1 ([DateTimeOffset]::Parse('2027-01-31T06:00:00+07:00'))).ToString('yyyy-MM-dd HH:mm') | Should -Be '2027-02-27 23:00'
    }
    It 'rejects executable content in managed job metadata' {
        $job = New-ToolkitManagedJob Defender Realtime ([pscustomobject]@{ Disabled = $false }) ([pscustomobject]@{ Disabled = $true }) $null
        $job | Add-Member -NotePropertyName Command -NotePropertyValue 'anything'
        { Test-ToolkitManagedJob $job } | Should -Throw '*Unknown field*'
    }
    It 'rejects arbitrary paths as job identifiers' {
        { Get-ToolkitJobPath '../outside' } | Should -Throw '*identifier*'
        { Get-ToolkitHelperPath '../outside' } | Should -Throw '*version*'
    }
    It 'does not allow power actions inside a restoration job' {
        $job = New-ToolkitManagedJob Defender Realtime ([pscustomobject]@{ Disabled = $false }) ([pscustomobject]@{ Disabled = $true }) $null
        $job.PowerAction = 'Restart'
        { Test-ToolkitManagedJob $job } | Should -Throw '*Power action*'
    }
    It 'rejects source-mode recovery before touching ProgramData' {
        $script:ToolkitStandalone = $false
        Mock Test-ToolkitAdministrator { $true }
        Mock Initialize-ToolkitProtectedDirectory {}
        { Initialize-ToolkitRecovery } | Should -Throw '*standalone*'
        Should -Invoke Initialize-ToolkitProtectedDirectory -Times 0
    }
}

Describe 'Power action safety' {
    BeforeEach {
        Mock Get-ToolkitWindowsExecutable { 'C:\Windows\System32\shutdown.exe' }
        Mock Invoke-ToolkitPowerRequest {}
        Mock Initialize-ToolkitRecovery {}
        Mock Enter-ToolkitManagedLock { New-Object IO.MemoryStream }
        Mock Register-ToolkitManagedTask {}
        Mock Remove-ToolkitManagedTask {}
        Mock Get-ToolkitBootId { 'same-boot' }
        $script:jobs = @{}
        Mock Get-ToolkitManagedJob { @($script:jobs.Values) }
        Mock Read-ToolkitManagedJob { param($Id) $script:jobs[$Id] }
        Mock Save-ToolkitManagedJob { param($Job) Test-ToolkitManagedJob $Job; $script:jobs[$Job.Id] = $Job }
    }
    It 'normal shutdown never uses an implicit forced timeout' {
        $spec = Get-ToolkitPowerSpec Shutdown $false
        $spec.Arguments -join ' ' | Should -Be '/s /t 0'
        $spec.Arguments | Should -Not -Contain '/f'
    }
    It 'force restart is explicit' {
        (Get-ToolkitPowerSpec Restart $true).Arguments -join ' ' | Should -Be '/r /t 0 /f'
    }
    It 'rejects overlong countdowns before recovery setup' {
        { Start-ToolkitPowerCountdown @{ action = 'Shutdown'; duration = 8; unit = 'Days'; closure = 'Normal' } } | Should -Throw '*seven days*'
        Should -Invoke Initialize-ToolkitRecovery -Times 0
    }
    It 'schedules without issuing a power request in the interactive process' {
        Start-ToolkitPowerCountdown @{ action = 'Shutdown'; duration = 5; unit = 'Minutes'; closure = 'Normal' }
        @($script:jobs.Values)[0].Status | Should -Be 'Active'
        Should -Invoke Register-ToolkitManagedTask -Times 1
        Should -Invoke Invoke-ToolkitPowerRequest -Times 0
    }
    It 'cancels an owned job before it can be executed' {
        Start-ToolkitPowerCountdown @{ action = 'Shutdown'; duration = 5; unit = 'Minutes'; closure = 'Normal' }
        Mock Test-Path { $true }
        Stop-ToolkitPowerCountdown
        @($script:jobs.Values)[0].Status | Should -Be 'Cancelled'
        Should -Invoke Remove-ToolkitManagedTask -Times 1
        Should -Invoke Invoke-ToolkitPowerRequest -Times 0
    }
    It 'prevents duplicate pending power countdowns' {
        Start-ToolkitPowerCountdown @{ action = 'Restart'; duration = 5; unit = 'Minutes'; closure = 'Normal' }
        { Start-ToolkitPowerCountdown @{ action = 'Shutdown'; duration = 1; unit = 'Minutes'; closure = 'Force' } } | Should -Throw '*already exists*'
    }
}

Describe 'Scheduled helper execution' {
    BeforeEach {
        $script:ToolkitStandalone = $true
        $script:ToolkitEntryPath = Get-ToolkitHelperPath '0.2.0'
        $script:workerJob = New-ToolkitManagedJob Power Local ([pscustomobject]@{}) ([pscustomobject]@{}) ([DateTimeOffset]::UtcNow.AddSeconds(-5))
        $script:workerJob.PowerAction = 'Shutdown'; $script:workerJob.BootId = 'original-boot'; $script:workerJob.Status = 'Active'
        Mock Read-ToolkitManagedJob { $script:workerJob }
        Mock Test-ToolkitAdministrator { $true }
        Mock Test-ToolkitProtectedPath {}
        Mock Enter-ToolkitManagedLock { New-Object IO.MemoryStream }
        Mock Save-ToolkitManagedJob {}
        Mock Remove-ToolkitManagedTask {}
        Mock Get-ToolkitBootId { 'original-boot' }
        Mock Invoke-ToolkitPowerRequest {}
    }
    It 'expires missed power deadlines instead of shutting down later' {
        $script:workerJob.ExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(-10).ToString('o')
        Invoke-ToolkitManagedWorker $script:workerJob.Id Execute
        $script:workerJob.Status | Should -Be 'Expired'
        Should -Invoke Invoke-ToolkitPowerRequest -Times 0
    }
    It 'does not execute a previous-boot power countdown' {
        Mock Get-ToolkitBootId { 'different-boot' }
        Invoke-ToolkitManagedWorker $script:workerJob.Id Execute
        $script:workerJob.Status | Should -Be 'Expired'
        Should -Invoke Invoke-ToolkitPowerRequest -Times 0
    }
    It 'does not execute cancelled jobs even if their task was already queued' {
        $script:workerJob.Status = 'Cancelled'
        Invoke-ToolkitManagedWorker $script:workerJob.Id Execute
        Should -Invoke Invoke-ToolkitPowerRequest -Times 0
    }
    It 'never executes a failed power scheduling transaction' {
        $script:workerJob.Status = 'Failed'
        Invoke-ToolkitManagedWorker $script:workerJob.Id Execute
        Should -Invoke Invoke-ToolkitPowerRequest -Times 0
    }
    It 'issues a due confirmed power request only once' {
        Invoke-ToolkitManagedWorker $script:workerJob.Id Execute
        Invoke-ToolkitManagedWorker $script:workerJob.Id Execute
        $script:workerJob.Status | Should -Be 'Executed'
        Should -Invoke Invoke-ToolkitPowerRequest -Times 1
    }
    It 'rejects invocation from an unprotected portable copy' {
        $script:ToolkitEntryPath = 'C:\USB\Toolkit.ps1'
        { Invoke-ToolkitManagedWorker $script:workerJob.Id Execute } | Should -Throw '*pinned*'
        Should -Invoke Invoke-ToolkitPowerRequest -Times 0
    }
}
