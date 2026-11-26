function Get-ToolkitProperty {
    param([object]$Object, [string]$Name, [object]$Default = $null)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Test-ToolkitObjectField {
    param([object]$Object, [string[]]$Allowed, [string[]]$Required = @())
    if ($null -eq $Object -or $Object -isnot [pscustomobject]) { throw 'Expected a JSON object.' }
    foreach ($property in $Object.PSObject.Properties.Name) {
        if ($property -notin $Allowed) { throw "Unknown field: $property" }
    }
    foreach ($property in $Required) {
        if ($null -eq $Object.PSObject.Properties[$property]) { throw "Missing field: $property" }
    }
}

function Test-ToolkitLocalPath {
    param([string]$Path, [ValidateSet('File', 'Directory')][string]$Kind = 'File')
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOfAny([char[]]"`r`n`0") -ge 0) { throw 'Enter a local path.' }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.Substring(2).Contains(':')) { throw 'Only local drive paths without alternate streams are supported.' }
    $drive = New-Object IO.DriveInfo($full.Substring(0, 3))
    if ($drive.DriveType -notin @([IO.DriveType]::Fixed, [IO.DriveType]::Removable, [IO.DriveType]::CDRom)) { throw 'Network and unsupported drive types are not allowed.' }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if (($Kind -eq 'File' -and $item.PSIsContainer) -or ($Kind -eq 'Directory' -and -not $item.PSIsContainer)) { throw "Expected a $Kind path." }
    return $item.FullName
}

function Test-ToolkitParameter {
    param([object]$Definition, [object]$Value)
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        if ($null -ne $Definition.default) { $text = [string]$Definition.default }
        elseif ($Definition.required) { throw "$($Definition.label) is required." }
        else { return $null }
    }
    if ($text.IndexOfAny([char[]]"`r`n`0") -ge 0) { throw 'Control characters are not accepted.' }
    switch ($Definition.type) {
        'Host' {
            if ($text.Length -gt 253 -or $text.StartsWith('-')) { throw 'Enter a hostname or IP address.' }
            $ip = $null
            if (-not [Net.IPAddress]::TryParse($text, [ref]$ip) -and $text -notmatch '^(?=.{1,253}\.?$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.?$') { throw 'Enter a hostname or IP address.' }
            if ($null -eq $ip) {
                foreach ($label in $text.TrimEnd('.').Split('.')) {
                    if ($label.Length -lt 1 -or $label.Length -gt 63 -or $label.StartsWith('-') -or $label.EndsWith('-')) { throw 'Invalid hostname label.' }
                }
            }
            return $text
        }
        'Integer' {
            $number = 0
            if (-not [int]::TryParse($text, [ref]$number) -or $number -lt $Definition.minimum -or $number -gt $Definition.maximum) { throw "Enter an integer from $($Definition.minimum) to $($Definition.maximum)." }
            return $number
        }
        'Choice' {
            if ($text -notin $Definition.allowedValues) { throw "Choose: $($Definition.allowedValues -join ', ')" }
            return $text
        }
        'LocalFile' { return Test-ToolkitLocalPath -Path $text -Kind File }
        'LocalDirectory' { return Test-ToolkitLocalPath -Path $text -Kind Directory }
        'DriveLetter' {
            if ($text -notmatch '^[A-Za-z]:?$') { throw 'Enter a local drive letter, for example C.' }
            $letter = $text.Substring(0, 1).ToUpperInvariant()
            Test-ToolkitLocalPath -Path ($letter + ':\') -Kind Directory | Out-Null
            return $letter
        }
        'Sha256' {
            if ($text -notmatch '^[a-fA-F0-9]{64}$') { throw 'A SHA-256 checksum must contain 64 hexadecimal characters.' }
            return $text.ToUpperInvariant()
        }
        default { throw "Unsupported parameter type: $($Definition.type)" }
    }
}

function ConvertTo-ToolkitParameterMap {
    param([object]$Command, [hashtable]$Values = @{})
    $result = @{}
    foreach ($key in $Values.Keys) {
        if ($key -notin @($Command.parameters | ForEach-Object { $_.name })) { throw "Unexpected parameter: $key" }
    }
    foreach ($definition in $Command.parameters) {
        $value = Test-ToolkitParameter -Definition $definition -Value $Values[$definition.name]
        if ($null -ne $value) { $result[$definition.name] = $value }
    }
    return $result
}

function ConvertTo-ToolkitArgument {
    param([AllowEmptyString()][string]$Value)
    if ($Value.IndexOfAny([char[]]"`r`n`0") -ge 0) { throw 'Invalid native argument.' }
    # Windows argv quoting: double backslashes before a quote or the closing delimiter.
    $quoted = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $quoted = [regex]::Replace($quoted, '(\\+)$', '$1$1')
    return '"' + $quoted + '"'
}

function ConvertTo-ToolkitSafeText {
    param([AllowNull()][object]$Value)
    $text = [string]$Value
    $text = [regex]::Replace($text, '\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)', '')
    $text = [regex]::Replace($text, '\x1B\[[0-?]*[ -/]*[@-~]', '')
    return [regex]::Replace($text, '[\x00-\x08\x0B-\x1F\x7F]', '')
}

function Get-ToolkitIdentity {
    $product = if ([string]::IsNullOrWhiteSpace($script:ToolkitProductName)) { 'TOOLX Windows Edition' } else { [string]$script:ToolkitProductName }
    $channel = if ([string]::IsNullOrWhiteSpace($script:ToolkitChannel)) { 'Alpha' } else { [string]$script:ToolkitChannel }
    $version = if ([string]::IsNullOrWhiteSpace($script:ToolkitVersion)) { '0.2.2' } else { [string]$script:ToolkitVersion }
    $signature = if ([string]::IsNullOrWhiteSpace($script:ToolkitSignature)) { 'by ALSA' } else { [string]$script:ToolkitSignature }
    $versionLabel = "$channel $version"
    return [pscustomobject]@{
        ProductName = $product
        Channel = $channel
        Version = $version
        VersionLabel = $versionLabel
        Signature = $signature
        Banner = "$product $versionLabel | $signature"
        WindowTitle = "$product - $versionLabel ($signature)"
        VersionOutput = "$product $versionLabel ($signature)"
    }
}
