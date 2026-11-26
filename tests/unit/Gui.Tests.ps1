BeforeAll { . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1') }

Describe 'GUI command contracts' {
    It 'routes only ordinary read-only commands to the background worker' {
        foreach ($command in $script:ToolkitRegistry.commands) {
            $route = Get-ToolkitGuiExecutionRoute $command
            if ($command.risk -eq 'ReadOnly' -and -not $command.requiresAdmin) { $route | Should -Be 'Background' }
            else { $route | Should -Be 'Console' }
        }
        Get-ToolkitGuiExecutionRoute ([pscustomobject]@{ sourceKind = 'CustomScript'; risk = 'ReadOnly'; requiresAdmin = $false }) | Should -Be 'Console'
        Get-ToolkitGuiExecutionRoute (Get-TestCommand 'system.full-specs') -Elevated | Should -Be 'Console'
    }
    It 'validates scope defaults, numeric bounds and unknown choices' {
        (ConvertTo-ToolkitGuiParameterMap (Get-TestCommand 'system.full-specs') @{}).scope | Should -Be 'Full'
        { ConvertTo-ToolkitGuiParameterMap (Get-TestCommand 'system.full-specs') @{ scope = 'Other' } } | Should -Throw
        { ConvertTo-ToolkitGuiParameterMap (Get-TestCommand 'network.port') @{ host = 'localhost'; port = '70000' } } | Should -Throw
        (ConvertTo-ToolkitGuiParameterMap (Get-TestCommand 'network.port') @{ host = 'localhost'; port = '443' }).port | Should -Be 443
    }
    It 'hides and omits security-control options that do not apply' {
        foreach ($id in @('security.firewall-control','security.defender-control')) {
            $command = Get-TestCommand $id
            $values = ConvertTo-ToolkitGuiParameterMap $command @{ profile = 'Private'; action = 'Enable'; mode = 'invalid'; minutes = 'invalid' }
            $values.ContainsKey('mode') | Should -BeFalse
            $values.ContainsKey('minutes') | Should -BeFalse
            $values = ConvertTo-ToolkitGuiParameterMap $command @{ profile = 'Private'; action = 'Disable'; mode = 'Manual'; minutes = 'invalid' }
            $values.mode | Should -Be 'Manual'
            $values.ContainsKey('minutes') | Should -BeFalse
        }
    }
}

Describe 'WPF view and operation lifecycle' {
    BeforeAll {
        $script:ToolkitProductName = 'TOOLX Windows Edition'
        $script:ToolkitChannel = 'Alpha'
        $script:ToolkitSignature = 'by ALSA'
        $script:ToolkitVersion = '0.2.2'
    }
    BeforeEach {
        $state = New-ToolkitGuiWindow
        $script:ToolkitGui = $state
    }
    AfterEach {
        $state.Timer.Stop()
        $state.Window.Close()
    }
    It 'constructs a usable window with every catalog entry and accessible inputs' {
        $state.Window.Title | Should -Be 'TOOLX Windows Edition - Alpha 0.2.2 (by ALSA)'
        $state.Brand.Text | Should -Be 'TOOLX Windows Edition'
        $state.VersionTag.Text | Should -Be 'Alpha 0.2.2'
        $state.Signature.Text | Should -Be 'by ALSA'
        $builtInCount = 0; $customCount = 0
        foreach ($category in $state.Tree.Items) {
            foreach ($entry in $category.Items) {
                if ($entry.Tag.sourceKind -eq 'CustomScript') { $customCount++ }
                else { $builtInCount++ }
            }
        }
        $builtInCount | Should -Be 91
        $customCount | Should -Be @($script:ToolkitCustomCommands).Count
        $customCount | Should -BeGreaterOrEqual 5
        $categoryOrder = @($state.Tree.Items | ForEach-Object { [string]$_.Header })
        $categoryOrder | Should -Be @(
            'System Information','Hardware Diagnostics','Storage Management','Networking','Processes and Services',
            'Troubleshooting','Windows Repair and Maintenance','Security and Administration','Power and Scheduling','Custom Scripts'
        )
        $sysItems = @($state.Tree.Items[0].Items | ForEach-Object { $_.Tag.id })
        $sysItems[0] | Should -Be 'system.full-specs'
        $repairCategory = @($state.Tree.Items | Where-Object Header -eq 'Windows Repair and Maintenance')[0]
        $repairRisks = @($repairCategory.Items | ForEach-Object { $_.Tag.risk })
        $firstMod = $repairRisks.IndexOf('SystemModification')
        $firstHigh = $repairRisks.IndexOf('HighRisk')
        $repairRisks[0] | Should -Be 'ReadOnly'
        $firstMod | Should -BeGreaterThan 0
        $firstHigh | Should -BeGreaterThan $firstMod
        Show-ToolkitGuiCommand (Get-TestCommand 'system.full-specs')
        $state.Fields.scope.Control.SelectedItem | Should -Be 'Full'
        [System.Windows.Automation.AutomationProperties]::GetName($state.Fields.scope.Control) | Should -Match 'Specification scope'
        $state.Run.IsEnabled | Should -BeTrue
        $state.Timer.IsEnabled | Should -BeFalse
    }
    It 'shows a useful empty search state and restores the catalog' {
        Show-ToolkitGuiCommand (Get-TestCommand 'system.full-specs')
        $state.Search.Text = 'THIS_COMMAND_DOES_NOT_EXIST'
        $state.Tree.Items.Count | Should -Be 0
        $state.Status.Text | Should -Match 'No matching'
        $state.Run.IsEnabled | Should -BeFalse
        $state.Command | Should -BeNullOrEmpty
        $state.Search.Text = 'firmware'
        @($state.Tree.Items | Where-Object { $_.Tag.id -eq 'system.full-specs' }).Count | Should -Be 1
    }
    It 'constructs parameter forms for all built-ins without dispatching commands' {
        Mock Get-ToolkitCapability { [pscustomobject]@{ Available = $true; Reason = '' } }
        foreach ($command in $script:ToolkitRegistry.commands) {
            Show-ToolkitGuiCommand $command
            $state.Heading.Text | Should -Be $command.name
            $state.Fields.Count | Should -Be @($command.parameters).Count
            foreach ($definition in $command.parameters) {
                [System.Windows.Automation.AutomationProperties]::GetName($state.Fields[$definition.name].Control) | Should -Be $definition.label
            }
        }
    }
    It 'rejects a disabled command before launching any worker' {
        Mock Get-ToolkitCapability { [pscustomobject]@{ Available = $false; Reason = 'Fixture unavailable' } }
        Mock Start-ToolkitExecution { throw 'Must not start' }
        $state.Command = Get-TestCommand 'system.environment'
        Start-ToolkitGuiOperation
        $state.Status.Text | Should -Match 'unavailable'
        Should -Invoke Start-ToolkitExecution -Times 0
    }
    It 'reuses console confirmation and elevation flags without running a real action' {
        Mock Get-ToolkitCapability { [pscustomobject]@{ Available = $true; Reason = '' } }
        Mock Start-ToolkitConsole { [pscustomobject]@{ HasExited = $false } }
        $state.Command = Get-TestCommand 'repair.winsock'
        $script:ToolkitConfirmActions = $false
        try {
            Start-ToolkitGuiOperation
            Should -Invoke Start-ToolkitConsole -Times 1 -Exactly -ParameterFilter { $OperationId -eq 'repair.winsock' -and $Elevated -and $SkipActionConfirmation }
            $state.Run.IsEnabled | Should -BeFalse
            $state.Cancel.IsEnabled | Should -BeFalse
        }
        finally { $state.External = $null; $script:ToolkitConfirmActions = $true }
    }
    It 'renders structured device results as reflowable selectable blocks' {
        Show-ToolkitGuiSpecification @(
            [pscustomobject]@{ Section = 'Computer'; DeviceIndex = 0; Field = 'TotalPhysicalMemory'; Value = 16GB; Status = 'Reported' },
            [pscustomobject]@{ Section = 'BIOS'; Field = ''; Value = 'Fixture access denied'; Status = 'Unavailable' }
        )
        $state.SpecWrap.Children.Count | Should -Be 2
        $state.SpecScroll.Visibility.ToString() | Should -Be 'Visible'
        $state.SpecWrap.Children[0].Child.Children[1].Text | Should -Be 'RAM: 16 GiB'
        $state.SpecWrap.Children[1].Child.Children[1].Text | Should -Match 'Unavailable: Fixture access denied'
        (Get-ToolkitGuiCopyText) | Should -Match '\[Computer\]'
        (Get-ToolkitGuiCopyText) | Should -Match 'RAM: 16 GiB'
        $state.CopyButton.IsEnabled | Should -BeTrue
    }
    It 'toggles the sidebar, clears search, and supports quick-launch selection' {
        $state.SidebarCollapsed | Should -BeFalse
        $state.SidebarToggle.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $state.SidebarCollapsed | Should -BeTrue
        $state.SidebarPanel.Visibility.ToString() | Should -Be 'Collapsed'
        $state.SidebarToggle.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $state.SidebarCollapsed | Should -BeFalse
        $state.SidebarPanel.Visibility.ToString() | Should -Be 'Visible'

        $state.Search.Text = 'firmware'
        $state.ClearSearch.Visibility.ToString() | Should -Be 'Visible'
        $state.ClearSearch.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $state.Search.Text | Should -Be ''
        $state.ClearSearch.Visibility.ToString() | Should -Be 'Collapsed'

        $state.QuickSpecs.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $state.Command.id | Should -Be 'system.full-specs'
        $state.ParametersSection.Visibility.ToString() | Should -Be 'Visible'
        $state.WelcomePanel.Visibility.ToString() | Should -Be 'Collapsed'
    }
    It 'populates all theme brushes and formats plain output for clipboard copy' {
        foreach ($key in @('Background','Chrome','Surface','Raised','Divider','Edge','Text','Muted','Accent','PrimaryFill','Success','Warning','Danger')) {
            $state.Window.Resources[$key] | Should -Not -BeNullOrEmpty
        }
        Show-ToolkitGuiCommand (Get-TestCommand 'system.environment')
        $state.ParametersSection.Visibility.ToString() | Should -Be 'Collapsed'
        Add-ToolkitGuiOutput 'PowerShellVersion : 5.1'
        $state.ResultText.Text = $state.Output.ToArray() -join "`r`n"
        Update-ToolkitGuiAvailability
        $state.CopyButton.IsEnabled | Should -BeTrue
        (Get-ToolkitGuiCopyText) | Should -Match 'PowerShellVersion : 5.1'
    }
    It 'bounds retained GUI text and marks truncation' {
        1..2100 | ForEach-Object { Add-ToolkitGuiOutput ('Line ' + $_) }
        $state.Output.Count | Should -Be 2000
        $state.OutputTruncated | Should -BeTrue
        $state.Output.Peek() | Should -Be 'Line 101'
    }
    It 'requires two-step button confirmation to disable and supports restoring session confirmations' {
        $script:ToolkitConfirmActions = $true
        $dialog = New-ToolkitGuiSettingWindow
        try {
            $dialog.Tag.Toggle.Content | Should -Be 'Disable confirmations (1/2)'
            $dialog.Tag.Toggle.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            $script:ToolkitConfirmActions | Should -BeTrue
            $dialog.Tag.Toggle.Content | Should -Be 'Confirm disable (2/2)'
            $dialog.Tag.Notice.Visibility.ToString() | Should -Be 'Visible'
            $dialog.Tag.Notice.Text | Should -Be 'Are you sure?'
            $dialog.Tag.Toggle.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            $script:ToolkitConfirmActions | Should -BeFalse
            $state.Privilege.Text | Should -Match 'ACTION CONFIRMATIONS OFF'
            $restore = New-ToolkitGuiSettingWindow
            try { $restore.Tag.Toggle.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)) }
            finally { $restore.Close() }
            $script:ToolkitConfirmActions | Should -BeTrue
        }
        finally { $dialog.Close(); $script:ToolkitConfirmActions = $true }
    }
    It 'cleans up a stopped diagnostic before completing a pending close' {
        Mock Stop-ToolkitExecution {}
        $queue = New-Object 'Collections.Concurrent.BlockingCollection[string]' 2
        $handle = [pscustomobject]@{ IsCompleted = $false }
        $state.Command = Get-TestCommand 'system.environment'
        $state.Worker = [pscustomobject]@{ Handle = $handle; Queue = $queue; Started = [DateTime]::UtcNow; DeadlineExceeded = $false }
        $state.ClosePending = $true
        try {
            Stop-ToolkitGuiOperation
            Should -Invoke Stop-ToolkitExecution -Times 1 -Exactly
            $state.Stopping | Should -BeTrue
            $handle.IsCompleted = $true
            $queue.Add('LAST_OUTPUT')
            Mock Complete-ToolkitExecution { [pscustomobject]@{ Status = 'Cancelled'; Elapsed = [timespan]::Zero; Truncated = $false; Specifications = @() } }
            Update-ToolkitGuiOperation
            $state.Worker | Should -BeNullOrEmpty
            $state.Output.ToArray() | Should -Contain 'LAST_OUTPUT'
            $state.Timer.IsEnabled | Should -BeFalse
            $state.Status.Text | Should -Match '^Cancelled'
        }
        finally { $state.Worker = $null; $queue.Dispose() }
    }
    It 'reports a closed operation console without claiming a successful repair' {
        $child = [pscustomobject]@{ HasExited = $true; ExitCode = 0; Disposed = $false }
        $child | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed = $true }
        $state.External = $child
        Update-ToolkitGuiOperation
        $child.Disposed | Should -BeTrue
        $state.External | Should -BeNullOrEmpty
        $state.Status.Text | Should -Match 'console closed.*exit code 0'
        $state.Status.Text | Should -Not -Match 'Succeeded'
    }
    It 'constructs the import dialog, switches modes, and imports a local fixture script' {
        $state.OpenTerminal | Should -Not -BeNullOrEmpty
        $state.ImportScript | Should -Not -BeNullOrEmpty
        $savedRoot = $script:ToolkitRoot
        $tempRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $sourceFile = Join-Path $TestDrive 'ImportedCheck.ps1'
        Set-Content -LiteralPath $sourceFile -Value 'Write-Output "imported"'
        $script:ToolkitRoot = $tempRoot
        $importDialog = New-ToolkitGuiImportWindow
        try {
            $importDialog.Tag.Mode.SelectedItem = 'HTTPS script URL'
            $importDialog.Tag.ShaPanel.Visibility.ToString() | Should -Be 'Visible'
            $importDialog.Tag.Mode.SelectedItem = 'Published manifest URL'
            $importDialog.Tag.ManifestScroll.Visibility.ToString() | Should -Be 'Visible'
            $importDialog.Tag.Mode.SelectedItem = 'Local file or ZIP'
            $importDialog.Tag.Source.Text = $sourceFile
            $importDialog.Tag.Folder.Text = 'Tinkerer'
            $importDialog.Tag.NameBox.Text = 'Imported Fixture'
            $importDialog.Tag.ImportButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            Test-Path -LiteralPath (Join-Path $tempRoot 'Scripts\Tinkerer\ImportedCheck.ps1') | Should -BeTrue
            $state.Status.Text | Should -Match 'Imported 1 script'
        }
        finally {
            $importDialog.Close()
            $script:ToolkitRoot = $savedRoot
            Update-ToolkitCustomCatalog
        }
    }
}
