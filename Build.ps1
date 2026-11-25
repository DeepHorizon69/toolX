#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dependencies = @{ Pester = '5.7.1'; PSScriptAnalyzer = '1.24.0' }
foreach ($name in ($dependencies.Keys | Sort-Object)) {
    $modulePath = Join-Path $root ".tools/$name/$($dependencies[$name])/$name.psd1"
    if (-not (Test-Path -LiteralPath $modulePath)) { throw "Missing $name $($dependencies[$name]). Run tools/Initialize-Development.ps1 explicitly to prepare development tools." }
    Import-Module -Name $modulePath -Force -ErrorAction Stop
}
$manifest = [IO.File]::ReadAllText((Join-Path $root 'Build.Manifest.json')) | ConvertFrom-Json
$sources = @($manifest.files | ForEach-Object { Join-Path $root $_ }) + @(Join-Path $root 'src/Main.ps1')
foreach ($path in ($sources + @($PSCommandPath) + @(Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Filter '*.ps1' | ForEach-Object { $_.FullName }))) {
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { throw ($errors | Out-String) }
}
foreach ($source in $manifest.files) { . (Join-Path $root $source) }
$registry = [IO.File]::ReadAllText((Join-Path $root 'src/config/commands.json')) | ConvertFrom-Json
Test-ToolkitRegistry $registry
$diagnostics = @($sources + @($PSCommandPath) + @(Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Filter '*.ps1' | ForEach-Object { $_.FullName }) | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Settings (Join-Path $root 'PSScriptAnalyzerSettings.psd1') })
if ($diagnostics.Count) { $diagnostics | Format-Table -AutoSize | Out-Host; throw 'Static analysis failed.' }
. (Join-Path $root 'tools/Bundler.ps1')
$text = New-ToolkitBundleText $root
$staging = Join-Path $root '.build'
[IO.Directory]::CreateDirectory($staging) | Out-Null
$candidate = Join-Path $staging 'Toolkit.ps1'
[IO.File]::WriteAllText($candidate, $text, (New-Object Text.UTF8Encoding($true)))
if ((Get-Item -LiteralPath $candidate).Length -ge 500000) { throw 'The distribution exceeds 500,000 bytes.' }
$tokens = $null; $errors = $null
[Management.Automation.Language.Parser]::ParseFile($candidate, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count) { throw ($errors | Out-String) }
$diagnostics = @(Invoke-ScriptAnalyzer -Path $candidate -Settings (Join-Path $root 'PSScriptAnalyzerSettings.psd1'))
if ($diagnostics.Count) { $diagnostics | Format-Table -AutoSize | Out-Host; throw 'Bundle static analysis failed.' }
$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $root 'tests'
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputPath = Join-Path $staging 'TestResults.xml'
$result = Invoke-Pester -Configuration $configuration
if ($result.Result -ne 'Passed') { throw 'Tests failed; the distribution has not been updated.' }
$destination = Join-Path $root 'dist'
[IO.Directory]::CreateDirectory($destination) | Out-Null
$artifact = Join-Path $destination 'Toolkit.ps1'
Copy-Item -LiteralPath $candidate -Destination $artifact -Force
$hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash
[IO.File]::WriteAllText(($artifact + '.sha256'), "$hash  Toolkit.ps1`r`n", (New-Object Text.UTF8Encoding($false)))
Write-Output "Built $artifact ($((Get-Item -LiteralPath $artifact).Length) bytes)"
Write-Output "SHA-256: $hash"
