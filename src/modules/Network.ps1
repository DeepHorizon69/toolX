function Invoke-ToolkitNetworkAction {
    param([string]$TargetId, [hashtable]$Values)
    switch ($TargetId) {
        'network.adapters' { NetAdapter\Get-NetAdapter | Select-Object Name,InterfaceDescription,Status,LinkSpeed,ifIndex }
        'network.dns' { DnsClient\Resolve-DnsName -Name $Values.host -Type $Values.recordType -DnsOnly -QuickTimeout }
        'network.loss' {
            $ping = New-Object Net.NetworkInformation.Ping
            $times = New-Object 'Collections.Generic.List[long]'
            $lastFailure = ''
            try {
                for ($index = 1; $index -le 20; $index++) {
                    try {
                        $reply = $ping.Send([string]$Values.host, 1000)
                        if ($reply.Status -eq [Net.NetworkInformation.IPStatus]::Success) { $times.Add($reply.RoundtripTime) }
                    }
                    catch [Net.NetworkInformation.PingException] { $lastFailure = $_.Exception.Message }
                    if ($index -lt 20) { Start-Sleep -Milliseconds 250 }
                }
                $stats = $times | Measure-Object -Minimum -Maximum -Average
                [pscustomobject]@{ Target = $Values.host; Sent = 20; Received = $times.Count; LossPercent = (20 - $times.Count) * 5; MinimumMs = $stats.Minimum; MaximumMs = $stats.Maximum; AverageMs = $stats.Average; LastProbeError = $lastFailure }
            }
            finally { $ping.Dispose() }
        }
        'network.port' {
            $client = New-Object Net.Sockets.TcpClient
            $async = $null
            try {
                $async = $client.BeginConnect([string]$Values.host, [int]$Values.port, $null, $null)
                if (-not $async.AsyncWaitHandle.WaitOne(5000)) { throw [TimeoutException]::new('The TCP connection wait exceeded five seconds.') }
                $client.EndConnect($async)
                [pscustomobject]@{ Target = $Values.host; Port = $Values.port; Connected = $true }
            }
            finally {
                $client.Close()
                if ($null -ne $async) { $async.AsyncWaitHandle.Close() }
            }
        }
        default { throw 'Unknown network operation.' }
    }
}

function Get-ToolkitNativeSpec {
    param([string]$TargetId, [hashtable]$Values)
    $name = ''; $arguments = @()
    switch ($TargetId) {
        'network.ip' { $name = 'ipconfig.exe'; $arguments = @('/all') }
        'network.ping' { $name = 'ping.exe'; $arguments = @('-n','4','-w','1000',$Values.host) }
        'network.trace' { $name = 'tracert.exe'; $arguments = @('-d','-h','15','-w','1000',$Values.host) }
        'network.arp' { $name = 'arp.exe'; $arguments = @('-a') }
        'network.routes' { $name = 'route.exe'; $arguments = @('print') }
        'network.connections' { $name = 'netstat.exe'; $arguments = @('-ano') }
        'network.flush-dns' { $name = 'ipconfig.exe'; $arguments = @('/flushdns') }
        'repair.sfc-verify' { $name = 'sfc.exe'; $arguments = @('/verifyonly') }
        'repair.sfc' { $name = 'sfc.exe'; $arguments = @('/scannow') }
        'repair.dism-check' { $name = 'dism.exe'; $arguments = @('/Online','/Cleanup-Image','/CheckHealth') }
        'repair.dism-scan' { $name = 'dism.exe'; $arguments = @('/Online','/Cleanup-Image','/ScanHealth') }
        'repair.dism-restore' {
            $name = 'dism.exe'; $arguments = @('/Online','/Cleanup-Image','/RestoreHealth','/LimitAccess')
            if ($Values.ContainsKey('source')) { $arguments += '/Source:' + (Test-ToolkitLocalPath $Values.source Directory) }
        }
        'repair.chkdsk' {
            $name = 'chkdsk.exe'
            if ([string]$Values.drive -notmatch '^[A-Za-z]$') { throw 'Invalid CHKDSK drive.' }
            $arguments = @($Values.drive + ':')
        }
        'repair.winsock' { $name = 'netsh.exe'; $arguments = @('winsock','reset') }
        default { throw 'Unknown native operation.' }
    }
    return [pscustomobject]@{ FileName = (Get-ToolkitWindowsExecutable $name); Arguments = [string[]]$arguments }
}
