BeforeAll { . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1') }

Describe 'Session confirmation setting' {
    BeforeEach { $script:ToolkitConfirmActions = $true; Mock Read-ToolkitInput { '' } }
    It 'keeps confirmations enabled if the warning is cancelled' {
        Mock Read-ToolkitInput { $null }
        Set-ToolkitActionConfirmation
        $script:ToolkitConfirmActions | Should -BeTrue
    }
    It 'requires explicit acknowledgement of the warning before switching off' {
        Mock Read-ToolkitInput { 'OFF' }
        Set-ToolkitActionConfirmation
        $script:ToolkitConfirmActions | Should -BeFalse
        Should -Invoke Read-ToolkitInput -Times 1 -ParameterFilter {
            ($Description -join ' ') -match 'force a restart' -and ($Description -join ' ') -match 'Windows UAC' -and $Prompt -match 'OFF'
        }
    }
    It 'does not treat empty or mistyped acknowledgement as consent' {
        Mock Read-ToolkitInput { 'off' }
        Set-ToolkitActionConfirmation
        $script:ToolkitConfirmActions | Should -BeTrue
    }
    It 'can re-enable confirmations immediately' {
        $script:ToolkitConfirmActions = $false
        Set-ToolkitActionConfirmation
        $script:ToolkitConfirmActions | Should -BeTrue
        Should -Invoke Read-ToolkitInput -Times 0
    }
}

Describe 'Confirmation policy passed to operation consoles' {
    BeforeEach {
        $script:ToolkitEntryPath = Join-Path $script:RepositoryRoot 'src/Main.ps1'
        Mock Start-Process { [pscustomobject]@{ Id = 123 } }
    }
    It 'omits the skip option by default even if a caller has changed a global variable' {
        $script:ToolkitConfirmActions = $false
        Start-ToolkitConsole 'processes.task-manager' @{} | Out-Null
        Should -Invoke Start-Process -Times 1 -ParameterFilter { $ArgumentList -notmatch 'SkipActionConfirmation' }
    }
    It 'passes explicit skip and elevation options together without bypassing UAC' {
        Start-ToolkitConsole 'power.force-restart' @{} -Elevated -SkipActionConfirmation | Out-Null
        Should -Invoke Start-Process -Times 1 -ParameterFilter { $Verb -eq 'RunAs' -and $ArgumentList -match 'SkipActionConfirmation' -and $ArgumentList -match 'RequireElevation' -and $ArgumentList -notmatch 'ExecutionPolicy' }
    }
    It 'propagates the session setting when selecting a high-risk command' {
        $script:ToolkitConfirmActions = $false
        $fakeProcess = [pscustomobject]@{ HasExited = $true; ExitCode = 0 }
        $fakeProcess | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
        Mock Get-ToolkitCapability { [pscustomobject]@{ Available = $true; Reason = '' } }
        Mock Start-ToolkitConsole { $fakeProcess }
        Mock Wait-ToolkitAcknowledgement {}
        Invoke-ToolkitSelectedCommand (Get-TestCommand 'power.force-restart')
        Should -Invoke Start-ToolkitConsole -Times 1 -ParameterFilter { $Elevated -and $SkipActionConfirmation }
    }
}

Describe 'Operation worker without action confirmation' {
    BeforeEach {
        Mock Write-Host {}
        Mock Read-Host { param($Prompt) if ($Prompt -notmatch 'Press Enter to close') { throw 'Unexpected confirmation prompt' }; '' }
        Mock Test-ToolkitAdministrator { $true }
        Mock Get-ToolkitCapability { [pscustomobject]@{ Available = $true; Reason = '' } }
        Mock Invoke-ToolkitPowerRequest {}
        Mock Start-Process {}
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}'))
    }
    It 'skips typed confirmation for high-risk actions only when explicitly requested' {
        Invoke-ToolkitConsoleWorker 'power.force-restart' $payload -SkipConfirmation | Should -Be 0
        Should -Invoke Invoke-ToolkitPowerRequest -Times 1
        Should -Invoke Read-Host -Times 1 -ParameterFilter { $Prompt -match 'Press Enter to close' }
    }
    It 'also skips the yes prompt in the Task Manager screenshot' {
        Invoke-ToolkitConsoleWorker 'processes.task-manager' $payload -SkipConfirmation | Should -Be 0
        Should -Invoke Start-Process -Times 1
        Should -Invoke Read-Host -Times 1
    }
    It 'retains ordinary confirmation when the option is not supplied' {
        Mock Read-Host { '' }
        Invoke-ToolkitConsoleWorker 'processes.task-manager' $payload | Should -Be 1223
        Should -Invoke Start-Process -Times 0
    }
    It 'does not skip administrator checks' {
        Mock Test-ToolkitAdministrator { $false }
        Invoke-ToolkitConsoleWorker 'power.force-restart' $payload -SkipConfirmation | Should -Be 1
        Should -Invoke Invoke-ToolkitPowerRequest -Times 0
    }
    It 'does not skip argument validation' {
        $bad = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"duration":0}'))
        Mock Invoke-ToolkitPowerShellAction {}
        Invoke-ToolkitConsoleWorker 'power.countdown' $bad -SkipConfirmation | Should -Be 1
        Should -Invoke Invoke-ToolkitPowerShellAction -Times 0
    }
    It 'does not skip availability checks' {
        Mock Get-ToolkitCapability { [pscustomobject]@{ Available = $false; Reason = 'Missing feature' } }
        Invoke-ToolkitConsoleWorker 'power.force-restart' $payload -SkipConfirmation | Should -Be 1
        Should -Invoke Invoke-ToolkitPowerRequest -Times 0
    }
    It 'keeps cleanup preview and restricted deletion while removing pagination prompts' {
        Mock Get-ToolkitCleanupPreview { 1..21 | ForEach-Object { [pscustomobject]@{ Path = "C:\Temp\fixture$_.tmp" } } }
        Mock Invoke-ToolkitCleanup {}
        Invoke-ToolkitConsoleWorker 'repair.temp' $payload -SkipConfirmation | Should -Be 0
        Should -Invoke Invoke-ToolkitCleanup -Times 1 -ParameterFilter { $Confirmation -ceq 'repair.temp' -and $Preview.Count -eq 21 }
        Should -Invoke Read-Host -Times 1
    }
    It 'applies to custom scripts without rewriting their own input behavior' {
        $custom = Get-TestCommand 'processes.task-manager' | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        $custom.id = 'custom/example.ps1'; $custom.sourceKind = 'CustomScript'; $custom.risk = 'HighRisk'; $custom.confirmation = 'TypeCommandId'
        $custom | Add-Member -NotePropertyName path -NotePropertyValue 'C:\Toolkit\Scripts\example.ps1'
        Mock Resolve-ToolkitCustomScript { $custom }
        Mock Invoke-ToolkitScriptProcess { 17 }
        Invoke-ToolkitConsoleWorker $custom.id $payload -SkipConfirmation | Should -Be 17
        Should -Invoke Invoke-ToolkitScriptProcess -Times 1
        Should -Invoke Read-Host -Times 1
    }
}
