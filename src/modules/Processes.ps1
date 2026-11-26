function Invoke-ToolkitProcessesAction {
    param([string]$TargetId)
    switch ($TargetId) {
        'processes.list' { Microsoft.PowerShell.Management\Get-Process | Select-Object Id,ProcessName,CPU,WorkingSet64 }
        'processes.services' { Microsoft.PowerShell.Management\Get-Service | Select-Object Name,DisplayName,Status }
        'processes.startup' { Get-CimInstance Win32_StartupCommand -OperationTimeoutSec 15 | Select-Object Name,Command,Location }
        'processes.top-resources' {
            $snapshot = @(Microsoft.PowerShell.Management\Get-Process -ErrorAction SilentlyContinue)
            $snapshot | Sort-Object WorkingSet64 -Descending | Select-Object -First 15 | ForEach-Object {
                [pscustomobject]@{ Group = 'TopMemory'; Id = $_.Id; ProcessName = $_.ProcessName; MemoryMiB = [Math]::Round($_.WorkingSet64 / 1MB, 1); CpuSeconds = [Math]::Round($_.CPU, 2) }
            }
            $snapshot | Sort-Object CPU -Descending | Select-Object -First 15 | ForEach-Object {
                [pscustomobject]@{ Group = 'TopCPU'; Id = $_.Id; ProcessName = $_.ProcessName; MemoryMiB = [Math]::Round($_.WorkingSet64 / 1MB, 1); CpuSeconds = [Math]::Round($_.CPU, 2) }
            }
        }
        'processes.scheduled-tasks' {
            ScheduledTasks\Get-ScheduledTask -ErrorAction Stop |
                Where-Object { $_.TaskPath -notlike '\Microsoft\Windows\*' } |
                Sort-Object TaskPath,TaskName |
                Select-Object -First 200 |
                ForEach-Object {
                    $actionText = ''
                    if ($_.Actions -and $_.Actions.Count -gt 0) {
                        $first = $_.Actions[0]
                        $actionText = ("$($first.Execute) $($first.Arguments)").Trim()
                    }
                    [pscustomobject]@{ TaskPath = $_.TaskPath; TaskName = $_.TaskName; State = [string]$_.State; Action = $actionText }
                }
        }
        'processes.stopped-auto-services' {
            $stopped = @(CimCmdlets\Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State<>'Running'" -OperationTimeoutSec 15)
            if (-not $stopped.Count) { return 'All automatic services are currently running.' }
            $stopped | Sort-Object Name | Select-Object Name,DisplayName,State,StartMode,DelayedAutoStart,ExitCode
        }
        default { throw 'Unknown process operation.' }
    }
}
