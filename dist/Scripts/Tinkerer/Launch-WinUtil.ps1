#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

Write-Host 'Chris Titus Tech Windows Utility (WinUtil)' -ForegroundColor Cyan
Write-Host 'Upstream URL: https://christitus.com/win (source: https://github.com/ChrisTitusTech/winutil)'
Write-Host 'This script downloads and executes the remote WinUtil script in this elevated session.' -ForegroundColor Yellow

$confirm = Read-Host 'Type yes to download and launch WinUtil (Enter cancels)'
if ($confirm -cne 'yes') {
    Write-Host 'Cancelled.'
    exit 0
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Write-Host 'Downloading https://christitus.com/win ...'
$scriptContent = Invoke-RestMethod -Uri 'https://christitus.com/win' -ErrorAction Stop
if ([string]::IsNullOrWhiteSpace([string]$scriptContent)) {
    throw 'Downloaded WinUtil payload was empty.'
}

$tempScript = Join-Path ([IO.Path]::GetTempPath()) ("winutil-" + [guid]::NewGuid().ToString('N') + '.ps1')
try {
    [IO.File]::WriteAllText($tempScript, [string]$scriptContent, (New-Object Text.UTF8Encoding($false)))
    & $tempScript
}
finally {
    if (Test-Path -LiteralPath $tempScript -PathType Leaf) {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
}
