$script:RepositoryRoot = Split-Path $PSScriptRoot -Parent
$manifest = [IO.File]::ReadAllText((Join-Path $script:RepositoryRoot 'Build.Manifest.json')) | ConvertFrom-Json
foreach ($source in $manifest.files) {
    $path = Join-Path $script:RepositoryRoot $source
    if (Test-Path -LiteralPath $path) { . $path }
}
$script:ToolkitRegistry = [IO.File]::ReadAllText((Join-Path $script:RepositoryRoot 'src/config/commands.json')) | ConvertFrom-Json
$script:ToolkitRoot = $script:RepositoryRoot
$script:ToolkitEntryPath = Join-Path $script:RepositoryRoot 'src/Main.ps1'
$script:ToolkitCustomCommands = @()
$script:ToolkitCustomLoaded = $false
$script:ToolkitCustomNotice = ''
$script:ToolkitConfirmActions = $true

function Get-TestCommand {
    param([string]$Id)
    return $script:ToolkitRegistry.commands | Where-Object { $_.id -eq $Id } | Select-Object -First 1
}
