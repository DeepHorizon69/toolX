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
        default { throw 'Unknown storage operation.' }
    }
}
