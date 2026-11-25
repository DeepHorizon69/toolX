function Test-ToolkitContainedPath {
    param([string]$Root, [string]$Path)
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath($Path)
    return $full.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)
}

function Test-ToolkitNoReparsePoint {
    param([string]$Root, [string]$Path)
    if (-not (Test-ToolkitContainedPath -Root $Root -Path $Path)) { throw 'Script path is outside the Scripts directory.' }
    $current = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    while ($null -ne $current) {
        if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse points are not allowed in script paths.' }
        if ($current.FullName.TrimEnd('\').Equals($rootPath, [StringComparison]::OrdinalIgnoreCase)) { return }
        if ($current -is [IO.FileInfo]) { $current = $current.Directory }
        else { $current = $current.Parent }
    }
    throw 'Script root could not be verified.'
}

function Get-ToolkitCustomDescriptor {
    param([IO.FileInfo]$File, [string]$Root)
    $relative = $File.FullName.Substring($Root.TrimEnd('\').Length + 1).Replace('\', '/')
    $entry = [pscustomobject]@{
        id = 'custom/' + $relative.ToLowerInvariant(); name = $File.BaseName
        description = 'Local custom script. Its behavior has not been reviewed by the toolkit.'
        category = 'Custom Scripts'; keywords = @($relative, $File.Extension.TrimStart('.'))
        sourceKind = 'CustomScript'; executionType = 'CustomScript'; targetId = $relative
        path = $File.FullName; relativePath = $relative; parameters = @()
        requiresAdmin = $false; risk = 'HighRisk'; confirmation = 'TypeCommandId'
        consequences = 'Runs your script with the displayed Windows permissions. The toolkit does not restrict its system or network access.'
        cost = 'Variable'; networkAccess = 'UserScript'; cancellation = 'Unavailable'
        available = $true; unavailableReason = ''; enabled = $true
    }
    try {
        Test-ToolkitNoReparsePoint -Root $Root -Path $File.FullName
        $metadataPath = $File.FullName + '.json'
        if (Test-Path -LiteralPath $metadataPath) {
            Test-ToolkitNoReparsePoint -Root $Root -Path $metadataPath
            $metadataFile = Get-Item -LiteralPath $metadataPath -Force
            if ($metadataFile.PSIsContainer -or $metadataFile.Length -gt 65536) { throw 'Metadata must be a file no larger than 64 KiB.' }
            $metadata = [IO.File]::ReadAllText($metadataPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
            Test-ToolkitObjectField -Object $metadata -Allowed @('schemaVersion','name','description','requiresAdmin','enabled') -Required @('schemaVersion')
            if ($metadata.schemaVersion -isnot [int] -or $metadata.schemaVersion -ne 1) { throw 'Metadata schemaVersion must be 1.' }
            foreach ($name in @('name','description')) {
                if ($metadata.PSObject.Properties[$name]) {
                    if ($metadata.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($metadata.$name) -or $metadata.$name.Length -gt 1024) { throw "Invalid metadata $name." }
                    $entry.$name = ConvertTo-ToolkitSafeText $metadata.$name
                }
            }
            foreach ($name in @('requiresAdmin','enabled')) {
                if ($metadata.PSObject.Properties[$name]) {
                    if ($metadata.$name -isnot [bool]) { throw "Metadata $name must be a JSON boolean." }
                    $entry.$name = $metadata.$name
                }
            }
        }
        if (-not $entry.enabled) { throw 'Disabled by script metadata.' }
    }
    catch { $entry.available = $false; $entry.unavailableReason = $_.Exception.Message }
    return $entry
}

function Get-ToolkitCustomScript {
    $root = Join-Path $script:ToolkitRoot 'Scripts'
    $script:ToolkitCustomNotice = ''
    $result = New-Object 'Collections.Generic.List[object]'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    try {
        Test-ToolkitLocalPath -Path $root -Kind Directory | Out-Null
        if (((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'The Scripts directory cannot be a reparse point.' }
        $directories = @($root)
        $directories += @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop | Where-Object { $_.Name -notmatch '^[_.]' -and ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 } | Sort-Object Name | Select-Object -First 501 | ForEach-Object { $_.FullName })
        if ($directories.Count -gt 501) { $script:ToolkitCustomNotice = 'Discovery is incomplete: more than 500 script folders.' }
        foreach ($directory in $directories) {
            foreach ($file in (Get-ChildItem -LiteralPath $directory -File -ErrorAction Stop)) {
                if ($file.Extension.ToLowerInvariant() -notin @('.ps1','.bat','.cmd') -or $file.Name -match '^[_.]') { continue }
                if ($result.Count -ge 500) { $script:ToolkitCustomNotice = 'Discovery is incomplete: the 500-script limit was reached.'; return $result.ToArray() }
                $result.Add((Get-ToolkitCustomDescriptor -File $file -Root $root))
            }
        }
    }
    catch { $script:ToolkitCustomNotice = $_.Exception.Message }
    return @($result.ToArray() | Sort-Object relativePath)
}

function Update-ToolkitCustomCatalog {
    $script:ToolkitCustomCommands = @(Get-ToolkitCustomScript)
    $script:ToolkitCustomLoaded = $true
}

function Resolve-ToolkitCustomScript {
    param([string]$Id)
    if (-not $Id.StartsWith('custom/', [StringComparison]::Ordinal)) { throw 'Invalid custom command ID.' }
    $relative = $Id.Substring(7).Replace('/', '\')
    if ($relative -match '(^|\\)\.\.?($|\\)' -or [IO.Path]::IsPathRooted($relative) -or $relative.Contains(':') -or $relative.Split('\').Count -gt 2) { throw 'Invalid custom script path.' }
    foreach ($part in $relative.Split('\')) { if ($part -match '^[_.]') { throw 'Support files are not entrypoints.' } }
    $root = Join-Path $script:ToolkitRoot 'Scripts'
    $path = Join-Path $root $relative
    Test-ToolkitNoReparsePoint -Root $root -Path $path
    Test-ToolkitLocalPath -Path $path -Kind File | Out-Null
    $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($file.Extension.ToLowerInvariant() -notin @('.ps1','.bat','.cmd')) { throw 'Unsupported script format.' }
    $entry = Get-ToolkitCustomDescriptor -File $file -Root $root
    if (-not $entry.available) { throw $entry.unavailableReason }
    return $entry
}
