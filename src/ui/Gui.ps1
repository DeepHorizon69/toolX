function Get-ToolkitGuiVisibleParameter {
    param([object]$Command, [hashtable]$Values)
    foreach ($definition in $Command.parameters) {
        if ($Command.id -in @('security.firewall-control','security.defender-control')) {
            if ($definition.name -in @('mode','minutes') -and $Values.action -eq 'Enable') { continue }
            if ($definition.name -eq 'minutes' -and $Values.mode -eq 'Manual') { continue }
        }
        $definition
    }
}

function ConvertTo-ToolkitGuiParameterMap {
    param([object]$Command, [hashtable]$Values)
    $result = @{}
    foreach ($definition in $Command.parameters) {
        $visible = @(Get-ToolkitGuiVisibleParameter $Command $result)
        if ($definition.name -notin @($visible.name)) { continue }
        $value = Test-ToolkitParameter $definition $Values[$definition.name]
        if ($null -ne $value) { $result[$definition.name] = $value }
    }
    return $result
}

function Get-ToolkitGuiExecutionRoute {
    param([object]$Command, [switch]$Elevated)
    if ($Command.sourceKind -eq 'CustomScript' -or $Command.requiresAdmin -or $Command.risk -ne 'ReadOnly' -or $Elevated) { return 'Console' }
    return 'Background'
}

function Set-ToolkitGuiWindowChrome {
    param([System.Windows.Window]$Window)
    if ($null -eq $Window -or [System.Windows.SystemParameters]::HighContrast) { return }
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($Window)
        $handle = $helper.Handle
        if ($handle -eq [IntPtr]::Zero) { return }
        if (-not ('ToolkitDwmNative' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ToolkitDwmNative
{
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
}
'@
        }
        $dark = 1
        if ([ToolkitDwmNative]::DwmSetWindowAttribute($handle, 20, [ref]$dark, 4) -ne 0) {
            [void][ToolkitDwmNative]::DwmSetWindowAttribute($handle, 19, [ref]$dark, 4)
        }
        # BGR hex values matching Chrome (#10151C) and Divider (#232C37) for Windows 11 DWM chrome.
        $caption = 0x001C1510
        $border = 0x00372C23
        [void][ToolkitDwmNative]::DwmSetWindowAttribute($handle, 35, [ref]$caption, 4)
        [void][ToolkitDwmNative]::DwmSetWindowAttribute($handle, 34, [ref]$border, 4)
    }
    catch { Write-Verbose 'Native dark title bar attributes are unavailable on this host.' }
}

function Set-ToolkitGuiStatus {
    param([string]$Text, [string]$Role = 'Muted')
    $state = $script:ToolkitGui
    $state.Status.Text = ConvertTo-ToolkitSafeText $Text
    $state.Status.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, $Role)
    if ($null -ne $state.StatusDot) {
        $dotRole = $Role
        if ($dotRole -eq 'Text') { $dotRole = 'Accent' }
        $state.StatusDot.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, $dotRole)
    }
}

function Set-ToolkitGuiTheme {
    $state = $script:ToolkitGui
    $highContrast = [System.Windows.SystemParameters]::HighContrast
    if ($null -ne $state.HighContrast -and $state.HighContrast -eq $highContrast) { return }
    $colors = @{
        Background = '#0B0F14'; Chrome = '#10151C'; Surface = '#141B24'; Raised = '#1C2532'
        Divider = '#232C37'; Edge = '#687C93'; ScrollThumb = '#5E7287'; ScrollHover = '#7D93AA'
        Text = '#E6EDF3'; Muted = '#9AA8B8'; DisabledText = '#8C9CAE'
        Accent = '#66D6C7'; PrimaryFill = '#52C4B5'; PrimaryHover = '#66D6C7'; PrimaryText = '#081312'
        Success = '#7EE787'; SuccessBg = '#13261E'; Warning = '#E5B552'; WarningBg = '#262012'
        Danger = '#FF8E88'; DangerHover = '#FFA5A0'; DangerBg = '#2A1517'; DangerText = '#1A0707'
    }
    if ($highContrast) {
        $colors.Background = [System.Windows.SystemColors]::WindowColor
        $colors.Chrome = [System.Windows.SystemColors]::WindowColor
        $colors.Surface = [System.Windows.SystemColors]::WindowColor
        $colors.Raised = [System.Windows.SystemColors]::ControlColor
        $colors.Divider = [System.Windows.SystemColors]::WindowTextColor
        $colors.Edge = [System.Windows.SystemColors]::WindowTextColor
        $colors.ScrollThumb = [System.Windows.SystemColors]::WindowTextColor
        $colors.ScrollHover = [System.Windows.SystemColors]::HighlightColor
        $colors.Text = [System.Windows.SystemColors]::WindowTextColor
        $colors.Muted = [System.Windows.SystemColors]::WindowTextColor
        $colors.DisabledText = [System.Windows.SystemColors]::GrayTextColor
        $colors.Accent = [System.Windows.SystemColors]::HighlightColor
        $colors.PrimaryFill = [System.Windows.SystemColors]::HighlightColor
        $colors.PrimaryHover = [System.Windows.SystemColors]::HighlightColor
        $colors.PrimaryText = [System.Windows.SystemColors]::HighlightTextColor
        $colors.Success = [System.Windows.SystemColors]::WindowTextColor
        $colors.SuccessBg = [System.Windows.SystemColors]::ControlColor
        $colors.Warning = [System.Windows.SystemColors]::WindowTextColor
        $colors.WarningBg = [System.Windows.SystemColors]::ControlColor
        $colors.Danger = [System.Windows.SystemColors]::WindowTextColor
        $colors.DangerHover = [System.Windows.SystemColors]::HighlightColor
        $colors.DangerBg = [System.Windows.SystemColors]::ControlColor
        $colors.DangerText = [System.Windows.SystemColors]::HighlightTextColor
    }
    foreach ($key in $colors.Keys) {
        $color = [System.Windows.Media.ColorConverter]::ConvertFromString([string]$colors[$key])
        $state.Window.Resources[$key] = [System.Windows.Media.SolidColorBrush]::new($color)
    }
    $state.Window.Resources[[System.Windows.SystemColors]::WindowBrushKey] = $state.Window.Resources['Surface'].PSObject.BaseObject
    $state.Window.Resources[[System.Windows.SystemColors]::WindowTextBrushKey] = $state.Window.Resources['Text'].PSObject.BaseObject
    $state.Window.Resources[[System.Windows.SystemColors]::ControlBrushKey] = $state.Window.Resources['Chrome'].PSObject.BaseObject
    $state.Window.Resources[[System.Windows.SystemColors]::HighlightBrushKey] = $state.Window.Resources['Accent'].PSObject.BaseObject
    $highlightText = $state.Window.Resources['Background'].PSObject.BaseObject
    if ($highContrast) { $highlightText = [System.Windows.SystemColors]::HighlightTextBrush }
    $state.Window.Resources[[System.Windows.SystemColors]::HighlightTextBrushKey] = $highlightText
    $state.Window.Resources[[System.Windows.SystemColors]::InactiveSelectionHighlightBrushKey] = $state.Window.Resources['Raised'].PSObject.BaseObject
    $state.Window.Resources[[System.Windows.SystemColors]::InactiveSelectionHighlightTextBrushKey] = $state.Window.Resources['Text'].PSObject.BaseObject
    $state.Progress.IsIndeterminate = [System.Windows.SystemParameters]::ClientAreaAnimation
    $state.HighContrast = $highContrast
}

function New-ToolkitGuiTag {
    param([string]$Text, [string]$ForegroundKey = 'Muted', [string]$BackgroundKey = 'Raised')
    $border = New-Object System.Windows.Controls.Border
    $border.CornerRadius = [System.Windows.CornerRadius]::new(4)
    $border.Padding = '8,3'
    $border.Margin = '0,0,6,6'
    $border.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, $BackgroundKey)
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Text
    $label.FontSize = 11.5
    $label.FontWeight = 'SemiBold'
    $label.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $ForegroundKey)
    $border.Child = $label
    return $border
}

function Update-ToolkitGuiCopyState {
    $state = $script:ToolkitGui
    if ($null -eq $state.CopyButton) { return }
    $busy = $null -ne $state.Worker -or $null -ne $state.External
    $hasText = -not $busy -and (($state.SpecScroll.Visibility -eq 'Visible' -and $state.SpecBlocks.Count -gt 0) -or ($state.ResultText.Visibility -eq 'Visible' -and $state.Output.Count -gt 0))
    $state.CopyButton.IsEnabled = $hasText
    if (-not $hasText) { $state.CopyButton.Content = 'Copy' }
}

function Update-ToolkitGuiAvailability {
    $state = $script:ToolkitGui
    $busy = $null -ne $state.Worker -or $null -ne $state.External
    foreach ($control in @($state.Tree,$state.Search,$state.ClearSearch,$state.Refresh,$state.ImportScript,$state.Settings,$state.Parameters,$state.WelcomePanel)) {
        if ($null -ne $control) { $control.IsEnabled = -not $busy }
    }
    $state.Run.IsEnabled = -not $busy -and $state.CanRun
    $state.RunAdmin.IsEnabled = $state.Run.IsEnabled
    $state.Cancel.IsEnabled = $null -ne $state.Worker -and -not $state.Stopping
    $state.Progress.Visibility = 'Collapsed'; if ($busy) { $state.Progress.Visibility = 'Visible' }
    $state.Privilege.Text = 'Standard user | Confirmations: ON'
    if ($state.Administrator) { $state.Privilege.Text = 'ADMINISTRATOR: children inherit this token | Confirmations: ON' }
    $state.Privilege.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Muted')
    $state.PrivilegeBadge.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'Surface')
    $state.PrivilegeBadge.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'Divider')
    if (-not $script:ToolkitConfirmActions) {
        $state.Privilege.Text = $state.Privilege.Text.Replace('Confirmations: ON', 'ACTION CONFIRMATIONS OFF')
        $state.Privilege.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Danger')
        $state.PrivilegeBadge.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'DangerBg')
        $state.PrivilegeBadge.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'Danger')
    }
    elseif ($state.Administrator) {
        $state.Privilege.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Warning')
        $state.PrivilegeBadge.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'WarningBg')
        $state.PrivilegeBadge.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'Warning')
    }
    $state.Run.Content = 'Run'
    $runStyle = 'PrimaryButtonStyle'
    if ($null -ne $state.Command -and -not $script:ToolkitConfirmActions -and (Get-ToolkitGuiExecutionRoute $state.Command) -eq 'Console') {
        $state.Run.Content = 'Run now'
        $runStyle = 'DangerButtonStyle'
    }
    $state.Run.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, $runStyle)
    Update-ToolkitGuiCopyState
}

function Switch-ToolkitGuiSidebar {
    $state = $script:ToolkitGui
    $state.SidebarCollapsed = -not $state.SidebarCollapsed
    if ($state.SidebarCollapsed) {
        $state.SidebarColumn.MinWidth = 0
        $state.SidebarColumn.Width = [System.Windows.GridLength]::new(0)
        $state.SplitterColumn.Width = [System.Windows.GridLength]::new(0)
        $state.SidebarPanel.Visibility = 'Collapsed'
        $state.Splitter.Visibility = 'Collapsed'
        [System.Windows.Automation.AutomationProperties]::SetName($state.SidebarToggle, 'Show sidebar')
        $state.SidebarToggle.ToolTip = 'Show command library (Ctrl+B)'
    }
    else {
        $width = 296
        if ($state.Window.ActualWidth -gt 0 -and $state.Window.ActualWidth -lt 820) { $width = 236 }
        $state.SidebarColumn.MinWidth = 175
        $state.SidebarColumn.Width = [System.Windows.GridLength]::new($width)
        $state.SplitterColumn.Width = [System.Windows.GridLength]::new(5)
        $state.SidebarPanel.Visibility = 'Visible'
        $state.Splitter.Visibility = 'Visible'
        [System.Windows.Automation.AutomationProperties]::SetName($state.SidebarToggle, 'Hide sidebar')
        $state.SidebarToggle.ToolTip = 'Hide command library (Ctrl+B)'
    }
    Update-ToolkitGuiSpecificationWidth
}

function Update-ToolkitGuiLayout {
    $state = $script:ToolkitGui
    if ($null -eq $state -or $null -eq $state.Workspace) { return }
    $width = $state.Window.ActualWidth
    if ($width -le 0) { $width = $state.Window.Width }
    $narrow = $width -lt 780
    if ($narrow) { $state.Workspace.Margin = '12,10,12,8' }
    else { $state.Workspace.Margin = '22,16,22,10' }
    $available = $state.Workspace.ActualWidth
    if ($available -le 0) {
        $rail = 296; if ($state.SidebarCollapsed) { $rail = 0 }
        $available = [Math]::Max(240, $width - $rail - 48)
    }
    $fieldWidth = [Math]::Min(256, [Math]::Max(170, [int]($available - 16)))
    foreach ($name in $state.Fields.Keys) { $state.Fields[$name].Container.Width = $fieldWidth }
    Update-ToolkitGuiSpecificationWidth
}

function Get-ToolkitGuiOrderedCommand {
    param([object[]]$Commands)
    $list = @($Commands)
    $indexed = for ($i = 0; $i -lt $list.Count; $i++) {
        $cmd = $list[$i]
        $pin = 1; if ($cmd.id -eq 'system.full-specs') { $pin = 0 }
        $tier = 0
        if ($cmd.risk -eq 'SystemModification') { $tier = 1 }
        elseif ($cmd.risk -eq 'HighRisk') { $tier = 2 }
        [pscustomobject]@{ Pin = $pin; Tier = $tier; Order = $i; Command = $cmd }
    }
    return @($indexed | Sort-Object Pin,Tier,Order | ForEach-Object { $_.Command })
}

function Update-ToolkitGuiCatalog {
    $state = $script:ToolkitGui
    $state.Tree.Items.Clear()
    Clear-ToolkitGuiSelection
    $catalog = @(Get-ToolkitCatalog -IncludeCustom)
    $query = $state.Search.Text.Trim()
    if ($null -ne $state.SearchPlaceholder) {
        $state.SearchPlaceholder.Visibility = 'Collapsed'; if (-not $state.Search.Text.Length) { $state.SearchPlaceholder.Visibility = 'Visible' }
    }
    if ($null -ne $state.ClearSearch) {
        $state.ClearSearch.Visibility = 'Collapsed'; if ($state.Search.Text.Length -gt 0) { $state.ClearSearch.Visibility = 'Visible' }
    }
    $commands = @(Find-ToolkitCommand $catalog $query)
    if ($query) {
        foreach ($command in $commands) {
            $item = New-Object System.Windows.Controls.TreeViewItem
            $item.Header = $command.name; $item.Tag = $command
            $item.ToolTip = $command.description
            if ($command.risk -eq 'SystemModification') { $item.Uid = 'MOD' }
            elseif ($command.risk -eq 'HighRisk') { $item.Uid = 'HIGH' }
            [System.Windows.Automation.AutomationProperties]::SetName($item, $command.name)
            [void]$state.Tree.Items.Add($item)
        }
    }
    else {
        $byCategory = @{}
        foreach ($command in $commands) {
            if (-not $byCategory.ContainsKey($command.category)) {
                $byCategory[$command.category] = New-Object 'Collections.Generic.List[object]'
            }
            $byCategory[$command.category].Add($command)
        }
        $preferred = @(
            'System Information',
            'Hardware Diagnostics',
            'Storage Management',
            'Networking',
            'Processes and Services',
            'Troubleshooting',
            'Windows Repair and Maintenance',
            'Security and Administration',
            'Power and Scheduling'
        )
        $orderedCategories = New-Object 'Collections.Generic.List[string]'
        foreach ($name in $preferred) {
            if ($byCategory.ContainsKey($name)) { $orderedCategories.Add($name) }
        }
        foreach ($name in $byCategory.Keys) {
            if ($name -ne 'Custom Scripts' -and $name -notin $preferred) { $orderedCategories.Add($name) }
        }
        $orderedCategories.Add('Custom Scripts')
        $sectionTags = @{
            'System Information' = 'GRP_INSPECT'
            'Troubleshooting' = 'GRP_REPAIR'
            'Security and Administration' = 'GRP_CONTROL'
            'Custom Scripts' = 'GRP_CUSTOM'
        }
        foreach ($categoryName in $orderedCategories) {
            $category = New-Object System.Windows.Controls.TreeViewItem
            $category.Header = $categoryName
            $category.IsExpanded = $false
            if ($sectionTags.ContainsKey($categoryName)) { $category.Uid = $sectionTags[$categoryName] }
            if ($categoryName -eq 'Custom Scripts' -and -not $byCategory.ContainsKey('Custom Scripts')) {
                $category.ToolTip = 'No local scripts. Put PS1, BAT or CMD files in the Scripts folder beside the toolkit, then refresh.'
            }
            if ($byCategory.ContainsKey($categoryName)) {
                foreach ($command in (Get-ToolkitGuiOrderedCommand $byCategory[$categoryName].ToArray())) {
                    $item = New-Object System.Windows.Controls.TreeViewItem
                    $item.Header = $command.name; $item.Tag = $command
                    $item.ToolTip = $command.description
                    if ($command.risk -eq 'SystemModification') { $item.Uid = 'MOD' }
                    elseif ($command.risk -eq 'HighRisk') { $item.Uid = 'HIGH' }
                    [System.Windows.Automation.AutomationProperties]::SetName($item, $command.name)
                    [void]$category.Items.Add($item)
                }
            }
            $category.Add_MouseLeftButtonUp({
                param($uiSender, $mouseEvent)
                if (-not $uiSender.HasItems) { return }
                $node = $mouseEvent.OriginalSource -as [System.Windows.DependencyObject]
                while ($null -ne $node -and $node -ne $uiSender) {
                    if ($node -is [System.Windows.Controls.Primitives.ToggleButton]) { return }
                    if ($node -is [System.Windows.Controls.TreeViewItem]) { return }
                    if ($node -is [System.Windows.Media.Visual] -or $node -is [System.Windows.Media.Media3D.Visual3D]) {
                        $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
                    }
                    else { $node = [System.Windows.LogicalTreeHelper]::GetParent($node) }
                }
                if ($node -eq $uiSender) {
                    $uiSender.IsExpanded = -not $uiSender.IsExpanded
                    $mouseEvent.Handled = $true
                }
            })
            [void]$state.Tree.Items.Add($category)
        }
    }
    $state.CatalogCount.Text = "$($commands.Count) commands"
    if (-not $commands.Count) { Set-ToolkitGuiStatus 'No matching commands. Clear the search to see the library.' }
}

function Select-ToolkitGuiCommandById {
    param([string]$Id)
    $state = $script:ToolkitGui
    if ([string]::IsNullOrWhiteSpace($Id) -or $null -ne $state.Worker -or $null -ne $state.External) { return }
    if ($state.Search.Text.Length -gt 0) { $state.Search.Text = '' }
    foreach ($node in $state.Tree.Items) {
        if ($null -ne $node.Tag -and $node.Tag.id -eq $Id) {
            $node.IsSelected = $true
            $node.BringIntoView()
            return
        }
        foreach ($child in $node.Items) {
            if ($null -ne $child.Tag -and $child.Tag.id -eq $Id) {
                $node.IsExpanded = $true
                $child.IsSelected = $true
                $child.BringIntoView()
                return
            }
        }
    }
}

function Clear-ToolkitGuiSelection {
    param([string]$Title = 'Choose a command')
    $state = $script:ToolkitGui
    $state.Command = $null; $state.CanRun = $false; $state.Fields = @{}
    $state.SpecBlocks = @(); $state.Output.Clear(); $state.OutputCharacters = 0; $state.OutputTruncated = $false
    $state.Parameters.Children.Clear()
    $state.ParametersSection.Visibility = 'Collapsed'
    $state.Heading.Text = $Title
    $state.CommandId.Text = ''; $state.CommandId.Visibility = 'Collapsed'
    $categoryDescriptions = @{
        'System Information' = 'Operating system, hardware summary, drivers, installed apps, activation and power plans.'
        'Hardware Diagnostics' = 'CPU, memory, GPU, board, BIOS, disks, USB devices, displays and TPM status.'
        'Storage Management' = 'Disk partitions, volumes, free space, large-file scan, file checksums and shares.'
        'Networking' = 'IP configuration, connectivity tests, DNS, ports, Wi-Fi, hosts, proxy and DHCP.'
        'Processes and Services' = 'Running processes, top CPU/RAM consumers, services, startup items and scheduled tasks.'
        'Troubleshooting' = 'Event logs, problem devices, battery health, Windows Update, BSOD dumps and printers.'
        'Windows Repair and Maintenance' = 'SFC, DISM, CHKDSK, Winsock/TCP-IP reset, spooler/cache cleanup and update policy.'
        'Security and Administration' = 'Defender, Firewall, local accounts, administrators, certificates and system tools.'
        'Power and Scheduling' = 'Scheduled shutdown or restart countdowns, status, cancellation and force restart.'
        'Custom Scripts' = 'Local PowerShell and batch scripts loaded from the Scripts folder beside the toolkit.'
    }
    $state.Description.Text = 'Browse the library or search for a diagnostic.'
    if ($categoryDescriptions.ContainsKey($Title)) { $state.Description.Text = $categoryDescriptions[$Title] }
    $state.Metadata.Text = ''
    $state.MetadataTags.Children.Clear(); $state.MetadataTags.Visibility = 'Collapsed'
    $state.Consequences.Text = ''; $state.ConsequenceBox.Visibility = 'Collapsed'
    $state.RunAdmin.Visibility = 'Collapsed'; $state.SpecScroll.Visibility = 'Collapsed'
    $state.ResultText.Text = 'Choose a command and select Run to see results.'
    if ($Title -eq 'Custom Scripts' -and -not $script:ToolkitCustomCommands.Count) {
        $state.WelcomePanel.Visibility = 'Collapsed'
        $state.ResultText.Visibility = 'Visible'
        $state.ViewportTitle.Text = 'CUSTOM SCRIPTS'
        $state.ResultText.Text = 'No local scripts. Put PS1, BAT or CMD files in the Scripts folder beside Toolkit.ps1, then select Refresh scripts.'
    }
    else {
        $state.WelcomePanel.Visibility = 'Visible'
        $state.ResultText.Visibility = 'Collapsed'
        $state.ViewportTitle.Text = 'WORKBENCH'
    }
    Set-ToolkitGuiStatus 'Ready'
    Update-ToolkitGuiAvailability
}

function Update-ToolkitGuiParameterVisibility {
    $state = $script:ToolkitGui
    if ($null -eq $state.Command) { return }
    $values = @{}
    foreach ($name in $state.Fields.Keys) { $values[$name] = $state.Fields[$name].Control.Text }
    $visible = @(Get-ToolkitGuiVisibleParameter $state.Command $values)
    foreach ($name in $state.Fields.Keys) {
        $state.Fields[$name].Container.Visibility = 'Collapsed'
        if ($name -in @($visible.name)) { $state.Fields[$name].Container.Visibility = 'Visible' }
    }
}

function Show-ToolkitGuiCommand {
    param([object]$Command)
    $state = $script:ToolkitGui
    if ($null -eq $Command -or $null -ne $state.Worker -or $null -ne $state.External) { return }
    $state.Command = $Command; $state.Fields = @{}
    $state.SpecBlocks = @(); $state.Output.Clear(); $state.OutputCharacters = 0; $state.OutputTruncated = $false
    $state.Parameters.Children.Clear()
    $state.Heading.Text = $Command.name
    $state.CommandId.Text = $Command.id; $state.CommandId.Visibility = 'Visible'
    $state.Description.Text = ConvertTo-ToolkitSafeText $Command.description
    $state.Metadata.Text = "Risk: $($Command.risk) | Administrator required: $($Command.requiresAdmin) | Cost: $($Command.cost)"

    $state.MetadataTags.Children.Clear(); $state.MetadataTags.Visibility = 'Visible'
    if ($Command.risk -eq 'ReadOnly') { [void]$state.MetadataTags.Children.Add((New-ToolkitGuiTag 'Read-only' 'Success' 'SuccessBg')) }
    elseif ($Command.risk -eq 'SystemModification') { [void]$state.MetadataTags.Children.Add((New-ToolkitGuiTag 'Modifies system' 'Warning' 'WarningBg')) }
    else { [void]$state.MetadataTags.Children.Add((New-ToolkitGuiTag 'High risk' 'Danger' 'DangerBg')) }

    if ($Command.requiresAdmin) { [void]$state.MetadataTags.Children.Add((New-ToolkitGuiTag 'Admin required' 'Warning' 'WarningBg')) }
    else { [void]$state.MetadataTags.Children.Add((New-ToolkitGuiTag 'Standard user' 'Muted' 'Raised')) }

    [void]$state.MetadataTags.Children.Add((New-ToolkitGuiTag ("Cost: $($Command.cost)") 'Muted' 'Raised'))

    $route = Get-ToolkitGuiExecutionRoute $Command
    if ($route -eq 'Console') { [void]$state.MetadataTags.Children.Add((New-ToolkitGuiTag 'Separate console' 'Warning' 'WarningBg')) }
    else { [void]$state.MetadataTags.Children.Add((New-ToolkitGuiTag 'In-window' 'Muted' 'Raised')) }

    $consequenceText = ConvertTo-ToolkitSafeText $Command.consequences
    if ($route -eq 'Console') { $consequenceText += "`nOpens a separate operation console for prompts and results." }
    $state.Consequences.Text = $consequenceText
    $state.ConsequenceBox.Visibility = 'Visible'
    if ($Command.risk -eq 'HighRisk') {
        $state.ConsequenceBox.BorderThickness = '2,0,0,0'
        $state.ConsequenceBox.Padding = '10,6'
        $state.ConsequenceBox.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'Danger')
        $state.ConsequenceBox.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'DangerBg')
        $state.Consequences.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Text')
    }
    elseif ($route -eq 'Console') {
        $state.ConsequenceBox.BorderThickness = '2,0,0,0'
        $state.ConsequenceBox.Padding = '10,6'
        $state.ConsequenceBox.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'Warning')
        $state.ConsequenceBox.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'WarningBg')
        $state.Consequences.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Text')
    }
    else {
        $state.ConsequenceBox.BorderThickness = '0'
        $state.ConsequenceBox.Padding = '0'
        $state.ConsequenceBox.Background = [System.Windows.Media.Brushes]::Transparent
        $state.Consequences.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Muted')
    }

    foreach ($definition in $Command.parameters) {
        $container = New-Object System.Windows.Controls.StackPanel
        $container.Width = 256; $container.Margin = '0,0,14,10'
        $label = New-Object System.Windows.Controls.Label
        $labelText = New-Object System.Windows.Controls.TextBlock
        $labelText.Text = $definition.label; $labelText.TextWrapping = 'Wrap'; $labelText.FontSize = 12.5
        $label.Content = $labelText; $label.Padding = '0,0,0,4'
        if ($definition.type -eq 'Choice') {
            $inputControl = New-Object System.Windows.Controls.ComboBox
            foreach ($value in $definition.allowedValues) { [void]$inputControl.Items.Add([string]$value) }
            if ($null -ne $definition.default) { $inputControl.SelectedItem = [string]$definition.default }
            $inputControl.Add_SelectionChanged({ Update-ToolkitGuiParameterVisibility })
        }
        else {
            $inputControl = New-Object System.Windows.Controls.TextBox
            if ($null -ne $definition.default) { $inputControl.Text = [string]$definition.default }
        }
        $label.Target = $inputControl
        [System.Windows.Automation.AutomationProperties]::SetName($inputControl, $definition.label)
        $inputControl.MinHeight = 32
        $hint = 'Optional'; if ($definition.required) { $hint = 'Required' }
        if ($definition.type -eq 'Integer') { $hint += " | $($definition.minimum) to $($definition.maximum)" }
        $inputControl.ToolTip = "Type: $($definition.type); $hint"
        $hintText = New-Object System.Windows.Controls.TextBlock
        $hintText.Text = $hint; $hintText.FontSize = 11; $hintText.Margin = '0,3,0,0'
        $hintText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Muted')
        [void]$container.Children.Add($label); [void]$container.Children.Add($inputControl); [void]$container.Children.Add($hintText)
        [void]$state.Parameters.Children.Add($container)
        $state.Fields[$definition.name] = @{ Control = $inputControl; Container = $container }
    }
    if (@($Command.parameters).Count -gt 0) { $state.ParametersSection.Visibility = 'Visible' }
    else { $state.ParametersSection.Visibility = 'Collapsed' }
    Update-ToolkitGuiParameterVisibility
    Update-ToolkitGuiLayout

    $capability = Get-ToolkitCapability $Command
    $state.CanRun = $capability.Available
    $state.RunAdmin.Visibility = 'Collapsed'
    if ($Command.sourceKind -eq 'CustomScript' -and -not $Command.requiresAdmin) { $state.RunAdmin.Visibility = 'Visible' }
    $state.WelcomePanel.Visibility = 'Collapsed'
    $state.SpecScroll.Visibility = 'Collapsed'
    $state.ResultText.Visibility = 'Visible'
    $state.ViewportTitle.Text = "READY | $($Command.id)"
    $state.ResultText.Text = 'Select Run to view results.'
    if (-not $capability.Available) { $state.ResultText.Text = 'Unavailable: ' + $capability.Reason; Set-ToolkitGuiStatus $state.ResultText.Text 'Danger' }
    else { Set-ToolkitGuiStatus 'Ready' }
    Update-ToolkitGuiAvailability
}

function Update-ToolkitGuiSpecificationWidth {
    $state = $script:ToolkitGui
    if ($null -eq $state -or $null -eq $state.SpecScroll) { return }
    $width = [Math]::Max(1, $state.SpecScroll.ActualWidth - 20)
    $count = [Math]::Max(1, [int][Math]::Floor($width / 285))
    $cardWidth = [Math]::Max(1, [int][Math]::Floor($width / $count) - 10)
    foreach ($child in $state.SpecWrap.Children) { $child.Width = $cardWidth }
}

function Show-ToolkitGuiSpecification {
    param([object[]]$Records)
    $state = $script:ToolkitGui
    $state.SpecWrap.Children.Clear()
    $blocks = @(Get-ToolkitSpecificationBlock $Records)
    if ($state.Output.Count) { $blocks += [pscustomobject]@{ Title = 'Execution details'; Lines = $state.Output.ToArray() } }
    $state.SpecBlocks = $blocks
    if (-not $blocks.Count) { $state.ResultText.Text = 'No specification data was reported.'; Update-ToolkitGuiCopyState; return }
    foreach ($block in $blocks) {
        $card = New-Object System.Windows.Controls.Border
        $card.CornerRadius = [System.Windows.CornerRadius]::new(5)
        $card.BorderThickness = '1'
        $card.Padding = '12,10'
        $card.Margin = '0,0,10,10'
        $card.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'Surface')
        $card.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'Divider')
        $panel = New-Object System.Windows.Controls.StackPanel
        $title = New-Object System.Windows.Controls.TextBlock
        $title.Text = $block.Title; $title.FontWeight = 'SemiBold'; $title.FontSize = 14; $title.Margin = '0,0,0,6'
        $title.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Accent')
        $body = New-Object System.Windows.Controls.TextBox
        $body.Text = $block.Lines -join "`r`n"; $body.IsReadOnly = $true; $body.TextWrapping = 'Wrap'
        $body.FontFamily = New-Object System.Windows.Media.FontFamily('Cascadia Mono, Consolas')
        $body.FontSize = 12.5
        $body.BorderThickness = 0; $body.Padding = 0; $body.Background = [System.Windows.Media.Brushes]::Transparent
        $body.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'Text')
        [System.Windows.Automation.AutomationProperties]::SetName($body, $block.Title + ' specifications')
        [void]$panel.Children.Add($title); [void]$panel.Children.Add($body)
        $card.Child = $panel
        [void]$state.SpecWrap.Children.Add($card)
    }
    $state.WelcomePanel.Visibility = 'Collapsed'
    $state.ResultText.Visibility = 'Collapsed'; $state.SpecScroll.Visibility = 'Visible'
    $state.ViewportTitle.Text = "SPECIFICATIONS | $($blocks.Count) blocks"
    Update-ToolkitGuiSpecificationWidth
    Update-ToolkitGuiCopyState
}

function Get-ToolkitGuiCopyText {
    $state = $script:ToolkitGui
    if ($state.SpecScroll.Visibility -eq 'Visible' -and $state.SpecBlocks.Count -gt 0) {
        $sections = foreach ($block in $state.SpecBlocks) { "[$($block.Title)]`r`n" + ($block.Lines -join "`r`n") }
        return ($sections -join "`r`n`r`n")
    }
    if ($state.ResultText.Visibility -eq 'Visible') { return $state.ResultText.Text }
    return ''
}

function Copy-ToolkitGuiOutput {
    $state = $script:ToolkitGui
    $text = Get-ToolkitGuiCopyText
    if ([string]::IsNullOrEmpty($text)) { return }
    try {
        [System.Windows.Clipboard]::SetText($text)
        $state.CopyButton.Content = 'Copied'
        Set-ToolkitGuiStatus 'Output copied to clipboard.' 'Success'
    }
    catch { Set-ToolkitGuiStatus ('Clipboard copy failed: ' + $_.Exception.Message) 'Danger' }
}

function Add-ToolkitGuiOutput {
    param([string]$Text)
    $state = $script:ToolkitGui
    foreach ($part in ($Text -split "`r?`n")) {
        $safe = ConvertTo-ToolkitSafeText $part
        $state.Output.Enqueue($safe); $state.OutputCharacters += $safe.Length
        while ($state.Output.Count -gt 2000 -or $state.OutputCharacters -gt 1048576) {
            $state.OutputCharacters -= $state.Output.Dequeue().Length; $state.OutputTruncated = $true
        }
    }
}

function Start-ToolkitGuiOperation {
    param([switch]$Elevated)
    $state = $script:ToolkitGui
    if ($null -eq $state.Command -or $null -ne $state.Worker -or $null -ne $state.External) { return }
    try {
        $capability = Get-ToolkitCapability $state.Command
        if (-not $capability.Available) { throw $capability.Reason }
        $raw = @{}
        foreach ($name in $state.Fields.Keys) { $raw[$name] = $state.Fields[$name].Control.Text }
        $values = ConvertTo-ToolkitGuiParameterMap $state.Command $raw
        $state.SpecBlocks = @()
        $state.Output.Clear(); $state.OutputCharacters = 0; $state.OutputTruncated = $false; $state.Stopping = $false
        $state.WelcomePanel.Visibility = 'Collapsed'
        $state.SpecScroll.Visibility = 'Collapsed'; $state.ResultText.Visibility = 'Visible'
        $state.ResultText.Text = 'Running...'
        if ((Get-ToolkitGuiExecutionRoute $state.Command -Elevated:$Elevated) -eq 'Console') {
            $state.External = Start-ToolkitConsole $state.Command.id $values -Elevated:($state.Command.requiresAdmin -or $Elevated) -SkipActionConfirmation:($script:ToolkitConfirmActions -eq $false)
            $state.ViewportTitle.Text = "CONSOLE | $($state.Command.id)"
            $state.ResultText.Text = 'Operation console is open. Complete its prompts and review the results there. Closing this GUI leaves that console running.'
            Set-ToolkitGuiStatus 'Waiting for the operation console to close.' 'Accent'
        }
        else {
            $state.Worker = Start-ToolkitExecution $state.Command $values
            $state.ViewportTitle.Text = "OUTPUT | $($state.Command.id)"
            if ($state.Command.id -eq 'system.full-specs') { $state.ResultText.Text = 'Collecting selected specification data...' }
            Set-ToolkitGuiStatus 'Running... 0.0s' 'Accent'
        }
        Update-ToolkitGuiAvailability
        $state.Timer.Start()
    }
    catch { $state.ResultText.Text = 'Operation not started: ' + $_.Exception.Message; Set-ToolkitGuiStatus $state.ResultText.Text 'Danger' }
}

function Stop-ToolkitGuiOperation {
    if ($null -eq $script:ToolkitGui.Worker -or $script:ToolkitGui.Stopping) { return }
    $script:ToolkitGui.Stopping = $true
    Stop-ToolkitExecution $script:ToolkitGui.Worker
    $script:ToolkitGui.Cancel.IsEnabled = $false
    Set-ToolkitGuiStatus 'Cancelling; waiting for the diagnostic to stop...' 'Warning'
}

function Update-ToolkitGuiOperation {
    $state = $script:ToolkitGui
    if ($null -ne $state.External) {
        if (-not $state.External.HasExited) { return }
        $code = $state.External.ExitCode; $state.External.Dispose(); $state.External = $null
        $state.Timer.Stop()
        $state.ResultText.Text = "Operation console closed (exit code $code). Detailed results were shown there. An exit code does not verify a repair."
        Set-ToolkitGuiStatus $state.ResultText.Text
        Update-ToolkitGuiAvailability
        return
    }
    if ($null -eq $state.Worker) { $state.Timer.Stop(); return }
    $line = ''; $changed = $false
    while ($state.Worker.Queue.TryTake([ref]$line)) { Add-ToolkitGuiOutput $line; $changed = $true }
    if ($changed) { $state.ResultText.Text = $state.Output.ToArray() -join "`r`n" }
    if (-not $state.Worker.Handle.IsCompleted) {
        $elapsedSeconds = [Math]::Round(([DateTime]::UtcNow - $state.Worker.Started).TotalSeconds, 1)
        if (-not $state.Stopping) { Set-ToolkitGuiStatus ("Running... {0:0.0}s" -f $elapsedSeconds) 'Accent' }
        $limit = 60; if ($state.Command.id -eq 'system.full-specs') { $limit = 180 }
        if ($state.Command.id -ne 'storage.hash' -and -not $state.Worker.DeadlineExceeded -and $elapsedSeconds -gt $limit) {
            Stop-ToolkitExecution $state.Worker -TimedOut; $state.Stopping = $true
            $state.Cancel.IsEnabled = $false; Set-ToolkitGuiStatus 'Time limit reached; waiting for the diagnostic to stop...' 'Warning'
        }
        return
    }
    while ($state.Worker.Queue.TryTake([ref]$line)) { Add-ToolkitGuiOutput $line; $changed = $true }
    if ($changed) { $state.ResultText.Text = $state.Output.ToArray() -join "`r`n" }
    $result = Complete-ToolkitExecution $state.Worker; $state.Worker = $null
    $state.Timer.Stop()
    if ($state.Command.id -eq 'system.full-specs') { Show-ToolkitGuiSpecification $result.Specifications }
    elseif (-not $state.Output.Count) { $state.ResultText.Text = 'The diagnostic returned no output.' }
    $status = "$($result.Status) | $([Math]::Round($result.Elapsed.TotalSeconds, 2)) seconds"
    if ($result.Truncated -or $state.OutputTruncated) { $status += ' | Output truncated' }
    $role = 'Muted'; if ($result.Status -eq 'Succeeded') { $role = 'Success' }
    elseif ($result.Status -in @('Failed','PermissionDenied','TimedOut')) { $role = 'Danger' }
    elseif ($result.Status -eq 'Cancelled') { $role = 'Warning' }
    Set-ToolkitGuiStatus $status $role
    Update-ToolkitGuiAvailability
    if ($state.ClosePending) { $state.Window.Close() }
}

function New-ToolkitGuiSettingWindow {
    $state = $script:ToolkitGui
    $dialog = New-Object System.Windows.Window
    $dialog.Title = 'Action confirmations'; $dialog.Width = 520
    if ($state.Window.IsVisible) { $dialog.Owner = $state.Window }
    $dialog.FontFamily = 'Segoe UI'; $dialog.FontSize = 14
    $dialog.MaxHeight = [Math]::Max(1, [System.Windows.SystemParameters]::WorkArea.Height - 24)
    $dialog.Width = [Math]::Min(520, [Math]::Max(1, [System.Windows.SystemParameters]::WorkArea.Width - 24))
    $dialog.SizeToContent = 'Height'; $dialog.ResizeMode = 'NoResize'; $dialog.WindowStartupLocation = 'CenterOwner'
    $dialog.Resources.MergedDictionaries.Add($state.Window.Resources)
    $dialog.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'Background')
    $dialog.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'Text')
    $dialog.Add_SourceInitialized({ Set-ToolkitGuiWindowChrome $this })

    $panel = New-Object System.Windows.Controls.StackPanel; $panel.Margin = 20
    $header = New-Object System.Windows.Controls.DockPanel; $header.Margin = '0,0,0,14'
    $statusBadge = New-Object System.Windows.Controls.Border
    $statusBadge.CornerRadius = [System.Windows.CornerRadius]::new(4); $statusBadge.Padding = '8,3'
    [System.Windows.Controls.DockPanel]::SetDock($statusBadge, 'Right')
    $statusLabel = New-Object System.Windows.Controls.TextBlock; $statusLabel.FontSize = 11.5; $statusLabel.FontWeight = 'SemiBold'
    $statusBadge.Child = $statusLabel
    $heading = New-Object System.Windows.Controls.TextBlock
    $heading.Text = 'Session safety settings'; $heading.FontSize = 18; $heading.FontWeight = 'SemiBold'; $heading.VerticalAlignment = 'Center'
    [void]$header.Children.Add($statusBadge); [void]$header.Children.Add($heading)

    $callout = New-Object System.Windows.Controls.Border
    $callout.CornerRadius = [System.Windows.CornerRadius]::new(5); $callout.BorderThickness = '2,0,0,0'; $callout.Padding = '12,10'; $callout.Margin = '0,0,0,14'
    $message = New-Object System.Windows.Controls.TextBlock; $message.TextWrapping = 'Wrap'; $message.FontSize = 13.5
    $message.Text = 'Confirmations apply to modifying commands, high-risk commands and custom scripts. This setting lasts for this session only.'
    $callout.Child = $message

    $stepNotice = New-Object System.Windows.Controls.TextBlock
    $stepNotice.TextWrapping = 'Wrap'; $stepNotice.FontSize = 12.5; $stepNotice.Margin = '0,0,0,12'; $stepNotice.Visibility = 'Collapsed'
    $stepNotice.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Danger')

    $actions = New-Object System.Windows.Controls.StackPanel; $actions.Orientation = 'Horizontal'
    $button = New-Object System.Windows.Controls.Button; $button.Content = 'Enable confirmations'; $button.Margin = '0,0,10,0'
    $button.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'PrimaryButtonStyle')
    if ($script:ToolkitConfirmActions) {
        $statusLabel.Text = 'Confirmations: ON'
        $statusLabel.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Success')
        $statusBadge.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'SuccessBg')
        $callout.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'Danger')
        $callout.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'DangerBg')
        $message.Text = "Disabling confirmations skips yes and typed-command prompts for ALL modifying commands, high-risk commands and custom scripts. Run may immediately delete files, disable protection, alter updates or force a restart. Unsaved work can be lost.`n`nUAC, permission checks, recovery preflight and scripts' own prompts still apply. This lasts for the current session only.`n`nSelect Disable confirmations twice to turn off confirmations for this session."
        $button.ClearValue([System.Windows.FrameworkElement]::StyleProperty)
        $button.Content = 'Disable confirmations (1/2)'
    }
    else {
        $statusLabel.Text = 'Confirmations: OFF'
        $statusLabel.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Danger')
        $statusBadge.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'DangerBg')
        $callout.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'Accent')
        $callout.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'Surface')
    }
    $button.Tag = @{ Dialog = $dialog; Notice = $stepNotice; Step = 1 }
    $button.Add_Click({
        param($uiSender)
        if ($script:ToolkitConfirmActions -and $uiSender.Tag.Step -lt 2) {
            $uiSender.Tag.Step = 2
            $uiSender.Tag.Notice.Text = 'Are you sure?'
            $uiSender.Tag.Notice.Visibility = 'Visible'
            $uiSender.Content = 'Confirm disable (2/2)'
            $uiSender.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'DangerButtonStyle')
            return
        }
        $script:ToolkitConfirmActions = -not $script:ToolkitConfirmActions
        $uiSender.Tag.Dialog.Close(); Update-ToolkitGuiAvailability
    })
    $close = New-Object System.Windows.Controls.Button; $close.Content = 'Cancel'; $close.IsCancel = $true
    $close.Tag = $dialog
    $close.Add_Click({ param($uiSender) $uiSender.Tag.Close() })
    [void]$actions.Children.Add($button); [void]$actions.Children.Add($close)
    foreach ($control in @($header,$callout,$stepNotice,$actions)) { [void]$panel.Children.Add($control) }
    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.HorizontalScrollBarVisibility = 'Disabled'; $scroll.Content = $panel
    $scroll.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'Background')
    $dialog.Content = $scroll
    $dialog.Tag = @{ Toggle = $button; Notice = $stepNotice; Warning = $message }
    return $dialog
}

function Show-ToolkitGuiSetting {
    $dialog = New-ToolkitGuiSettingWindow
    [void]$dialog.ShowDialog()
}

function Start-ToolkitGuiTerminal {
    $cliExe = Join-Path $script:ToolkitRoot 'Toolkit.CLI.exe'
    $start = @{ WorkingDirectory = $script:ToolkitRoot; ErrorAction = 'Stop' }
    if (Test-Path -LiteralPath $cliExe -PathType Leaf) {
        $start.FilePath = $cliExe
    }
    else {
        $start.FilePath = Get-ToolkitPowerShellPath
        $start.ArgumentList = (@('-NoLogo','-NoProfile','-STA','-File',$script:ToolkitEntryPath,'-AppRoot',$script:ToolkitRoot) | ForEach-Object { ConvertTo-ToolkitArgument $_ }) -join ' '
    }
    try {
        [void](Start-Process @start)
        Set-ToolkitGuiStatus 'Terminal interface opened in a separate console window.' 'Muted'
    }
    catch {
        Set-ToolkitGuiStatus ('Could not start terminal interface: ' + $_.Exception.Message) 'Danger'
    }
}

function New-ToolkitGuiImportWindow {
    $state = $script:ToolkitGui
    $dialog = New-Object System.Windows.Window
    $dialog.Title = 'Import script'; $dialog.Width = 580
    if ($state.Window.IsVisible) { $dialog.Owner = $state.Window }
    $dialog.FontFamily = 'Segoe UI'; $dialog.FontSize = 13.5
    $dialog.MaxHeight = [Math]::Max(1, [System.Windows.SystemParameters]::WorkArea.Height - 24)
    $dialog.Width = [Math]::Min(580, [Math]::Max(1, [System.Windows.SystemParameters]::WorkArea.Width - 24))
    $dialog.SizeToContent = 'Height'; $dialog.ResizeMode = 'NoResize'; $dialog.WindowStartupLocation = 'CenterOwner'
    $dialog.Resources.MergedDictionaries.Add($state.Window.Resources)
    $dialog.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'Background')
    $dialog.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'Text')
    $dialog.Add_SourceInitialized({ Set-ToolkitGuiWindowChrome $this })

    $panel = New-Object System.Windows.Controls.StackPanel; $panel.Margin = 20
    $heading = New-Object System.Windows.Controls.TextBlock
    $heading.Text = 'Import script into Scripts'; $heading.FontSize = 18; $heading.FontWeight = 'SemiBold'; $heading.Margin = '0,0,0,4'
    $subtitle = New-Object System.Windows.Controls.TextBlock
    $subtitle.Text = 'Imported scripts stay portable beside the executable and are never executed automatically.'
    $subtitle.TextWrapping = 'Wrap'; $subtitle.FontSize = 12.5; $subtitle.Margin = '0,0,0,14'
    $subtitle.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Muted')

    $modeLabel = New-Object System.Windows.Controls.Label; $modeLabel.Content = 'Import source'; $modeLabel.Padding = '0,0,0,4'
    $mode = New-Object System.Windows.Controls.ComboBox; $mode.Margin = '0,0,0,10'; $mode.MinHeight = 32
    foreach ($opt in @('Local file or ZIP','HTTPS script URL','Published manifest URL')) { [void]$mode.Items.Add($opt) }
    $mode.SelectedIndex = 0
    $modeLabel.Target = $mode
    [System.Windows.Automation.AutomationProperties]::SetName($mode, 'Import source mode')

    $sourceLabel = New-Object System.Windows.Controls.Label; $sourceLabel.Content = 'File path (.ps1, .bat, .cmd, .zip)'; $sourceLabel.Padding = '0,0,0,4'
    $sourceRow = New-Object System.Windows.Controls.DockPanel; $sourceRow.Margin = '0,0,0,10'
    $browse = New-Object System.Windows.Controls.Button; $browse.Content = 'Browse'; $browse.Margin = '8,0,0,0'; $browse.MinWidth = 84
    [System.Windows.Controls.DockPanel]::SetDock($browse, 'Right')
    $loadManifest = New-Object System.Windows.Controls.Button; $loadManifest.Content = 'Load catalog'; $loadManifest.Margin = '8,0,0,0'; $loadManifest.MinWidth = 104; $loadManifest.Visibility = 'Collapsed'
    [System.Windows.Controls.DockPanel]::SetDock($loadManifest, 'Right')
    $source = New-Object System.Windows.Controls.TextBox; $source.MinHeight = 32
    $sourceLabel.Target = $source
    [System.Windows.Automation.AutomationProperties]::SetName($source, 'Script file path or HTTPS URL')
    [void]$sourceRow.Children.Add($browse); [void]$sourceRow.Children.Add($loadManifest); [void]$sourceRow.Children.Add($source)

    $singleOptions = New-Object System.Windows.Controls.StackPanel
    $folderLabel = New-Object System.Windows.Controls.Label; $folderLabel.Content = 'Subfolder inside Scripts (optional, e.g. IT-Support or Tinkerer)'; $folderLabel.Padding = '0,0,0,4'
    $folder = New-Object System.Windows.Controls.TextBox; $folder.Margin = '0,0,0,10'; $folder.MinHeight = 32
    $folderLabel.Target = $folder
    [System.Windows.Automation.AutomationProperties]::SetName($folder, 'Target subfolder inside Scripts')

    $shaPanel = New-Object System.Windows.Controls.StackPanel; $shaPanel.Visibility = 'Collapsed'
    $shaLabel = New-Object System.Windows.Controls.Label; $shaLabel.Content = 'Expected SHA-256 checksum (optional 64-hex verification)'; $shaLabel.Padding = '0,0,0,4'
    $shaBox = New-Object System.Windows.Controls.TextBox; $shaBox.Margin = '0,0,0,10'; $shaBox.MinHeight = 32
    $shaBox.FontFamily = New-Object System.Windows.Media.FontFamily('Cascadia Mono, Consolas')
    $shaLabel.Target = $shaBox
    [System.Windows.Automation.AutomationProperties]::SetName($shaBox, 'Expected SHA-256 checksum')
    [void]$shaPanel.Children.Add($shaLabel); [void]$shaPanel.Children.Add($shaBox)

    $nameLabel = New-Object System.Windows.Controls.Label; $nameLabel.Content = 'Display name (optional)'; $nameLabel.Padding = '0,0,0,4'
    $nameBox = New-Object System.Windows.Controls.TextBox; $nameBox.Margin = '0,0,0,10'; $nameBox.MinHeight = 32
    $nameLabel.Target = $nameBox
    [System.Windows.Automation.AutomationProperties]::SetName($nameBox, 'Display name')

    $descLabel = New-Object System.Windows.Controls.Label; $descLabel.Content = 'Description (optional)'; $descLabel.Padding = '0,0,0,4'
    $descBox = New-Object System.Windows.Controls.TextBox; $descBox.Margin = '0,0,0,10'; $descBox.MinHeight = 32
    $descLabel.Target = $descBox
    [System.Windows.Automation.AutomationProperties]::SetName($descBox, 'Description')

    $adminCheck = New-Object System.Windows.Controls.CheckBox; $adminCheck.Content = 'Requires administrator'; $adminCheck.Margin = '0,2,0,8'
    foreach ($ctrl in @($folderLabel,$folder,$shaPanel,$nameLabel,$nameBox,$descLabel,$descBox,$adminCheck)) { [void]$singleOptions.Children.Add($ctrl) }

    $manifestScroll = New-Object System.Windows.Controls.ScrollViewer
    $manifestScroll.MaxHeight = 200; $manifestScroll.VerticalScrollBarVisibility = 'Auto'; $manifestScroll.HorizontalScrollBarVisibility = 'Disabled'
    $manifestScroll.Visibility = 'Collapsed'; $manifestScroll.Margin = '0,0,0,10'
    $manifestBorder = New-Object System.Windows.Controls.Border
    $manifestBorder.CornerRadius = [System.Windows.CornerRadius]::new(5); $manifestBorder.BorderThickness = '1'; $manifestBorder.Padding = '10,8'
    $manifestBorder.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'Surface')
    $manifestBorder.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'Divider')
    $manifestList = New-Object System.Windows.Controls.StackPanel
    $manifestBorder.Child = $manifestList
    $manifestScroll.Content = $manifestBorder

    $overwriteCheck = New-Object System.Windows.Controls.CheckBox; $overwriteCheck.Content = 'Overwrite existing file if name matches'; $overwriteCheck.Margin = '0,2,0,12'
    $statusText = New-Object System.Windows.Controls.TextBlock; $statusText.TextWrapping = 'Wrap'; $statusText.FontSize = 12; $statusText.Margin = '0,0,0,12'; $statusText.Visibility = 'Collapsed'
    $statusText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Danger')

    $actions = New-Object System.Windows.Controls.StackPanel; $actions.Orientation = 'Horizontal'
    $importBtn = New-Object System.Windows.Controls.Button; $importBtn.Content = 'Import'; $importBtn.Margin = '0,0,10,0'; $importBtn.MinWidth = 96
    $importBtn.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'PrimaryButtonStyle')
    $cancelBtn = New-Object System.Windows.Controls.Button; $cancelBtn.Content = 'Cancel'; $cancelBtn.IsCancel = $true
    $cancelBtn.Tag = $dialog
    $cancelBtn.Add_Click({ param($uiSender) $uiSender.Tag.Close() })
    [void]$actions.Children.Add($importBtn); [void]$actions.Children.Add($cancelBtn)

    $ctx = @{
        Dialog = $dialog; Mode = $mode; SourceLabel = $sourceLabel; Source = $source; Browse = $browse; LoadManifest = $loadManifest
        SingleOptions = $singleOptions; Folder = $folder; ShaPanel = $shaPanel; Sha256 = $shaBox
        NameBox = $nameBox; DescBox = $descBox; AdminCheck = $adminCheck; OverwriteCheck = $overwriteCheck
        ManifestScroll = $manifestScroll; ManifestList = $manifestList; Status = $statusText; ImportButton = $importBtn
        ManifestEntries = @()
    }

    $browse.Tag = $ctx
    $browse.Add_Click({
        param($uiSender)
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Title = 'Select script or ZIP pack to import'
        $dlg.Filter = 'Supported scripts and packs (*.ps1;*.bat;*.cmd;*.zip)|*.ps1;*.bat;*.cmd;*.zip|All files (*.*)|*.*'
        if ($dlg.ShowDialog($uiSender.Tag.Dialog)) { $uiSender.Tag.Source.Text = $dlg.FileName }
    })

    $mode.Tag = $ctx
    $mode.Add_SelectionChanged({
        param($uiSender)
        $c = $uiSender.Tag
        $selected = [string]$c.Mode.SelectedItem
        $c.Status.Visibility = 'Collapsed'; $c.Status.Text = ''
        if ($selected -eq 'Local file or ZIP') {
            $c.SourceLabel.Content = 'File path (.ps1, .bat, .cmd, .zip)'
            $c.Browse.Visibility = 'Visible'; $c.LoadManifest.Visibility = 'Collapsed'
            $c.SingleOptions.Visibility = 'Visible'; $c.ShaPanel.Visibility = 'Collapsed'; $c.ManifestScroll.Visibility = 'Collapsed'
            $c.ImportButton.Content = 'Import'
        }
        elseif ($selected -eq 'HTTPS script URL') {
            $c.SourceLabel.Content = 'Published script URL (https://)'
            $c.Browse.Visibility = 'Collapsed'; $c.LoadManifest.Visibility = 'Collapsed'
            $c.SingleOptions.Visibility = 'Visible'; $c.ShaPanel.Visibility = 'Visible'; $c.ManifestScroll.Visibility = 'Collapsed'
            $c.ImportButton.Content = 'Download and import'
        }
        else {
            $c.SourceLabel.Content = 'Published manifest URL (https://.../manifest.json)'
            $c.Browse.Visibility = 'Collapsed'; $c.LoadManifest.Visibility = 'Visible'
            $c.SingleOptions.Visibility = 'Collapsed'; $c.ShaPanel.Visibility = 'Collapsed'; $c.ManifestScroll.Visibility = 'Visible'
            $c.ImportButton.Content = 'Import selected'
        }
    })

    $loadManifest.Tag = $ctx
    $loadManifest.Add_Click({
        param($uiSender)
        $c = $uiSender.Tag
        $c.Status.Visibility = 'Collapsed'; $c.ManifestList.Children.Clear(); $c.ManifestEntries = @()
        try {
            $loaded = Get-ToolkitPublishedManifest -Url $c.Source.Text.Trim()
            $c.ManifestEntries = $loaded.Scripts
            foreach ($entry in $loaded.Scripts) {
                $cb = New-Object System.Windows.Controls.CheckBox
                $folderNote = 'root'; if ($entry.folder) { $folderNote = $entry.folder }
                $adminNote = ''; if ($entry.requiresAdmin) { $adminNote = ' | Admin' }
                $cb.Content = "$($entry.name) [$folderNote/$($entry.fileName)$adminNote]"
                if ($entry.description) { $cb.ToolTip = $entry.description }
                $cb.Tag = $entry; $cb.Margin = '0,3,0,3'; $cb.IsChecked = $true
                [void]$c.ManifestList.Children.Add($cb)
            }
            $c.Status.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Success')
            $c.Status.Text = "Loaded $($loaded.Scripts.Count) verified script entries."
            $c.Status.Visibility = 'Visible'
        }
        catch {
            $c.Status.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Danger')
            $c.Status.Text = $_.Exception.Message; $c.Status.Visibility = 'Visible'
        }
    })

    $importBtn.Tag = $ctx
    $importBtn.Add_Click({
        param($uiSender)
        $c = $uiSender.Tag
        $c.Status.Visibility = 'Collapsed'
        try {
            $selected = [string]$c.Mode.SelectedItem
            $overwrite = [bool]$c.OverwriteCheck.IsChecked
            $imported = @()
            if ($selected -eq 'Local file or ZIP') {
                $imported = @(Import-ToolkitLocalScript -Path $c.Source.Text.Trim() -Folder $c.Folder.Text.Trim() -Name $c.NameBox.Text.Trim() -Description $c.DescBox.Text.Trim() -RequiresAdmin:([bool]$c.AdminCheck.IsChecked) -Overwrite:$overwrite)
            }
            elseif ($selected -eq 'HTTPS script URL') {
                $imported = @(Import-ToolkitUrlScript -Url $c.Source.Text.Trim() -Folder $c.Folder.Text.Trim() -ExpectedSha256 $c.Sha256.Text.Trim() -Name $c.NameBox.Text.Trim() -Description $c.DescBox.Text.Trim() -RequiresAdmin:([bool]$c.AdminCheck.IsChecked) -Overwrite:$overwrite)
            }
            else {
                $checked = @($c.ManifestList.Children | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
                $imported = @(Import-ToolkitManifestScript -Entries $checked -Overwrite:$overwrite)
            }
            Update-ToolkitCustomCatalog
            Update-ToolkitGuiCatalog
            Set-ToolkitGuiStatus ("Imported $($imported.Count) script(s) into Scripts.") 'Success'
            $c.Dialog.Close()
        }
        catch {
            $c.Status.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Danger')
            $c.Status.Text = $_.Exception.Message; $c.Status.Visibility = 'Visible'
        }
    })

    foreach ($control in @($heading,$subtitle,$modeLabel,$mode,$sourceLabel,$sourceRow,$singleOptions,$manifestScroll,$overwriteCheck,$statusText,$actions)) {
        [void]$panel.Children.Add($control)
    }
    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.HorizontalScrollBarVisibility = 'Disabled'; $scroll.Content = $panel
    $scroll.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'Background')
    $dialog.Content = $scroll
    $dialog.Tag = $ctx
    return $dialog
}

function Show-ToolkitGuiImport {
    $dialog = New-ToolkitGuiImportWindow
    [void]$dialog.ShowDialog()
}

function New-ToolkitGuiWindow {
    Add-Type -AssemblyName PresentationFramework
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'The GUI requires STA mode. Use Toolkit.exe or powershell.exe -STA -File Toolkit.ps1 -Gui.' }
    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="TOOLX Windows Edition - Alpha 0.2.2 (by ALSA)" Width="1120" Height="760" MinWidth="680" MinHeight="460" WindowStartupLocation="CenterScreen" Background="{DynamicResource Background}" Foreground="{DynamicResource Text}" FontFamily="Segoe UI" FontSize="13.5" UseLayoutRounding="True" SnapsToDevicePixels="True">
 <Window.Resources>
  <SolidColorBrush x:Key="Background" Color="#0B0F14"/><SolidColorBrush x:Key="Chrome" Color="#10151C"/><SolidColorBrush x:Key="Surface" Color="#141B24"/><SolidColorBrush x:Key="Raised" Color="#1C2532"/>
  <SolidColorBrush x:Key="Divider" Color="#232C37"/><SolidColorBrush x:Key="Edge" Color="#687C93"/><SolidColorBrush x:Key="ScrollThumb" Color="#5E7287"/><SolidColorBrush x:Key="ScrollHover" Color="#7D93AA"/>
  <SolidColorBrush x:Key="Text" Color="#E6EDF3"/><SolidColorBrush x:Key="Muted" Color="#9AA8B8"/><SolidColorBrush x:Key="DisabledText" Color="#8C9CAE"/>
  <SolidColorBrush x:Key="Accent" Color="#66D6C7"/><SolidColorBrush x:Key="PrimaryFill" Color="#52C4B5"/><SolidColorBrush x:Key="PrimaryHover" Color="#66D6C7"/><SolidColorBrush x:Key="PrimaryText" Color="#081312"/>
  <SolidColorBrush x:Key="Success" Color="#7EE787"/><SolidColorBrush x:Key="SuccessBg" Color="#13261E"/><SolidColorBrush x:Key="Warning" Color="#E5B552"/><SolidColorBrush x:Key="WarningBg" Color="#262012"/>
  <SolidColorBrush x:Key="Danger" Color="#FF8E88"/><SolidColorBrush x:Key="DangerHover" Color="#FFA5A0"/><SolidColorBrush x:Key="DangerBg" Color="#2A1517"/><SolidColorBrush x:Key="DangerText" Color="#1A0707"/>
  <SolidColorBrush x:Key="{x:Static SystemColors.WindowBrushKey}" Color="#141B24"/><SolidColorBrush x:Key="{x:Static SystemColors.WindowTextBrushKey}" Color="#E6EDF3"/>
  <SolidColorBrush x:Key="{x:Static SystemColors.ControlBrushKey}" Color="#10151C"/><SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#66D6C7"/><SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#0B0F14"/>
  <Style x:Key="ScrollRepeatStyle" TargetType="RepeatButton">
   <Setter Property="OverridesDefaultStyle" Value="True"/><Setter Property="Background" Value="Transparent"/><Setter Property="Focusable" Value="False"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton"><Rectangle Fill="Transparent"/></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="ScrollThumbStyle" TargetType="Thumb">
   <Setter Property="OverridesDefaultStyle" Value="True"/><Setter Property="IsTabStop" Value="False"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb"><Border x:Name="thumb" CornerRadius="3" Background="{DynamicResource ScrollThumb}"/><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="thumb" Property="Background" Value="{DynamicResource ScrollHover}"/></Trigger><Trigger Property="IsDragging" Value="True"><Setter TargetName="thumb" Property="Background" Value="{DynamicResource Accent}"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="ScrollBar">
   <Setter Property="OverridesDefaultStyle" Value="True"/><Setter Property="Background" Value="Transparent"/>
   <Style.Triggers>
    <Trigger Property="Orientation" Value="Vertical">
     <Setter Property="Width" Value="8"/><Setter Property="MinWidth" Value="8"/>
     <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar"><Grid Background="Transparent"><Track x:Name="PART_Track" IsDirectionReversed="True"><Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource ScrollRepeatStyle}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton><Track.Thumb><Thumb Style="{StaticResource ScrollThumbStyle}" Margin="1,2" MinHeight="28"/></Track.Thumb><Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource ScrollRepeatStyle}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton></Track></Grid></ControlTemplate></Setter.Value></Setter>
    </Trigger>
    <Trigger Property="Orientation" Value="Horizontal">
     <Setter Property="Height" Value="8"/><Setter Property="MinHeight" Value="8"/>
     <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar"><Grid Background="Transparent"><Track x:Name="PART_Track" IsDirectionReversed="False"><Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource ScrollRepeatStyle}" Command="ScrollBar.PageLeftCommand"/></Track.DecreaseRepeatButton><Track.Thumb><Thumb Style="{StaticResource ScrollThumbStyle}" Margin="2,1" MinWidth="28"/></Track.Thumb><Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource ScrollRepeatStyle}" Command="ScrollBar.PageRightCommand"/></Track.IncreaseRepeatButton></Track></Grid></ControlTemplate></Setter.Value></Setter>
    </Trigger>
   </Style.Triggers>
  </Style>
  <Style TargetType="Button">
   <Setter Property="Background" Value="{DynamicResource Raised}"/><Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="BorderBrush" Value="{DynamicResource Edge}"/>
   <Setter Property="Padding" Value="12,6"/><Setter Property="Cursor" Value="Hand"/><Setter Property="MinHeight" Value="32"/><Setter Property="FontSize" Value="13"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="frame" CornerRadius="5" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="frame" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="frame" Property="BorderBrush" Value="{DynamicResource Accent}"/><Setter TargetName="frame" Property="BorderThickness" Value="2"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="frame" Property="Background" Value="{DynamicResource Surface}"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource DisabledText}"/><Setter TargetName="frame" Property="Background" Value="{DynamicResource Surface}"/><Setter TargetName="frame" Property="BorderBrush" Value="{DynamicResource Divider}"/><Setter Property="Cursor" Value="Arrow"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="PrimaryButtonStyle" TargetType="Button">
   <Setter Property="Background" Value="{DynamicResource PrimaryFill}"/><Setter Property="Foreground" Value="{DynamicResource PrimaryText}"/><Setter Property="BorderBrush" Value="{DynamicResource PrimaryFill}"/>
   <Setter Property="Padding" Value="16,6"/><Setter Property="Cursor" Value="Hand"/><Setter Property="MinHeight" Value="32"/><Setter Property="FontSize" Value="13"/><Setter Property="FontWeight" Value="SemiBold"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="frame" CornerRadius="5" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="frame" Property="Background" Value="{DynamicResource PrimaryHover}"/><Setter TargetName="frame" Property="BorderBrush" Value="{DynamicResource PrimaryHover}"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="frame" Property="BorderBrush" Value="{DynamicResource Text}"/><Setter TargetName="frame" Property="BorderThickness" Value="2"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="frame" Property="Opacity" Value="0.88"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource DisabledText}"/><Setter TargetName="frame" Property="Background" Value="{DynamicResource Raised}"/><Setter TargetName="frame" Property="BorderBrush" Value="{DynamicResource Divider}"/><Setter Property="Cursor" Value="Arrow"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="DangerButtonStyle" TargetType="Button">
   <Setter Property="Background" Value="{DynamicResource Danger}"/><Setter Property="Foreground" Value="{DynamicResource DangerText}"/><Setter Property="BorderBrush" Value="{DynamicResource Danger}"/>
   <Setter Property="Padding" Value="16,6"/><Setter Property="Cursor" Value="Hand"/><Setter Property="MinHeight" Value="32"/><Setter Property="FontSize" Value="13"/><Setter Property="FontWeight" Value="SemiBold"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="frame" CornerRadius="5" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="frame" Property="Background" Value="{DynamicResource DangerHover}"/><Setter TargetName="frame" Property="BorderBrush" Value="{DynamicResource DangerHover}"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="frame" Property="BorderBrush" Value="{DynamicResource Text}"/><Setter TargetName="frame" Property="BorderThickness" Value="2"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="frame" Property="Opacity" Value="0.88"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource DisabledText}"/><Setter TargetName="frame" Property="Background" Value="{DynamicResource Raised}"/><Setter TargetName="frame" Property="BorderBrush" Value="{DynamicResource Divider}"/><Setter Property="Cursor" Value="Arrow"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="SubtleButtonStyle" TargetType="Button">
   <Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="BorderBrush" Value="Transparent"/>
   <Setter Property="Padding" Value="8,4"/><Setter Property="Cursor" Value="Hand"/><Setter Property="MinHeight" Value="26"/><Setter Property="FontSize" Value="12"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="frame" CornerRadius="4" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="frame" Property="Background" Value="{DynamicResource Raised}"/><Setter TargetName="frame" Property="BorderBrush" Value="{DynamicResource Edge}"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="frame" Property="BorderBrush" Value="{DynamicResource Accent}"/><Setter TargetName="frame" Property="BorderThickness" Value="2"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="frame" Property="Background" Value="{DynamicResource Surface}"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource DisabledText}"/><Setter Property="Cursor" Value="Arrow"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="TextBox">
   <Setter Property="Background" Value="{DynamicResource Surface}"/><Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="CaretBrush" Value="{DynamicResource Accent}"/>
   <Setter Property="BorderBrush" Value="{DynamicResource Edge}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="9,6"/><Setter Property="VerticalContentAlignment" Value="Center"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TextBox"><Border x:Name="frame" CornerRadius="5" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"><ScrollViewer x:Name="PART_ContentHost" Margin="0" VerticalAlignment="Stretch"/></Border><ControlTemplate.Triggers><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="frame" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource DisabledText}"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="ComboBox">
   <Setter Property="Background" Value="{DynamicResource Surface}"/><Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="BorderBrush" Value="{DynamicResource Edge}"/><Setter Property="Padding" Value="9,6"/><Setter Property="Cursor" Value="Hand"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox"><Grid><Border x:Name="comboFrame" CornerRadius="5" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Background="{TemplateBinding Background}"/><ToggleButton Focusable="False" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}" Background="Transparent" BorderThickness="0" Foreground="{TemplateBinding Foreground}"><ToggleButton.Template><ControlTemplate TargetType="ToggleButton"><Border Background="{TemplateBinding Background}"><ContentPresenter/></Border></ControlTemplate></ToggleButton.Template><Grid Margin="9,4"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="18"/></Grid.ColumnDefinitions><ContentPresenter Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}" VerticalAlignment="Center"/><Path Grid.Column="1" Data="M 0 0 L 4 4 L 8 0" Stroke="{DynamicResource Muted}" StrokeThickness="1.5" StrokeEndLineCap="Round" StrokeStartLineCap="Round" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid></ToggleButton><Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False"><Border CornerRadius="5" Background="{DynamicResource Surface}" BorderBrush="{DynamicResource Edge}" BorderThickness="1" Margin="0,3,0,0" MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="260"><ScrollViewer VerticalScrollBarVisibility="Auto"><ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer></Border></Popup></Grid><ControlTemplate.Triggers><Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="comboFrame" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="comboFrame" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="{DynamicResource DisabledText}"/><Setter Property="Cursor" Value="Arrow"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="ComboBoxItem"><Setter Property="Background" Value="{DynamicResource Surface}"/><Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="Padding" Value="10,6"/><Style.Triggers><Trigger Property="IsHighlighted" Value="True"><Setter Property="Background" Value="{DynamicResource Raised}"/><Setter Property="Foreground" Value="{DynamicResource Text}"/></Trigger></Style.Triggers></Style>
  <Style TargetType="Label"><Setter Property="Foreground" Value="{DynamicResource Text}"/></Style>
  <Style TargetType="CheckBox"><Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="Cursor" Value="Hand"/><Setter Property="VerticalContentAlignment" Value="Center"/></Style>
  <Style TargetType="ToolTip"><Setter Property="Background" Value="{DynamicResource Surface}"/><Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="BorderBrush" Value="{DynamicResource Edge}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="8,5"/><Setter Property="FontSize" Value="12"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ToolTip"><Border CornerRadius="4" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}"><ContentPresenter/></Border></ControlTemplate></Setter.Value></Setter></Style>
  <Style x:Key="TreeExpanderStyle" TargetType="ToggleButton">
   <Setter Property="Focusable" Value="False"/><Setter Property="Width" Value="16"/><Setter Property="Height" Value="16"/><Setter Property="Cursor" Value="Hand"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ToggleButton"><Border Background="Transparent"><Path x:Name="Arrow" Data="M 0 0 L 4 4 L 0 8" Stroke="{DynamicResource Muted}" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" HorizontalAlignment="Center" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5"/></Border><ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="Arrow" Property="RenderTransform"><Setter.Value><RotateTransform Angle="90"/></Setter.Value></Setter><Setter TargetName="Arrow" Property="Stroke" Value="{DynamicResource Text}"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="TreeViewItem">
   <Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="Padding" Value="4,5"/><Setter Property="FontSize" Value="12.5"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TreeViewItem"><StackPanel><StackPanel x:Name="GroupHeader" Visibility="Collapsed"><Border x:Name="SectionRule" Height="1" Background="{DynamicResource Divider}" Margin="4,8,4,6"/><TextBlock x:Name="GroupLabel" FontSize="11" FontWeight="SemiBold" Foreground="{DynamicResource Muted}" Margin="6,2,4,4"/></StackPanel><Border x:Name="Bd" CornerRadius="4" Margin="0,1" Padding="{TemplateBinding Padding}" Background="Transparent" BorderBrush="Transparent" BorderThickness="1"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><Border x:Name="ActiveBar" Width="2" Height="14" CornerRadius="1" Background="{DynamicResource Accent}" Margin="0,0,6,0" Opacity="0" VerticalAlignment="Center"/><ToggleButton x:Name="Expander" Grid.Column="1" Style="{StaticResource TreeExpanderStyle}" IsChecked="{Binding IsExpanded, RelativeSource={RelativeSource TemplatedParent}}" ClickMode="Press" Margin="0,0,5,0" Visibility="Collapsed"/><ContentPresenter x:Name="PART_Header" Grid.Column="2" ContentSource="Header" VerticalAlignment="Center"><ContentPresenter.Resources><Style TargetType="TextBlock"><Setter Property="TextTrimming" Value="CharacterEllipsis"/></Style></ContentPresenter.Resources></ContentPresenter><Border x:Name="CountChip" Grid.Column="3" CornerRadius="3" Background="{DynamicResource Surface}" Padding="6,1" Margin="6,0,0,0" VerticalAlignment="Center" Visibility="Collapsed"><TextBlock Text="{Binding Items.Count, RelativeSource={RelativeSource TemplatedParent}}" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource Muted}"/></Border><TextBlock x:Name="RiskBadge" Grid.Column="3" FontFamily="Cascadia Mono, Consolas" FontSize="10" FontWeight="SemiBold" VerticalAlignment="Center" Margin="6,0,2,0" Visibility="Collapsed"/></Grid></Border><ItemsPresenter x:Name="ItemsHost" Margin="10,0,0,0"/></StackPanel><ControlTemplate.Triggers><Trigger Property="HasItems" Value="True"><Setter TargetName="Expander" Property="Visibility" Value="Visible"/><Setter TargetName="CountChip" Property="Visibility" Value="Visible"/><Setter TargetName="ActiveBar" Property="Visibility" Value="Collapsed"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="FontSize" Value="13"/><Setter Property="Padding" Value="4,6"/></Trigger><Trigger Property="IsExpanded" Value="False"><Setter TargetName="ItemsHost" Property="Visibility" Value="Collapsed"/></Trigger><Trigger Property="Uid" Value="GRP_INSPECT"><Setter TargetName="GroupHeader" Property="Visibility" Value="Visible"/><Setter TargetName="SectionRule" Property="Visibility" Value="Collapsed"/><Setter TargetName="GroupLabel" Property="Text" Value="Inspect and monitor"/></Trigger><Trigger Property="Uid" Value="GRP_REPAIR"><Setter TargetName="GroupHeader" Property="Visibility" Value="Visible"/><Setter TargetName="GroupLabel" Property="Text" Value="Troubleshoot and repair"/></Trigger><Trigger Property="Uid" Value="GRP_CONTROL"><Setter TargetName="GroupHeader" Property="Visibility" Value="Visible"/><Setter TargetName="GroupLabel" Property="Text" Value="Security and power"/></Trigger><Trigger Property="Uid" Value="GRP_CUSTOM"><Setter TargetName="GroupHeader" Property="Visibility" Value="Visible"/><Setter TargetName="GroupLabel" Property="Text" Value="Custom and external"/></Trigger><Trigger Property="Uid" Value="MOD"><Setter TargetName="RiskBadge" Property="Visibility" Value="Visible"/><Setter TargetName="RiskBadge" Property="Text" Value="MOD"/><Setter TargetName="RiskBadge" Property="Foreground" Value="{DynamicResource Warning}"/></Trigger><Trigger Property="Uid" Value="HIGH"><Setter TargetName="RiskBadge" Property="Visibility" Value="Visible"/><Setter TargetName="RiskBadge" Property="Text" Value="HIGH"/><Setter TargetName="RiskBadge" Property="Foreground" Value="{DynamicResource Danger}"/></Trigger><Trigger SourceName="Bd" Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource Raised}"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource Raised}"/><Setter TargetName="ActiveBar" Property="Opacity" Value="1"/><Setter Property="Foreground" Value="{DynamicResource Text}"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
  </Style>
 </Window.Resources>
 <Grid Background="{DynamicResource Background}">
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <Border Grid.Row="0" Background="{DynamicResource Chrome}" BorderBrush="{DynamicResource Divider}" BorderThickness="0,0,0,1" Padding="14,8">
   <DockPanel LastChildFill="True">
    <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
     <Border x:Name="PrivilegeBadge" CornerRadius="4" Background="{DynamicResource Surface}" BorderBrush="{DynamicResource Divider}" BorderThickness="1" Padding="8,4" Margin="0,0,10,0" VerticalAlignment="Center"><TextBlock x:Name="Privilege" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" Foreground="{DynamicResource Muted}"/></Border>
     <Button x:Name="OpenTerminal" Content="Terminal" MinHeight="28" Padding="10,4" Margin="0,0,8,0" FontSize="12.5" ToolTip="Open terminal interface"/>
     <Button x:Name="Settings" Content="Settings" MinHeight="28" Padding="10,4" FontSize="12.5"/>
    </StackPanel>
    <Grid HorizontalAlignment="Left" VerticalAlignment="Center" Margin="0,0,10,0">
     <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <Button x:Name="SidebarToggle" Grid.Column="0" Style="{StaticResource SubtleButtonStyle}" Width="30" Height="28" Padding="0" Margin="0,0,10,0" ToolTip="Hide command library (Ctrl+B)" AutomationProperties.Name="Hide sidebar"><Path Data="M 1 2 H 13 M 1 7 H 13 M 1 12 H 13" Stroke="{DynamicResource Muted}" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/></Button>
     <TextBlock x:Name="Brand" Grid.Column="1" FontSize="14.5" FontWeight="SemiBold" Foreground="{DynamicResource Accent}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
     <Border x:Name="VersionBadge" Grid.Column="2" CornerRadius="4" Background="{DynamicResource Surface}" BorderBrush="{DynamicResource Divider}" BorderThickness="1" Padding="6,2" Margin="10,0,0,0" VerticalAlignment="Center"><TextBlock x:Name="VersionTag" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource Muted}"/></Border>
    </Grid>
   </DockPanel>
  </Border>
  <Grid Grid.Row="1">
   <Grid.ColumnDefinitions><ColumnDefinition x:Name="SidebarColumn" Width="296" MinWidth="175" MaxWidth="400"/><ColumnDefinition x:Name="SplitterColumn" Width="5"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
   <Border x:Name="SidebarPanel" Grid.Column="0" Background="{DynamicResource Chrome}" BorderBrush="{DynamicResource Divider}" BorderThickness="0,0,1,0">
    <Grid Margin="10,10,10,8">
     <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
     <Grid Grid.Row="0" Margin="0,0,0,8">
      <TextBox x:Name="Search" Padding="28,6,26,6" MinHeight="32" AutomationProperties.Name="Search commands"/>
      <Path Data="M 6 1 A 5 5 0 1 0 6 11 A 5 5 0 1 0 6 1 M 9.5 9.5 L 13 13" Stroke="{DynamicResource Muted}" StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Margin="9,0,0,0" HorizontalAlignment="Left" VerticalAlignment="Center" IsHitTestVisible="False"/>
      <TextBlock x:Name="SearchPlaceholder" Text="Search (Ctrl+K)" Foreground="{DynamicResource Muted}" FontSize="12.5" Margin="30,0,26,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
      <Button x:Name="ClearSearch" Style="{StaticResource SubtleButtonStyle}" Width="22" Height="22" MinHeight="22" Padding="0" Margin="0,0,5,0" HorizontalAlignment="Right" VerticalAlignment="Center" Visibility="Collapsed" ToolTip="Clear search (Esc)" AutomationProperties.Name="Clear search"><Path Data="M 1 1 L 7 7 M 7 1 L 1 7" Stroke="{DynamicResource Muted}" StrokeThickness="1.5" StrokeStartLineCap="Round"/></Button>
     </Grid>
     <TreeView x:Name="Tree" Grid.Row="1" BorderThickness="0" Background="Transparent" Foreground="{DynamicResource Text}" FocusVisualStyle="{x:Null}" VirtualizingStackPanel.IsVirtualizing="True" ScrollViewer.HorizontalScrollBarVisibility="Disabled" ScrollViewer.VerticalScrollBarVisibility="Auto" AutomationProperties.Name="Command library"/>
     <Border Grid.Row="2" BorderBrush="{DynamicResource Divider}" BorderThickness="0,1,0,0" Padding="2,8,0,0" Margin="0,6,0,0">
      <DockPanel><StackPanel DockPanel.Dock="Right" Orientation="Horizontal"><Button x:Name="ImportScript" Content="Import" Style="{StaticResource SubtleButtonStyle}" Padding="8,4" Margin="0,0,4,0" ToolTip="Import script from local file, ZIP or HTTPS URL"/><Button x:Name="Refresh" Content="Refresh" Style="{StaticResource SubtleButtonStyle}" Padding="8,4" ToolTip="Refresh custom scripts (F5)"/></StackPanel><TextBlock x:Name="CatalogCount" VerticalAlignment="Center" Foreground="{DynamicResource Muted}" FontFamily="Cascadia Mono, Consolas" FontSize="11.5"/></DockPanel>
     </Border>
    </Grid>
   </Border>
   <GridSplitter x:Name="Splitter" Grid.Column="1" Width="5" HorizontalAlignment="Stretch" Background="Transparent"/>
   <Grid x:Name="Workspace" Grid.Column="2" Margin="22,16,22,10">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <ScrollViewer MaxHeight="190" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
     <StackPanel Margin="0,0,0,8">
      <DockPanel LastChildFill="True">
       <TextBlock x:Name="CommandId" DockPanel.Dock="Right" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" Foreground="{DynamicResource Muted}" VerticalAlignment="Center" Margin="12,0,0,0" Visibility="Collapsed"/>
       <TextBlock x:Name="Heading" Text="Choose a command" FontSize="21" FontWeight="SemiBold" TextWrapping="Wrap"/>
      </DockPanel>
      <TextBlock x:Name="Description" Text="Browse the library or search for a diagnostic." Foreground="{DynamicResource Muted}" TextWrapping="Wrap" Margin="0,5,0,8"/>
      <WrapPanel x:Name="MetadataTags" Visibility="Collapsed"/>
      <TextBlock x:Name="Metadata" Visibility="Collapsed"/>
      <Border x:Name="ConsequenceBox" CornerRadius="4" Visibility="Collapsed" Margin="0,2,0,4"><TextBlock x:Name="Consequences" TextWrapping="Wrap" FontSize="12"/></Border>
     </StackPanel>
    </ScrollViewer>
    <Border x:Name="ParametersSection" Grid.Row="1" BorderBrush="{DynamicResource Divider}" BorderThickness="0,1,0,0" Padding="0,10,0,2" Margin="0,2,0,4" Visibility="Collapsed">
     <ScrollViewer MaxHeight="185" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><WrapPanel x:Name="Parameters"/></ScrollViewer>
    </Border>
    <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,4,0,12">
     <Button x:Name="Run" Style="{StaticResource PrimaryButtonStyle}" Content="Run" IsEnabled="False" MinWidth="92"/>
     <Button x:Name="RunAdmin" Content="Run as administrator" Visibility="Collapsed" Margin="8,0,0,0"/>
     <Button x:Name="Cancel" Content="Cancel" IsEnabled="False" Margin="8,0,0,0"/>
    </StackPanel>
    <Border Grid.Row="3" CornerRadius="6" Background="{DynamicResource Surface}" BorderBrush="{DynamicResource Divider}" BorderThickness="1">
     <Grid>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
      <Border Grid.Row="0" Background="{DynamicResource Chrome}" BorderBrush="{DynamicResource Divider}" BorderThickness="0,0,0,1" CornerRadius="6,6,0,0" Padding="12,5">
       <DockPanel><Button x:Name="CopyButton" DockPanel.Dock="Right" Content="Copy" Style="{StaticResource SubtleButtonStyle}" IsEnabled="False" Padding="8,2" MinHeight="22" AutomationProperties.Name="Copy output"/><TextBlock x:Name="ViewportTitle" Text="WORKBENCH" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource Muted}" VerticalAlignment="Center"/></DockPanel>
      </Border>
      <Grid Grid.Row="1">
       <ScrollViewer x:Name="WelcomePanel" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="16,14">
        <StackPanel>
         <TextBlock Text="Quick diagnostics" FontSize="13.5" FontWeight="SemiBold" Foreground="{DynamicResource Text}" Margin="0,0,0,4"/>
         <TextBlock Text="Select a command from the library or start with a common read-only check:" Foreground="{DynamicResource Muted}" FontSize="12.5" TextWrapping="Wrap" Margin="0,0,0,12"/>
         <WrapPanel Margin="0,0,0,14">
          <Button x:Name="QuickSpecs" Content="Full specifications" Margin="0,0,8,8"/>
          <Button x:Name="QuickIp" Content="IP configuration" Margin="0,0,8,8"/>
          <Button x:Name="QuickDisk" Content="Available disk space" Margin="0,0,8,8"/>
          <Button x:Name="QuickEvents" Content="Critical and error events" Margin="0,0,8,8"/>
         </WrapPanel>
         <TextBlock Text="Ctrl+K Search   |   Ctrl+B Sidebar   |   Ctrl+Enter Run   |   F5 Refresh   |   Esc Cancel" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" Foreground="{DynamicResource Muted}" TextWrapping="Wrap"/>
        </StackPanel>
       </ScrollViewer>
       <TextBox x:Name="ResultText" Visibility="Collapsed" Text="Choose a command and select Run to see results." IsReadOnly="True" TextWrapping="Wrap" AcceptsReturn="True" VerticalContentAlignment="Top" VerticalScrollBarVisibility="Auto" BorderThickness="0" Background="Transparent" Padding="12,10" FontFamily="Cascadia Mono, Consolas" FontSize="12.5" AutomationProperties.Name="Diagnostic output"/>
       <ScrollViewer x:Name="SpecScroll" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="10,10,0,0"><WrapPanel x:Name="SpecWrap"/></ScrollViewer>
      </Grid>
     </Grid>
    </Border>
   </Grid>
  </Grid>
  <Border Grid.Row="2" Background="{DynamicResource Chrome}" BorderBrush="{DynamicResource Divider}" BorderThickness="0,1,0,0">
   <Grid>
    <ProgressBar x:Name="Progress" Height="2" VerticalAlignment="Top" IsIndeterminate="True" Visibility="Collapsed" Foreground="{DynamicResource Accent}" Background="Transparent" BorderThickness="0"/>
    <DockPanel Margin="14,7">
     <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center" Margin="12,0,0,0">
      <TextBlock Text="Ctrl+K Search | Ctrl+B Sidebar" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource Muted}" VerticalAlignment="Center"/>
      <TextBlock Text="|" FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{DynamicResource Divider}" Margin="10,0" VerticalAlignment="Center"/>
      <TextBlock x:Name="Signature" FontFamily="Cascadia Mono, Consolas" FontSize="11" FontWeight="SemiBold" Foreground="{DynamicResource Accent}" VerticalAlignment="Center"/>
     </StackPanel>
     <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
      <Ellipse x:Name="StatusDot" Width="6" Height="6" Fill="{DynamicResource Muted}" Margin="0,0,8,0" VerticalAlignment="Center"/>
      <TextBlock x:Name="Status" Text="Ready" TextWrapping="Wrap" FontSize="12" Foreground="{DynamicResource Muted}" AutomationProperties.LiveSetting="Polite"/>
     </StackPanel>
    </DockPanel>
   </Grid>
  </Border>
 </Grid>
</Window>
'@
    $reader = New-Object Xml.XmlNodeReader $xaml
    try { $window = [System.Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    $state = @{
        Window = $window; Worker = $null; External = $null; Command = $null; Fields = @{}; CanRun = $false
        HighContrast = $null; ClosePending = $false; Stopping = $false; SidebarCollapsed = $false
        SpecBlocks = @(); Output = (New-Object 'Collections.Generic.Queue[string]'); OutputCharacters = 0
        OutputTruncated = $false; Administrator = (Test-ToolkitAdministrator)
    }
    $controlNames = @(
        'SidebarToggle','Brand','VersionBadge','VersionTag','Signature','PrivilegeBadge','Privilege','OpenTerminal','Settings','SidebarColumn','SplitterColumn',
        'SidebarPanel','Splitter','Search','SearchPlaceholder','ClearSearch','ImportScript','Refresh','CatalogCount','Tree',
        'Workspace','CommandId','Heading','Description','MetadataTags','Metadata','ConsequenceBox','Consequences',
        'ParametersSection','Parameters','Run','RunAdmin','Cancel','CopyButton','ViewportTitle','WelcomePanel',
        'QuickSpecs','QuickIp','QuickDisk','QuickEvents','ResultText','SpecScroll','SpecWrap','Progress',
        'StatusDot','Status'
    )
    foreach ($name in $controlNames) { $state[$name] = $window.FindName($name) }
    $script:ToolkitGui = $state
    $identity = Get-ToolkitIdentity
    $window.Title = $identity.WindowTitle
    $state.Brand.Text = $identity.ProductName
    $state.VersionTag.Text = $identity.VersionLabel
    $state.Signature.Text = $identity.Signature
    $state.Timer = New-Object System.Windows.Threading.DispatcherTimer
    $state.Timer.Interval = [timespan]::FromMilliseconds(100)
    $state.Timer.Add_Tick({
        try { Update-ToolkitGuiOperation }
        catch { Set-ToolkitGuiStatus ('Operation error: ' + $_.Exception.Message) 'Danger'; Stop-ToolkitGuiOperation }
    })
    $state.Tree.Add_SelectedItemChanged({
        $selection = $script:ToolkitGui.Tree.SelectedItem
        if ($null -ne $selection) {
            if ($null -ne $selection.Tag) { Show-ToolkitGuiCommand $selection.Tag }
            else { Clear-ToolkitGuiSelection ([string]$selection.Header) }
        }
    })
    $state.SidebarToggle.Add_Click({ Switch-ToolkitGuiSidebar })
    $state.Search.Add_TextChanged({ Update-ToolkitGuiCatalog })
    $state.ClearSearch.Add_Click({ $script:ToolkitGui.Search.Text = ''; [void]$script:ToolkitGui.Search.Focus() })
    $state.ImportScript.Add_Click({ Show-ToolkitGuiImport })
    $state.Refresh.Add_Click({ Update-ToolkitCustomCatalog; Update-ToolkitGuiCatalog; Set-ToolkitGuiStatus ("Custom scripts refreshed: $($script:ToolkitCustomCommands.Count). " + $script:ToolkitCustomNotice) })
    $state.OpenTerminal.Add_Click({ Start-ToolkitGuiTerminal })
    $state.Settings.Add_Click({ Show-ToolkitGuiSetting })
    $state.Run.Add_Click({ Start-ToolkitGuiOperation })
    $state.RunAdmin.Add_Click({ Start-ToolkitGuiOperation -Elevated })
    $state.Cancel.Add_Click({ Stop-ToolkitGuiOperation })
    $state.CopyButton.Add_Click({ Copy-ToolkitGuiOutput })
    $state.QuickSpecs.Add_Click({ Select-ToolkitGuiCommandById 'system.full-specs' })
    $state.QuickIp.Add_Click({ Select-ToolkitGuiCommandById 'network.ip' })
    $state.QuickDisk.Add_Click({ Select-ToolkitGuiCommandById 'storage.space' })
    $state.QuickEvents.Add_Click({ Select-ToolkitGuiCommandById 'troubleshooting.events' })
    $state.SpecScroll.Add_SizeChanged({ Update-ToolkitGuiSpecificationWidth })
    $window.Add_SizeChanged({ Update-ToolkitGuiLayout })
    $window.Add_SourceInitialized({ Set-ToolkitGuiWindowChrome $this })
    $window.Add_Activated({ Set-ToolkitGuiTheme })
    $window.Add_PreviewKeyDown({
        param($uiSender, $keyEvent)
        $guiState = $script:ToolkitGui
        if ($uiSender -ne $guiState.Window) { return }
        $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
        if ($ctrl -and ($keyEvent.Key -eq [System.Windows.Input.Key]::K -or $keyEvent.Key -eq [System.Windows.Input.Key]::F)) {
            if ($guiState.SidebarCollapsed) { Switch-ToolkitGuiSidebar }
            [void]$guiState.Search.Focus(); $guiState.Search.SelectAll(); $keyEvent.Handled = $true
        }
        elseif ($ctrl -and $keyEvent.Key -eq [System.Windows.Input.Key]::B) {
            Switch-ToolkitGuiSidebar; $keyEvent.Handled = $true
        }
        elseif ($ctrl -and $keyEvent.Key -eq [System.Windows.Input.Key]::Return) {
            if ($guiState.Run.IsEnabled) { Start-ToolkitGuiOperation; $keyEvent.Handled = $true }
        }
        elseif ($keyEvent.Key -eq [System.Windows.Input.Key]::F5) {
            if ($null -eq $guiState.Worker -and $null -eq $guiState.External) {
                Update-ToolkitCustomCatalog; Update-ToolkitGuiCatalog
                Set-ToolkitGuiStatus ("Custom scripts refreshed: $($script:ToolkitCustomCommands.Count). " + $script:ToolkitCustomNotice)
                $keyEvent.Handled = $true
            }
        }
        elseif ($keyEvent.Key -eq [System.Windows.Input.Key]::Escape) {
            if ($guiState.Cancel.IsEnabled) { Stop-ToolkitGuiOperation; $keyEvent.Handled = $true }
            elseif ($guiState.Search.IsKeyboardFocused -and $guiState.Search.Text.Length -gt 0) { $guiState.Search.Text = ''; $keyEvent.Handled = $true }
        }
    })
    $window.Add_Closing({
        param($uiSender, $uiClosing)
        if ($uiSender -eq $script:ToolkitGui.Window -and $null -ne $script:ToolkitGui.Worker) { $uiClosing.Cancel = $true; $script:ToolkitGui.ClosePending = $true; Stop-ToolkitGuiOperation }
    })
    $window.Add_Closed({
        $script:ToolkitGui.Timer.Stop()
        if ($null -ne $script:ToolkitGui.External) { $script:ToolkitGui.External.Dispose(); $script:ToolkitGui.External = $null }
    })
    $area = [System.Windows.SystemParameters]::WorkArea
    $window.MinWidth = [Math]::Min(680, [Math]::Max(1, $area.Width - 24))
    $window.MinHeight = [Math]::Min(460, [Math]::Max(1, $area.Height - 24))
    $window.Width = [Math]::Min(1120, [Math]::Max(1, $area.Width - 24))
    $window.Height = [Math]::Min(760, [Math]::Max(1, $area.Height - 24))
    Set-ToolkitGuiTheme
    Update-ToolkitGuiCatalog
    Update-ToolkitGuiAvailability
    return $state
}

function Start-ToolkitGui {
    $state = New-ToolkitGuiWindow
    [void]$state.Window.ShowDialog()
}
