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
            $output.Trim() | Should -Be '0.2.1'
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
}
