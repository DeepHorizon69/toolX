#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$defaultFolder = [Environment]::GetFolderPath('Desktop')
if ([string]::IsNullOrWhiteSpace($defaultFolder) -or -not (Test-Path -LiteralPath $defaultFolder -PathType Container)) {
    $defaultFolder = [Environment]::GetFolderPath('MyDocuments')
}
Write-Host "Default output folder: $defaultFolder"
$inputFolder = Read-Host 'Enter output folder path (or press Enter for default)'
$targetFolder = $defaultFolder
if (-not [string]::IsNullOrWhiteSpace($inputFolder)) { $targetFolder = $inputFolder.Trim().Trim('"') }
if (-not (Test-Path -LiteralPath $targetFolder -PathType Container)) {
    throw "Output folder does not exist: $targetFolder"
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportPath = Join-Path $targetFolder "SupportReport-$stamp.txt"

$lines = New-Object 'Collections.Generic.List[string]'
$lines.Add('TOOLX Windows Edition (Alpha 0.2.2 | by ALSA) - IT Support Diagnostic Report')
$lines.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
$lines.Add("Computer: $env:COMPUTERNAME | User: $env:USERNAME")
$lines.Add('')

$lines.Add('=== Operating System ===')
$os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 10
$lines.Add(($os | Select-Object Caption,Version,BuildNumber,OSArchitecture,LastBootUpTime | Format-List | Out-String).Trim())
$lines.Add('')

$lines.Add('=== Computer & CPU ===')
$cs = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 10
$cpu = Get-CimInstance Win32_Processor -OperationTimeoutSec 10
$lines.Add(($cs | Select-Object Manufacturer,Model,TotalPhysicalMemory,SystemType | Format-List | Out-String).Trim())
$lines.Add(($cpu | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed | Format-List | Out-String).Trim())
$lines.Add('')

$lines.Add('=== Fixed Disk Space ===')
$disks = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -OperationTimeoutSec 10 | ForEach-Object {
    [pscustomobject]@{
        Drive = $_.DeviceID; Label = $_.VolumeName; FileSystem = $_.FileSystem
        SizeGiB = [Math]::Round($_.Size / 1GB, 2); FreeGiB = [Math]::Round($_.FreeSpace / 1GB, 2)
    }
}
$lines.Add(($disks | Format-Table -AutoSize | Out-String).Trim())
$lines.Add('')

$lines.Add('=== IP Configuration ===')
$lines.Add((& "$env:SystemRoot\System32\ipconfig.exe" /all | Out-String).Trim())
$lines.Add('')

$lines.Add('=== Recent System Critical & Error Events (24h, max 25) ===')
try {
    $events = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = @(1, 2); StartTime = (Get-Date).AddHours(-24) } -MaxEvents 25 -ErrorAction Stop |
        Select-Object TimeCreated,Id,ProviderName,LevelDisplayName,Message
    $lines.Add(($events | Format-List | Out-String).Trim())
}
catch {
    $lines.Add("Event query note: $($_.Exception.Message)")
}
$lines.Add('')

$lines.Add('=== Minidumps ===')
$minidump = Join-Path $env:SystemRoot 'Minidump'
if (Test-Path -LiteralPath $minidump -PathType Container) {
    $dumps = @(Get-ChildItem -LiteralPath $minidump -Filter '*.dmp' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 10)
    if ($dumps.Count) { $lines.Add(($dumps | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize | Out-String).Trim()) }
    else { $lines.Add('No .dmp files found.') }
}
else { $lines.Add('Minidump directory not present.') }

[IO.File]::WriteAllLines($reportPath, $lines, (New-Object Text.UTF8Encoding($false)))
Write-Host "Support report saved to: $reportPath" -ForegroundColor Green
