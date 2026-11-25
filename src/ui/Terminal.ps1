$script:ToolkitTerminalState = $null

function Get-ToolkitTerminalSize {
    try {
        if ([Console]::IsOutputRedirected) { return $null }
        return [pscustomobject]@{ Width = [Console]::WindowWidth; Height = [Console]::WindowHeight; Left = [Console]::WindowLeft; Top = [Console]::WindowTop }
    }
    catch { return $null }
}

function Get-ToolkitGeometryKey {
    param([object]$Size)
    if ($null -eq $Size) { return 'unavailable' }
    return '{0}:{1}:{2}:{3}' -f $Size.Width, $Size.Height, $Size.Left, $Size.Top
}

function Initialize-ToolkitTerminal {
    param([switch]$Basic)
    $script:ToolkitTerminalState = [pscustomobject]@{
        ForcedBasic = ([bool]$Basic -or $Host.Name -ne 'ConsoleHost'); Failed = $false
        Administrator = (Test-ToolkitAdministrator); TrueColor = $false
        Foreground = $null; Background = $null; Cursor = $null
    }
    $script:ToolkitFrameCache = $null
    $script:ToolkitNotice = ''
    try {
        $script:ToolkitTerminalState.Foreground = [Console]::ForegroundColor
        $script:ToolkitTerminalState.Background = [Console]::BackgroundColor
        $script:ToolkitTerminalState.Cursor = [Console]::CursorVisible
        $script:ToolkitTerminalState.TrueColor = -not [Console]::IsOutputRedirected -and $Host.UI.SupportsVirtualTerminal -and ($env:WT_SESSION -or $env:COLORTERM -in @('truecolor','24bit'))
    }
    catch { $script:ToolkitTerminalState.ForcedBasic = $true }
    Update-ToolkitTerminalMode (Get-ToolkitTerminalSize)
    if (-not $script:ToolkitBasic) { try { [Console]::CursorVisible = $false } catch { $script:ToolkitTerminalState.Cursor = $null } }
}

function Update-ToolkitTerminalMode {
    param([object]$Size)
    if ($null -eq $script:ToolkitTerminalState) { return }
    $wasBasic = $script:ToolkitBasic
    $script:ToolkitBasic = $script:ToolkitTerminalState.ForcedBasic -or $script:ToolkitTerminalState.Failed -or $null -eq $Size -or $Size.Width -lt 60 -or $Size.Height -lt 12
    if ($wasBasic -and -not $script:ToolkitBasic -and $null -ne $script:ToolkitTerminalState.Cursor) {
        try { [Console]::CursorVisible = $false } catch { Write-Verbose 'The host cannot hide the cursor.' }
    }
}

function Restore-ToolkitTerminal {
    param([switch]$LeaveScreen)
    if ($null -eq $script:ToolkitTerminalState) { return }
    try {
        if ($script:ToolkitTerminalState.TrueColor) { [Console]::Write(([string][char]27 + '[0m')) }
        if ($null -ne $script:ToolkitTerminalState.Foreground) { [Console]::ForegroundColor = $script:ToolkitTerminalState.Foreground }
        if ($null -ne $script:ToolkitTerminalState.Background) { [Console]::BackgroundColor = $script:ToolkitTerminalState.Background }
        if ($null -ne $script:ToolkitTerminalState.Cursor) { [Console]::CursorVisible = $script:ToolkitTerminalState.Cursor }
        if ($LeaveScreen -and $null -ne $script:ToolkitFrameCache) {
            [Console]::SetCursorPosition([Console]::WindowLeft, [Console]::WindowTop + [Console]::WindowHeight - 1)
            [Console]::WriteLine()
        }
    }
    catch { Write-Verbose 'The host no longer exposes console appearance controls.' }
}

function Read-ToolkitKey {
    return [Console]::ReadKey($true)
}

function Read-ToolkitInput {
    param([string]$Prompt, [string[]]$Description = @())
    $value = ''; $pendingKey = $null; $streamEditing = $false
    while ($true) {
        $size = Get-ToolkitTerminalSize
        Update-ToolkitTerminalMode $size
        $shown = ConvertTo-ToolkitDisplayText $value
        $inputWidth = 70; if ($null -ne $size) { $inputWidth = [Math]::Max(1, $size.Width - 6) }
        if ($shown.Length -gt $inputWidth) { $shown = '...' + $shown.Substring($shown.Length - $inputWidth) }
        $frame = New-ToolkitTextFrame 'Input' (@($Description) + @($Prompt, '', ('> ' + $shown))) -Status 'Awaiting input' -Footer @('Enter: accept | Esc: cancel | Backspace: delete') -Size $size -PreserveAll
        $plain = $script:ToolkitBasic -or $frame.UseBasic
        if ($plain) { Restore-ToolkitTerminal -LeaveScreen }
        Show-ToolkitFrame -Frame $frame -Plain:$plain
        if (($plain -or $script:ToolkitBasic) -and -not $value.Length -and $null -eq $pendingKey -and -not $streamEditing) {
            $answer = Read-Host ((ConvertTo-ToolkitSafeText $Prompt) + ' (cancel to return)')
            if ($answer -ceq 'cancel') { return $null }
            return $answer
        }
        if ($plain) { $streamEditing = $true }
        if ($null -ne $pendingKey) { $key = $pendingKey; $pendingKey = $null }
        else {
            $key = Read-ToolkitKey
            if ((Get-ToolkitGeometryKey (Get-ToolkitTerminalSize)) -ne (Get-ToolkitGeometryKey $size)) { $pendingKey = $key; continue }
        }
        switch ($key.Key.ToString()) {
            'Escape' { return $null }
            'Enter' { return $value }
            'Backspace' { if ($value.Length) { $value = $value.Substring(0, $value.Length - 1) } }
            default { if (-not [char]::IsControl($key.KeyChar) -and $value.Length -lt 2048) { $value += $key.KeyChar } }
        }
    }
}

function Wait-ToolkitAcknowledgement {
    param([string]$Message)
    $frame = New-ToolkitTextFrame 'Result' @($Message) -Status $Message -Footer @('Press any key to return.') -Size (Get-ToolkitTerminalSize) -PreserveAll
    $plain = $script:ToolkitBasic -or $frame.UseBasic
    if ($plain) { Restore-ToolkitTerminal -LeaveScreen }
    Show-ToolkitFrame -Frame $frame -Plain:$plain
    if ($plain -or $script:ToolkitBasic) { Read-Host 'Enter to return' | Out-Null }
    else { Read-ToolkitKey | Out-Null }
}
