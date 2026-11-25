#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
$packages = @{ Pester = '5.7.1'; PSScriptAnalyzer = '1.24.0' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($name in ($packages.Keys | Sort-Object)) {
    $version = $packages[$name]
    $destination = Join-Path $repository ".tools/$name/$version"
    if (Test-Path -LiteralPath (Join-Path $destination "$name.psd1")) { continue }
    [IO.Directory]::CreateDirectory($destination) | Out-Null
    $archive = Join-Path $repository ".tools/$name.$version.zip"
    Invoke-WebRequest -UseBasicParsing -Uri "https://www.powershellgallery.com/api/v2/package/$name/$version" -OutFile $archive
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $destination)
    Remove-Item -LiteralPath $archive
    Write-Output "Prepared $name $version in .tools (development only)."
}
