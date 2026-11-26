#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
$raw = & $netsh wlan show profiles 2>&1
if ($LASTEXITCODE -ne 0) {
    $raw | ForEach-Object { Write-Host $_ }
    exit $LASTEXITCODE
}

$profiles = @()
foreach ($line in $raw) {
    if ([string]$line -match 'Profile\s*:\s*(.+)$') {
        $name = $Matches[1].Trim()
        if ($name -and $name -notin $profiles) { $profiles += $name }
    }
}

if (-not $profiles.Count) {
    Write-Host 'No saved Wi-Fi profiles were found.'
    exit 0
}

Write-Host 'Saved Wi-Fi profiles:'
for ($i = 0; $i -lt $profiles.Count; $i++) {
    Write-Host ("[{0}] {1}" -f ($i + 1), $profiles[$i])
}

$choice = Read-Host 'Select a profile number to display its key (or q to quit)'
if ($choice -eq 'q' -or [string]::IsNullOrWhiteSpace($choice)) { exit 0 }

$index = 0
if (-not [int]::TryParse($choice, [ref]$index) -or $index -lt 1 -or $index -gt $profiles.Count) {
    throw 'Invalid selection.'
}

$selected = $profiles[$index - 1]
Write-Host ''
& $netsh wlan show profile name="$selected" key=clear
