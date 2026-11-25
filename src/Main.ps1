#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Basic,
    [switch]$ListCommands,
    [switch]$Version,
    [switch]$Check,
    [string]$WorkerId,
    [string]$ParameterData,
    [switch]$RequireElevation,
    [switch]$SkipActionConfirmation,
    [string]$ManagedJobId,
    [ValidateSet('Probe','Execute')][string]$ManagedMode = 'Execute'
)
$ErrorActionPreference = 'Stop'
$script:ToolkitEntryPath = $PSCommandPath
$script:ToolkitRoot = $PSScriptRoot
$script:ToolkitStandalone = $false
# <TOOLKIT_BOOTSTRAP>
$repository = Split-Path $PSScriptRoot -Parent
$manifest = [IO.File]::ReadAllText((Join-Path $repository 'Build.Manifest.json')) | ConvertFrom-Json
foreach ($source in $manifest.files) { . (Join-Path $repository $source) }
$script:ToolkitRegistry = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'config/commands.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
$script:ToolkitVersion = $manifest.version
$script:ToolkitRoot = $repository
# </TOOLKIT_BOOTSTRAP>
$script:ToolkitCustomLoaded = $false
$script:ToolkitCustomCommands = @()
$script:ToolkitCustomNotice = ''
$script:ToolkitConfirmActions = $true
try {
    if ($Version) { Write-Output $script:ToolkitVersion; return }
    Test-ToolkitRegistry $script:ToolkitRegistry
    if ($ManagedJobId) { Invoke-ToolkitManagedWorker -Id $ManagedJobId -Mode $ManagedMode; return }
    if ($WorkerId) { $workerExit = Invoke-ToolkitConsoleWorker $WorkerId $ParameterData -RequireElevation:$RequireElevation -SkipConfirmation:$SkipActionConfirmation; exit $workerExit }
    if ($ParameterData -or $RequireElevation -or $SkipActionConfirmation) { throw 'Worker options require a valid operation ID.' }
    if ($ListCommands) { Get-ToolkitCatalog -IncludeCustom; return }
    if ($Check) {
        foreach ($command in (Get-ToolkitCatalog -IncludeCustom)) {
            $capability = Get-ToolkitCapability $command
            [pscustomobject]@{ Id = $command.id; Source = $command.sourceKind; Available = $capability.Available; RequiresAdmin = $command.requiresAdmin; Detail = $capability.Reason }
        }
        if ($script:ToolkitCustomNotice) { Write-Warning $script:ToolkitCustomNotice }
        return
    }
    if ([Console]::IsInputRedirected) { throw 'Interactive input is unavailable. Use -ListCommands, -Check or -Version; open a console to use the menus.' }
    Start-ToolkitInterface -Basic:$Basic
}
catch { Write-Error -Message $_.Exception.Message -ErrorAction Continue; exit 1 }
