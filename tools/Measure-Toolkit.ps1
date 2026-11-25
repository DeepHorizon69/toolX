#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ToolkitPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist/Toolkit.ps1'),
    [ValidateRange(1, 100)][int]$Iterations = 20
)
$ErrorActionPreference = 'Stop'
$full = (Resolve-Path -LiteralPath $ToolkitPath).Path
$hostPath = Join-Path $PSHOME 'powershell.exe'
$times = New-Object 'Collections.Generic.List[double]'
for ($index = 0; $index -lt $Iterations; $index++) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $hostPath
    $info.Arguments = '-NoProfile -File "' + $full + '" -ListCommands'
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    try {
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $outputTask.GetAwaiter().GetResult() | Out-Null
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw $errorText }
    }
    finally { $process.Dispose() }
    $watch.Stop(); $times.Add($watch.Elapsed.TotalMilliseconds)
}
$sorted = @($times | Sort-Object)
$percentile = [Math]::Max(0, [int][Math]::Ceiling($sorted.Count * 0.95) - 1)
[pscustomobject]@{
    Measurement = 'Process start through catalog output and process exit, not first-menu render'
    Iterations = $Iterations; MedianMs = $sorted[[int][Math]::Floor($sorted.Count / 2)]
    P95Ms = $sorted[$percentile]; Bytes = (Get-Item -LiteralPath $full).Length
    PowerShell = $PSVersionTable.PSVersion.ToString(); Is64BitProcess = [Environment]::Is64BitProcess
    WindowsBuild = [Environment]::OSVersion.Version.ToString()
}
