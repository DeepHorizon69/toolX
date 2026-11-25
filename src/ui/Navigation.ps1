function Get-ToolkitSelection {
    param([int]$Index, [int]$Count, [string]$Key, [int]$PageSize = 10)
    if ($Count -le 0) { return 0 }
    switch ($Key) {
        'UpArrow' { $Index-- }
        'DownArrow' { $Index++ }
        'Home' { $Index = 0 }
        'End' { $Index = $Count - 1 }
        'PageUp' { $Index -= $PageSize }
        'PageDown' { $Index += $PageSize }
    }
    return [Math]::Max(0, [Math]::Min($Count - 1, $Index))
}

function Read-ToolkitMenu {
    param([string]$Title, [object[]]$Items, [string[]]$Description = @(), [int]$InitialIndex = 0, [object]$Context)
    $selected = Get-ToolkitSelection $InitialIndex $Items.Count ''; $pendingKey = $null
    while ($true) {
        $size = Get-ToolkitTerminalSize
        Update-ToolkitTerminalMode $size
        if ($null -eq $size) { $script:ToolkitBasic = $true }
        $frame = New-ToolkitMenuFrame $Title $Items $Description $selected $size $Context
        $plain = $script:ToolkitBasic -or $frame.UseBasic
        if ($plain) { Restore-ToolkitTerminal -LeaveScreen }
        Show-ToolkitFrame -Frame $frame -Plain:$plain
        if (($plain -or $script:ToolkitBasic) -and $null -eq $pendingKey) {
            $answer = Read-Host 'Number, back, /search text, r or q'
            if ($answer -in @('back','cancel','')) { return [pscustomobject]@{ Action = 'Back'; Value = $null; Index = $selected } }
            if ($answer -eq 'q') { return [pscustomobject]@{ Action = 'Quit'; Value = $null; Index = $selected } }
            if ($answer -eq 'r') { return [pscustomobject]@{ Action = 'Refresh'; Value = $null; Index = $selected } }
            if ($answer.StartsWith('/')) { return [pscustomobject]@{ Action = 'Search'; Value = $answer.Substring(1); Index = $selected } }
            $number = 0
            if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Items.Count) { return [pscustomobject]@{ Action = 'Select'; Value = $Items[$number - 1].Value; Index = $number - 1 } }
            Write-Host 'Choose a listed number or back.'
        }
        else {
            if ($null -ne $pendingKey) { $key = $pendingKey; $pendingKey = $null }
            else {
                $key = Read-ToolkitKey
                if ((Get-ToolkitGeometryKey (Get-ToolkitTerminalSize)) -ne (Get-ToolkitGeometryKey $size)) { $pendingKey = $key; continue }
            }
            switch ($key.Key.ToString()) {
                'Escape' { return [pscustomobject]@{ Action = 'Back'; Value = $null; Index = $selected } }
                'Enter' { if ($Items.Count) { return [pscustomobject]@{ Action = 'Select'; Value = $Items[$selected].Value; Index = $selected } } }
                default {
                    if ($key.KeyChar -eq '/') { return [pscustomobject]@{ Action = 'Search'; Value = ''; Index = $selected } }
                    if ($key.KeyChar -in @('r','R')) { return [pscustomobject]@{ Action = 'Refresh'; Value = $null; Index = $selected } }
                    if ($key.KeyChar -in @('q','Q')) { return [pscustomobject]@{ Action = 'Quit'; Value = $null; Index = $selected } }
                    $selected = Get-ToolkitSelection $selected $Items.Count $key.Key.ToString() $frame.PageSize
                }
            }
        }
    }
}

function Show-ToolkitDiagnostic {
    param([object]$Command, [hashtable]$Values)
    $execution = Start-ToolkitExecution $Command $Values
    $lines = New-Object 'Collections.Generic.Queue[string]'
    $characters = 0; $truncated = $false; $painted = $false; $lastGeometry = ''
    try {
        while ($true) {
            $dirty = $false; $line = ''
            while ($execution.Queue.TryTake([ref]$line)) {
                foreach ($part in ($line -split "`r?`n")) {
                    $text = ConvertTo-ToolkitSafeText $part
                    $lines.Enqueue($text); $characters += $text.Length
                    while ($lines.Count -gt 2000 -or $characters -gt 1048576) { $characters -= $lines.Dequeue().Length; $truncated = $true }
                    if ($script:ToolkitBasic) { Write-Host $text }
                }
                $dirty = $true
            }
            $size = Get-ToolkitTerminalSize
            $wasBasic = $script:ToolkitBasic
            Update-ToolkitTerminalMode $size
            if ($script:ToolkitBasic -and -not $wasBasic) { Restore-ToolkitTerminal; $lines.ToArray() | ForEach-Object { Write-Host $_ } }
            $geometry = Get-ToolkitGeometryKey $size
            if (-not $script:ToolkitBasic -and ($dirty -or -not $painted -or $geometry -ne $lastGeometry)) {
                $height = 15; $width = 79
                if ($null -ne $size) { $height = [Math]::Max(1, $size.Height - 8); $width = [Math]::Max(1, $size.Width - 1) }
                $tail = @($lines.ToArray() | Select-Object -Last $height | ForEach-Object { Format-ToolkitText $_ $width -Display } | Select-Object -Last $height)
                $instruction = 'C: cancel | Waiting for output'
                if ($Command.cancellation -eq 'Unavailable') { $instruction = 'Cancellation unavailable; wait for completion.' }
                Show-ToolkitFrame -Frame (New-ToolkitTextFrame $Command.name $tail -Status 'Running' -Footer @($instruction) -Size $size)
                $painted = $true; $lastGeometry = $geometry
            }
            if ($execution.Handle.IsCompleted) { break }
            $limit = 60
            if ($Command.id -eq 'system.full-specs') { $limit = 180 }
            if (-not $execution.DeadlineExceeded -and $Command.id -ne 'storage.hash' -and ([DateTime]::UtcNow - $execution.Started).TotalSeconds -gt $limit) { Stop-ToolkitExecution $execution -TimedOut }
            if (-not $script:ToolkitBasic -and [Console]::KeyAvailable) {
                $key = Read-ToolkitKey
                if ($key.KeyChar -in @('c','C')) { Stop-ToolkitExecution $execution }
            }
            Start-Sleep -Milliseconds 100
        }
        # Drain the final batch before disposing the transport.
        $line = ''
        while ($execution.Queue.TryTake([ref]$line)) {
            foreach ($part in ($line -split "`r?`n")) {
                $text = ConvertTo-ToolkitSafeText $part
                $lines.Enqueue($text); $characters += $text.Length
                while ($lines.Count -gt 2000 -or $characters -gt 1048576) { $characters -= $lines.Dequeue().Length; $truncated = $true }
                if ($script:ToolkitBasic) { Write-Host $text }
            }
        }
        $result = Complete-ToolkitExecution $execution
        $summary = "$($result.Status) | $([Math]::Round($result.Elapsed.TotalSeconds, 2)) seconds"
        if ($truncated -or $result.Truncated) { $summary += ' | Output truncated' }
        if ($script:ToolkitBasic) { Wait-ToolkitAcknowledgement $summary }
        else {
            $offset = 0; $all = $lines.ToArray(); $wrapped = @(); $wrappedWidth = 0; $pendingKey = $null; $lineStarts = @()
            while ($true) {
                $size = Get-ToolkitTerminalSize
                Update-ToolkitTerminalMode $size
                if ($null -eq $size -or $script:ToolkitBasic) { $script:ToolkitBasic = $true; $all | ForEach-Object { Write-Host $_ }; Wait-ToolkitAcknowledgement $summary; break }
                $height = [Math]::Max(1, $size.Height - 8)
                if ($wrappedWidth -ne $size.Width) {
                    $sourceLine = 0; $column = 0
                    for ($index = 0; $index -lt $lineStarts.Count -and $lineStarts[$index] -le $offset; $index++) { $sourceLine = $index }
                    if ($lineStarts.Count) { $column = ($offset - $lineStarts[$sourceLine]) * ($wrappedWidth - 1) }
                    $outputRows = New-Object 'Collections.Generic.List[string]'; $starts = New-Object 'Collections.Generic.List[int]'
                    foreach ($text in $all) {
                        $starts.Add($outputRows.Count)
                        foreach ($part in (Format-ToolkitText $text ($size.Width - 1) -Display)) { $outputRows.Add($part) }
                    }
                    $wrapped = $outputRows.ToArray(); $lineStarts = $starts.ToArray()
                    if ($lineStarts.Count) { $offset = $lineStarts[$sourceLine] + [int][Math]::Floor($column / ($size.Width - 1)) }
                    $wrappedWidth = $size.Width
                }
                $offset = [Math]::Max(0, [Math]::Min($offset, [Math]::Max(0, $wrapped.Count - $height)))
                Show-ToolkitFrame -Frame (New-ToolkitTextFrame $Command.name @($wrapped | Select-Object -Skip $offset -First $height) -Status $summary -Footer @('Up/Down, PgUp/PgDn, Home/End: output', 'Enter/Esc: return') -Size $size)
                if ($null -ne $pendingKey) { $key = $pendingKey; $pendingKey = $null }
                else {
                    $key = Read-ToolkitKey
                    if ((Get-ToolkitGeometryKey (Get-ToolkitTerminalSize)) -ne (Get-ToolkitGeometryKey $size)) { $pendingKey = $key; continue }
                }
                if ($key.Key.ToString() -in @('Enter','Escape')) { break }
                $offset = Get-ToolkitSelection $offset ([Math]::Max(1, $wrapped.Count - $height + 1)) $key.Key.ToString() $height
            }
        }
    }
    finally {
        if (-not $execution.Handle.IsCompleted) { Stop-ToolkitExecution $execution }
    }
}

function Invoke-ToolkitSelectedCommand {
    param([object]$Command, [switch]$Elevated)
    $capability = Get-ToolkitCapability $Command
    if (-not $capability.Available) { Wait-ToolkitAcknowledgement ('Unavailable: ' + $capability.Reason); return }
    $values = @{}
    foreach ($parameter in $Command.parameters) {
        if ($Command.id -in @('security.firewall-control','security.defender-control')) {
            if ($parameter.name -in @('mode','minutes') -and $values.action -eq 'Enable') { continue }
            if ($parameter.name -eq 'minutes' -and $values.mode -eq 'Manual') { continue }
        }
        while ($true) {
            $prompt = $parameter.label
            if ($null -ne $parameter.default) { $prompt += ' [' + $parameter.default + ']' }
            $hints = @("Type: $($parameter.type) | Required: $($parameter.required)")
            if ($parameter.allowedValues.Count) { $hints += 'Choices: ' + ($parameter.allowedValues -join ', ') }
            if ($null -ne $parameter.minimum) { $hints += "Range: $($parameter.minimum)-$($parameter.maximum)" }
            $answer = Read-ToolkitInput $prompt -Description $hints
            if ($null -eq $answer) { return }
            try { $value = Test-ToolkitParameter $parameter $answer; if ($null -ne $value) { $values[$parameter.name] = $value }; break }
            catch { Wait-ToolkitAcknowledgement $_.Exception.Message }
        }
    }
    if ($Command.sourceKind -eq 'CustomScript' -or $Command.requiresAdmin -or $Command.risk -ne 'ReadOnly' -or $Elevated) {
        $process = Start-ToolkitConsole $Command.id $values -Elevated:($Command.requiresAdmin -or $Elevated) -SkipActionConfirmation:($script:ToolkitConfirmActions -eq $false)
        try {
            $lastGeometry = ''
            while (-not $process.HasExited) {
                $size = Get-ToolkitTerminalSize
                $geometry = Get-ToolkitGeometryKey $size
                if (-not $script:ToolkitBasic -and $geometry -ne $lastGeometry) {
                    $instruction = 'Review and confirm there. Waiting for that console to close.'
                    if ($script:ToolkitConfirmActions -eq $false) { $instruction = 'Action confirmations are OFF. The operation may execute immediately.' }
                    Show-ToolkitFrame -Frame (New-ToolkitTextFrame $Command.name @('Operation console is open.', $instruction) -Status 'Waiting for operation console to close' -Size $size -PreserveAll)
                    $lastGeometry = $geometry
                }
                Start-Sleep -Milliseconds 100
            }
            Wait-ToolkitAcknowledgement "Operation console closed (worker exit code $($process.ExitCode)). Detailed results were shown there."
        }
        finally { $process.Dispose() }
    }
    else { Show-ToolkitDiagnostic $Command $values }
}

function Set-ToolkitActionConfirmation {
    if ($script:ToolkitConfirmActions -eq $false) { $script:ToolkitConfirmActions = $true; return }
    $warning = @(
        'WARNING: DISABLE ACTION CONFIRMATIONS',
        '',
        'This skips toolbox yes/typed prompts for ALL modifying commands,',
        'high-risk commands and custom scripts. Selecting Run can immediately',
        'delete files, disable protection, alter updates or force a restart.',
        'Unsaved work can be lost. No per-action confirmation will be requested.',
        '',
        'Windows UAC, permissions, validation and recovery preflight still apply.',
        'Scripts may still ask for their own input. Output consoles remain open.',
        'This setting lasts for this toolkit session only.',
        ''
    )
    $answer = Read-ToolkitInput -Prompt 'Type OFF to disable confirmations; Esc/cancel keeps them on.' -Description $warning
    if ($answer -ceq 'OFF') { $script:ToolkitConfirmActions = $false }
}

function Start-ToolkitInterface {
    param([switch]$Basic)
    Initialize-ToolkitTerminal -Basic:$Basic
    try {
        $category = ''; $query = ''; $isSearch = $false; $selected = 0; $detail = $null; $settingsOpen = $false
        while ($true) {
            if ($settingsOpen) {
                $stateLabel = 'ON'; if ($script:ToolkitConfirmActions -eq $false) { $stateLabel = 'OFF' }
                $items = @([pscustomobject]@{ Label = "Action confirmations: $stateLabel (toggle)"; Value = 'Toggle' }, [pscustomobject]@{ Label = 'Back'; Value = 'Back' })
                $choice = Read-ToolkitMenu 'Settings' $items @('Applies to all modifying, high-risk and custom-script actions.', 'Session only. New toolkit launches start with confirmations ON.')
                if ($choice.Action -eq 'Select' -and $choice.Value -eq 'Toggle') { Set-ToolkitActionConfirmation; continue }
                if ($choice.Action -eq 'Back' -or ($choice.Action -eq 'Select' -and $choice.Value -eq 'Back')) { $settingsOpen = $false; continue }
            }
            elseif ($null -ne $detail) {
                $capability = Get-ToolkitCapability $detail
                $description = @(Get-ToolkitCommandContext $detail)
                if (-not $capability.Available) { $description += 'Unavailable: ' + $capability.Reason }
                $items = @()
                if ($capability.Available) {
                    $runLabel = 'Run (confirmation follows when required)'
                    if ($script:ToolkitConfirmActions -eq $false -and ($detail.risk -ne 'ReadOnly' -or $detail.sourceKind -eq 'CustomScript')) { $runLabel = 'Run now (action confirmations OFF)' }
                    $items += [pscustomobject]@{ Label = $runLabel; Value = 'Run' }
                    if ($detail.sourceKind -eq 'CustomScript' -and -not $detail.requiresAdmin) { $items += [pscustomobject]@{ Label = 'Run as administrator'; Value = 'Elevate' } }
                }
                $items += [pscustomobject]@{ Label = 'Back'; Value = 'Back' }
                $choice = Read-ToolkitMenu $detail.name $items $description -Context $detail
                if ($choice.Action -eq 'Select' -and $choice.Value -in @('Run','Elevate')) {
                    try { Invoke-ToolkitSelectedCommand $detail -Elevated:($choice.Value -eq 'Elevate') }
                    catch { Wait-ToolkitAcknowledgement ('Operation not started: ' + $_.Exception.Message) }
                    continue
                }
                $detail = $null
                if ($choice.Action -eq 'Select') { continue }
            }
            elseif (-not $category -and -not $isSearch) {
                $items = @($script:ToolkitRegistry.commands | Select-Object -ExpandProperty category -Unique | ForEach-Object { [pscustomobject]@{ Label = $_; Value = $_ } })
                $items += [pscustomobject]@{ Label = 'Custom Scripts'; Value = 'Custom Scripts' }
                $items += [pscustomobject]@{ Label = 'Search all commands'; Value = 'Search' }
                $items += [pscustomobject]@{ Label = 'Settings'; Value = 'Settings' }
                $choice = Read-ToolkitMenu 'Command library' $items
                if ($choice.Action -eq 'Select') {
                    if ($choice.Value -eq 'Settings') { $settingsOpen = $true; continue }
                    elseif ($choice.Value -eq 'Search') { $choice.Action = 'Search'; $choice.Value = '' }
                    else { $category = $choice.Value; $selected = 0; continue }
                }
                if ($choice.Action -eq 'Back') { break }
            }
            else {
                $commands = @(Get-ToolkitCatalog -IncludeCustom:($isSearch -or $category -eq 'Custom Scripts'))
                $title = $category
                if ($isSearch) { $commands = @(Find-ToolkitCommand $commands $query); $title = 'Search: ' + $query }
                else { $commands = @($commands | Where-Object category -eq $category) }
                $items = @($commands | ForEach-Object {
                    $label = $_.name
                    if ($_.sourceKind -eq 'CustomScript') { $label += ' [custom: ' + $_.relativePath + ']'; if (-not $_.available) { $label += ' [unavailable]' } }
                    [pscustomobject]@{ Label = $label; Value = $_ }
                })
                $description = @()
                if ($script:ToolkitCustomNotice) { $description = @($script:ToolkitCustomNotice) }
                $choice = Read-ToolkitMenu $title $items $description $selected
                $selected = $choice.Index
                if ($choice.Action -eq 'Select') { $detail = $choice.Value; continue }
                if ($choice.Action -eq 'Back') { $category = ''; $isSearch = $false; $selected = 0; continue }
            }
            if ($choice.Action -eq 'Quit') { break }
            if ($choice.Action -eq 'Refresh') {
                Update-ToolkitCustomCatalog
                $script:ToolkitNotice = "Custom scripts refreshed: $($script:ToolkitCustomCommands.Count) entries"
                if ($script:ToolkitCustomNotice) { $script:ToolkitNotice = 'Refresh incomplete; open Custom Scripts for details' }
                continue
            }
            if ($choice.Action -eq 'Search') {
                $searchText = $choice.Value
                if (-not $searchText) { $searchText = Read-ToolkitInput 'Search all commands' }
                if ($null -ne $searchText) { $query = $searchText; $isSearch = $true; $category = ''; $selected = 0; $settingsOpen = $false }
            }
        }
    }
    finally { Restore-ToolkitTerminal -LeaveScreen }
}
