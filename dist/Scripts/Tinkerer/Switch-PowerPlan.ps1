#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$powercfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
$lines = & $powercfg /list 2>&1
if ($LASTEXITCODE -ne 0) {
    $lines | ForEach-Object { Write-Host $_ }
    exit $LASTEXITCODE
}

$plans = @()
foreach ($line in $lines) {
    if ([string]$line -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s+\((.+?)\)(\s+\*)?') {
        $plans += [pscustomobject]@{
            Guid = $Matches[1]
            Name = $Matches[2]
            Active = ($Matches[3] -like '*`**')
        }
    }
}

if (-not $plans.Count) {
    Write-Host 'No power plans were parsed from powercfg /list.'
    exit 1
}

Write-Host 'Available Windows power plans:'
for ($i = 0; $i -lt $plans.Count; $i++) {
    $marker = '  '
    if ($plans[$i].Active) { $marker = '* ' }
    Write-Host ("[{0}] {1}{2} ({3})" -f ($i + 1), $marker, $plans[$i].Name, $plans[$i].Guid)
}

$choice = Read-Host 'Select plan number to activate (or q to cancel)'
if ($choice -eq 'q' -or [string]::IsNullOrWhiteSpace($choice)) { exit 0 }

$index = 0
if (-not [int]::TryParse($choice, [ref]$index) -or $index -lt 1 -or $index -gt $plans.Count) {
    throw 'Invalid selection.'
}

$picked = $plans[$index - 1]
& $powercfg /setactive $picked.Guid
if ($LASTEXITCODE -ne 0) { throw "powercfg /setactive failed with exit code $LASTEXITCODE." }
Write-Host "Active power plan switched to: $($picked.Name)" -ForegroundColor Green
