#Requires -Version 5.1
[CmdletBinding()]
param([string]$OutputDirectory = '')
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repository '.build/gui-preview' }
. (Join-Path $repository 'tests/TestSupport.ps1')
$script:ToolkitProductName = 'TOOLX Windows Edition'
$script:ToolkitChannel = 'Alpha'
$script:ToolkitSignature = 'by ALSA'
$script:ToolkitVersion = '0.2.2'
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

function Save-ToolkitGuiPreview {
    param([object]$State, [int]$Width, [int]$Height, [string]$Path)
    $content = $State.Window.Content
    if ($State.ContainsKey('Workspace')) { $State.Window.Width = $Width; Update-ToolkitGuiLayout }
    $content.Measure([System.Windows.Size]::new($Width, $Height))
    $content.Arrange([System.Windows.Rect]::new(0, 0, $Width, $Height))
    $content.UpdateLayout()
    [void]$content.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
    if ($State.ContainsKey('Workspace')) { Update-ToolkitGuiLayout }
    else { Update-ToolkitGuiSpecificationWidth }
    $content.UpdateLayout()
    $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($Width, $Height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($content)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create($Path)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

function Wait-ToolkitGuiDiagnostic {
    param([int]$Seconds = 30)
    $script:ToolkitGuiPreviewFrame = New-Object System.Windows.Threading.DispatcherFrame
    $script:ToolkitGuiPreviewDeadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    $watch = New-Object System.Windows.Threading.DispatcherTimer
    $watch.Interval = [timespan]::FromMilliseconds(25)
    $watch.Add_Tick({
        if ($null -eq $script:ToolkitGui.Worker -or [DateTime]::UtcNow -gt $script:ToolkitGuiPreviewDeadline) { $script:ToolkitGuiPreviewFrame.Continue = $false }
    })
    try { $watch.Start(); [System.Windows.Threading.Dispatcher]::PushFrame($script:ToolkitGuiPreviewFrame) }
    finally { $watch.Stop() }
    if ($null -ne $script:ToolkitGui.Worker) { throw 'GUI diagnostic did not complete through its dispatcher timer.' }
}

$state = New-ToolkitGuiWindow
try {
    Save-ToolkitGuiPreview $state 1120 720 (Join-Path $OutputDirectory 'welcome.png')
    Show-ToolkitGuiCommand (Get-TestCommand 'security.firewall-control')
    Save-ToolkitGuiPreview $state 1120 720 (Join-Path $OutputDirectory 'high-risk.png')
    $category = @($state.Tree.Items | Where-Object Header -eq 'System Information')[0]
    $category.IsExpanded = $true
    $entry = @($category.Items | Where-Object { $_.Tag.id -eq 'system.full-specs' })[0]
    $entry.IsSelected = $true
    if ($state.Command.id -ne 'system.full-specs') { throw 'GUI selection event did not update the command.' }
    Save-ToolkitGuiPreview $state 1120 720 (Join-Path $OutputDirectory 'parameters.png')
    $state.Run.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    Wait-ToolkitGuiDiagnostic
    if ($null -ne $state.Worker) { throw 'GUI full-specification diagnostic did not complete.' }
    if ($state.Status.Text -notmatch '^Succeeded') { throw $state.Status.Text }
    Save-ToolkitGuiPreview $state 1120 720 (Join-Path $OutputDirectory 'specifications-wide.png')
    Save-ToolkitGuiPreview $state 760 580 (Join-Path $OutputDirectory 'specifications-narrow.png')
    "Full specification GUI: $($state.Status.Text); blocks: $($state.SpecWrap.Children.Count)"
    Show-ToolkitGuiCommand (Get-TestCommand 'system.environment')
    $state.Run.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    Wait-ToolkitGuiDiagnostic -Seconds 10
    if ($null -ne $state.Worker -or $state.Status.Text -notmatch '^Succeeded' -or $state.ResultText.Text -notmatch 'PowerShellVersion') { throw 'GUI text diagnostic failed.' }
    "Environment GUI: $($state.Status.Text)"
    Save-ToolkitGuiPreview $state 1120 720 (Join-Path $OutputDirectory 'diagnostic.png')
    $setting = New-ToolkitGuiSettingWindow
    try {
        $setting.Content.Measure([System.Windows.Size]::new(520, 540))
        $setting.Content.Arrange([System.Windows.Rect]::new(0, 0, 520, 540))
        $setting.Content.UpdateLayout()
        Save-ToolkitGuiPreview @{ Window = $setting } 520 540 (Join-Path $OutputDirectory 'settings.png')
    }
    finally { $setting.Close() }
    $importWin = New-ToolkitGuiImportWindow
    try {
        $importWin.Content.Measure([System.Windows.Size]::new(580, 620))
        $importWin.Content.Arrange([System.Windows.Rect]::new(0, 0, 580, 620))
        $importWin.Content.UpdateLayout()
        Save-ToolkitGuiPreview @{ Window = $importWin } 580 620 (Join-Path $OutputDirectory 'import.png')
    }
    finally { $importWin.Close() }
}
finally {
    if ($null -ne $state.Worker) { Stop-ToolkitExecution $state.Worker }
    $state.Timer.Stop()
    if ($null -eq $state.Worker) { $state.Window.Close() }
}
