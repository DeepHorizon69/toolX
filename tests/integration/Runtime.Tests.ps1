BeforeAll { . (Join-Path (Split-Path $PSScriptRoot -Parent) 'TestSupport.ps1') }

Describe 'Real interpreter adapters with harmless fixtures' {
    BeforeEach {
        $script:ToolkitRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path (Join-Path $script:ToolkitRoot 'Scripts') -Force | Out-Null
    }
    It 'runs batch files literally from paths containing shell characters and Unicode' {
        $folder = 'R&D (Lab) 100% complete! ' + [char]0x5de5 + [char]0x5177
        $directory = Join-Path $script:ToolkitRoot (Join-Path 'Scripts' $folder)
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        foreach ($extension in @('cmd','bat')) {
            $path = Join-Path $directory ("check %PATH%! & test.$extension")
            [IO.File]::WriteAllText($path, "@echo off`r`necho BATCH_STARTED`r`nexit /b 23`r`n", [Text.Encoding]::ASCII)
            $entry = @(Get-ToolkitCustomScript | Where-Object path -eq $path)[0]
            $info = New-ToolkitScriptStartInfo $entry
            $info.CreateNoWindow = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
            $process = [Diagnostics.Process]::Start($info)
            try {
                $output = $process.StandardOutput.ReadToEnd()
                $errorText = $process.StandardError.ReadToEnd()
                $process.WaitForExit()
                $process.ExitCode | Should -Be 23 -Because $errorText
                $output | Should -Match 'BATCH_STARTED'
            }
            finally { $process.Dispose() }
        }
    }
    It 'preserves the PowerShell script directory and explicit exit code' {
        $path = Join-Path $script:ToolkitRoot "Scripts/check O'Brien.ps1"
        [IO.File]::WriteAllText($path, 'Write-Output ($PSScriptRoot -eq (Get-Location).Path); exit 17', (New-Object Text.UTF8Encoding($true)))
        $entry = @(Get-ToolkitCustomScript)[0]
        $info = New-ToolkitScriptStartInfo $entry
        $info.CreateNoWindow = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($info)
        try {
            $output = $process.StandardOutput.ReadToEnd()
            $errorText = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            $process.ExitCode | Should -Be 17 -Because $errorText
            $output | Should -Match 'True'
        }
        finally { $process.Dispose() }
    }
}

Describe 'Double-click launcher' {
    BeforeAll {
        function Invoke-LauncherFixture {
            param([string]$Directory)
            $info = New-Object Diagnostics.ProcessStartInfo
            $info.FileName = Get-ToolkitWindowsExecutable 'cmd.exe'
            $info.Arguments = '/d /v:on /s /c ""%TOOLKIT_LAUNCHER_FIXTURE%""'
            $info.EnvironmentVariables['TOOLKIT_LAUNCHER_FIXTURE'] = Join-Path $Directory 'Toolkit.cmd'
            $info.WorkingDirectory = $TestDrive
            $info.UseShellExecute = $false; $info.CreateNoWindow = $true
            $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
            $process = [Diagnostics.Process]::Start($info)
            try {
                $process.StandardInput.WriteLine('')
                $process.StandardInput.Close()
                if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Launcher fixture did not exit.' }
                [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $process.StandardOutput.ReadToEnd(); ErrorText = $process.StandardError.ReadToEnd() }
            }
            finally { $process.Dispose() }
        }
    }
    BeforeEach {
        $folder = "USB R&D (Lab) %PATH% ! O'Brien " + [char]0x5de5 + [char]0x5177
        $directory = Join-Path (Join-Path $TestDrive ([guid]::NewGuid().ToString())) $folder
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot '.build/Toolkit.cmd') -Destination (Join-Path $directory 'Toolkit.cmd')
    }
    It 'starts its adjacent script from a portable path with inherited delayed expansion enabled' {
        [IO.File]::WriteAllText((Join-Path $directory 'Toolkit.ps1'), 'Write-Output ("LAUNCHER_ROOT=" + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($PSScriptRoot))); exit 0', (New-Object Text.UTF8Encoding($true)))
        [IO.File]::WriteAllText((Join-Path $TestDrive 'Toolkit.ps1'), 'Write-Output "WRONG_SCRIPT"; exit 99', (New-Object Text.UTF8Encoding($true)))
        $result = Invoke-LauncherFixture $directory
        $result.ExitCode | Should -Be 0 -Because $result.ErrorText
        $encodedDirectory = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($directory))
        $result.Output | Should -Match ([regex]::Escape('LAUNCHER_ROOT=' + $encodedDirectory))
        $result.Output | Should -Not -Match 'WRONG_SCRIPT|Toolkit stopped'
    }
    It 'keeps a script failure visible and preserves its exit code' {
        [IO.File]::WriteAllText((Join-Path $directory 'Toolkit.ps1'), 'Write-Output "FIXTURE_FAILURE"; exit 17', (New-Object Text.UTF8Encoding($true)))
        $result = Invoke-LauncherFixture $directory
        $result.ExitCode | Should -Be 17
        $result.Output | Should -Match 'FIXTURE_FAILURE'
        $result.Output | Should -Match 'Toolkit stopped with error code 17'
        $result.Output | Should -Match 'Windows policy'
    }
    It 'reports a missing adjacent toolkit script instead of running another copy' {
        $result = Invoke-LauncherFixture $directory
        $result.ExitCode | Should -Be 2
        $result.Output | Should -Match 'Toolkit.ps1 is missing'
    }
}

Describe 'Asynchronous read-only execution' {
    It 'returns a bounded stream and disposes a real runspace' {
        $execution = Start-ToolkitExecution (Get-TestCommand 'system.environment') @{}
        $lines = New-Object 'Collections.Generic.List[string]'
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while (-not $execution.Handle.IsCompleted -and [DateTime]::UtcNow -lt $deadline) {
            $line = ''
            while ($execution.Queue.TryTake([ref]$line)) { $lines.Add($line) }
            Start-Sleep -Milliseconds 25
        }
        $execution.Handle.IsCompleted | Should -BeTrue
        $line = ''
        while ($execution.Queue.TryTake([ref]$line)) { $lines.Add($line) }
        $result = Complete-ToolkitExecution $execution
        $result.Status | Should -Be 'Succeeded'
        ($lines -join "`n") | Should -Match 'PowerShellVersion'
    }
}

Describe 'Standalone release' {
    It 'starts the GUI launcher beside a script in a portable path without a console shell' {
        $directory = Join-Path $TestDrive ("GUI R&D (Lab) %PATH% ! O'Brien " + [char]0x5de5 + [char]0x5177)
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $launcher = Join-Path $directory 'Toolkit.GUI.exe'
        Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot '.build/Toolkit.GUI.exe') -Destination $launcher
        $fixture = 'param([switch]$Gui); [IO.File]::WriteAllText((Join-Path $PSScriptRoot "started.txt"), ($Gui.ToString() + "|" + [Threading.Thread]::CurrentThread.ApartmentState + "|" + $PSScriptRoot)); exit 0'
        [IO.File]::WriteAllText((Join-Path $directory 'Toolkit.ps1'), $fixture, (New-Object Text.UTF8Encoding($true)))
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $launcher; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
        $process = [Diagnostics.Process]::Start($info)
        try {
            if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'GUI launcher fixture timed out.' }
            $process.ExitCode | Should -Be 0
            [IO.File]::ReadAllText((Join-Path $directory 'started.txt')) | Should -Be ('True|STA|' + $directory)
        }
        finally { $process.Dispose() }
    }
    It 'rejects combining GUI mode with noninteractive entrypoint modes' {
        $candidate = Join-Path $script:RepositoryRoot '.build/Toolkit.ps1'
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = Get-ToolkitPowerShellPath
        $info.Arguments = (@('-NoProfile','-File',$candidate,'-Gui','-Version') | ForEach-Object { ConvertTo-ToolkitArgument $_ }) -join ' '
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($info)
        try {
            $errorText = $process.StandardError.ReadToEnd(); $process.WaitForExit()
            $process.ExitCode | Should -Be 1
            $errorText | Should -Match 'Gui cannot be combined'
        }
        finally { $process.Dispose() }
    }
    It 'runs without the original source or external registry in a path with spaces and Unicode' {
        $candidate = Join-Path $script:RepositoryRoot '.build/Toolkit.ps1'
        Test-Path -LiteralPath $candidate | Should -BeTrue
        $directory = Join-Path $TestDrive ('USB copy ' + [char]0x5de5)
        New-Item -ItemType Directory -Path $directory | Out-Null
        $copy = Join-Path $directory 'Toolkit.ps1'
        Copy-Item -LiteralPath $candidate -Destination $copy
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = Get-ToolkitPowerShellPath
        $info.Arguments = (@('-NoProfile','-File',$copy,'-Version') | ForEach-Object { ConvertTo-ToolkitArgument $_ }) -join ' '
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($info)
        try {
            $output = $process.StandardOutput.ReadToEnd(); $errorText = $process.StandardError.ReadToEnd(); $process.WaitForExit()
            $process.ExitCode | Should -Be 0 -Because $errorText
            $output.Trim() | Should -Be 'TOOLX Windows Edition Alpha 0.2.2 (by ALSA)'
        }
        finally { $process.Dispose() }
        (Get-Item -LiteralPath $copy).Length | Should -BeLessThan 500000
    }
    It 'produces identical bundle text from unchanged inputs' {
        . (Join-Path $script:RepositoryRoot 'tools/Bundler.ps1')
        $first = New-ToolkitBundleText $script:RepositoryRoot
        $second = New-ToolkitBundleText $script:RepositoryRoot
        $first | Should -BeExactly $second
        $first | Should -Not -Match ([regex]::Escape($script:RepositoryRoot))
    }
    It 'runs compact CLI executable standalone with zero leftover temp files and portable Scripts discovery' {
        $compactCli = Join-Path $script:RepositoryRoot '.build/Toolkit.CLI.exe'
        $compactGui = Join-Path $script:RepositoryRoot '.build/Toolkit.exe'
        Test-Path -LiteralPath $compactCli | Should -BeTrue
        Test-Path -LiteralPath $compactGui | Should -BeTrue
        (Get-Item -LiteralPath $compactCli).Length | Should -BeLessThan 250000
        (Get-Item -LiteralPath $compactGui).Length | Should -BeLessThan 250000
        foreach ($exePath in @($compactGui, $compactCli)) {
            $vi = (Get-Item -LiteralPath $exePath).VersionInfo
            $vi.ProductName | Should -Be 'TOOLX Windows Edition'
            $vi.CompanyName | Should -Be 'ALSA'
            $vi.LegalCopyright | Should -Be 'by ALSA'
            $vi.FileVersion | Should -Be '0.2.2.0'
            $vi.ProductVersion | Should -Match 'Alpha 0\.2\.2 \(by ALSA\)'
        }

        $portableDir = Join-Path $TestDrive ('Compact Portable ' + [char]0x5de5)
        New-Item -ItemType Directory -Path (Join-Path $portableDir 'Scripts') -Force | Out-Null
        $exeCopy = Join-Path $portableDir 'Toolkit.CLI.exe'
        Copy-Item -LiteralPath $compactCli -Destination $exeCopy
        Set-Content -LiteralPath (Join-Path $portableDir 'Scripts\Hello.ps1') -Value 'Write-Output "HELLO"'

        $beforeTemp = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'toolX-*' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $exeCopy
        $info.Arguments = '-Version'
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($info)
        try {
            $output = $process.StandardOutput.ReadToEnd(); $errorText = $process.StandardError.ReadToEnd(); $process.WaitForExit()
            $process.ExitCode | Should -Be 0 -Because $errorText
            $output.Trim() | Should -Be 'TOOLX Windows Edition Alpha 0.2.2 (by ALSA)'
        }
        finally { $process.Dispose() }

        $listInfo = New-Object Diagnostics.ProcessStartInfo
        $listInfo.FileName = $exeCopy
        $listInfo.Arguments = '-ListCommands'
        $listInfo.UseShellExecute = $false; $listInfo.CreateNoWindow = $true; $listInfo.RedirectStandardOutput = $true; $listInfo.RedirectStandardError = $true
        $listProc = [Diagnostics.Process]::Start($listInfo)
        try {
            $listOut = $listProc.StandardOutput.ReadToEnd(); $listErr = $listProc.StandardError.ReadToEnd(); $listProc.WaitForExit()
            $listProc.ExitCode | Should -Be 0 -Because $listErr
            $listOut | Should -Match 'custom/hello\.ps1'
        }
        finally { $listProc.Dispose() }

        $afterTemp = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'toolX-*' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        @($afterTemp | Where-Object { $_ -notin $beforeTemp }).Count | Should -Be 0
    }
}
