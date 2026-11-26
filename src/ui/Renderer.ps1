$script:ToolkitFrameCache = $null
$script:ToolkitEscape = [string][char]27
$script:ToolkitTheme = @{
    Background = @('0D1117', 'Black')
    Border = @('30363D', 'DarkGray', "$($script:ToolkitEscape)[38;2;48;54;61m$($script:ToolkitEscape)[48;2;13;17;23m")
    Primary = @('C9D1D9', 'Gray', "$($script:ToolkitEscape)[38;2;201;209;217m$($script:ToolkitEscape)[48;2;13;17;23m")
    Secondary = @('8B949E', 'DarkGray', "$($script:ToolkitEscape)[38;2;139;148;158m$($script:ToolkitEscape)[48;2;13;17;23m")
    Accent = @('79C5BA', 'Cyan', "$($script:ToolkitEscape)[38;2;121;197;186m$($script:ToolkitEscape)[48;2;13;17;23m")
    Selected = @('0D1117', 'Black', "$($script:ToolkitEscape)[38;2;13;17;23m$($script:ToolkitEscape)[48;2;121;197;186m")
    Success = @('7EE787', 'Green', "$($script:ToolkitEscape)[38;2;126;231;135m$($script:ToolkitEscape)[48;2;13;17;23m")
    Warning = @('D29922', 'Yellow', "$($script:ToolkitEscape)[38;2;210;153;34m$($script:ToolkitEscape)[48;2;13;17;23m")
    Danger = @('F85149', 'Red', "$($script:ToolkitEscape)[38;2;248;81;73m$($script:ToolkitEscape)[48;2;13;17;23m")
}

function ConvertTo-ToolkitDisplayText {
    param([AllowNull()][object]$Text)
    $safe = (ConvertTo-ToolkitSafeText $Text).Replace("`t", '    ').Replace("`r", ' ').Replace("`n", ' ')
    if ($safe -cmatch '^[\x20-\x7E]*$') { return $safe }
    # Positioned output cannot assume a font's Unicode cell widths. Plain output retains Unicode.
    return [regex]::Replace($safe, '[^\x20-\x7E]', { param($match) '\u{0:X4}' -f [int][char]$match.Value })
}

function Format-ToolkitText {
    param([string]$Text, [ValidateRange(1, 32767)][int]$Width = 76, [switch]$Display)
    $safe = (ConvertTo-ToolkitSafeText $Text).Replace("`t", '    ')
    foreach ($line in ($safe -split "`r\n|`r|`n")) {
        $remaining = $line
        if ($Display) { $remaining = ConvertTo-ToolkitDisplayText $remaining }
        while ($remaining.Length -gt $Width) {
            $break = $remaining.LastIndexOf(' ', $Width - 1, $Width)
            if ($break -lt 1) { $break = $Width }
            $remaining.Substring(0, $break)
            $remaining = $remaining.Substring($break).TrimStart()
        }
        $remaining
    }
}

function Format-ToolkitCell {
    param([AllowNull()][object]$Text, [int]$Width)
    if ($Width -le 0) { return '' }
    $value = ConvertTo-ToolkitDisplayText $Text
    if ($value.Length -gt $Width) {
        if ($Width -le 3) { return $value.Substring(0, $Width) }
        $value = $value.Substring(0, $Width - 3) + '...'
    }
    return $value.PadRight($Width)
}

function New-ToolkitRow {
    param([string]$Text = '', [string]$Role = 'Primary')
    return [pscustomobject]@{ Segments = @([pscustomobject]@{ Text = $Text; Role = $Role }) }
}

function Get-ToolkitLineRole {
    param([string]$Text)
    if ($Text -match '^(Failed|PermissionDenied|TimedOut|Unavailable:|Operation not started:|Risk: HighRisk)') { return 'Danger' }
    if ($Text -match '^(WARNING|ACTION CONFIRMATIONS OFF|Cancelled|Risk: SystemModification)') { return 'Warning' }
    if ($Text -match '^(Succeeded|Risk: ReadOnly)') { return 'Success' }
    return 'Primary'
}

function Format-ToolkitMenuLabel {
    param([object]$Item)
    if ($null -ne $Item.Value -and $Item.Value.PSObject.Properties['risk']) {
        $tag = 'Read'
        if ($Item.Value.risk -eq 'SystemModification') { $tag = 'Modify' }
        elseif ($Item.Value.risk -eq 'HighRisk') { $tag = 'High risk' }
        return "[$tag] $($Item.Label)"
    }
    return $Item.Label
}

function Get-ToolkitHeader {
    param([string]$Title, [int]$Width)
    $token = 'Standard user'
    if ($null -ne $script:ToolkitTerminalState -and $script:ToolkitTerminalState.Administrator) { $token = 'ADMINISTRATOR: children inherit' }
    $confirmation = 'Confirmations: ON'; $role = 'Secondary'
    if ($script:ToolkitConfirmActions -eq $false) { $confirmation = 'ACTION CONFIRMATIONS OFF'; $role = 'Warning' }
    elseif ($token.StartsWith('ADMINISTRATOR')) { $role = 'Warning' }
    New-ToolkitRow (Format-ToolkitCell (Get-ToolkitIdentity).Banner $Width) 'Accent'
    New-ToolkitRow (Format-ToolkitCell "$token | $confirmation" $Width) $role
    New-ToolkitRow (Format-ToolkitCell $Title $Width) 'Primary'
    New-ToolkitRow ('-' * $Width) 'Border'
}

function Get-ToolkitCommandContext {
    param([object]$Command)
    $Command.name
    $Command.description
    ''
    "Source: $($Command.sourceKind)"
    "Risk: $($Command.risk)"
    "Administrator requested: $($Command.requiresAdmin)"
    $confirmation = $Command.confirmation
    if ($script:ToolkitConfirmActions -eq $false -and $confirmation -ne 'None') { $confirmation = 'OFF for this session; execution may be immediate' }
    "Confirmation: $confirmation"
    "Cost: $($Command.cost)"
    foreach ($parameter in $Command.parameters) {
        $text = "Parameter: $($parameter.label) [$($parameter.type)]"
        if ($parameter.required) { $text += ' (required)' }
        if ($null -ne $parameter.default) { $text += "; default: $($parameter.default)" }
        if ($parameter.allowedValues.Count) { $text += '; choices: ' + ($parameter.allowedValues -join ', ') }
        if ($null -ne $parameter.minimum) { $text += "; range: $($parameter.minimum)-$($parameter.maximum)" }
        $text
    }
    ''
    $Command.consequences
    if ($Command.sourceKind -eq 'CustomScript') { 'File: ' + $Command.path }
}

function New-ToolkitMenuFrame {
    param([string]$Title, [object[]]$Items, [string[]]$Description, [int]$Selected, [object]$Size, [object]$Context)
    if ($null -eq $Size) { $Size = [pscustomobject]@{ Width = 80; Height = 24 } }
    $width = [Math]::Max(1, $Size.Width - 1); $bodyHeight = [Math]::Max(1, $Size.Height - 8)
    $wide = $Size.Width -ge 110 -and $Size.Height -ge 20
    $leftWidth = $width
    if ($wide) { $leftWidth = [Math]::Max(36, [Math]::Min(48, [int]($width * 0.4))) }
    $preview = @(); $item = $null
    if ($Items.Count) { $item = $Items[$Selected] }
    if ($null -ne $Context) { $preview = $Description }
    elseif ($null -ne $item -and $null -ne $item.Value -and $item.Value.PSObject.Properties['sourceKind']) {
        $preview = @($Description) + @(Get-ToolkitCommandContext $item.Value)
    }
    elseif ($null -ne $item) {
        $preview = @($Description) + @($item.Label)
        $categoryCommands = @($script:ToolkitRegistry.commands | Where-Object category -eq $item.Value)
        if ($categoryCommands.Count) { $preview += @("$($categoryCommands.Count) built-in commands", '') + @($categoryCommands.name) }
        elseif ($item.Value -eq 'Custom Scripts') {
            if ($script:ToolkitCustomLoaded) { $preview += @("$($script:ToolkitCustomCommands.Count) local scripts") + @($script:ToolkitCustomCommands.name) }
            else { $preview += 'Open to discover local scripts.' }
        }
        elseif ($item.Value -eq 'Search') { $preview += 'Search command names, descriptions, IDs and keywords.' }
    }
    else { $preview = @($Description) + @('No matching entries.', 'Use / to search again or Esc to return.') }
    $contextWidth = $width
    if ($wide) { $contextWidth = $width - $leftWidth - 3 }
    $wrapped = @($preview | ForEach-Object { Format-ToolkitText $_ $contextWidth -Display })
    $descriptionLines = @($Description | ForEach-Object { Format-ToolkitText $_ $width -Display })
    $useBasic = $false
    if ($null -ne $Context) {
        if ($wide) { $useBasic = $wrapped.Count -gt $bodyHeight }
        else { $useBasic = $descriptionLines.Count + $Items.Count -gt $bodyHeight }
    }
    elseif ($descriptionLines.Count -ge $bodyHeight) { $useBasic = $true }
    $contextRows = 0
    if (-not $wide) {
        if ($null -ne $Context) { $contextRows = $descriptionLines.Count }
        else { $contextRows = [Math]::Min(3, [Math]::Max(0, $bodyHeight - 2)) }
    }
    $pageSize = [Math]::Max(1, $bodyHeight - $contextRows)
    $start = [int][Math]::Floor($Selected / $pageSize) * $pageSize
    $rows = New-Object 'Collections.Generic.List[object]'
    foreach ($row in (Get-ToolkitHeader $Title $width)) { $rows.Add($row) }
    for ($rowIndex = 0; $rowIndex -lt $bodyHeight; $rowIndex++) {
        $label = ''; $role = 'Primary'; $index = $start + $rowIndex
        if ($rowIndex -lt $pageSize) {
            if ($Items.Count -eq 0 -and $rowIndex -eq 0) { $label = 'No matching entries.' }
            elseif ($index -lt $Items.Count) {
                $marker = '  '
                if ($index -eq $Selected) { $marker = '> '; $role = 'Selected' }
                $label = $marker + (Format-ToolkitMenuLabel $Items[$index])
                if ($role -ne 'Selected' -and $null -ne $Items[$index].Value -and $Items[$index].Value.PSObject.Properties['risk']) { $role = Get-ToolkitLineRole ('Risk: ' + $Items[$index].Value.risk) }
            }
        }
        if ($wide) {
            $right = ''; if ($rowIndex -lt $wrapped.Count) { $right = $wrapped[$rowIndex] }
            if ($wrapped.Count -gt $bodyHeight -and $rowIndex -eq $bodyHeight - 1) { $right = 'Open details for complete information.' }
            $rows.Add([pscustomobject]@{ Segments = @(
                [pscustomobject]@{ Text = (Format-ToolkitCell $label $leftWidth); Role = $role },
                [pscustomobject]@{ Text = ' | '; Role = 'Border' },
                [pscustomobject]@{ Text = (Format-ToolkitCell $right $contextWidth); Role = (Get-ToolkitLineRole $right) }
            ) })
        }
        else {
            if ($rowIndex -ge $pageSize) {
                $contextIndex = $rowIndex - $pageSize
                if ($null -ne $Context) { $label = $descriptionLines[$contextIndex] }
                elseif ($contextIndex -lt $wrapped.Count) { $label = $wrapped[$contextIndex] }
                $role = Get-ToolkitLineRole $label
            }
            $rows.Add((New-ToolkitRow (Format-ToolkitCell $label $width) $role))
        }
    }
    $range = '0 entries'
    if ($Items.Count) { $range = '{0}-{1} of {2}' -f ($start + 1), [Math]::Min($start + $pageSize, $Items.Count), $Items.Count }
    $status = 'Ready'; if ($script:ToolkitNotice) { $status = $script:ToolkitNotice }
    $rows.Add((New-ToolkitRow (Format-ToolkitCell "$status | $range | Home/End, PgUp/PgDn" $width) 'Secondary'))
    $rows.Add((New-ToolkitRow (Format-ToolkitCell 'Up/Down: navigate | Enter: select | Esc: back' $width) 'Secondary'))
    $rows.Add((New-ToolkitRow (Format-ToolkitCell '/: search | R: refresh | Q: exit' $width) 'Secondary'))
    $plain = @((Get-ToolkitIdentity).Banner)
    $token = 'Standard user'
    if ($null -ne $script:ToolkitTerminalState -and $script:ToolkitTerminalState.Administrator) { $token = 'ADMINISTRATOR: children inherit this token' }
    $plain += $token
    if ($script:ToolkitConfirmActions -eq $false) { $plain += 'ACTION CONFIRMATIONS OFF' } else { $plain += 'Action confirmations: ON' }
    $plain += @($Title) + $Description
    if ($script:ToolkitNotice) { $plain += $script:ToolkitNotice }
    for ($index = 0; $index -lt $Items.Count; $index++) { $plain += ('{0}. {1}' -f ($index + 1), (Format-ToolkitMenuLabel $Items[$index])) }
    if (-not $Items.Count) { $plain += 'No matching entries.' }
    $plain += 'Number: select | back/cancel: return | /search text | r: refresh | q: exit'
    return [pscustomobject]@{ Rows = $rows.ToArray(); PlainLines = $plain; UseBasic = $useBasic; PageSize = $pageSize; Size = $Size }
}

function New-ToolkitTextFrame {
    param([string]$Title, [string[]]$Lines, [string]$Status = 'Ready', [string[]]$Footer = @(), [object]$Size, [switch]$PreserveAll)
    if ($null -eq $Size) { $Size = [pscustomobject]@{ Width = 80; Height = 24 } }
    $width = [Math]::Max(1, $Size.Width - 1); $height = [Math]::Max(1, $Size.Height - 8)
    $wrapped = @($Lines | ForEach-Object { Format-ToolkitText $_ $width -Display })
    $rows = New-Object 'Collections.Generic.List[object]'
    foreach ($row in (Get-ToolkitHeader $Title $width)) { $rows.Add($row) }
    for ($index = 0; $index -lt $height; $index++) {
        $text = ''; if ($index -lt $wrapped.Count) { $text = $wrapped[$index] }
        $rows.Add((New-ToolkitRow (Format-ToolkitCell $text $width) (Get-ToolkitLineRole $text)))
    }
    $rows.Add((New-ToolkitRow (Format-ToolkitCell $Status $width) (Get-ToolkitLineRole $Status)))
    for ($index = 0; $index -lt 2; $index++) {
        $text = ''; if ($index -lt $Footer.Count) { $text = $Footer[$index] }
        $rows.Add((New-ToolkitRow (Format-ToolkitCell $text $width) 'Secondary'))
    }
    $plain = @((Get-ToolkitIdentity).Banner, $Title)
    if ($null -ne $script:ToolkitTerminalState -and $script:ToolkitTerminalState.Administrator) { $plain += 'ADMINISTRATOR: children inherit this token' }
    if ($script:ToolkitConfirmActions -eq $false) { $plain += 'ACTION CONFIRMATIONS OFF' }
    return [pscustomobject]@{ Rows = $rows.ToArray(); PlainLines = @($plain + $Lines + @($Status) + $Footer); UseBasic = ($PreserveAll -and $wrapped.Count -gt $height); Size = $Size }
}

function Write-ToolkitRow {
    param([object]$Row, [int]$Left, [int]$Top)
    [Console]::SetCursorPosition($Left, $Top)
    $trueColor = $null -ne $script:ToolkitTerminalState -and $script:ToolkitTerminalState.TrueColor
    if ($trueColor) {
        $builder = New-Object Text.StringBuilder
        $escape = [char]27
        foreach ($segment in $Row.Segments) {
            [void]$builder.Append($script:ToolkitTheme[$segment.Role][2])
            [void]$builder.Append($segment.Text)
        }
        [void]$builder.Append("$escape[0m")
        [Console]::Write($builder.ToString())
    }
    else {
        foreach ($segment in $Row.Segments) {
            $foreground = $script:ToolkitTheme[$segment.Role][1]; $background = 'Black'
            if ($segment.Role -eq 'Selected') { $foreground = 'Black'; $background = 'Cyan' }
            [Console]::ForegroundColor = $foreground; [Console]::BackgroundColor = $background
            [Console]::Write($segment.Text)
        }
    }
}

function Show-ToolkitFrame {
    param([string[]]$Lines, [object]$Frame, [switch]$Plain, [switch]$Retry)
    $size = Get-ToolkitTerminalSize
    if ($null -eq $Frame) { $Frame = New-ToolkitTextFrame 'Output' $Lines -Size $size -PreserveAll }
    if ($Plain -or $script:ToolkitBasic -or $null -eq $size -or $Frame.UseBasic) {
        $script:ToolkitFrameCache = $null
        foreach ($line in $Frame.PlainLines) { Write-Host (ConvertTo-ToolkitSafeText $line) }
        return
    }
    try {
        $geometry = Get-ToolkitGeometryKey $size
        if ((Get-ToolkitGeometryKey $Frame.Size) -ne $geometry) { $script:ToolkitFrameCache = $null; return }
        $previous = $script:ToolkitFrameCache
        $keys = New-Object 'Collections.Generic.List[string]'
        for ($index = 0; $index -lt [Math]::Min($Frame.Rows.Count, $size.Height - 1); $index++) {
            $row = $Frame.Rows[$index]
            $key = ($row.Segments | ForEach-Object { $_.Role + ':' + $_.Text }) -join [char]30
            $keys.Add($key)
            if ($null -eq $previous -or $previous.Geometry -ne $geometry -or $index -ge $previous.Keys.Count -or $previous.Keys[$index] -cne $key) {
                $left = 0; $top = 0
                if ($size.PSObject.Properties['Left']) { $left = $size.Left; $top = $size.Top }
                Write-ToolkitRow $row $left ($top + $index)
            }
        }
        $script:ToolkitFrameCache = [pscustomobject]@{ Geometry = $geometry; Keys = $keys.ToArray() }
    }
    catch {
        $script:ToolkitFrameCache = $null
        if (-not $Retry -and (Get-ToolkitGeometryKey (Get-ToolkitTerminalSize)) -eq $geometry) { Show-ToolkitFrame -Frame $Frame -Retry; return }
        if ($null -ne $script:ToolkitTerminalState) { $script:ToolkitTerminalState.Failed = $true }
        $script:ToolkitBasic = $true
        Restore-ToolkitTerminal
        Write-Host 'Console positioning unavailable; using numbered menus.'
        foreach ($line in $Frame.PlainLines) { Write-Host (ConvertTo-ToolkitSafeText $line) }
    }
}
