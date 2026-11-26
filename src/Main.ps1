#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Gui,
    [switch]$Basic,
    [switch]$ListCommands,
    [switch]$Version,
    [switch]$Check,
    [string]$AppRoot,
    [string]$ImportLocal,
    [string]$ImportUrl,
    [string]$ImportFolder,
    [string]$ImportSha256,
    [switch]$ImportOverwrite,
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
$script:ToolkitProductName = $manifest.productName
$script:ToolkitChannel = $manifest.channel
$script:ToolkitSignature = $manifest.signature
$script:ToolkitVersion = $manifest.version
$script:ToolkitRoot = $repository
# </TOOLKIT_BOOTSTRAP>
$script:ToolkitCustomLoaded = $false
$script:ToolkitCustomCommands = @()
$script:ToolkitCustomNotice = ''
$script:ToolkitConfirmActions = $true
try {
    if ($AppRoot) { $script:ToolkitRoot = Test-ToolkitLocalPath -Path $AppRoot -Kind Directory }
    if ($Gui -and @($PSBoundParameters.Keys | Where-Object { $_ -notin @('Gui','AppRoot') }).Count) { throw 'Gui cannot be combined with other entrypoint options.' }
    if ($Version) { Write-Output (Get-ToolkitIdentity).VersionOutput; return }
    Test-ToolkitRegistry $script:ToolkitRegistry
    if ($ManagedJobId) { Invoke-ToolkitManagedWorker -Id $ManagedJobId -Mode $ManagedMode; return }
    if ($WorkerId) { $workerExit = Invoke-ToolkitConsoleWorker $WorkerId $ParameterData -RequireElevation:$RequireElevation -SkipConfirmation:$SkipActionConfirmation; exit $workerExit }
    if ($ParameterData -or $RequireElevation -or $SkipActionConfirmation) { throw 'Worker options require a valid operation ID.' }
    if ($ImportLocal -and $ImportUrl) { throw 'Choose either -ImportLocal or -ImportUrl, not both.' }
    if ($ImportLocal) {
        $imported = Import-ToolkitLocalScript -Path $ImportLocal -Folder $ImportFolder -Overwrite:$ImportOverwrite
        $imported | Select-Object id,name,relativePath,requiresAdmin
        return
    }
    if ($ImportUrl) {
        $imported = Import-ToolkitUrlScript -Url $ImportUrl -Folder $ImportFolder -ExpectedSha256 $ImportSha256 -Overwrite:$ImportOverwrite
        $imported | Select-Object id,name,relativePath,requiresAdmin
        return
    }
    if ($ListCommands) { Get-ToolkitCatalog -IncludeCustom; return }
    if ($Check) {
        foreach ($command in (Get-ToolkitCatalog -IncludeCustom)) {
            $capability = Get-ToolkitCapability $command
            [pscustomobject]@{ Id = $command.id; Source = $command.sourceKind; Available = $capability.Available; RequiresAdmin = $command.requiresAdmin; Detail = $capability.Reason }
        }
        if ($script:ToolkitCustomNotice) { Write-Warning $script:ToolkitCustomNotice }
        return
    }
    if ($Gui) { Start-ToolkitGui; return }
    if ([Console]::IsInputRedirected) { throw 'Interactive input is unavailable. Use -ListCommands, -Check or -Version; open a console to use the menus.' }
    Start-ToolkitInterface -Basic:$Basic
}
catch { Write-Error -Message $_.Exception.Message -ErrorAction Continue; exit 1 }
