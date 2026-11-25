function Get-ToolkitFirewallScope {
    param([string]$Scope)
    if ($Scope -notin @('Private','Public','Domain','All')) { throw 'Invalid firewall profile selection.' }
    if ($Scope -eq 'All') { return @('Domain','Private','Public') }
    return @($Scope)
}

function Get-ToolkitUpdatePolicyKey {
    param([switch]$Writable)
    $view = [Microsoft.Win32.RegistryView]::Registry32
    if ([Environment]::Is64BitOperatingSystem) { $view = [Microsoft.Win32.RegistryView]::Registry64 }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
    try {
        if ($Writable) { return $base.CreateSubKey('SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU') }
        return $base.OpenSubKey('SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', $false)
    }
    finally { $base.Dispose() }
}

function Get-ToolkitSettingState {
    param([string]$Kind, [string]$Scope)
    switch ($Kind) {
        'Firewall' {
            $state = [ordered]@{}
            foreach ($name in (Get-ToolkitFirewallScope $Scope)) {
                $firewallProfile = NetSecurity\Get-NetFirewallProfile -Name $name -PolicyStore PersistentStore -ErrorAction Stop
                $value = $firewallProfile.Enabled.ToString()
                if ($value -notin @('True','False','NotConfigured')) { throw 'Unrecognized firewall configuration.' }
                $state[$name] = $value
            }
            return [pscustomobject]$state
        }
        'Defender' {
            $status = Defender\Get-MpComputerStatus -ErrorAction Stop
            if (-not $status.AMServiceEnabled -or -not $status.AntivirusEnabled) { throw 'Defender Antivirus is not active; its real-time setting cannot be managed here.' }
            return [pscustomobject]@{ Disabled = (-not [bool]$status.RealTimeProtectionEnabled) }
        }
        'Updates' {
            $key = Get-ToolkitUpdatePolicyKey
            try {
                if ($null -eq $key -or 'NoAutoUpdate' -notin $key.GetValueNames()) { return [pscustomobject]@{ Exists = $false; Value = 0; ValueKind = 'None' } }
                $kindName = $key.GetValueKind('NoAutoUpdate').ToString()
                $value = $key.GetValue('NoAutoUpdate')
                if ($kindName -ne 'DWord' -or $value -notin @(0,1)) { throw 'NoAutoUpdate has an unsupported value or type; it will not be overwritten.' }
                return [pscustomobject]@{ Exists = $true; Value = [int]$value; ValueKind = 'DWord' }
            }
            finally { if ($null -ne $key) { $key.Dispose() } }
        }
        default { throw 'Unknown managed setting.' }
    }
}

function Set-ToolkitSettingState {
    param([string]$Kind, [string]$Scope, [object]$State)
    switch ($Kind) {
        'Firewall' {
            foreach ($name in (Get-ToolkitFirewallScope $Scope)) {
                if ($State.$name -notin @('True','False','NotConfigured')) { throw 'Invalid firewall state.' }
                NetSecurity\Set-NetFirewallProfile -Name $name -Enabled $State.$name -PolicyStore PersistentStore -ErrorAction Stop
            }
        }
        'Defender' {
            if ($State.Disabled -isnot [bool]) { throw 'Invalid Defender state.' }
            $status = Get-ToolkitDefenderStatus
            if ($State.Disabled -and $status.IsTamperProtected) { throw 'Tamper Protection blocks this change. The toolbox will not bypass it.' }
            Set-ToolkitDefenderPreference $State.Disabled
        }
        'Updates' {
            $key = Get-ToolkitUpdatePolicyKey -Writable
            try {
                if ($State.Exists) {
                    if ($State.ValueKind -ne 'DWord' -or $State.Value -notin @(0,1)) { throw 'Invalid update policy state.' }
                    $key.SetValue('NoAutoUpdate', [int]$State.Value, [Microsoft.Win32.RegistryValueKind]::DWord)
                }
                else { $key.DeleteValue('NoAutoUpdate', $false) }
            }
            finally { $key.Dispose() }
        }
        default { throw 'Unknown managed setting.' }
    }
    $actual = Get-ToolkitSettingState $Kind $Scope
    if (-not (Test-ToolkitStateEqual $State $actual)) { throw 'Windows did not retain the requested setting. Review policy or Tamper Protection.' }
    if ($Kind -eq 'Firewall') {
        foreach ($name in (Get-ToolkitFirewallScope $Scope)) {
            if ($State.$name -eq 'NotConfigured') { continue }
            $effective = NetSecurity\Get-NetFirewallProfile -Name $name -PolicyStore ActiveStore -ErrorAction Stop
            if ($effective.Enabled.ToString() -ne $State.$name) { throw 'Firewall policy overrides the requested profile state.' }
        }
    }
}

function Get-ToolkitDefenderStatus {
    return Defender\Get-MpComputerStatus -ErrorAction Stop
}

function Set-ToolkitDefenderPreference {
    param([bool]$Disabled)
    Defender\Set-MpPreference -DisableRealtimeMonitoring $Disabled -ErrorAction Stop
}

function Get-ToolkitChangeDeadline {
    param([string]$Kind, [string]$Mode, [int]$Minutes, [int]$Months, [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    if ($Mode -notin @('Timed','Manual') -or $Minutes -lt 1 -or $Minutes -gt 1440 -or $Months -lt 1 -or $Months -gt 36) { throw 'Invalid change duration or mode.' }
    if ($Kind -eq 'Updates') { return $Now.AddMonths($Months).ToUniversalTime() }
    if ($Mode -eq 'Timed') { return $Now.ToUniversalTime().AddMinutes($Minutes) }
    return $null
}

function Test-ToolkitUpdateEdition {
    $edition = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID -ErrorAction Stop).EditionID
    return $edition -match '^(Professional|Enterprise|Education)'
}

function Test-ToolkitUpdateEligibility {
    if (-not (Test-ToolkitUpdateEdition)) { throw 'Long automatic-update suspension requires a validated Pro, Enterprise or Education edition. Home is not supported.' }
    $computer = CimCmdlets\Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 10 -ErrorAction Stop
    if ($computer.PartOfDomain) { throw 'Domain-managed update policy must be changed by the organization administrator.' }
    if (Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo') { throw 'An organization join was detected; update management must be reviewed by its administrator.' }
    $enrollments = Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue
    foreach ($enrollment in $enrollments) {
        $value = Get-ItemProperty -LiteralPath $enrollment.PSPath -ErrorAction Stop
        if ($value.EnrollmentState -eq 1 -and $value.ProviderID) { throw 'Active device management was detected; local update suspension is unavailable.' }
    }
    if ((Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue).WUServer) { throw 'An update server policy is already configured.' }
}

function Get-ToolkitActiveJob {
    param([string]$Kind)
    return @(Get-ToolkitManagedJob | Where-Object { $_.Kind -eq $Kind -and $_.Status -in @('Prepared','Active','Restoring','Failed','Conflict') })
}

function Restore-ToolkitManagedJob {
    param([object]$Job)
    if ($Job.Kind -notin @('Firewall','Defender','Updates')) { throw 'This is not a restorable setting change.' }
    $current = Get-ToolkitSettingState $Job.Kind $Job.Scope
    foreach ($property in $Job.Original.PSObject.Properties) {
        $name = $property.Name
        if ($current.$name -cne $property.Value -and $current.$name -cne $Job.Applied.$name) {
            $Job.Status = 'Conflict'; $Job.Detail = 'Current settings differ from both the original and toolbox-applied state. No values were overwritten.'
            Save-ToolkitManagedJob $Job
            throw $Job.Detail
        }
    }
    try {
        $Job.Status = 'Restoring'; Save-ToolkitManagedJob $Job
        if (-not (Test-ToolkitStateEqual $current $Job.Original)) { Set-ToolkitSettingState $Job.Kind $Job.Scope $Job.Original }
        $Job.Status = 'Restored'; $Job.Detail = 'Original setting restored and verified.'
        Save-ToolkitManagedJob $Job
        Remove-ToolkitManagedTask $Job.Id
    }
    catch {
        $Job.Status = 'Failed'; $Job.Detail = 'Restoration needs attention: ' + $_.Exception.Message
        Save-ToolkitManagedJob $Job
        throw
    }
}

function Start-ToolkitSettingChange {
    param([string]$Kind, [string]$Scope, [object]$Applied, [string]$Mode, [int]$Minutes = 30, [int]$Months = 1)
    if ($Mode -notin @('Timed','Manual') -or $Minutes -lt 1 -or $Minutes -gt 1440 -or $Months -lt 1 -or $Months -gt 36) { throw 'Invalid change duration or mode.' }
    if ($Kind -eq 'Updates') { Test-ToolkitUpdateEligibility }
    Initialize-ToolkitRecovery
    $lock = Enter-ToolkitManagedLock
    try {
        $existing = @(Get-ToolkitActiveJob $Kind)
        foreach ($job in $existing) {
            if ($Kind -ne 'Firewall' -or $Scope -eq 'All' -or $job.Scope -eq 'All' -or $Scope -eq $job.Scope) { throw 'An overlapping change already exists. Restore it before creating another.' }
        }
        $original = Get-ToolkitSettingState $Kind $Scope
        if (Test-ToolkitStateEqual $original $Applied) { 'The requested setting already exists; no change or restoration job was created.'; return }
        $deadline = Get-ToolkitChangeDeadline $Kind $Mode $Minutes $Months
        $job = New-ToolkitManagedJob $Kind $Scope $original $Applied $deadline
        Save-ToolkitManagedJob $job
        try {
            if ($null -ne $deadline) { Register-ToolkitManagedTask $job }
            Set-ToolkitSettingState $Kind $Scope $Applied
            $job.Status = 'Active'; $job.Detail = 'Applied and verified. Manual changes or organization policy can override this setting.'
            Save-ToolkitManagedJob $job
        }
        catch {
            $failure = $_.Exception.Message
            $job.Status = 'Failed'; $job.Detail = $failure; Save-ToolkitManagedJob $job
            try { Restore-ToolkitManagedJob $job }
            catch { throw "Change failed: $failure. Rollback also needs attention: $($_.Exception.Message). The recovery record was retained." }
            throw "Change failed and was rolled back: $failure"
        }
        Get-ToolkitManagedSummary | Where-Object Id -eq $job.Id
    }
    finally { $lock.Dispose() }
}

function Restore-ToolkitSetting {
    param([string]$Kind)
    $root = Get-ToolkitManagedRoot
    if (-not (Test-Path -LiteralPath (Join-Path $root 'state.lock'))) { 'No toolbox changes exist to restore.'; return }
    $lock = Enter-ToolkitManagedLock
    try {
        $jobs = @(Get-ToolkitActiveJob $Kind)
        if (-not $jobs.Count) { 'No active toolbox-owned changes exist for this setting.' }
        foreach ($job in $jobs) {
            try { Restore-ToolkitManagedJob $job; "Restored $($job.Id) ($($job.Scope))." }
            catch { "Restore failed for $($job.Id): $($_.Exception.Message)"; throw }
        }
    }
    finally { $lock.Dispose() }
}

function Enable-ToolkitProtection {
    param([string]$Kind, [string]$Scope)
    Initialize-ToolkitRecovery
    $lock = Enter-ToolkitManagedLock
    try {
        $jobs = @(Get-ToolkitActiveJob $Kind)
        foreach ($job in $jobs) {
            if ($Kind -eq 'Firewall' -and $job.Scope -eq 'All' -and $Scope -ne 'All') { throw 'Restore the existing All-profiles change first, then enable individual profiles.' }
        }
        $state = [pscustomobject]@{ Disabled = $false }
        if ($Kind -eq 'Firewall') {
            $stateMap = [ordered]@{}
            foreach ($name in (Get-ToolkitFirewallScope $Scope)) { $stateMap[$name] = 'True' }
            $state = [pscustomobject]$stateMap
        }
        Set-ToolkitSettingState $Kind $Scope $state
        foreach ($job in $jobs) {
            if ($Kind -ne 'Firewall' -or $Scope -eq 'All' -or $job.Scope -eq $Scope) {
                $job.Status = 'Superseded'; $job.Detail = 'Explicit Enable superseded the original restoration request.'
                Save-ToolkitManagedJob $job; Remove-ToolkitManagedTask $job.Id
            }
        }
        'Protection enabled and effective state verified.'
    }
    finally { $lock.Dispose() }
}

function Get-ToolkitBootId {
    return (CimCmdlets\Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 10 -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o')
}

function Get-ToolkitPowerSpec {
    param([string]$Action, [bool]$Force)
    if ($Action -notin @('Shutdown','Restart')) { throw 'Unknown power action.' }
    $arguments = @('/s','/t','0')
    if ($Action -eq 'Restart') { $arguments[0] = '/r' }
    if ($Force) { $arguments += '/f' }
    return [pscustomobject]@{ FileName = (Get-ToolkitWindowsExecutable 'shutdown.exe'); Arguments = $arguments }
}

function Invoke-ToolkitPowerRequest {
    param([string]$Action, [bool]$Force)
    $spec = Get-ToolkitPowerSpec $Action $Force
    & $spec.FileName @($spec.Arguments)
    if ($LASTEXITCODE -ne 0) { throw "Windows rejected the power request (exit code $LASTEXITCODE)." }
}

function Start-ToolkitPowerCountdown {
    param([hashtable]$Values)
    $multipliers = @{ Seconds = 1; Minutes = 60; Hours = 3600; Days = 86400 }
    if ($Values.unit -notin $multipliers.Keys -or $Values.action -notin @('Shutdown','Restart') -or $Values.closure -notin @('Normal','Force')) { throw 'Invalid countdown options.' }
    $seconds = [long]$Values.duration * $multipliers[$Values.unit]
    if ($seconds -lt 1 -or $seconds -gt 604800) { throw 'Countdown must be from one second through seven days.' }
    Initialize-ToolkitRecovery
    $lock = Enter-ToolkitManagedLock
    try {
        if (@(Get-ToolkitActiveJob Power).Count) { throw 'A power action already exists. Cancel it before scheduling another.' }
        $job = New-ToolkitManagedJob Power Local ([pscustomobject]@{}) ([pscustomobject]@{}) ([DateTimeOffset]::UtcNow.AddSeconds($seconds))
        $job.PowerAction = $Values.action; $job.Force = $Values.closure -eq 'Force'; $job.BootId = Get-ToolkitBootId
        $job.Status = 'Active'; $job.Detail = 'Survives console closure. Does not wake the PC. Missed deadlines and changed boot sessions expire.'
        Save-ToolkitManagedJob $job
        try {
            Register-ToolkitManagedTask $job
            if ([DateTimeOffset]::UtcNow -ge [DateTimeOffset]::Parse($job.ExpiresUtc)) { Start-ScheduledTask -TaskName ('WET-' + $job.Id) -TaskPath '\WindowsEngineeringToolkit\' -ErrorAction Stop }
        }
        catch {
            $job.Status = 'Failed'; $job.Detail = $_.Exception.Message
            try { Save-ToolkitManagedJob $job }
            finally { Remove-ToolkitManagedTask $job.Id }
            throw
        }
        Get-ToolkitManagedSummary | Where-Object Id -eq $job.Id
    }
    finally { $lock.Dispose() }
}

function Stop-ToolkitPowerCountdown {
    if (-not (Test-Path -LiteralPath (Join-Path (Get-ToolkitManagedRoot) 'state.lock'))) { 'No toolbox power countdown exists.'; return }
    $lock = Enter-ToolkitManagedLock
    try {
        $jobs = @(Get-ToolkitActiveJob Power)
        if (-not $jobs.Count) { 'No cancellable toolbox countdown exists. Already-issued Windows shutdown requests cannot be cancelled here.' }
        foreach ($job in $jobs) {
            $job.Status = 'Cancelled'; $job.Detail = 'Cancelled before the power request was issued.'
            Save-ToolkitManagedJob $job; Remove-ToolkitManagedTask $job.Id
            "Cancelled $($job.Id)."
        }
    }
    finally { $lock.Dispose() }
}

function Invoke-ToolkitManagedWorker {
    param([string]$Id, [ValidateSet('Probe','Execute')][string]$Mode)
    if (-not (Test-ToolkitAdministrator) -or -not $script:ToolkitStandalone) { throw 'Recovery requires the protected standalone helper and an elevated token.' }
    $job = Read-ToolkitManagedJob $Id
    $expectedHelper = Get-ToolkitHelperPath $job.HelperVersion
    if ([IO.Path]::GetFullPath($script:ToolkitEntryPath) -ine $expectedHelper) { throw 'Recovery may only run from the pinned protected helper.' }
    Test-ToolkitProtectedPath $expectedHelper
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { if ($identity.User.Value -ne $job.OwnerSid) { throw 'Scheduled account does not match the job owner.' } } finally { $identity.Dispose() }
    if ($Mode -eq 'Probe') {
        if ($job.Kind -ne 'Probe' -or $job.Status -ne 'Prepared') { throw 'Invalid recovery preflight.' }
        $job.Status = 'ProbePassed'; $job.Detail = 'Scheduled account, policy and protected storage checks passed.'; Save-ToolkitManagedJob $job
        return
    }
    if ($job.Kind -eq 'Probe') { throw 'Preflight jobs cannot execute operations.' }
    $lock = Enter-ToolkitManagedLock
    try {
        $job = Read-ToolkitManagedJob $Id
        if ($job.Status -notin @('Prepared','Active','Restoring','Failed','Conflict')) { return }
        if (-not $job.ExpiresUtc -or [DateTimeOffset]::UtcNow -lt [DateTimeOffset]::Parse($job.ExpiresUtc)) { return }
        if ($job.Kind -eq 'Power') {
            if ($job.Status -ne 'Active') { return }
            $lateSeconds = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($job.ExpiresUtc)).TotalSeconds
            if ($lateSeconds -gt 60 -or (Get-ToolkitBootId) -ne $job.BootId) {
                $job.Status = 'Expired'; $job.Detail = 'Missed deadline or changed boot session. No power request was issued.'
                Save-ToolkitManagedJob $job; Remove-ToolkitManagedTask $job.Id; return
            }
            # Persist before issuing the request so retries cannot repeat a power action.
            $job.Status = 'Executed'; $job.Detail = 'Power request issued; normal application closure may postpone or block it.'; Save-ToolkitManagedJob $job
            try { Invoke-ToolkitPowerRequest $job.PowerAction $job.Force }
            catch { $job.Detail = 'Power request failed: ' + $_.Exception.Message; Save-ToolkitManagedJob $job; throw }
            finally { Remove-ToolkitManagedTask $job.Id }
        }
        else { Restore-ToolkitManagedJob $job }
    }
    finally { $lock.Dispose() }
}

function Invoke-ToolkitControlAction {
    param([string]$TargetId, [hashtable]$Values)
    switch ($TargetId) {
        'security.firewall-control' {
            if ($Values.action -eq 'Enable') { Enable-ToolkitProtection Firewall $Values.profile }
            else {
                $state = [ordered]@{}; foreach ($name in (Get-ToolkitFirewallScope $Values.profile)) { $state[$name] = 'False' }
                Start-ToolkitSettingChange Firewall $Values.profile ([pscustomobject]$state) $Values.mode -Minutes $Values.minutes
            }
        }
        'security.defender-control' {
            if ($Values.action -eq 'Enable') { Enable-ToolkitProtection Defender Realtime }
            else { Start-ToolkitSettingChange Defender Realtime ([pscustomobject]@{ Disabled = $true }) $Values.mode -Minutes $Values.minutes }
        }
        'security.firewall-restore' { Restore-ToolkitSetting Firewall }
        'security.defender-restore' { Restore-ToolkitSetting Defender }
        'updates.suspend' { Start-ToolkitSettingChange Updates Automatic ([pscustomobject]@{ Exists = $true; Value = 1; ValueKind = 'DWord' }) Timed -Months $Values.months }
        'updates.resume' { Restore-ToolkitSetting Updates }
        'power.countdown' { Start-ToolkitPowerCountdown $Values }
        'power.cancel' { Stop-ToolkitPowerCountdown }
        'power.status' { Get-ToolkitManagedSummary | Where-Object { $_ -is [string] -or $_.Kind -eq 'Power' } }
        'power.force-restart' { Invoke-ToolkitPowerRequest Restart $true }
        default { throw 'Unknown control operation.' }
    }
}
