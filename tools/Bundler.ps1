function New-ToolkitBundleText {
    param([string]$Root)
    $manifest = [IO.File]::ReadAllText((Join-Path $Root 'Build.Manifest.json')) | ConvertFrom-Json
    $entry = [IO.File]::ReadAllText((Join-Path $Root 'src/Main.ps1'))
    $startMarker = '# <TOOLKIT_BOOTSTRAP>'
    $endMarker = '# </TOOLKIT_BOOTSTRAP>'
    $start = $entry.IndexOf($startMarker, [StringComparison]::Ordinal)
    $end = $entry.IndexOf($endMarker, [StringComparison]::Ordinal)
    if ($start -lt 0 -or $end -lt $start) { throw 'The bootstrap markers are missing.' }
    $builder = New-Object Text.StringBuilder
    [void]$builder.AppendLine('$script:ToolkitStandalone = $true')
    foreach ($relative in $manifest.files) {
        if ($relative -notmatch '^src/[a-zA-Z0-9/.-]+\.ps1$' -or $relative.Contains('..')) { throw 'Invalid build manifest path.' }
        $content = [IO.File]::ReadAllText((Join-Path $Root $relative))
        [void]$builder.AppendLine("# Source: $relative")
        [void]$builder.AppendLine($content)
    }
    $json = [IO.File]::ReadAllText((Join-Path $Root 'src/config/commands.json'))
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    [void]$builder.AppendLine('$script:ToolkitRegistry = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $encoded + ''')) | ConvertFrom-Json')
    if ($manifest.version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid application version.' }
    $productName = ([string]$manifest.productName).Replace("'", "''")
    $channel = ([string]$manifest.channel).Replace("'", "''")
    $signature = ([string]$manifest.signature).Replace("'", "''")
    [void]$builder.AppendLine('$script:ToolkitProductName = ''' + $productName + '''')
    [void]$builder.AppendLine('$script:ToolkitChannel = ''' + $channel + '''')
    [void]$builder.AppendLine('$script:ToolkitSignature = ''' + $signature + '''')
    [void]$builder.AppendLine('$script:ToolkitVersion = ''' + $manifest.version + '''')
    $bundle = $entry.Substring(0, $start) + $builder.ToString() + $entry.Substring($end + $endMarker.Length)
    return $bundle.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", "`r`n")
}
