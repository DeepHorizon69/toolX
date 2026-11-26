function Invoke-ToolkitStorageAction {
    param([string]$TargetId, [hashtable]$Values)
    switch ($TargetId) {
        'storage.layout' { Get-CimInstance Win32_DiskPartition -OperationTimeoutSec 15 | Select-Object DiskIndex,Index,DeviceID,Type,Size,StartingOffset,BootPartition }
        'storage.volumes' { Get-CimInstance Win32_LogicalDisk -OperationTimeoutSec 15 | Select-Object DeviceID,VolumeName,FileSystem,DriveType }
        'storage.space' { Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -OperationTimeoutSec 15 | Select-Object DeviceID,Size,FreeSpace }
        'storage.hash' {
            $hash = Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $Values.path -Algorithm SHA256
            if ($Values.ContainsKey('expected')) {
                [pscustomobject]@{ Path = $hash.Path; Algorithm = 'SHA256'; Hash = $hash.Hash; Expected = $Values.expected; Matches = ($hash.Hash -eq $Values.expected) }
                if ($hash.Hash -ne $Values.expected) { throw 'The computed checksum does not match the expected value.' }
            }
            else { $hash }
        }
        'storage.large-files' {
            $root = Test-ToolkitLocalPath -Path $Values.path -Kind Directory
            $top = 25; if ($Values.ContainsKey('top')) { $top = [int]$Values.top }
            $stack = New-Object 'Collections.Generic.Stack[string]'
            $stack.Push($root)
            $collected = New-Object 'Collections.Generic.List[object]'
            $scanned = 0; $skippedFolders = 0; $capped = $false
            while ($stack.Count -gt 0) {
                $current = $stack.Pop()
                try {
                    foreach ($filePath in [IO.Directory]::EnumerateFiles($current)) {
                        $item = Get-Item -LiteralPath $filePath -Force -ErrorAction SilentlyContinue
                        if ($null -eq $item -or $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                        $collected.Add([pscustomobject]@{ Length = [int64]$item.Length; LastWriteTime = $item.LastWriteTime; Path = $item.FullName })
                        $scanned++
                        if ($scanned -ge 50000) { $capped = $true; break }
                    }
                    if ($capped) { break }
                    foreach ($subPath in [IO.Directory]::EnumerateDirectories($current)) {
                        $dir = Get-Item -LiteralPath $subPath -Force -ErrorAction SilentlyContinue
                        if ($null -ne $dir -and ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { $stack.Push($dir.FullName) }
                    }
                }
                catch { $skippedFolders++ }
            }
            $collected | Sort-Object Length -Descending | Select-Object -First $top | ForEach-Object {
                [pscustomobject]@{
                    SizeMiB = [Math]::Round($_.Length / 1MB, 2)
                    SizeGiB = [Math]::Round($_.Length / 1GB, 3)
                    LastWriteTime = $_.LastWriteTime
                    Path = $_.Path
                }
            }
            if ($capped -or $skippedFolders -gt 0) {
                [pscustomobject]@{ ScannedFiles = $scanned; ScanLimitReached = $capped; SkippedFolders = $skippedFolders }
            }
        }
        'storage.shares' {
            '--- SMB shares ---'
            CimCmdlets\Get-CimInstance Win32_Share -OperationTimeoutSec 15 | Select-Object Name,Path,Description,Type
            '--- Mapped network drives ---'
            $mapped = @(CimCmdlets\Get-CimInstance Win32_MappedLogicalDisk -OperationTimeoutSec 15)
            if ($mapped.Count) { $mapped | Select-Object DeviceID,ProviderName,Size,FreeSpace }
            else { 'No mapped network drives were reported.' }
        }
        default { throw 'Unknown storage operation.' }
    }
}
