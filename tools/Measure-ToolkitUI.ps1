#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ToolkitPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist/Toolkit.ps1'),
    [ValidateRange(5, 100)][int]$Iterations = 20,
    [switch]$Live,
    [ValidateRange(60, 500)][int]$Width = 120,
    [ValidateRange(12, 100)][int]$Height = 30,
    [string]$OutputPath
)
$ErrorActionPreference = 'Stop'
if ($Live -and ([Console]::IsOutputRedirected -or [Console]::IsInputRedirected)) { throw 'Live measurement requires an interactive console.' }
$uiBundlePath = (Resolve-Path -LiteralPath $ToolkitPath).Path
$uiEntries = New-Object 'Collections.Generic.List[double]'
$uiMenus = New-Object 'Collections.Generic.List[double]'
$script:uiLive = [bool]$Live; $script:uiWidth = $Width; $script:uiHeight = $Height
for ($uiIndex = 0; $uiIndex -lt $Iterations; $uiIndex++) {
    $script:uiEntryWatch = [Diagnostics.Stopwatch]::StartNew()
    . $uiBundlePath -Version | Out-Null
    Test-ToolkitRegistry $script:ToolkitRegistry
    $script:uiOriginalFrame = ${function:Show-ToolkitFrame}
    function Show-ToolkitFrame {
        param([string[]]$Lines, [object]$Frame, [switch]$Plain, [switch]$Retry)
        if ($script:uiLive) { & $script:uiOriginalFrame @PSBoundParameters }
        $script:uiEntryWatch.Stop(); $script:uiMenuWatch.Stop()
    }
    function Read-ToolkitKey { return [ConsoleKeyInfo]::new([char]'q', [ConsoleKey]::Q, $false, $false, $false) }
    $script:uiMenuWatch = [Diagnostics.Stopwatch]::StartNew()
    if ($Live) { Start-ToolkitInterface }
    else {
        function Get-ToolkitTerminalSize { return [pscustomobject]@{Width=$script:uiWidth;Height=$script:uiHeight;Left=0;Top=0} }
        $script:ToolkitBasic = $false
        $uiItems = @($script:ToolkitRegistry.commands | Select-Object -ExpandProperty category -Unique | ForEach-Object { [pscustomobject]@{Label=$_;Value=$_} })
        $uiItems += @([pscustomobject]@{Label='Custom Scripts';Value='Custom Scripts'}, [pscustomobject]@{Label='Search all commands';Value='Search'}, [pscustomobject]@{Label='Settings';Value='Settings'})
        Read-ToolkitMenu 'Command library' $uiItems | Out-Null
    }
    $uiEntries.Add($script:uiEntryWatch.Elapsed.TotalMilliseconds)
    $uiMenus.Add($script:uiMenuWatch.Elapsed.TotalMilliseconds)
}
$uiEntrySorted = @($uiEntries | Sort-Object); $uiMenuSorted = @($uiMenus | Sort-Object)
$uiP95 = [int][Math]::Ceiling($Iterations * 0.95) - 1
$uiMedian = [int][Math]::Floor($Iterations / 2)
$uiMeasurement = 'Synthetic menu composition; no console writes or host initialization'
if ($Live) { $uiMeasurement = 'Same-process warm bundle entry to first painted menu; excludes process launch, key is supplied by harness' }
$uiResult = [pscustomobject]@{
    Measurement=$uiMeasurement; Iterations=$Iterations
    EntryMedianMs=$uiEntrySorted[$uiMedian]; EntryP95Ms=$uiEntrySorted[$uiP95]
    MenuMedianMs=$uiMenuSorted[$uiMedian]; MenuP95Ms=$uiMenuSorted[$uiP95]
    EntrySamplesMs=$uiEntries.ToArray(); MenuSamplesMs=$uiMenus.ToArray()
    Bytes=(Get-Item -LiteralPath $uiBundlePath).Length; PowerShell=$PSVersionTable.PSVersion.ToString()
    Width=$Width; Height=$Height
}
if ($Live) { $uiSize = Get-ToolkitTerminalSize; $uiResult.Width = $uiSize.Width; $uiResult.Height = $uiSize.Height; [Console]::SetCursorPosition(0, [Console]::WindowTop + [Console]::WindowHeight - 1) }
$uiJson = $uiResult | ConvertTo-Json -Depth 4
if ($OutputPath) { [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), $uiJson, (New-Object Text.UTF8Encoding($false))) }
Write-Output $uiJson
