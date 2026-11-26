function Get-ToolkitTempRoot {
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    if (-not $local) { throw 'The local application-data folder is unavailable.' }
    $root = Test-ToolkitLocalPath -Path (Join-Path $local 'Temp') -Kind Directory
    $item = Get-Item -LiteralPath $root -Force
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Cleanup does not follow reparse points.' }
        $item = $item.Parent
    }
    return $root
}

function Get-ToolkitCleanupPreview {
    $root = Get-ToolkitTempRoot
    $cutoff = [DateTime]::UtcNow.AddDays(-7)
    $preview = New-Object 'Collections.Generic.List[object]'
    foreach ($path in [IO.Directory]::EnumerateFiles($root)) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($null -eq $item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.LastWriteTimeUtc -ge $cutoff) { continue }
        $preview.Add([pscustomobject]@{ Path = $item.FullName; Length = $item.Length; LastWriteTimeUtc = $item.LastWriteTimeUtc })
        if ($preview.Count -ge 200) { break }
    }
    return $preview.ToArray()
}

function Invoke-ToolkitCleanup {
    param([object[]]$Preview, [string]$Confirmation)
    if ($Confirmation -cne 'repair.temp') { throw 'Cleanup requires typed confirmation of this preview.' }
    $root = Get-ToolkitTempRoot
    if (@($Preview).Count -gt 200) { throw 'Cleanup batch exceeds the limit.' }
    foreach ($candidate in $Preview) {
        try {
            if (-not (Test-ToolkitContainedPath $root $candidate.Path) -or [IO.Path]::GetDirectoryName($candidate.Path) -ne $root) { throw 'Candidate is outside the immediate Temp directory.' }
            Test-ToolkitNoReparsePoint $root $candidate.Path
            $current = Get-Item -LiteralPath $candidate.Path -Force -ErrorAction Stop
            if ($current.PSIsContainer -or $current.Length -ne $candidate.Length -or $current.LastWriteTimeUtc -ne $candidate.LastWriteTimeUtc -or $current.LastWriteTimeUtc -ge [DateTime]::UtcNow.AddDays(-7)) { throw 'File changed after preview or is no longer eligible.' }
            Remove-Item -LiteralPath $current.FullName -ErrorAction Stop
            [pscustomobject]@{ Path = $candidate.Path; Status = 'Deleted'; Detail = '' }
        }
        catch { [pscustomobject]@{ Path = $candidate.Path; Status = 'Skipped'; Detail = $_.Exception.Message } }
    }
}

function Invoke-ToolkitRepairAction {
    param([string]$TargetId)
    switch ($TargetId) {
        'repair.restart-spooler' {
            $queueRoot = Join-Path $env:SystemRoot 'System32\spool\PRINTERS'
            $verifiedRoot = Test-ToolkitLocalPath -Path $queueRoot -Kind Directory
            Test-ToolkitNoReparsePoint (Split-Path $verifiedRoot -Parent) $verifiedRoot
            Stop-Service -Name 'Spooler' -Force -ErrorAction Stop
            $removed = 0; $skipped = 0
            try {
                foreach ($filePath in [IO.Directory]::EnumerateFiles($verifiedRoot)) {
                    try {
                        $item = Get-Item -LiteralPath $filePath -Force -ErrorAction Stop
                        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $skipped++; continue }
                        Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
                        $removed++
                    }
                    catch { $skipped++ }
                }
            }
            finally { Start-Service -Name 'Spooler' -ErrorAction Stop }
            [pscustomobject]@{ Service = 'Spooler'; QueuePath = $verifiedRoot; RemovedFiles = $removed; SkippedFiles = $skipped; FinalStatus = [string](Get-Service -Name 'Spooler').Status }
        }
        'repair.icon-cache' {
            $local = [Environment]::GetFolderPath('LocalApplicationData')
            if (-not $local) { throw 'LocalApplicationData is unavailable.' }
            $cacheDir = Test-ToolkitLocalPath -Path (Join-Path $local 'Microsoft\Windows\Explorer') -Kind Directory
            Test-ToolkitNoReparsePoint $local $cacheDir
            Get-Process -Name 'explorer' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
            $removed = 0; $skipped = 0
            try {
                foreach ($filePath in [IO.Directory]::EnumerateFiles($cacheDir)) {
                    $name = [IO.Path]::GetFileName($filePath)
                    if ($name -notlike 'iconcache_*.db' -and $name -notlike 'thumbcache_*.db') { continue }
                    try {
                        $item = Get-Item -LiteralPath $filePath -Force -ErrorAction Stop
                        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $skipped++; continue }
                        Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
                        $removed++
                    }
                    catch { $skipped++ }
                }
            }
            finally {
                $explorerPath = Join-Path $env:SystemRoot 'explorer.exe'
                if (Test-Path -LiteralPath $explorerPath -PathType Leaf) { Start-Process -FilePath $explorerPath | Out-Null }
            }
            [pscustomobject]@{ CachePath = $cacheDir; RemovedFiles = $removed; SkippedFiles = $skipped; ExplorerRestarted = $true }
        }
        default { throw 'Unknown repair operation.' }
    }
}
