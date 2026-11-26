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
$launcher = Join-Path $staging 'Toolkit.cmd'
$launcherText = [IO.File]::ReadAllText((Join-Path $root 'tools/Toolkit.cmd')).Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", "`r`n")
[IO.File]::WriteAllText($launcher, $launcherText, [Text.Encoding]::ASCII)
. (Join-Path $root 'tools/Build-GuiLauncher.ps1')
$null = New-ToolkitGuiLauncher -Root $root -OutputPath (Join-Path $staging 'Toolkit.GUI.exe')
$compactGui = New-ToolkitCompactExecutable -Root $root -BundlePath $candidate -OutputPath (Join-Path $staging 'Toolkit.exe') -Mode Gui -Version $manifest.version -ProductName $manifest.productName -Channel $manifest.channel -Signature $manifest.signature
$compactCli = New-ToolkitCompactExecutable -Root $root -BundlePath $candidate -OutputPath (Join-Path $staging 'Toolkit.CLI.exe') -Mode Cli -Version $manifest.version -ProductName $manifest.productName -Channel $manifest.channel -Signature $manifest.signature
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
$distGui = Join-Path $destination 'Toolkit.exe'
$distCli = Join-Path $destination 'Toolkit.CLI.exe'
Copy-Item -LiteralPath $compactGui -Destination $distGui -Force
Copy-Item -LiteralPath $compactCli -Destination $distCli -Force
$guiHash = (Get-FileHash -LiteralPath $distGui -Algorithm SHA256).Hash
$cliHash = (Get-FileHash -LiteralPath $distCli -Algorithm SHA256).Hash
[IO.File]::WriteAllText(($distGui + '.sha256'), "$guiHash  Toolkit.exe`r`n", (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText(($distCli + '.sha256'), "$cliHash  Toolkit.CLI.exe`r`n", (New-Object Text.UTF8Encoding($false)))
foreach ($obsolete in @('Toolkit.ps1','Toolkit.ps1.sha256','Toolkit.GUI.exe','Toolkit.GUI.exe.sha256','Toolkit.cmd')) {
    $obsoletePath = Join-Path $destination $obsolete
    if (Test-Path -LiteralPath $obsoletePath) { Remove-Item -LiteralPath $obsoletePath -Force }
}
Write-Output "Built $distGui ($((Get-Item -LiteralPath $distGui).Length) bytes)"
Write-Output "SHA-256 (Toolkit.exe): $guiHash"
Write-Output "Built $distCli ($((Get-Item -LiteralPath $distCli).Length) bytes)"
Write-Output "SHA-256 (Toolkit.CLI.exe): $cliHash"
