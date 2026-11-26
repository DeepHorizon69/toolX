function New-ToolkitScriptStartInfo {
    param([object]$Command)
    $entry = Resolve-ToolkitCustomScript -Id $Command.id
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.UseShellExecute = $false; $info.CreateNoWindow = $false
    $info.WorkingDirectory = Split-Path $entry.path -Parent
    if ([IO.Path]::GetExtension($entry.path) -ieq '.ps1') {
        $info.FileName = Get-ToolkitPowerShellPath
        $info.Arguments = (@('-NoLogo','-NoProfile','-File',$entry.path) | ForEach-Object { ConvertTo-ToolkitArgument $_ }) -join ' '
    }
    else {
        $info.FileName = Get-ToolkitWindowsExecutable 'cmd.exe'
        $info.EnvironmentVariables['TOOLKIT_CUSTOM_SCRIPT_PATH'] = $entry.path
        # Expansion happens once inside quotes; CALL would introduce another parsing pass.
        $info.Arguments = '/d /v:off /s /c ""%TOOLKIT_CUSTOM_SCRIPT_PATH%""'
    }
    return $info
}

function Invoke-ToolkitScriptProcess {
    param([object]$Command)
    $process = [Diagnostics.Process]::Start((New-ToolkitScriptStartInfo $Command))
    try { $process.WaitForExit(); return $process.ExitCode }
    finally { $process.Dispose() }
}

function ConvertFrom-ToolkitPayload {
    param([string]$Data)
    if (-not $Data -or $Data.Length -gt 8192) { throw 'Invalid worker payload size.' }
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Data))
    $object = $json | ConvertFrom-Json -ErrorAction Stop
    if ($object -isnot [pscustomobject]) { throw 'Worker parameters must be a JSON object.' }
    $result = @{}
    foreach ($property in $object.PSObject.Properties) {
        if ($null -ne $property.Value -and $property.Value -isnot [string] -and $property.Value -isnot [int]) { throw 'Worker parameters must be scalar strings or integers.' }
        $result[$property.Name] = $property.Value
    }
    return $result
}

function Invoke-ToolkitConsoleWorker {
    param([string]$Id, [string]$Data, [switch]$RequireElevation, [switch]$SkipConfirmation)
    $exitCode = 1
    try {
        $values = ConvertFrom-ToolkitPayload $Data
        if ($Id.StartsWith('custom/', [StringComparison]::Ordinal)) {
            $command = Resolve-ToolkitCustomScript $Id
            if ($values.Count) { throw 'Custom scripts do not accept toolbox-supplied arguments.' }
        }
        else {
            $command = @($script:ToolkitRegistry.commands | Where-Object { $_.id -ceq $Id })
            if ($command.Count -ne 1) { throw 'Unknown worker command.' }
            $command = $command[0]
            $values = ConvertTo-ToolkitParameterMap $command $values
        }
        $admin = Test-ToolkitAdministrator
        if (($RequireElevation -or $command.requiresAdmin) -and -not $admin) { throw 'This operation requires an administrator token.' }
        $capability = Get-ToolkitCapability $command
        if (-not $capability.Available) { throw $capability.Reason }
        Write-Host "$((Get-ToolkitIdentity).Banner) | Operation console" -ForegroundColor Cyan
        Write-Host (ConvertTo-ToolkitSafeText $command.name) -ForegroundColor Cyan
        $privilegeColor = 'Gray'; if ($admin) { $privilegeColor = 'Yellow' }
        Write-Host "Privilege: $(if ($admin) { 'ADMINISTRATOR' } else { 'Standard user' })" -ForegroundColor $privilegeColor
        $riskColor = 'Green'
        if ($command.risk -eq 'SystemModification') { $riskColor = 'Yellow' }
        elseif ($command.risk -eq 'HighRisk') { $riskColor = 'Red' }
        Write-Host "Risk: $($command.risk)" -ForegroundColor $riskColor
        if ($SkipConfirmation) { Write-Host 'ACTION CONFIRMATIONS OFF: the selected operation will execute without a toolbox confirmation prompt.' -ForegroundColor Yellow }
        Write-Host (ConvertTo-ToolkitSafeText $command.consequences)
        if ($command.sourceKind -eq 'CustomScript') { Write-Host ('Script: ' + (ConvertTo-ToolkitSafeText $command.path)) }
        elseif ($values.Count) { $values | Format-Table -AutoSize | Out-Host }
        if ($command.id -in @('security.firewall-control','security.defender-control') -and $values.action -eq 'Disable') {
            if ($values.mode -eq 'Manual') { Write-Host 'MANUAL MODE: No automatic restoration will be scheduled.' }
            else { Write-Host "Automatic restoration requested after $($values.minutes) minutes. Recovery preflight must pass first." }
        }
        if ($command.id -eq 'updates.suspend') { Write-Host ('Estimated restore date: ' + [DateTimeOffset]::Now.AddMonths($values.months).ToString('yyyy-MM-dd HH:mm:ss zzz') + '. Exact deadline is recorded after preflight.') }
        if ($command.id -eq 'power.countdown') {
            Write-Host "Requested: $($values.action) after $($values.duration) $($values.unit), with $($values.closure) application closure. The countdown starts after recovery preflight."
            if ($values.closure -eq 'Force') { Write-Host 'FORCED CLOSURE: Unsaved data can be lost.' }
        }
        $preview = @()
        if ($command.id -eq 'repair.temp') {
            $preview = @(Get-ToolkitCleanupPreview)
            if ($preview.Count -eq 0) { Write-Host 'No eligible temporary files.'; return 0 }
            Write-Host "Preview: $($preview.Count) files. Every candidate is shown before confirmation."
            for ($index = 0; $index -lt $preview.Count; $index++) {
                Write-Host (ConvertTo-ToolkitSafeText $preview[$index].Path)
                if (-not $SkipConfirmation -and ($index + 1) % 20 -eq 0 -and $index + 1 -lt $preview.Count) { if ((Read-Host 'Enter for more; type cancel to stop') -eq 'cancel') { return 1223 } }
            }
        }
        $confirmation = ''
        if ($SkipConfirmation) { $confirmation = $command.id }
        elseif ($command.confirmation -eq 'TypeCommandId') {
            $confirmation = Read-Host "Type $($command.id) to execute; Enter cancels"
            if ($confirmation -cne $command.id) { Write-Host 'Cancelled.'; return 1223 }
        }
        elseif ($command.confirmation -eq 'Confirm') {
            if ((Read-Host 'Execute this operation? Type yes; Enter cancels') -cne 'yes') { Write-Host 'Cancelled.'; return 1223 }
        }
        if ($command.sourceKind -eq 'CustomScript') { $exitCode = Invoke-ToolkitScriptProcess $command }
        elseif ($command.id -eq 'repair.temp') { Invoke-ToolkitCleanup -Preview $preview -Confirmation $confirmation | Format-Table -AutoSize | Out-Host; $exitCode = 0 }
        elseif ($command.executionType -eq 'Native') {
            $spec = Get-ToolkitNativeSpec $command.targetId $values
            & $spec.FileName @($spec.Arguments)
            $exitCode = $LASTEXITCODE
        }
        elseif ($command.executionType -in @('Executable','Mmc','Settings')) {
            $spec = Get-ToolkitLaunchSpec $command.targetId
            $launch = @{ FilePath = $spec.FileName; ErrorAction = 'Stop' }
            if ($spec.Arguments.Count) { $launch.ArgumentList = (($spec.Arguments | ForEach-Object { ConvertTo-ToolkitArgument $_ }) -join ' ') }
            Start-Process @launch | Out-Null
            Write-Host 'Administrative interface launched. Subsequent actions are outside the toolkit.'
            $exitCode = 0
        }
        elseif ($command.targetId -eq 'system.full-specs') {
            $records = @(Invoke-ToolkitPowerShellAction $command.targetId $values)
            $size = Get-ToolkitTerminalSize; $width = 79
            if ($null -ne $size) { $width = [Math]::Max(1, $size.Width - 1) }
            Format-ToolkitSpecificationLayout @(Get-ToolkitSpecificationBlock $records) $width | Out-Host
            $exitCode = 0
        }
        else { Invoke-ToolkitPowerShellAction $command.targetId $values | Format-List | Out-Host; $exitCode = 0 }
        Write-Host "Interpreter/operation exit code: $exitCode. Review the output; zero does not verify a repair."
    }
    catch { Write-Host ('Operation failed: ' + (ConvertTo-ToolkitSafeText $_.Exception.Message)) -ForegroundColor Red }
    finally { Read-Host 'Press Enter to close this operation console' | Out-Null }
    return $exitCode
}
