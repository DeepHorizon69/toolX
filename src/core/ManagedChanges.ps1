function Get-ToolkitManagedRoot {
    return Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'WindowsEngineeringToolkit'
}

function Set-ToolkitProtectedAcl {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Recovery paths cannot be reparse points.' }
    $acl = New-Object Security.AccessControl.FileSecurity
    if ($item.PSIsContainer) { $acl = New-Object Security.AccessControl.DirectorySecurity }
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544','S-1-5-32-545')) {
        $rights = [Security.AccessControl.FileSystemRights]::ReadAndExecute
        if ($sid -ne 'S-1-5-32-545') { $rights = [Security.AccessControl.FileSystemRights]::FullControl }
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        if ($item.PSIsContainer) {
            $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, $rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        }
        else { $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, $rights, 'Allow') }
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Test-ToolkitProtectedPath {
    param([string]$Path)
    $root = Get-ToolkitManagedRoot
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -ne $root -and -not (Test-ToolkitContainedPath $root $full)) { throw 'Recovery path escapes protected storage.' }
    $current = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    while ($null -ne $current) {
        if ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Recovery paths cannot be reparse points.' }
        $acl = Get-Acl -LiteralPath $current.FullName -ErrorAction Stop
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($owner -notin @('S-1-5-18','S-1-5-32-544')) { throw 'Recovery storage has an unexpected owner.' }
        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            $writeMask = [Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
            if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544') -and ($rule.FileSystemRights -band $writeMask)) { throw 'Recovery storage grants write access to an unexpected identity.' }
        }
        if ($current.FullName -eq $root) { return }
        if ($current -is [IO.FileInfo]) { $current = $current.Directory } else { $current = $current.Parent }
    }
    throw 'Recovery root could not be verified.'
}

function Initialize-ToolkitProtectedDirectory {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { Test-ToolkitProtectedPath $Path; return }
    $root = Get-ToolkitManagedRoot
    if ($Path -ne $root) { Test-ToolkitProtectedPath (Split-Path $Path -Parent) }
    else {
        $ancestor = Get-Item -LiteralPath (Split-Path $root -Parent) -Force
        while ($null -ne $ancestor) {
            if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'ProgramData ancestry contains a reparse point.' }
            $ancestor = $ancestor.Parent
        }
    }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544','S-1-5-32-545')) {
        $rights = 'ReadAndExecute'; if ($sid -ne 'S-1-5-32-545') { $rights = 'FullControl' }
        $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), $rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    [IO.Directory]::CreateDirectory($Path, $acl) | Out-Null
    Test-ToolkitProtectedPath $Path
}

function Write-ToolkitProtectedText {
    param([string]$Path, [string]$Text)
    Test-ToolkitProtectedPath (Split-Path $Path -Parent)
    if (Test-Path -LiteralPath $Path) { Test-ToolkitProtectedPath $Path }
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($true)))
        Set-ToolkitProtectedAcl $temporary
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, $null) }
        else { [IO.File]::Move($temporary, $Path) }
        Test-ToolkitProtectedPath $Path
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -ErrorAction Stop } }
}

function Enter-ToolkitManagedLock {
    $path = Join-Path (Get-ToolkitManagedRoot) 'state.lock'
    Test-ToolkitProtectedPath $path
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        try { return [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] { Start-Sleep -Milliseconds 100 }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Another toolbox change is busy. Try again when it finishes.'
}

function Get-ToolkitJobPath {
    param([string]$Id)
    if ($Id -notmatch '^[a-f0-9]{32}$') { throw 'Invalid managed job identifier.' }
    return Join-Path (Join-Path (Get-ToolkitManagedRoot) 'jobs') ($Id + '.json')
}

function Test-ToolkitManagedJob {
    param([object]$Job)
    $fields = @('SchemaVersion','Id','Kind','Scope','Original','Applied','OwnerSid','CreatedUtc','ExpiresUtc','HelperVersion','Status','Detail','PowerAction','Force','BootId')
    Test-ToolkitObjectField $Job $fields $fields
    if ($Job.SchemaVersion -ne 1 -or $Job.Id -notmatch '^[a-f0-9]{32}$' -or $Job.HelperVersion -notmatch '^\d+\.\d+\.\d+$' -or $Job.OwnerSid -notmatch '^S-1-5-[0-9-]+$') { throw 'Invalid managed job identity.' }
    if ($Job.Kind -notin @('Probe','Firewall','Defender','Updates','Power')) { throw 'Invalid managed operation.' }
    if ($Job.Status -notin @('Prepared','ProbePassed','Active','Restoring','Restored','Cancelled','Expired','Failed','Conflict','Superseded','Executed')) { throw 'Invalid managed job status.' }
    [DateTimeOffset]::Parse($Job.CreatedUtc) | Out-Null
    if ($null -ne $Job.ExpiresUtc) { [DateTimeOffset]::Parse($Job.ExpiresUtc) | Out-Null }
    if ($Job.Force -isnot [bool] -or $Job.PowerAction -notin @('None','Shutdown','Restart')) { throw 'Invalid managed power action.' }
    if ($Job.Kind -ne 'Power' -and ($Job.PowerAction -ne 'None' -or $Job.Force)) { throw 'Power action is not allowed for this job.' }
    $expected = @()
    switch ($Job.Kind) {
        'Firewall' { if ($Job.Scope -notin @('Private','Public','Domain','All')) { throw 'Invalid firewall scope.' }; $expected = @($Job.Scope); if ($Job.Scope -eq 'All') { $expected = @('Domain','Private','Public') } }
        'Defender' { if ($Job.Scope -ne 'Realtime') { throw 'Invalid Defender scope.' }; $expected = @('Disabled') }
        'Updates' { if ($Job.Scope -ne 'Automatic') { throw 'Invalid update scope.' }; $expected = @('Exists','Value','ValueKind') }
        'Power' { if ($Job.Scope -ne 'Local' -or $null -eq $Job.ExpiresUtc -or $Job.PowerAction -eq 'None' -or -not $Job.BootId) { throw 'Invalid power deadline.' } }
        'Probe' { if ($Job.Scope -ne 'Local') { throw 'Invalid preflight scope.' } }
    }
    foreach ($state in @($Job.Original, $Job.Applied)) {
        Test-ToolkitObjectField $state $expected $expected
        foreach ($property in $state.PSObject.Properties) {
            if ($Job.Kind -eq 'Defender' -and $property.Value -isnot [bool]) { throw 'Defender snapshots must use boolean values.' }
            if ($Job.Kind -eq 'Firewall' -and $property.Value -notin @('True','False','NotConfigured')) { throw 'Invalid firewall snapshot.' }
        }
        if ($Job.Kind -eq 'Updates' -and ($state.Exists -isnot [bool] -or $state.Value -isnot [int] -or $state.Value -notin @(0,1) -or $state.ValueKind -notin @('None','DWord') -or ($state.Exists -and $state.ValueKind -ne 'DWord'))) { throw 'Invalid update snapshot.' }
    }
}

function Read-ToolkitManagedJob {
    param([string]$Id)
    $path = Get-ToolkitJobPath $Id
    Test-ToolkitProtectedPath $path
    if ((Get-Item -LiteralPath $path).Length -gt 65536) { throw 'Managed job is too large.' }
    $job = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    Test-ToolkitManagedJob $job
    if ($job.Id -cne $Id) { throw 'Managed job identity does not match its filename.' }
    return $job
}

function Save-ToolkitManagedJob {
    param([object]$Job)
    Test-ToolkitManagedJob $Job
    Write-ToolkitProtectedText (Get-ToolkitJobPath $Job.Id) (ConvertTo-Json -InputObject $Job -Depth 5)
}

function Get-ToolkitManagedJob {
    $directory = Join-Path (Get-ToolkitManagedRoot) 'jobs'
    if (-not (Test-Path -LiteralPath $directory)) { return }
    Test-ToolkitProtectedPath $directory
    foreach ($path in [IO.Directory]::EnumerateFiles($directory, '*.json')) {
        $id = [IO.Path]::GetFileNameWithoutExtension($path)
        Read-ToolkitManagedJob $id
    }
}

function Get-ToolkitManagedSummary {
    try {
        $jobs = @(Get-ToolkitManagedJob | Where-Object Kind -ne 'Probe')
        if (-not $jobs.Count) { 'No toolbox-managed changes or power actions have been recorded.' }
        foreach ($job in $jobs) {
            $taskState = 'Not scheduled'; $lastResult = $null; $taskDetail = ''
            if ($job.ExpiresUtc -and $job.Status -in @('Prepared','Active','Restoring','Failed','Conflict')) {
                try {
                    $task = Get-ScheduledTask -TaskName ('WET-' + $job.Id) -TaskPath '\WindowsEngineeringToolkit\' -ErrorAction Stop
                    $taskState = $task.State.ToString()
                    $lastResult = (Get-ScheduledTaskInfo -TaskName ('WET-' + $job.Id) -TaskPath '\WindowsEngineeringToolkit\' -ErrorAction Stop).LastTaskResult
                }
                catch { $taskState = 'Unavailable'; $taskDetail = $_.Exception.Message }
            }
            [pscustomobject]@{
                Id = $job.Id; Kind = $job.Kind; Scope = $job.Scope; Status = $job.Status
                Deadline = $(if ($job.ExpiresUtc) { ([DateTimeOffset]::Parse($job.ExpiresUtc)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz') } else { 'Manual: no automatic restoration' })
                Due = ($job.ExpiresUtc -and [DateTimeOffset]::UtcNow -ge [DateTimeOffset]::Parse($job.ExpiresUtc) -and $job.Status -in @('Prepared','Active','Restoring','Failed','Conflict'))
                TaskState = $taskState; LastTaskResult = $lastResult; Detail = $job.Detail; TaskQueryDetail = $taskDetail
            }
        }
    }
    catch { [pscustomobject]@{ Status = 'Unavailable'; Detail = $_.Exception.Message } }
}

function New-ToolkitManagedJob {
    param([string]$Kind, [string]$Scope, [object]$Original, [object]$Applied, [AllowNull()][object]$Deadline)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $sid = $identity.User.Value } finally { $identity.Dispose() }
    return [pscustomobject]@{
        SchemaVersion = 1; Id = [guid]::NewGuid().ToString('N'); Kind = $Kind; Scope = $Scope
        Original = $Original; Applied = $Applied; OwnerSid = $sid; CreatedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        ExpiresUtc = $(if ($null -ne $Deadline) { ([DateTimeOffset]$Deadline).ToUniversalTime().ToString('o') } else { $null })
        HelperVersion = $script:ToolkitVersion; Status = 'Prepared'; Detail = ''; PowerAction = 'None'; Force = $false; BootId = ''
    }
}

function Get-ToolkitHelperPath {
    param([string]$Version)
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid helper version.' }
    return Join-Path (Join-Path (Join-Path (Get-ToolkitManagedRoot) 'versions') $Version) 'Toolkit.ps1'
}

function Initialize-ToolkitRecovery {
    if (-not (Test-ToolkitAdministrator)) { throw 'Administrator privileges are required.' }
    if (-not $script:ToolkitStandalone) { throw 'Scheduled controls require the standalone dist/Toolkit.ps1; build it first.' }
    $root = Get-ToolkitManagedRoot
    Initialize-ToolkitProtectedDirectory $root
    foreach ($name in @('jobs','versions')) { Initialize-ToolkitProtectedDirectory (Join-Path $root $name) }
    $versionDirectory = Join-Path (Join-Path $root 'versions') $script:ToolkitVersion
    Initialize-ToolkitProtectedDirectory $versionDirectory
    $helper = Get-ToolkitHelperPath $script:ToolkitVersion
    if (Test-Path -LiteralPath $helper) {
        Test-ToolkitProtectedPath $helper
        if ((Get-FileHash -LiteralPath $helper).Hash -ne (Get-FileHash -LiteralPath $script:ToolkitEntryPath).Hash) { throw 'This helper version already exists with different content. Use a new application version.' }
    }
    else { Write-ToolkitProtectedText $helper ([IO.File]::ReadAllText($script:ToolkitEntryPath)) }
    $lockPath = Join-Path $root 'state.lock'
    if (-not (Test-Path -LiteralPath $lockPath)) { Write-ToolkitProtectedText $lockPath '' }
    Test-ToolkitProtectedPath $lockPath
    $probe = New-ToolkitManagedJob Probe Local ([pscustomobject]@{}) ([pscustomobject]@{}) $null
    Save-ToolkitManagedJob $probe
    try {
        Register-ToolkitManagedTask $probe -Probe
        Start-ScheduledTask -TaskName ('WET-' + $probe.Id) -TaskPath '\WindowsEngineeringToolkit\' -ErrorAction Stop
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            Start-Sleep -Milliseconds 250
            if ((Read-ToolkitManagedJob $probe.Id).Status -eq 'ProbePassed') { return }
        } while ([DateTime]::UtcNow -lt $deadline)
        throw 'Scheduled recovery preflight failed. No Windows setting was changed. Check task logon rights and execution policy for the scheduled account.'
    }
    finally {
        Remove-ToolkitManagedTask $probe.Id
        Remove-Item -LiteralPath (Get-ToolkitJobPath $probe.Id) -ErrorAction Stop
    }
}

function Get-ToolkitTaskFolder {
    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $sddl = 'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GR;;;BU)'
    try { $folder = $service.GetFolder('\WindowsEngineeringToolkit') }
    catch { $folder = $service.GetFolder('\').CreateFolder('WindowsEngineeringToolkit', $sddl) }
    $folder.SetSecurityDescriptor($sddl, 0)
    return $folder
}

function Register-ToolkitManagedTask {
    param([object]$Job, [switch]$Probe)
    Test-ToolkitManagedJob $Job
    $helper = Get-ToolkitHelperPath $Job.HelperVersion
    Test-ToolkitProtectedPath $helper
    $folder = Get-ToolkitTaskFolder
    $sddl = 'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GR;;;BU)'
    $arguments = @('-NoLogo','-NoProfile','-File',$helper,'-ManagedJobId',$Job.Id,'-ManagedMode',$(if ($Probe) { 'Probe' } else { 'Execute' }))
    $action = New-ScheduledTaskAction -Execute (Get-ToolkitPowerShellPath) -Argument (($arguments | ForEach-Object { ConvertTo-ToolkitArgument $_ }) -join ' ')
    $principal = New-ScheduledTaskPrincipal -UserId $Job.OwnerSid -LogonType S4U -RunLevel Highest
    $settingParameters = @{ Disable = $true; AllowStartIfOnBatteries = $true; DontStopIfGoingOnBatteries = $true; ExecutionTimeLimit = (New-TimeSpan -Minutes 5); MultipleInstances = 'IgnoreNew' }
    if ($Job.Kind -ne 'Power' -and -not $Probe) { $settingParameters.RestartCount = 3; $settingParameters.RestartInterval = New-TimeSpan -Minutes 1 }
    $settings = New-ScheduledTaskSettingsSet @settingParameters
    $triggers = @()
    if (-not $Probe) {
        if (-not $Job.ExpiresUtc) { throw 'A scheduled operation requires a deadline.' }
        $triggers = @(New-ScheduledTaskTrigger -Once -At ([DateTimeOffset]::Parse($Job.ExpiresUtc)).LocalDateTime)
        if ($Job.Kind -ne 'Power') { $settings.StartWhenAvailable = $true; $triggers += New-ScheduledTaskTrigger -AtStartup }
    }
    $parameters = @{ TaskName = ('WET-' + $Job.Id); TaskPath = '\WindowsEngineeringToolkit\'; Action = $action; Principal = $principal; Settings = $settings; ErrorAction = 'Stop' }
    if ($triggers.Count) { $parameters.Trigger = $triggers }
    Register-ScheduledTask @parameters | Out-Null
    try {
        $folder.GetTask(('WET-' + $Job.Id)).SetSecurityDescriptor($sddl, 0x10)
        Enable-ScheduledTask -TaskName ('WET-' + $Job.Id) -TaskPath '\WindowsEngineeringToolkit\' -ErrorAction Stop | Out-Null
    }
    catch { Remove-ToolkitManagedTask $Job.Id; throw }
}

function Remove-ToolkitManagedTask {
    param([string]$Id)
    Get-ToolkitJobPath $Id | Out-Null
    $task = Get-ScheduledTask -TaskName ('WET-' + $Id) -TaskPath '\WindowsEngineeringToolkit\' -ErrorAction SilentlyContinue
    if ($null -ne $task) { Unregister-ScheduledTask -TaskName ('WET-' + $Id) -TaskPath '\WindowsEngineeringToolkit\' -Confirm:$false -ErrorAction Stop }
}

function Test-ToolkitStateEqual {
    param([object]$Left, [object]$Right)
    $names = @($Left.PSObject.Properties.Name)
    if ($names.Count -ne @($Right.PSObject.Properties.Name).Count) { return $false }
    foreach ($name in $names) { if ($null -eq $Right.PSObject.Properties[$name] -or $Left.$name -cne $Right.$name) { return $false } }
    return $true
}
