function Format-ToolkitSpecificationValue {
    param([string]$Section, [string]$Field, [AllowNull()][object]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return 'Not reported' }
    if ($Value -is [bool]) { if ($Value) { return 'Yes' }; return 'No' }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss') }
    $number = 0.0
    if ([double]::TryParse([string]$Value, [ref]$number)) {
        $unit = ''; $divisor = 1.0
        if ($Field -in @('TotalPhysicalMemory','Capacity','Size','FreeSpace')) {
            $unit = 'GiB'; $divisor = 1GB
            if ($number -gt 0 -and $number -lt 1GB) { $unit = 'MiB'; $divisor = 1MB }
        }
        elseif ($Field -eq 'MaxClockSpeed' -or ($Section -eq 'Memory' -and $Field -eq 'Speed')) { $unit = 'MHz' }
        elseif ($Section -eq 'Adapter' -and $Field -eq 'Speed') {
            $unit = 'Mbit/s'; $divisor = 1000000
            if ($number -ge 1000000000) { $unit = 'Gbit/s'; $divisor = 1000000000 }
        }
        elseif ($Field -in @('DesignCapacity','FullChargeCapacity')) { $unit = 'mWh' }
        elseif ($Field -eq 'HealthPercent') { $unit = '%' }
        if ($unit) { return (($number / $divisor).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) + ' ' + $unit) }
    }
    return (ConvertTo-ToolkitSafeText $Value).Trim()
}

function Get-ToolkitSpecificationBlock {
    param([object[]]$Records)
    $blocks = New-Object 'Collections.Generic.List[object]'
    $byKey = @{}; $batteryIndex = 0
    $labels = @{
        TotalPhysicalMemory = 'RAM'; NumberOfCores = 'Cores'; NumberOfLogicalProcessors = 'Threads'
        MaxClockSpeed = 'Max clock'; DeviceLocator = 'Slot'; PartNumber = 'Part number'
        DriverVersion = 'Driver'; CurrentHorizontalResolution = 'Width'; CurrentVerticalResolution = 'Height'
        SMBIOSBIOSVersion = 'Version'; ReleaseDate = 'Released'; LastBootUpTime = 'Last boot'
        OSArchitecture = 'Architecture'; BuildNumber = 'Build'; DeviceID = 'Device'; DiskIndex = 'Disk'
        InterfaceType = 'Interface'; VolumeName = 'Label'; FileSystem = 'Filesystem'; FreeSpace = 'Free'
        NetConnectionID = 'Connection'; NetEnabled = 'Enabled'; SystemType = 'System type'
        DesignCapacity = 'Design capacity'; FullChargeCapacity = 'Full charge'; HealthPercent = 'Health'
    }
    foreach ($record in $Records) {
        $section = [string]$record.Section
        $device = Get-ToolkitProperty $record 'DeviceIndex' 0
        $isBattery = $null -eq $record.PSObject.Properties['Field']
        if ($isBattery) { $device = $batteryIndex; $batteryIndex++ }
        $key = $section + ':' + $device
        if (-not $byKey.ContainsKey($key)) {
            $block = [pscustomobject]@{ Section = $section; Device = $device; Title = $section; Lines = (New-Object 'Collections.Generic.List[string]') }
            $byKey[$key] = $block; $blocks.Add($block)
        }
        $block = $byKey[$key]
        if ($isBattery) {
            foreach ($field in @('DesignCapacity','FullChargeCapacity','HealthPercent','Detail')) {
                if ($null -eq $record.PSObject.Properties[$field]) { continue }
                $label = $field; if ($labels.ContainsKey($field)) { $label = $labels[$field] }
                $block.Lines.Add($label + ': ' + (Format-ToolkitSpecificationValue $section $field $record.$field))
            }
            if ($record.Status) { $block.Lines.Add('Status: ' + (ConvertTo-ToolkitSafeText $record.Status)) }
        }
        elseif ($record.Status -ne 'Reported') { $block.Lines.Add('Unavailable: ' + (ConvertTo-ToolkitSafeText $record.Value)) }
        else {
            $label = $record.Field; if ($labels.ContainsKey($label)) { $label = $labels[$label] }
            $block.Lines.Add($label + ': ' + (Format-ToolkitSpecificationValue $section $record.Field $record.Value))
        }
    }
    foreach ($block in $blocks) {
        if (@($blocks | Where-Object Section -eq $block.Section).Count -gt 1) { $block.Title += ' ' + ($block.Device + 1) }
    }
    return $blocks.ToArray()
}

function Format-ToolkitSpecificationLayout {
    param([object[]]$Blocks, [ValidateRange(1,32767)][int]$Width = 79, [switch]$Display)
    if (-not $Blocks.Count) { return 'No specification data was reported.' }
    $columnCount = [Math]::Min($Blocks.Count, [Math]::Max(1, [int][Math]::Floor(($Width + 3) / 43)))
    $columnWidth = [Math]::Max(1, [int][Math]::Floor(($Width - 3 * ($columnCount - 1)) / $columnCount))
    $columns = @()
    for ($index = 0; $index -lt $columnCount; $index++) { $columns += ,(New-Object 'Collections.Generic.List[string]') }
    foreach ($block in $Blocks) {
        $target = 0
        for ($index = 1; $index -lt $columnCount; $index++) { if ($columns[$index].Count -lt $columns[$target].Count) { $target = $index } }
        if ($columns[$target].Count) { $columns[$target].Add('') }
        foreach ($line in (@('[' + $block.Title + ']') + @($block.Lines))) {
            foreach ($part in (Format-ToolkitText $line $columnWidth -Display:$Display)) { $columns[$target].Add($part) }
        }
    }
    $height = 0
    foreach ($column in $columns) { $height = [Math]::Max($height, $column.Count) }
    for ($row = 0; $row -lt $height; $row++) {
        $cells = @()
        foreach ($column in $columns) {
            $text = ''; if ($row -lt $column.Count) { $text = $column[$row] }
            $cells += $text.PadRight($columnWidth)
        }
        ($cells -join ' | ').TrimEnd()
    }
}
