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
        'network.listening-ports' {
            $procMap = @{}
            foreach ($proc in (Get-Process -ErrorAction SilentlyContinue)) { $procMap[[int]$proc.Id] = $proc.ProcessName }
            $rows = New-Object 'Collections.Generic.List[object]'
            foreach ($tcp in (NetTCPIP\Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)) {
                $rows.Add([pscustomobject]@{
                    Protocol = 'TCP'; LocalAddress = $tcp.LocalAddress; LocalPort = [int]$tcp.LocalPort
                    OwningProcess = [int]$tcp.OwningProcess; ProcessName = $procMap[[int]$tcp.OwningProcess]
                })
            }
            foreach ($udp in (NetTCPIP\Get-NetUDPEndpoint -ErrorAction SilentlyContinue)) {
                $rows.Add([pscustomobject]@{
                    Protocol = 'UDP'; LocalAddress = $udp.LocalAddress; LocalPort = [int]$udp.LocalPort
                    OwningProcess = [int]$udp.OwningProcess; ProcessName = $procMap[[int]$udp.OwningProcess]
                })
            }
            $rows | Sort-Object Protocol,LocalPort | Select-Object -First 300
        }
        'network.wifi' {
            $netsh = Get-ToolkitWindowsExecutable 'netsh.exe'
            '--- Active WLAN interfaces ---'
            & $netsh wlan show interfaces 2>&1 | ForEach-Object { [string]$_ }
            ''
            '--- Saved WLAN profiles ---'
            & $netsh wlan show profiles 2>&1 | ForEach-Object { [string]$_ }
        }
        'network.hosts' {
            $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
            if (-not (Test-Path -LiteralPath $hostsPath -PathType Leaf)) { return [pscustomobject]@{ Path = $hostsPath; Status = 'Missing' } }
            $lines = @(Get-Content -LiteralPath $hostsPath -ErrorAction Stop)
            $active = @($lines | Where-Object { $_ -notmatch '^\s*(#|$)' })
            [pscustomobject]@{ Path = $hostsPath; TotalLines = $lines.Count; ActiveEntryCount = $active.Count; ActiveEntries = $(if ($active.Count) { $active -join '; ' } else { 'No active custom host entries.' }) }
        }
        'network.proxy' {
            $internet = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
            [pscustomobject]@{
                UserProxyEnabled = [bool]($internet.ProxyEnable -eq 1)
                UserProxyServer = $internet.ProxyServer
                UserProxyOverride = $internet.ProxyOverride
                AutoConfigURL = $internet.AutoConfigURL
            }
            $netsh = Get-ToolkitWindowsExecutable 'netsh.exe'
            '--- WinHTTP proxy ---'
            & $netsh winhttp show proxy 2>&1 | ForEach-Object { [string]$_ }
        }
        'network.dhcp-renew' {
            $ipconfig = Get-ToolkitWindowsExecutable 'ipconfig.exe'
            & $ipconfig /release 2>&1 | ForEach-Object { [string]$_ }
            if ($LASTEXITCODE -ne 0) { throw "ipconfig /release returned exit code $LASTEXITCODE." }
            & $ipconfig /renew 2>&1 | ForEach-Object { [string]$_ }
            if ($LASTEXITCODE -ne 0) { throw "ipconfig /renew returned exit code $LASTEXITCODE." }
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
        'repair.tcpip-reset' { $name = 'netsh.exe'; $arguments = @('int','ip','reset') }
        default { throw 'Unknown native operation.' }
    }
    return [pscustomobject]@{ FileName = (Get-ToolkitWindowsExecutable $name); Arguments = [string[]]$arguments }
}
