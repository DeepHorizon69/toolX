function Get-ToolkitWindowsExecutable {
    param([string]$Name)
    if ($Name -notin @('ipconfig.exe', 'ping.exe', 'tracert.exe', 'arp.exe', 'route.exe', 'netstat.exe', 'resmon.exe', 'taskmgr.exe', 'mmc.exe', 'sfc.exe', 'dism.exe', 'chkdsk.exe', 'netsh.exe', 'cmd.exe', 'shutdown.exe', 'powercfg.exe')) { throw 'Executable is not in the built-in allowlist.' }
    $system = Join-Path $env:SystemRoot 'System32'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $system = Join-Path $env:SystemRoot 'Sysnative' }
    $path = Join-Path $system $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Windows utility is unavailable: $Name" }
    return $path
}

function Get-ToolkitCapability {
    param([object]$Command)
    try {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows is required.' }
        if ($Command.sourceKind -eq 'CustomScript') {
            if (-not $Command.available) { throw $Command.unavailableReason }
            Resolve-ToolkitCustomScript -Id $Command.id | Out-Null
        }
        else {
            $build = [int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber -ErrorAction Stop).CurrentBuildNumber
            if ($build -lt $Command.compatibility.minimumBuild) { throw 'This Windows build is not supported.' }
            if ($Command.id -eq 'updates.suspend' -and -not (Test-ToolkitUpdateEdition)) { throw 'Long automatic-update suspension is unavailable on this Windows edition; Pro, Enterprise or Education is required.' }
            foreach ($capability in $Command.compatibility.capabilities) {
                if ($capability.StartsWith('exe:')) { Get-ToolkitWindowsExecutable $capability.Substring(4) | Out-Null }
                elseif ($capability.StartsWith('cmdlet:')) {
                    if (-not (Get-Command -Name $capability.Substring(7) -CommandType Cmdlet,Function -ErrorAction SilentlyContinue)) { throw "Missing Windows command: $($capability.Substring(7))" }
                }
            }
            if ($Command.executionType -eq 'Mmc') {
                $snapIn = (Get-ToolkitLaunchSpec $Command.targetId).Arguments[0]
                if (-not (Test-Path -LiteralPath $snapIn)) { throw "Unavailable snap-in: $($Command.targetId)" }
            }
        }
        return [pscustomobject]@{ Available = $true; Reason = '' }
    }
    catch { return [pscustomobject]@{ Available = $false; Reason = $_.Exception.Message } }
}
