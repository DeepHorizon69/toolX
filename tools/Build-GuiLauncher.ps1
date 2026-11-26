function New-ToolkitGuiLauncher {
    param([string]$Root, [string]$OutputPath)
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319/csc.exe'
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'The .NET Framework C# compiler is required to build the GUI launcher.' }
    $source = Join-Path $Root 'src/launcher/ToolkitGuiLauncher.cs'
    $arguments = @('/nologo','/target:winexe','/platform:anycpu','/optimize+','/reference:System.Windows.Forms.dll',('/out:' + $OutputPath),$source)
    $diagnostics = @(& $compiler @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ('GUI launcher compilation failed: ' + ($diagnostics -join "`n")) }
    return $OutputPath
}

function New-ToolkitCompactExecutable {
    param(
        [string]$Root,
        [string]$BundlePath,
        [string]$OutputPath,
        [ValidateSet('Gui','Cli')][string]$Mode = 'Gui',
        [string]$Version = '0.2.2',
        [string]$ProductName = 'TOOLX Windows Edition',
        [string]$Channel = 'Alpha',
        [string]$Signature = 'by ALSA'
    )
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319/csc.exe'
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'The .NET Framework C# compiler is required to build the compact executable.' }
    $staging = Split-Path $OutputPath -Parent
    [IO.Directory]::CreateDirectory($staging) | Out-Null
    $bundleBytes = [IO.File]::ReadAllBytes($BundlePath)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $expectedSha = ([BitConverter]::ToString($sha.ComputeHash($bundleBytes))).Replace('-', '').ToUpperInvariant() }
    finally { $sha.Dispose() }

    $gzPath = Join-Path $staging 'Toolkit.ps1.gz'
    $gzStream = [IO.File]::Create($gzPath)
    try {
        $compressor = New-Object IO.Compression.GZipStream($gzStream, [IO.Compression.CompressionLevel]::Optimal)
        try { $compressor.Write($bundleBytes, 0, $bundleBytes.Length) }
        finally { $compressor.Dispose() }
    }
    finally { $gzStream.Dispose() }

    $escapeCs = { param([string]$s) $s.Replace('\', '\\').Replace('"', '\"') }
    $csProduct = & $escapeCs $ProductName
    $csChannel = & $escapeCs $Channel
    $csVersion = & $escapeCs $Version
    $csSignature = & $escapeCs $Signature
    $csTitle = if ($Mode -eq 'Cli') { "$csProduct (CLI)" } else { $csProduct }
    $csDescription = "$csProduct - Portable Windows System Toolkit ($csSignature)"
    $csInformational = "$csChannel $csVersion ($csSignature)"
    $csDisplayTitle = "$csProduct $csChannel $csVersion ($csSignature)"

    $metaPath = Join-Path $staging ("ToolkitEmbeddedMeta.$Mode.cs")
    $metaSource = @"
using System.Reflection;

[assembly: AssemblyTitle("$csTitle")]
[assembly: AssemblyDescription("$csDescription")]
[assembly: AssemblyProduct("$csProduct")]
[assembly: AssemblyCompany("ALSA")]
[assembly: AssemblyCopyright("$csSignature")]
[assembly: AssemblyVersion("$csVersion.0")]
[assembly: AssemblyFileVersion("$csVersion.0")]
[assembly: AssemblyInformationalVersion("$csInformational")]

internal static class ToolkitEmbeddedMeta
{
    public const string ProductName = "$csProduct";
    public const string Channel = "$csChannel";
    public const string Version = "$csVersion";
    public const string Signature = "$csSignature";
    public const string DisplayTitle = "$csDisplayTitle";
    public const string ExpectedSha256 = "$expectedSha";
}
"@
    [IO.File]::WriteAllText($metaPath, $metaSource, [Text.Encoding]::ASCII)

    $hostSource = Join-Path $Root 'src/launcher/ToolkitHost.cs'
    $targetFlag = '/target:winexe'
    $extraArgs = @('/reference:System.Windows.Forms.dll')
    if ($Mode -eq 'Cli') {
        $targetFlag = '/target:exe'
        $extraArgs = @('/define:CONSOLE_HOST')
    }
    $arguments = @('/nologo',$targetFlag,'/platform:anycpu','/optimize+',("/resource:$gzPath,Toolkit.ps1.gz"),("/out:$OutputPath")) + $extraArgs + @($hostSource, $metaPath)
    $diagnostics = @(& $compiler @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ("Compact $Mode executable compilation failed: " + ($diagnostics -join "`n")) }
    return $OutputPath
}
