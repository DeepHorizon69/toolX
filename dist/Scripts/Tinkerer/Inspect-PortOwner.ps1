#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$rawPort = Read-Host 'Enter TCP or UDP port number (1-65535)'
$port = 0
if (-not [int]::TryParse($rawPort, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
    throw 'Enter an integer port between 1 and 65535.'
}

$tcp = @(Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue | ForEach-Object {
    [pscustomobject]@{ Protocol = 'TCP'; LocalAddress = $_.LocalAddress; LocalPort = $_.LocalPort; State = [string]$_.State; PID = [int]$_.OwningProcess }
})
$udp = @(Get-NetUDPEndpoint -LocalPort $port -ErrorAction SilentlyContinue | ForEach-Object {
    [pscustomobject]@{ Protocol = 'UDP'; LocalAddress = $_.LocalAddress; LocalPort = $_.LocalPort; State = 'Bound'; PID = [int]$_.OwningProcess }
})
$bindings = @($tcp) + @($udp)

if (-not $bindings.Count) {
    Write-Host "No active TCP or UDP bindings found on port $port."
    exit 0
}

$bindings | Format-Table -AutoSize | Out-Host
$pids = @($bindings.PID | Where-Object { $_ -gt 0 } | Select-Object -Unique)
foreach ($procId in $pids) {
    $wmiProc = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue
    if ($null -ne $wmiProc) {
        [pscustomobject]@{
            ProcessId = $procId
            Name = $wmiProc.Name
            ExecutablePath = $wmiProc.ExecutablePath
            CommandLine = $wmiProc.CommandLine
        } | Format-List | Out-Host
    }
}

$answer = Read-Host 'Type a PID to terminate that process, or press Enter to exit'
if ([string]::IsNullOrWhiteSpace($answer)) { exit 0 }

$killPid = 0
if (-not [int]::TryParse($answer, [ref]$killPid) -or $killPid -notin $pids) {
    throw 'Entered PID is not among the inspected port owners.'
}

$confirm = Read-Host "Confirm terminating PID $killPid? Type yes to continue"
if ($confirm -ceq 'yes') {
    Stop-Process -Id $killPid -Force -ErrorAction Stop
    Write-Host "Terminated PID $killPid." -ForegroundColor Yellow
}
else {
    Write-Host 'Cancelled.'
}
