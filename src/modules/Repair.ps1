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
