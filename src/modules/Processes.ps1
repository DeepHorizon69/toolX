function Invoke-ToolkitProcessesAction {
    param([string]$TargetId)
    switch ($TargetId) {
        'processes.list' { Microsoft.PowerShell.Management\Get-Process | Select-Object Id,ProcessName,CPU,WorkingSet64 }
        'processes.services' { Microsoft.PowerShell.Management\Get-Service | Select-Object Name,DisplayName,Status }
        'processes.startup' { Get-CimInstance Win32_StartupCommand -OperationTimeoutSec 15 | Select-Object Name,Command,Location }
        default { throw 'Unknown process operation.' }
    }
}
