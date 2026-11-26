function Test-ToolkitAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    finally { $identity.Dispose() }
}

function Get-ToolkitPowerShellPath {
    $system = Join-Path $env:SystemRoot 'System32'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $system = Join-Path $env:SystemRoot 'Sysnative' }
    return Join-Path $system 'WindowsPowerShell/v1.0/powershell.exe'
}

function Start-ToolkitConsole {
    param([string]$OperationId, [hashtable]$Parameters = @{}, [switch]$Elevated, [switch]$SkipActionConfirmation)
    if (-not $script:ToolkitEntryPath -or -not (Test-Path -LiteralPath $script:ToolkitEntryPath -PathType Leaf)) { throw 'The toolkit script is no longer available.' }
    $json = ConvertTo-Json -InputObject ([pscustomobject]$Parameters) -Compress -Depth 4
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    if ($payload.Length -gt 8192) { throw 'Operation parameters are too large.' }
    $arguments = @('-NoLogo', '-NoProfile', '-File', $script:ToolkitEntryPath)
    if ($script:ToolkitRoot) { $arguments += @('-AppRoot', $script:ToolkitRoot) }
    $arguments += @('-WorkerId', $OperationId, '-ParameterData', $payload)
    if ($Elevated) { $arguments += '-RequireElevation' }
    if ($SkipActionConfirmation) { $arguments += '-SkipActionConfirmation' }
    $start = @{
        FilePath = Get-ToolkitPowerShellPath
        ArgumentList = (($arguments | ForEach-Object { ConvertTo-ToolkitArgument $_ }) -join ' ')
        WorkingDirectory = $env:SystemRoot
        PassThru = $true
        ErrorAction = 'Stop'
    }
    if ($Elevated) { $start.Verb = 'RunAs' }
    try { return Start-Process @start }
    catch [ComponentModel.Win32Exception] {
        if ($_.Exception.NativeErrorCode -eq 1223) { throw [OperationCanceledException]::new('The administrator prompt was cancelled.') }
        throw
    }
}
