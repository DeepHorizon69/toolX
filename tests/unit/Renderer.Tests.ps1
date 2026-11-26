BeforeAll { . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1') }

Describe 'Adaptive terminal presentation' {
    BeforeEach {
        $script:ToolkitProductName = 'TOOLX Windows Edition'
        $script:ToolkitChannel = 'Alpha'
        $script:ToolkitSignature = 'by ALSA'
        $script:ToolkitVersion = '0.2.2'; $script:ToolkitBasic = $false
        $script:ToolkitConfirmActions = $true; $script:ToolkitFrameCache = $null
        $script:ToolkitTerminalState = $null
        $script:items = @(1..30 | ForEach-Object { [pscustomobject]@{ Label = "Command $_"; Value = $_ } })
        Mock Write-ToolkitRow {}
        Mock Write-Host {}
    }

    It 'fits rows and keeps the selected item visible at <Width>x<Height>' -ForEach @(
        @{ Width=60; Height=12 }, @{ Width=60; Height=20 }, @{ Width=80; Height=24 },
        @{ Width=109; Height=19 }, @{ Width=109; Height=20 }, @{ Width=110; Height=20 }, @{ Width=120; Height=30 }
    ) {
        $size = [pscustomobject]@{ Width=$Width; Height=$Height }
        $frame = New-ToolkitMenuFrame 'Test' $script:items @() 25 $size
        $frame.Rows.Count | Should -Be ($Height - 1)
        foreach ($row in $frame.Rows) { (($row.Segments.Text -join '').Length) | Should -Be ($Width - 1) }
        ($frame.Rows.Segments.Text -join '') | Should -Match '> Command 26'
        $frame.PageSize | Should -BeGreaterThan 0
    }

    It 'uses two panels only above both wide-layout thresholds' {
        foreach ($size in @(@{Width=109;Height=30}, @{Width=120;Height=19})) {
            $frame = New-ToolkitMenuFrame 'Test' $script:items @() 0 ([pscustomobject]$size)
            $frame.Rows[4].Segments.Count | Should -Be 1
        }
        $frame = New-ToolkitMenuFrame 'Test' $script:items @() 0 ([pscustomobject]@{Width=110;Height=20})
        $frame.Rows[4].Segments.Count | Should -Be 3
    }

    It 'performs no writes for an identical frame and only changes affected rows' {
        Mock Get-ToolkitTerminalSize { [pscustomobject]@{Width=120;Height=30;Left=0;Top=0} }
        $frame = New-ToolkitMenuFrame 'Test' $script:items @() 0 (Get-ToolkitTerminalSize)
        Show-ToolkitFrame -Frame $frame
        Show-ToolkitFrame -Frame $frame
        Should -Invoke Write-ToolkitRow -Times 29 -Exactly
        Show-ToolkitFrame -Frame (New-ToolkitMenuFrame 'Test' $script:items @() 1 (Get-ToolkitTerminalSize))
        Should -Invoke Write-ToolkitRow -Times 31 -Exactly
        Should -Invoke Write-ToolkitRow -Times 1 -Exactly -ParameterFilter { $Top -eq 0 }
    }

    It 'pads a shorter row and invalidates cached geometry including viewport offsets' {
        $script:size = [pscustomobject]@{Width=80;Height=24;Left=2;Top=5}
        Mock Get-ToolkitTerminalSize { $script:size }
        Show-ToolkitFrame -Frame (New-ToolkitTextFrame 'Test' @('Long text') -Size $script:size)
        Show-ToolkitFrame -Frame (New-ToolkitTextFrame 'Test' @('Short') -Size $script:size)
        Should -Invoke Write-ToolkitRow -Times 1 -ParameterFilter { $Top -eq 9 -and $Row.Segments[0].Text -eq ('Short'.PadRight(79)) }
        $script:size.Top = 6
        Show-ToolkitFrame -Frame (New-ToolkitTextFrame 'Test' @('Short') -Size $script:size)
        Should -Invoke Write-ToolkitRow -Times 47 -Exactly
    }

    It 'falls back to complete text when details or warnings do not fit' {
        $command = Get-TestCommand 'power.force-restart'
        $description = @(Get-ToolkitCommandContext $command) + @('Important consequence: ' + ('X' * 500))
        $frame = New-ToolkitMenuFrame $command.name @([pscustomobject]@{Label='Run';Value='Run'}) $description 0 ([pscustomobject]@{Width=60;Height=12}) $command
        $frame.UseBasic | Should -BeTrue
        ($frame.PlainLines -join ' ') | Should -Match ([regex]::Escape($description[-1]))
        $inputFrame = New-ToolkitTextFrame 'Input' $description -Size ([pscustomobject]@{Width=80;Height=24}) -PreserveAll
        $inputFrame.UseBasic | Should -BeTrue
    }

    It 'shows admin inheritance and confirmations OFF without truncation at minimum rich width' {
        $script:ToolkitTerminalState = [pscustomobject]@{Administrator=$true}
        $script:ToolkitConfirmActions = $false
        $rows = @(Get-ToolkitHeader 'Test' 59)
        $rows[0].Segments[0].Text | Should -Match 'TOOLX Windows Edition Alpha 0\.2\.2 \| by ALSA'
        $rows[1].Segments[0].Text | Should -Match 'ADMINISTRATOR: children inherit.*ACTION CONFIRMATIONS OFF'
        $rows[1].Segments[0].Role | Should -Be 'Warning'
    }

    It 'constructs previews without capability checks or custom discovery' {
        Mock Get-ToolkitCapability { throw 'Preview queried the system' }
        Mock Update-ToolkitCustomCatalog { throw 'Preview discovered files' }
        $command = Get-TestCommand 'network.ping'
        $entries = @([pscustomobject]@{Label=$command.name;Value=$command})
        $frame = New-ToolkitMenuFrame 'Networking' $entries @() 0 ([pscustomobject]@{Width=120;Height=30})
        ($frame.Rows.Segments.Text -join '') | Should -Match 'Target hostname or IP'
        Should -Invoke Get-ToolkitCapability -Times 0
        Should -Invoke Update-ToolkitCustomCatalog -Times 0
    }

    It 'keeps complete metadata and actions reachable for all 91 built-ins' {
        foreach ($command in $script:ToolkitRegistry.commands) {
            $description = @(Get-ToolkitCommandContext $command)
            $frame = New-ToolkitMenuFrame $command.name @([pscustomobject]@{Label='Run';Value='Run'}, [pscustomobject]@{Label='Back';Value='Back'}) $description 0 ([pscustomobject]@{Width=120;Height=30}) $command
            ($frame.PlainLines -join ' ') | Should -Match ([regex]::Escape($command.consequences))
            ($frame.PlainLines -join ' ') | Should -Match ('Risk: ' + $command.risk)
            if (-not $frame.UseBasic) { ($frame.Rows.Segments.Text -join '') | Should -Match '> Run' }
        }
    }

    It 'strips terminal controls and safely displays uncertain Unicode cells without changing original text' {
        $original = 'Path ' + [char]0x5de5 + ([string][char]27 + '[31m') + "`tend"
        $display = ConvertTo-ToolkitDisplayText $original
        $display | Should -Be 'Path \u5DE5    end'
        (ConvertTo-ToolkitSafeText $original) | Should -Match ([string][char]0x5de5)
        @(Format-ToolkitText ('x' * 100) 1 -Display).Count | Should -Be 100
        Format-ToolkitCell 'abcdef' 2 | Should -Be 'ab'
    }

    It 'uses plain output without calling the positioned writer' {
        Mock Get-ToolkitTerminalSize { $null }
        Show-ToolkitFrame @('Retained output')
        Should -Invoke Write-ToolkitRow -Times 0
        Should -Invoke Write-Host -ParameterFilter { $Object -eq 'Retained output' }
    }

    It 'restores console appearance and switches to basic on a positioning failure' {
        Mock Get-ToolkitTerminalSize { [pscustomobject]@{Width=80;Height=24} }
        Mock Write-ToolkitRow { throw 'Console resized' }
        Mock Restore-ToolkitTerminal {}
        $script:ToolkitTerminalState = [pscustomobject]@{Administrator=$false;Failed=$false}
        Show-ToolkitFrame @('Retained output')
        $script:ToolkitBasic | Should -BeTrue
        $script:ToolkitTerminalState.Failed | Should -BeTrue
        Should -Invoke Restore-ToolkitTerminal -Times 1
        Should -Invoke Write-Host -ParameterFilter { $Object -eq 'Retained output' }
    }

    It 'distinguishes actual execution status with readable labels' -ForEach @(
        @{Status='Succeeded';Role='Success'}, @{Status='Failed';Role='Danger'},
        @{Status='PermissionDenied';Role='Danger'}, @{Status='TimedOut';Role='Danger'},
        @{Status='Cancelled';Role='Warning'}, @{Status='Running';Role='Primary'}
    ) {
        Get-ToolkitLineRole $Status | Should -Be $Role
    }
}

Describe 'Resize and input compatibility' {
    BeforeEach {
        $script:ToolkitTerminalState = $null; $script:ToolkitBasic = $false
        $script:size = [pscustomobject]@{Width=120;Height=30;Left=0;Top=0}
        Mock Get-ToolkitTerminalSize { $script:size }
        Mock Show-ToolkitFrame {}
        Mock Restore-ToolkitTerminal {}
    }

    It 'preserves a navigation key across reflow and applies it exactly once' {
        $script:keyIndex = 0
        Mock Read-ToolkitKey {
            $script:keyIndex++
            if ($script:keyIndex -eq 1) {
                $script:size = [pscustomobject]@{Width=80;Height=24;Left=0;Top=0}
                return [pscustomobject]@{Key=[ConsoleKey]::DownArrow;KeyChar=[char]0}
            }
            return [pscustomobject]@{Key=[ConsoleKey]::Enter;KeyChar=[char]13}
        }
        $items = @(1..4 | ForEach-Object { [pscustomobject]@{Label="Item $_";Value=$_} })
        $choice = Read-ToolkitMenu 'Test' $items
        $choice.Value | Should -Be 2
        $choice.Index | Should -Be 1
        Should -Invoke Read-ToolkitKey -Times 2
    }

    It 'preserves typed input and treats shortcut letters literally through resize' {
        $script:keys = New-Object 'Collections.Generic.Queue[object]'
        foreach ($character in @('q','r','/')) { $script:keys.Enqueue([pscustomobject]@{Key=[ConsoleKey]::A;KeyChar=[char]$character}) }
        $script:keys.Enqueue([pscustomobject]@{Key=[ConsoleKey]::Enter;KeyChar=[char]13})
        Mock Read-ToolkitKey {
            $script:size = [pscustomobject]@{Width=80;Height=24;Left=0;Top=0}
            $script:keys.Dequeue()
        }
        Read-ToolkitInput 'Target' | Should -Be 'qr/'
        Should -Invoke Read-ToolkitKey -Times 4
    }

    It 'recovers from size fallback but retains forced and failed fallback' {
        $script:ToolkitTerminalState = [pscustomobject]@{ForcedBasic=$false;Failed=$false}
        foreach ($size in @(@{Width=59;Height=24}, @{Width=80;Height=11})) {
            Update-ToolkitTerminalMode ([pscustomobject]$size)
            $script:ToolkitBasic | Should -BeTrue
        }
        Update-ToolkitTerminalMode ([pscustomobject]@{Width=60;Height=12})
        $script:ToolkitBasic | Should -BeFalse
        $script:ToolkitTerminalState.ForcedBasic = $true
        Update-ToolkitTerminalMode $script:size
        $script:ToolkitBasic | Should -BeTrue
        $script:ToolkitTerminalState.ForcedBasic = $false; $script:ToolkitTerminalState.Failed = $true
        Update-ToolkitTerminalMode $script:size
        $script:ToolkitBasic | Should -BeTrue
    }

    It 'retains text and the pending Enter when a populated input shrinks into basic mode' {
        $script:ToolkitTerminalState = [pscustomobject]@{ForcedBasic=$false;Failed=$false;Cursor=$null;Administrator=$false}
        $script:readCount = 0
        Mock Read-Host { throw 'Partially typed input was discarded' }
        Mock Read-ToolkitKey {
            $script:readCount++
            if ($script:readCount -eq 1) { return [pscustomobject]@{Key=[ConsoleKey]::A;KeyChar=[char]'a'} }
            $script:size = [pscustomobject]@{Width=59;Height=11;Left=0;Top=0}
            return [pscustomobject]@{Key=[ConsoleKey]::Enter;KeyChar=[char]13}
        }
        Read-ToolkitInput 'Target' | Should -Be 'a'
        Should -Invoke Read-ToolkitKey -Times 2
    }
}
