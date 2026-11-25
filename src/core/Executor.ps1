function Get-ToolkitLaunchSpec {
    param([string]$TargetId)
    $name = ''; $snapIn = ''
    switch ($TargetId) {
        'processes.resource-monitor' { $name = 'resmon.exe' }
        'processes.task-manager' { $name = 'taskmgr.exe' }
        'storage.management' { $snapIn = 'diskmgmt.msc' }
        'processes.events' { $snapIn = 'eventvwr.msc' }
        'security.devices' { $snapIn = 'devmgmt.msc' }
        'security.computer-management' { $snapIn = 'compmgmt.msc' }
        'security.settings' { return [pscustomobject]@{ FileName = 'ms-settings:windowsdefender'; Arguments = @() } }
        default { throw 'Unknown Windows interface.' }
    }
    if ($snapIn) {
        $name = 'mmc.exe'
        $executable = Get-ToolkitWindowsExecutable $name
        return [pscustomobject]@{ FileName = $executable; Arguments = @(Join-Path (Split-Path $executable -Parent) $snapIn) }
    }
    return [pscustomobject]@{ FileName = (Get-ToolkitWindowsExecutable $name); Arguments = @() }
}

function Write-ToolkitQueueText {
    param([object]$Queue, [hashtable]$State, [AllowNull()][object]$Text)
    $value = [string]$Text
    if ($value.Length -gt 4096) { $value = $value.Substring(0, 4096); $State.Truncated = $true }
    if (-not $Queue.TryAdd($value)) {
        $discard = ''
        $Queue.TryTake([ref]$discard) | Out-Null
        $Queue.TryAdd($value) | Out-Null
        $State.Truncated = $true
    }
}

function Invoke-ToolkitPowerShellAction {
    param([string]$TargetId, [hashtable]$Values)
    switch -Wildcard ($TargetId) {
        'system.*' { Invoke-ToolkitSystemAction $TargetId }
        'network.*' { Invoke-ToolkitNetworkAction $TargetId $Values }
        'hardware.*' { Invoke-ToolkitHardwareAction $TargetId }
        'storage.*' { Invoke-ToolkitStorageAction $TargetId $Values }
        'processes.*' { Invoke-ToolkitProcessesAction $TargetId }
        'security.*' {
            if ($TargetId -in @('security.firewall-control','security.firewall-restore','security.defender-control','security.defender-restore')) { Invoke-ToolkitControlAction $TargetId $Values }
            else { Invoke-ToolkitSecurityAction $TargetId }
        }
        'troubleshooting.*' { Invoke-ToolkitTroubleshootingAction $TargetId $Values }
        'updates.*' { Invoke-ToolkitControlAction $TargetId $Values }
        'power.*' { Invoke-ToolkitControlAction $TargetId $Values }
        'maintenance.managed-changes' { Get-ToolkitManagedSummary }
        default { throw 'Unknown PowerShell operation.' }
    }
}

function Invoke-ToolkitNativeCaptured {
    param([object]$Spec, [object]$Queue, [hashtable]$State, [hashtable]$Control)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Spec.FileName
    $info.Arguments = (($Spec.Arguments | ForEach-Object { ConvertTo-ToolkitArgument $_ }) -join ' ')
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $encoding = [Text.Encoding]::GetEncoding((Get-Culture).TextInfo.OEMCodePage)
    $info.StandardOutputEncoding = $encoding; $info.StandardErrorEncoding = $encoding
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'The native process could not be started.' }
        $State.ProcessId = $process.Id
        $stdout = New-Object char[] 2048; $stderr = New-Object char[] 2048
        $outTask = $process.StandardOutput.ReadAsync($stdout, 0, $stdout.Length)
        $errTask = $process.StandardError.ReadAsync($stderr, 0, $stderr.Length)
        while ($null -ne $outTask -or $null -ne $errTask -or -not $process.HasExited) {
            if ($Control.Cancel -and -not $process.HasExited) { $process.Kill(); $State.Cancelled = $true }
            if ($null -ne $outTask -and $outTask.IsCompleted) {
                $count = $outTask.GetAwaiter().GetResult()
                if ($count -eq 0) { $outTask = $null }
                else {
                    Write-ToolkitQueueText $Queue $State (-join $stdout[0..($count - 1)])
                    $outTask = $process.StandardOutput.ReadAsync($stdout, 0, $stdout.Length)
                }
            }
            if ($null -ne $errTask -and $errTask.IsCompleted) {
                $count = $errTask.GetAwaiter().GetResult()
                if ($count -eq 0) { $errTask = $null }
                else {
                    Write-ToolkitQueueText $Queue $State (-join $stderr[0..($count - 1)])
                    $errTask = $process.StandardError.ReadAsync($stderr, 0, $stderr.Length)
                }
            }
            Start-Sleep -Milliseconds 25
        }
        $process.WaitForExit()
        $State.ExitCode = $process.ExitCode
        if ($process.ExitCode -ne 0 -and -not $State.Cancelled) { throw "Native utility returned exit code $($process.ExitCode). Review its output." }
    }
    finally {
        if (-not $process.HasExited) { $process.Kill(); $State.Cancelled = $true }
        $process.Dispose()
    }
}

function Invoke-ToolkitBackgroundAction {
    param([object]$Command, [hashtable]$Values, [object]$Queue, [hashtable]$State, [hashtable]$Control)
    $ErrorActionPreference = 'Stop'
    try {
        if ($Command.sourceKind -ne 'BuiltIn' -or $Command.risk -ne 'ReadOnly' -or $Command.requiresAdmin) { throw 'This operation must use the confirmed console path.' }
        if ($Command.executionType -eq 'Native') { Invoke-ToolkitNativeCaptured (Get-ToolkitNativeSpec $Command.targetId $Values) $Queue $State $Control }
        else {
            Invoke-ToolkitPowerShellAction $Command.targetId $Values | Format-List | Out-String -Stream -Width 120 | ForEach-Object { Write-ToolkitQueueText $Queue $State $_ }
        }
        $State.Status = 'Succeeded'
    }
    catch {
        $State.Status = 'Failed'
        if ($_.Exception -is [UnauthorizedAccessException] -or $_.FullyQualifiedErrorId -match 'AccessDenied|Unauthorized|80041003|PermissionDenied' -or $_.Exception.Message -match 'Access is denied|Access denied') { $State.Status = 'PermissionDenied' }
        if ($_.Exception -is [TimeoutException]) { $State.Status = 'TimedOut' }
        Write-ToolkitQueueText $Queue $State $_.Exception.Message
    }
    finally { if ($State.Cancelled) { $State.Status = 'Cancelled' }; $State.Done = $true }
}

function Start-ToolkitExecution {
    param([object]$Command, [hashtable]$Values)
    if ($Command.sourceKind -ne 'BuiltIn' -or $Command.risk -ne 'ReadOnly' -or $Command.requiresAdmin) { throw 'Only unelevated read-only diagnostics may use the background worker.' }
    $validated = ConvertTo-ToolkitParameterMap $Command $Values
    $session = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($function in (Get-Command -CommandType Function -Name '*-Toolkit*')) {
        $entry = New-Object Management.Automation.Runspaces.SessionStateFunctionEntry($function.Name, $function.Definition)
        $session.Commands.Add($entry)
    }
    $runspace = [runspacefactory]::CreateRunspace($session)
    $runspace.Open()
    $powershell = [powershell]::Create(); $powershell.Runspace = $runspace
    $queue = New-Object 'Collections.Concurrent.BlockingCollection[string]' 128
    $state = [hashtable]::Synchronized(@{ Done = $false; Status = 'Running'; ExitCode = $null; ProcessId = $null; Truncated = $false; Cancelled = $false })
    $control = [hashtable]::Synchronized(@{ Cancel = $false })
    $powershell.AddCommand('Invoke-ToolkitBackgroundAction').AddArgument($Command).AddArgument($validated).AddArgument($queue).AddArgument($state).AddArgument($control) | Out-Null
    $handle = $powershell.BeginInvoke()
    return [pscustomobject]@{ PowerShell = $powershell; Runspace = $runspace; Handle = $handle; Queue = $queue; State = $state; Control = $control; Started = [DateTime]::UtcNow; Command = $Command; StopHandle = $null; DeadlineExceeded = $false }
}

function Stop-ToolkitExecution {
    param([object]$Execution, [switch]$TimedOut)
    if ($Execution.Command.cancellation -eq 'Unavailable') { return }
    $Execution.State.Cancelled = -not $TimedOut
    $Execution.DeadlineExceeded = [bool]$TimedOut
    $Execution.Control.Cancel = $true
    if ($Execution.Command.executionType -ne 'Native' -and $null -eq $Execution.StopHandle) {
        $Execution.StopHandle = $Execution.PowerShell.BeginStop($null, $null)
    }
}

function Complete-ToolkitExecution {
    param([object]$Execution)
    if (-not $Execution.Handle.IsCompleted) { throw 'The worker is still stopping; do not dispose it synchronously.' }
    try {
        try { $Execution.PowerShell.EndInvoke($Execution.Handle) | Out-Null } catch { if (-not $Execution.State.Cancelled -and -not $Execution.DeadlineExceeded) { $Execution.State.Status = 'Failed' } }
        if ($null -ne $Execution.StopHandle) { $Execution.PowerShell.EndStop($Execution.StopHandle) }
        if ($Execution.DeadlineExceeded) { $Execution.State.Status = 'TimedOut' }
        elseif ($Execution.State.Cancelled) { $Execution.State.Status = 'Cancelled' }
        return [pscustomobject]@{ CommandId = $Execution.Command.id; ExecutionId = [guid]::NewGuid().ToString(); Started = $Execution.Started; Elapsed = ([DateTime]::UtcNow - $Execution.Started); Status = $Execution.State.Status; ExitCode = $Execution.State.ExitCode; Truncated = $Execution.State.Truncated }
    }
    finally { $Execution.PowerShell.Dispose(); $Execution.Runspace.Dispose(); $Execution.Queue.Dispose() }
}
