#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

Write-Host 'Microsoft Activation Scripts (MAS)' -ForegroundColor Cyan
Write-Host 'Homepage: https://massgrave.dev/ (source: https://github.com/massgravel/Microsoft-Activation-Scripts)'
Write-Host 'Download URL: https://get.activated.win'
Write-Host 'This script downloads and executes the remote MAS launcher with administrator permissions and opens its interactive menu.' -ForegroundColor Yellow

$confirm = Read-Host 'Type yes to download and launch MAS (Enter cancels)'
if ($confirm -cne 'yes') {
    Write-Host 'Cancelled.'
    return
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Write-Host 'Downloading https://get.activated.win ...'
$scriptContent = Invoke-RestMethod -Uri 'https://get.activated.win' -ErrorAction Stop
if ([string]::IsNullOrWhiteSpace([string]$scriptContent)) {
    throw 'Downloaded MAS launcher was empty.'
}

$tempScript = Join-Path ([IO.Path]::GetTempPath()) ('mas-' + [guid]::NewGuid().ToString('N') + '.ps1')
try {
    [IO.File]::WriteAllText($tempScript, [string]$scriptContent, (New-Object Text.UTF8Encoding($true)))
    & $tempScript
}
finally {
    if (Test-Path -LiteralPath $tempScript -PathType Leaf) {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
}
