BeforeAll { . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1'); $script:ToolkitVersion = '0.1.0' }

Describe 'Terminal navigation' {
    It 'clamps arrow navigation at the list boundaries' {
        Get-ToolkitSelection 0 3 'UpArrow' | Should -Be 0
        Get-ToolkitSelection 2 3 'DownArrow' | Should -Be 2
        Get-ToolkitSelection 0 3 'DownArrow' | Should -Be 1
        Get-ToolkitSelection 1 3 'Home' | Should -Be 0
        Get-ToolkitSelection 0 3 'End' | Should -Be 2
    }
    It 'handles empty lists and page navigation' {
        Get-ToolkitSelection 10 0 'DownArrow' | Should -Be 0
        Get-ToolkitSelection 0 30 'PageDown' 10 | Should -Be 10
        Get-ToolkitSelection 10 30 'PageUp' 10 | Should -Be 0
    }
    It 'wraps long text without losing content or overflowing the width' {
        $lines = @(Format-ToolkitText 'A long description with useful information for the operator.' 20)
        @($lines | Where-Object Length -gt 20).Count | Should -Be 0
        ($lines -join ' ') | Should -Be 'A long description with useful information for the operator.'
    }
    It 'selects from the basic menu and accepts back' {
        $script:ToolkitBasic = $true
        Mock Get-ToolkitTerminalSize { $null }
        Mock Show-ToolkitFrame {}
        Mock Read-Host { '2' }
        $items = @([pscustomobject]@{ Label = 'One'; Value = 'one' }, [pscustomobject]@{ Label = 'Two'; Value = 'two' })
        (Read-ToolkitMenu 'Test' $items).Value | Should -Be 'two'
        Mock Read-Host { 'back' }
        (Read-ToolkitMenu 'Test' $items).Action | Should -Be 'Back'
    }
    It 'preserves literal search and refresh in basic mode' {
        $script:ToolkitBasic = $true
        Mock Get-ToolkitTerminalSize { $null }
        Mock Show-ToolkitFrame {}
        Mock Read-Host { '/[literal]' }
        $choice = Read-ToolkitMenu 'Test' @()
        $choice.Action | Should -Be 'Search'
        $choice.Value | Should -Be '[literal]'
        Mock Read-Host { 'r' }
        (Read-ToolkitMenu 'Test' @()).Action | Should -Be 'Refresh'
    }
    It 'supports full-console arrow selection and Escape without executing entries' {
        $script:ToolkitBasic = $false
        Mock Get-ToolkitTerminalSize { [pscustomobject]@{ Width = 80; Height = 24 } }
        Mock Show-ToolkitFrame {}
        $script:testKeys = New-Object 'Collections.Generic.Queue[object]'
        $script:testKeys.Enqueue([pscustomobject]@{ Key = [ConsoleKey]::DownArrow; KeyChar = [char]0 })
        $script:testKeys.Enqueue([pscustomobject]@{ Key = [ConsoleKey]::Enter; KeyChar = [char]13 })
        Mock Read-ToolkitKey { $script:testKeys.Dequeue() }
        $items = @([pscustomobject]@{ Label = 'One'; Value = 'one' }, [pscustomobject]@{ Label = 'Two'; Value = 'two' })
        (Read-ToolkitMenu 'Test' $items).Value | Should -Be 'two'
        $script:testKeys.Enqueue([pscustomobject]@{ Key = [ConsoleKey]::Escape; KeyChar = [char]27 })
        (Read-ToolkitMenu 'Test' $items).Action | Should -Be 'Back'
    }
    It 'cancels full-console parameter input with Escape' {
        $script:ToolkitBasic = $false
        Mock Show-ToolkitFrame {}
        Mock Read-ToolkitKey { [pscustomobject]@{ Key = [ConsoleKey]::Escape; KeyChar = [char]27 } }
        Read-ToolkitInput 'Target' | Should -BeNullOrEmpty
    }
}
