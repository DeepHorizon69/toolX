function Test-ToolkitImportSegment {
    param([string]$Value, [string]$Label = 'Name')
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 96) { throw "$Label must be 1 to 96 characters." }
    if ($Value -in @('.','..') -or $Value.StartsWith('_') -or $Value.StartsWith('.')) { throw "$Label cannot start with '.' or '_'." }
    if ($Value -notmatch '^[A-Za-z0-9._-]+$') { throw "$Label may contain only letters, digits, '.', '_' and '-'." }
    return $Value
}

function Get-ToolkitScriptsRoot {
    $root = Join-Path $script:ToolkitRoot 'Scripts'
    if (-not (Test-Path -LiteralPath $root)) {
        $parent = Split-Path $root -Parent
        Test-ToolkitLocalPath -Path $parent -Kind Directory | Out-Null
        $current = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
        while ($null -ne $current) {
            if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse points are not allowed in Scripts root ancestry.' }
            $current = $current.Parent
        }
        [IO.Directory]::CreateDirectory($root) | Out-Null
    }
    $verified = Test-ToolkitLocalPath -Path $root -Kind Directory
    $rootItem = Get-Item -LiteralPath $verified -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'The Scripts directory cannot be a reparse point.' }
    return $verified
}

function Get-ToolkitByteSha256 {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes)
        return ([BitConverter]::ToString($hash).Replace('-', '').ToUpperInvariant())
    }
    finally { $sha.Dispose() }
}

function Save-ToolkitImportedScript {
    param(
        [byte[]]$Bytes,
        [string]$FileName,
        [string]$Folder = '',
        [hashtable]$Metadata = $null,
        [byte[]]$MetadataBytes = $null,
        [switch]$Overwrite
    )
    if ($null -eq $Bytes -or $Bytes.Length -eq 0 -or $Bytes.Length -gt 524288) { throw 'Imported script must be between 1 byte and 512 KiB.' }
    $safeName = Test-ToolkitImportSegment -Value $FileName -Label 'Script file name'
    $ext = [IO.Path]::GetExtension($safeName).ToLowerInvariant()
    if ($ext -notin @('.ps1','.bat','.cmd')) { throw 'Only .ps1, .bat and .cmd scripts can be imported.' }

    $scriptsRoot = Get-ToolkitScriptsRoot
    $targetDir = $scriptsRoot
    if (-not [string]::IsNullOrWhiteSpace($Folder)) {
        $safeFolder = Test-ToolkitImportSegment -Value $Folder.Trim() -Label 'Folder name'
        $targetDir = Join-Path $scriptsRoot $safeFolder
        if (-not (Test-Path -LiteralPath $targetDir)) { [IO.Directory]::CreateDirectory($targetDir) | Out-Null }
        Test-ToolkitNoReparsePoint -Root $scriptsRoot -Path $targetDir
        Test-ToolkitLocalPath -Path $targetDir -Kind Directory | Out-Null
    }

    $destPath = Join-Path $targetDir $safeName
    if (Test-Path -LiteralPath $destPath) {
        if (-not $Overwrite) { throw "Script already exists: $safeName. Enable overwrite to replace it." }
        Test-ToolkitNoReparsePoint -Root $scriptsRoot -Path $destPath
    }

    $metaPayload = $null
    if ($null -ne $MetadataBytes -and $MetadataBytes.Length -gt 0) {
        if ($MetadataBytes.Length -gt 65536) { throw 'Script metadata exceeds 64 KiB.' }
        $metaText = [Text.Encoding]::UTF8.GetString($MetadataBytes)
        $parsed = $metaText | ConvertFrom-Json -ErrorAction Stop
        Test-ToolkitObjectField -Object $parsed -Allowed @('schemaVersion','name','description','requiresAdmin','enabled') -Required @('schemaVersion')
        $metaPayload = $MetadataBytes
    }
    elseif ($null -ne $Metadata -and $Metadata.Count -gt 0) {
        $obj = [ordered]@{ schemaVersion = 1 }
        if ($Metadata.ContainsKey('name') -and -not [string]::IsNullOrWhiteSpace([string]$Metadata.name)) { $obj.name = [string]$Metadata.name }
        if ($Metadata.ContainsKey('description') -and -not [string]::IsNullOrWhiteSpace([string]$Metadata.description)) { $obj.description = [string]$Metadata.description }
        if ($Metadata.ContainsKey('requiresAdmin')) { $obj.requiresAdmin = [bool]$Metadata.requiresAdmin }
        $obj.enabled = $true
        $json = ConvertTo-Json -InputObject ([pscustomobject]$obj) -Depth 3
        $metaPayload = [Text.Encoding]::UTF8.GetBytes($json + "`r`n")
    }

    $metaPath = $destPath + '.json'
    if ($null -ne $metaPayload -and (Test-Path -LiteralPath $metaPath)) {
        if (-not $Overwrite) { throw "Metadata file already exists: $safeName.json. Enable overwrite to replace it." }
        Test-ToolkitNoReparsePoint -Root $scriptsRoot -Path $metaPath
    }

    [IO.File]::WriteAllBytes($destPath, $Bytes)
    if ($null -ne $metaPayload) { [IO.File]::WriteAllBytes($metaPath, $metaPayload) }

    $descriptor = Get-ToolkitCustomDescriptor -File (Get-Item -LiteralPath $destPath -Force) -Root $scriptsRoot
    if (-not $descriptor.available) {
        if (Test-Path -LiteralPath $destPath) { Remove-Item -LiteralPath $destPath -Force -ErrorAction SilentlyContinue }
        if ($null -ne $metaPayload -and (Test-Path -LiteralPath $metaPath)) { Remove-Item -LiteralPath $metaPath -Force -ErrorAction SilentlyContinue }
        throw ("Imported script failed validation: " + $descriptor.unavailableReason)
    }
    return $descriptor
}

function Read-ToolkitZipEntryByte {
    param([object]$Entry, [int]$MaxBytes)
    if ($Entry.Length -gt $MaxBytes) { throw "Zip entry $($Entry.FullName) exceeds size limit." }
    $stream = $Entry.Open()
    $ms = New-Object IO.MemoryStream
    try {
        $buffer = New-Object byte[] 8192
        $total = 0
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $read
            if ($total -gt $MaxBytes) { throw "Zip entry $($Entry.FullName) exceeds size limit." }
            $ms.Write($buffer, 0, $read)
        }
        return ,$ms.ToArray()
    }
    finally {
        $ms.Dispose()
        $stream.Dispose()
    }
}

function Import-ToolkitZipPack {
    param([string]$Path, [string]$DefaultFolder = '', [switch]$Overwrite)
    $verified = Test-ToolkitLocalPath -Path $Path -Kind File
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($verified)
    try {
        $entries = @($zip.Entries | Where-Object { $_.Name -ne '' })
        if ($entries.Count -eq 0) { throw 'The ZIP archive contains no script files.' }
        if ($entries.Count -gt 100) { throw 'The ZIP archive exceeds the 100-entry import limit.' }
        [int64]$totalSize = 0
        $scripts = @{}
        $metas = @{}
        foreach ($entry in $entries) {
            $totalSize += [int64]$entry.Length
            if ($totalSize -gt 5242880) { throw 'Uncompressed ZIP content exceeds 5 MiB limit.' }
            $rel = $entry.FullName.Replace('\', '/')
            if ($rel.StartsWith('/') -or $rel.Contains(':') -or $rel.Contains('..')) { throw "Unsafe path inside ZIP archive: $rel" }
            $parts = @($rel.Split('/'))
            if ($parts.Count -gt 2) { throw "ZIP entry exceeds the 1-subfolder limit: $rel" }
            $folder = $DefaultFolder
            $fileName = $parts[0]
            if ($parts.Count -eq 2) {
                $folder = Test-ToolkitImportSegment -Value $parts[0] -Label 'ZIP folder'
                $fileName = $parts[1]
            }
            $null = Test-ToolkitImportSegment -Value $fileName -Label 'ZIP file'
            $ext = [IO.Path]::GetExtension($fileName).ToLowerInvariant()
            $key = ($folder + '/' + $fileName).ToLowerInvariant()
            if ($ext -in @('.ps1','.bat','.cmd')) {
                $scripts[$key] = @{ Folder = $folder; FileName = $fileName; Entry = $entry }
            }
            elseif ($ext -eq '.json') {
                $metas[$key] = $entry
            }
            else {
                throw "Unsupported file type in ZIP archive: $rel"
            }
        }
        if ($scripts.Count -eq 0) { throw 'No .ps1, .bat or .cmd scripts were found in the ZIP archive.' }
        $imported = New-Object 'Collections.Generic.List[object]'
        foreach ($key in ($scripts.Keys | Sort-Object)) {
            $item = $scripts[$key]
            [byte[]]$bytes = Read-ToolkitZipEntryByte -Entry $item.Entry -MaxBytes 524288
            [byte[]]$metaBytes = $null
            $metaKey = $key + '.json'
            if ($metas.ContainsKey($metaKey)) {
                [byte[]]$metaBytes = Read-ToolkitZipEntryByte -Entry $metas[$metaKey] -MaxBytes 65536
            }
            $imported.Add((Save-ToolkitImportedScript -Bytes $bytes -FileName $item.FileName -Folder $item.Folder -MetadataBytes $metaBytes -Overwrite:$Overwrite))
        }
        return $imported.ToArray()
    }
    finally { $zip.Dispose() }
}

function Import-ToolkitLocalScript {
    param(
        [string]$Path,
        [string]$Folder = '',
        [string]$Name = '',
        [string]$Description = '',
        [switch]$RequiresAdmin,
        [switch]$Overwrite
    )
    $verified = Test-ToolkitLocalPath -Path $Path -Kind File
    $item = Get-Item -LiteralPath $verified -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse points cannot be imported.' }
    $ext = $item.Extension.ToLowerInvariant()
    if ($ext -eq '.zip') {
        return @(Import-ToolkitZipPack -Path $verified -DefaultFolder $Folder -Overwrite:$Overwrite)
    }
    if ($item.Length -gt 524288) { throw 'Script file exceeds 512 KiB limit.' }
    [byte[]]$bytes = [IO.File]::ReadAllBytes($verified)
    [byte[]]$metaBytes = $null
    $metaObj = $null
    $hasCustomMeta = (-not [string]::IsNullOrWhiteSpace($Name)) -or (-not [string]::IsNullOrWhiteSpace($Description)) -or $RequiresAdmin
    if ($hasCustomMeta) {
        $metaObj = @{ name = $Name; description = $Description; requiresAdmin = [bool]$RequiresAdmin }
    }
    elseif (Test-Path -LiteralPath ($verified + '.json') -PathType Leaf) {
        $sibling = Get-Item -LiteralPath ($verified + '.json') -Force
        if (($sibling.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and $sibling.Length -le 65536) {
            [byte[]]$metaBytes = [IO.File]::ReadAllBytes($sibling.FullName)
        }
    }
    return @((Save-ToolkitImportedScript -Bytes $bytes -FileName $item.Name -Folder $Folder -Metadata $metaObj -MetadataBytes $metaBytes -Overwrite:$Overwrite))
}

function Invoke-ToolkitHttpsDownload {
    param([string]$Url, [int]$MaxBytes = 524288)
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or [string]::IsNullOrWhiteSpace($uri.Host)) {
        throw 'Only valid https:// URLs are supported.'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $request = [Net.HttpWebRequest]::Create($uri)
    $request.Method = 'GET'
    $request.Timeout = 15000
    $request.ReadWriteTimeout = 15000
    $request.UserAgent = "TOOLX-WindowsEdition/$script:ToolkitVersion"
    $response = $request.GetResponse()
    $stream = $response.GetResponseStream()
    $ms = New-Object IO.MemoryStream
    try {
        $buffer = New-Object byte[] 8192
        $total = 0
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $read
            if ($total -gt $MaxBytes) { throw "Downloaded content exceeds the $MaxBytes byte safety limit." }
            $ms.Write($buffer, 0, $read)
        }
        return ,$ms.ToArray()
    }
    finally {
        $ms.Dispose()
        $stream.Dispose()
        $response.Close()
    }
}

function Import-ToolkitUrlScript {
    param(
        [string]$Url,
        [string]$FileName = '',
        [string]$Folder = '',
        [string]$ExpectedSha256 = '',
        [string]$Name = '',
        [string]$Description = '',
        [switch]$RequiresAdmin,
        [switch]$Overwrite
    )
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and $ExpectedSha256.Trim() -notmatch '^[a-fA-F0-9]{64}$') {
        throw 'Expected SHA-256 must be 64 hexadecimal characters.'
    }
    [byte[]]$bytes = Invoke-ToolkitHttpsDownload -Url $Url -MaxBytes 524288
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        $actual = Get-ToolkitByteSha256 -Bytes $bytes
        if (-not $actual.Equals($ExpectedSha256.Trim(), [StringComparison]::OrdinalIgnoreCase)) {
            throw "SHA-256 verification failed. Expected $($ExpectedSha256.Trim().ToUpperInvariant()), got $actual."
        }
    }
    if ([string]::IsNullOrWhiteSpace($FileName)) {
        $uri = [Uri]$Url
        $FileName = [IO.Path]::GetFileName($uri.AbsolutePath)
    }
    $metaObj = $null
    if ((-not [string]::IsNullOrWhiteSpace($Name)) -or (-not [string]::IsNullOrWhiteSpace($Description)) -or $RequiresAdmin) {
        $metaObj = @{ name = $Name; description = $Description; requiresAdmin = [bool]$RequiresAdmin }
    }
    return @((Save-ToolkitImportedScript -Bytes $bytes -FileName $FileName -Folder $Folder -Metadata $metaObj -Overwrite:$Overwrite))
}

function Get-ToolkitPublishedManifest {
    param([string]$Url)
    [byte[]]$bytes = Invoke-ToolkitHttpsDownload -Url $Url -MaxBytes 262144
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $manifest = $text | ConvertFrom-Json -ErrorAction Stop
    Test-ToolkitObjectField -Object $manifest -Allowed @('schemaVersion','publisher','scripts') -Required @('schemaVersion','scripts')
    if ($manifest.schemaVersion -isnot [int] -or $manifest.schemaVersion -ne 1) { throw 'Unsupported manifest schemaVersion.' }
    $items = @($manifest.scripts)
    if ($items.Count -eq 0 -or $items.Count -gt 100) { throw 'Manifest must list between 1 and 100 scripts.' }
    $validated = New-Object 'Collections.Generic.List[object]'
    foreach ($entry in $items) {
        Test-ToolkitObjectField -Object $entry -Allowed @('name','description','folder','fileName','url','sha256','requiresAdmin') -Required @('name','fileName','url','sha256')
        $null = Test-ToolkitImportSegment -Value ([string]$entry.fileName) -Label 'Manifest fileName'
        $ext = [IO.Path]::GetExtension([string]$entry.fileName).ToLowerInvariant()
        if ($ext -notin @('.ps1','.bat','.cmd')) { throw "Unsupported manifest file extension: $($entry.fileName)" }
        $folder = ''; if ($entry.PSObject.Properties['folder'] -and -not [string]::IsNullOrWhiteSpace([string]$entry.folder)) { $folder = Test-ToolkitImportSegment -Value ([string]$entry.folder) -Label 'Manifest folder' }
        $entryUri = $null
        if (-not [Uri]::TryCreate([string]$entry.url, [UriKind]::Absolute, [ref]$entryUri) -or $entryUri.Scheme -cne 'https') { throw "Manifest entry $($entry.name) must use an https:// URL." }
        if ([string]$entry.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Manifest entry $($entry.name) must specify a valid 64-character SHA-256." }
        $requiresAdmin = $false
        if ($entry.PSObject.Properties['requiresAdmin']) {
            if ($entry.requiresAdmin -isnot [bool]) { throw "Manifest entry $($entry.name) requiresAdmin must be boolean." }
            $requiresAdmin = $entry.requiresAdmin
        }
        $desc = ''; if ($entry.PSObject.Properties['description']) { $desc = ConvertTo-ToolkitSafeText $entry.description }
        $validated.Add([pscustomobject]@{
            name = ConvertTo-ToolkitSafeText ([string]$entry.name)
            description = $desc
            folder = $folder
            fileName = [string]$entry.fileName
            url = [string]$entry.url
            sha256 = ([string]$entry.sha256).ToUpperInvariant()
            requiresAdmin = $requiresAdmin
        })
    }
    $publisher = ''; if ($manifest.PSObject.Properties['publisher']) { $publisher = ConvertTo-ToolkitSafeText $manifest.publisher }
    return [pscustomobject]@{ Publisher = $publisher; Scripts = $validated.ToArray() }
}

function Import-ToolkitManifestScript {
    param([object[]]$Entries, [switch]$Overwrite)
    $list = @($Entries)
    if ($list.Count -eq 0) { throw 'Select at least one script to import.' }
    $imported = New-Object 'Collections.Generic.List[object]'
    foreach ($entry in $list) {
        $result = Import-ToolkitUrlScript -Url $entry.url -FileName $entry.fileName -Folder $entry.folder -ExpectedSha256 $entry.sha256 -Name $entry.name -Description $entry.description -RequiresAdmin:([bool]$entry.requiresAdmin) -Overwrite:$Overwrite
        foreach ($item in $result) { $imported.Add($item) }
    }
    return $imported.ToArray()
}
