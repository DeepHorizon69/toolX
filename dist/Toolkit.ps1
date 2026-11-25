#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Basic,
    [switch]$ListCommands,
    [switch]$Version,
    [switch]$Check,
    [string]$WorkerId,
    [string]$ParameterData,
    [switch]$RequireElevation,
    [switch]$SkipActionConfirmation,
    [string]$ManagedJobId,
    [ValidateSet('Probe','Execute')][string]$ManagedMode = 'Execute'
)
$ErrorActionPreference = 'Stop'
$script:ToolkitEntryPath = $PSCommandPath
$script:ToolkitRoot = $PSScriptRoot
$script:ToolkitStandalone = $false
$script:ToolkitStandalone = $true
# Source: src/core/Validation.ps1
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

# Source: src/core/Registry.ps1
function Get-ToolkitTargetPolicy {
    $types = @{
        Function = 'system.os system.computer system.uptime system.environment system.locale network.loss network.port hardware.cpu hardware.memory hardware.gpu hardware.board hardware.bios hardware.disks hardware.disk-health storage.layout storage.volumes storage.space processes.startup repair.temp security.users system.full-specs troubleshooting.events troubleshooting.devices troubleshooting.battery troubleshooting.updates troubleshooting.connectivity security.firewall-control security.firewall-restore security.defender-control security.defender-restore updates.suspend updates.resume power.countdown power.cancel power.status power.force-restart maintenance.managed-changes'
        Cmdlet = 'system.updates network.dns network.adapters storage.hash processes.list processes.services security.defender security.firewall'
        Native = 'network.ip network.ping network.trace network.arp network.routes network.connections network.flush-dns repair.sfc-verify repair.sfc repair.dism-check repair.dism-scan repair.dism-restore repair.chkdsk repair.winsock'
        Executable = 'processes.resource-monitor processes.task-manager'
        Mmc = 'storage.management processes.events security.devices security.computer-management'
        Settings = 'security.settings'
    }
    $admin = 'network.flush-dns hardware.disk-health repair.sfc-verify repair.sfc repair.dism-check repair.dism-scan repair.dism-restore repair.chkdsk repair.winsock security.defender'.Split(' ')
    $modify = 'network.flush-dns processes.resource-monitor processes.task-manager processes.events repair.sfc repair.dism-check repair.dism-scan repair.dism-restore security.settings'.Split(' ')
    $high = 'storage.management security.devices security.computer-management repair.winsock repair.temp'.Split(' ')
    $admin += 'security.firewall-control security.firewall-restore security.defender-control security.defender-restore updates.suspend updates.resume power.countdown power.cancel power.force-restart'.Split(' ')
    $modify += 'power.cancel'
    $high += 'security.firewall-control security.firewall-restore security.defender-control security.defender-restore updates.suspend updates.resume power.countdown power.force-restart'.Split(' ')
    $result = @{}
    foreach ($type in $types.Keys) {
        foreach ($id in $types[$type].Split(' ')) {
            $risk = 'ReadOnly'
            if ($id -in $modify) { $risk = 'SystemModification' }
            if ($id -in $high) { $risk = 'HighRisk' }
            $result[$id] = [pscustomobject]@{ Type = $type; Risk = $risk; Admin = ($id -in $admin) }
        }
    }
    return $result
}

function Test-ToolkitRegistry {
    param([object]$Registry)
    Test-ToolkitObjectField $Registry @('schemaVersion','applicationVersion','commands') @('schemaVersion','applicationVersion','commands')
    if ($Registry.schemaVersion -ne 1) { throw 'Unsupported registry schema.' }
    if ($Registry.applicationVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid registry application version.' }
    $policies = Get-ToolkitTargetPolicy
    $seen = @{}
    $categories = @('System Information','Networking','Hardware Diagnostics','Storage Management','Processes and Services','Windows Repair and Maintenance','Security and Administration','Troubleshooting','Power and Scheduling')
    foreach ($command in $Registry.commands) {
        Test-ToolkitObjectField $command @('id','name','description','category','keywords','sourceKind','executionType','targetId','parameters','requiresAdmin','compatibility','risk','confirmation','consequences','cost','networkAccess','cancellation') @('id','name','description','category','keywords','sourceKind','executionType','targetId','parameters','requiresAdmin','compatibility','risk','confirmation','consequences','cost','networkAccess','cancellation')
        foreach ($field in @('id','name','description','category','sourceKind','executionType','targetId','risk','confirmation','consequences','cost','networkAccess','cancellation')) {
            if ($command.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($command.$field)) { throw "Invalid command field: $field" }
        }
        if ($command.id -notmatch '^[a-z]+\.[a-z0-9-]+$' -or $seen.ContainsKey($command.id)) { throw "Invalid or duplicate command ID: $($command.id)" }
        $seen[$command.id] = $true
        if ($command.sourceKind -ne 'BuiltIn' -or $command.category -notin $categories) { throw "Invalid source or category: $($command.id)" }
        if (-not $policies.ContainsKey($command.targetId)) { throw "Unknown target: $($command.targetId)" }
        $policy = $policies[$command.targetId]
        if ($command.executionType -ne $policy.Type -or $command.risk -ne $policy.Risk -or $command.requiresAdmin -isnot [bool] -or $command.requiresAdmin -ne $policy.Admin) { throw "Target safety policy mismatch: $($command.id)" }
        if ($command.risk -eq 'HighRisk' -and ($command.confirmation -ne 'TypeCommandId' -or [string]::IsNullOrWhiteSpace($command.consequences))) { throw 'High-risk commands require typed confirmation and consequences.' }
        if ($command.risk -eq 'SystemModification' -and $command.confirmation -ne 'Confirm') { throw 'Modifications require confirmation.' }
        if ($command.risk -eq 'ReadOnly' -and $command.confirmation -ne 'None') { throw 'Unexpected read-only confirmation.' }
        if ($command.cost -notin @('Quick','Variable','Heavy') -or $command.networkAccess -notin @('None','UserTarget') -or $command.cancellation -notin @('Cooperative','TerminateOwnedProcess','Unavailable')) { throw 'Invalid command enum.' }
        Test-ToolkitObjectField $command.compatibility @('minimumBuild','architectures','capabilities') @('minimumBuild','architectures','capabilities')
        if ($command.compatibility.minimumBuild -isnot [int] -or $command.compatibility.minimumBuild -lt 10240 -or @($command.compatibility.architectures | Where-Object { $_ -notin @('x86','x64') }).Count) { throw 'Invalid Windows compatibility metadata.' }
        $parameterNames = @{}
        foreach ($parameter in $command.parameters) {
            Test-ToolkitObjectField $parameter @('name','type','label','required','default','minimum','maximum','allowedValues') @('name','type','label','required','default','minimum','maximum','allowedValues')
            if ($parameter.name -notmatch '^[a-z][a-zA-Z0-9]*$' -or $parameterNames.ContainsKey($parameter.name)) { throw 'Invalid or duplicate parameter name.' }
            $parameterNames[$parameter.name] = $true
            if ($parameter.type -notin @('Host','Integer','Choice','LocalFile','LocalDirectory','DriveLetter','Sha256') -or $parameter.required -isnot [bool]) { throw 'Invalid parameter definition.' }
            if ($parameter.type -eq 'Integer' -and ($null -eq $parameter.minimum -or $null -eq $parameter.maximum -or $parameter.minimum -gt $parameter.maximum)) { throw 'Invalid parameter range.' }
            if ($parameter.type -eq 'Choice' -and @($parameter.allowedValues).Count -eq 0) { throw 'Choices cannot be empty.' }
            if ($null -ne $parameter.default -and $parameter.type -notin @('LocalFile','LocalDirectory','DriveLetter')) { Test-ToolkitParameter $parameter $parameter.default | Out-Null }
        }
    }
    if ($seen.Count -eq 0) { throw 'The built-in registry is empty.' }
}

function Get-ToolkitCatalog {
    param([switch]$IncludeCustom)
    if ($IncludeCustom -and -not $script:ToolkitCustomLoaded) { Update-ToolkitCustomCatalog }
    return @($script:ToolkitRegistry.commands) + @($script:ToolkitCustomCommands)
}

function Find-ToolkitCommand {
    param([object[]]$Commands, [string]$Query)
    $queryText = $Query.Trim()
    if (-not $queryText) { return @($Commands) }
    $scored = foreach ($command in $Commands) {
        $rank = 3
        if ($command.id.Equals($queryText, [StringComparison]::OrdinalIgnoreCase) -or $command.name.Equals($queryText, [StringComparison]::OrdinalIgnoreCase)) { $rank = 0 }
        elseif ($command.id.StartsWith($queryText, [StringComparison]::OrdinalIgnoreCase) -or $command.name.StartsWith($queryText, [StringComparison]::OrdinalIgnoreCase)) { $rank = 1 }
        $haystack = @($command.id, $command.name, $command.description, $command.category) + @($command.keywords)
        if (@($haystack | Where-Object { ([string]$_).IndexOf($queryText, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0) {
            [pscustomobject]@{ Rank = $rank; Name = $command.name; Command = $command }
        }
    }
    return @($scored | Sort-Object Rank,Name | ForEach-Object { $_.Command })
}

# Source: src/core/Compatibility.ps1
function Get-ToolkitWindowsExecutable {
    param([string]$Name)
    if ($Name -notin @('ipconfig.exe', 'ping.exe', 'tracert.exe', 'arp.exe', 'route.exe', 'netstat.exe', 'resmon.exe', 'taskmgr.exe', 'mmc.exe', 'sfc.exe', 'dism.exe', 'chkdsk.exe', 'netsh.exe', 'cmd.exe', 'shutdown.exe')) { throw 'Executable is not in the built-in allowlist.' }
    $system = Join-Path $env:SystemRoot 'System32'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $system = Join-Path $env:SystemRoot 'Sysnative' }
    $path = Join-Path $system $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Windows utility is unavailable: $Name" }
    return $path
}

function Get-ToolkitCapability {
    param([object]$Command)
    try {
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows is required.' }
        if ($Command.sourceKind -eq 'CustomScript') {
            if (-not $Command.available) { throw $Command.unavailableReason }
            Resolve-ToolkitCustomScript -Id $Command.id | Out-Null
        }
        else {
            $build = [int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber -ErrorAction Stop).CurrentBuildNumber
            if ($build -lt $Command.compatibility.minimumBuild) { throw 'This Windows build is not supported.' }
            if ($Command.id -eq 'updates.suspend' -and -not (Test-ToolkitUpdateEdition)) { throw 'Long automatic-update suspension is unavailable on this Windows edition; Pro, Enterprise or Education is required.' }
            foreach ($capability in $Command.compatibility.capabilities) {
                if ($capability.StartsWith('exe:')) { Get-ToolkitWindowsExecutable $capability.Substring(4) | Out-Null }
                elseif ($capability.StartsWith('cmdlet:')) {
                    if (-not (Get-Command -Name $capability.Substring(7) -CommandType Cmdlet,Function -ErrorAction SilentlyContinue)) { throw "Missing Windows command: $($capability.Substring(7))" }
                }
            }
            if ($Command.executionType -eq 'Mmc') {
                $snapIn = (Get-ToolkitLaunchSpec $Command.targetId).Arguments[0]
                if (-not (Test-Path -LiteralPath $snapIn)) { throw "Unavailable snap-in: $($Command.targetId)" }
            }
        }
        return [pscustomobject]@{ Available = $true; Reason = '' }
    }
    catch { return [pscustomobject]@{ Available = $false; Reason = $_.Exception.Message } }
}

# Source: src/core/Privileges.ps1
function Test-ToolkitAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    finally { $identity.Dispose() }
}

function Get-ToolkitPowerShellPath {
    $system = Join-Path $env:SystemRoot 'System32'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $system = Join-Path $env:SystemRoot 'Sysnative' }
    return Join-Path $system 'WindowsPowerShell/v1.0/powershell.exe'
}

function Start-ToolkitConsole {
    param([string]$OperationId, [hashtable]$Parameters = @{}, [switch]$Elevated, [switch]$SkipActionConfirmation)
    if (-not $script:ToolkitEntryPath -or -not (Test-Path -LiteralPath $script:ToolkitEntryPath -PathType Leaf)) { throw 'The toolkit script is no longer available.' }
    $json = ConvertTo-Json -InputObject ([pscustomobject]$Parameters) -Compress -Depth 4
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    if ($payload.Length -gt 8192) { throw 'Operation parameters are too large.' }
    $arguments = @('-NoLogo', '-NoProfile', '-File', $script:ToolkitEntryPath, '-WorkerId', $OperationId, '-ParameterData', $payload)
    if ($Elevated) { $arguments += '-RequireElevation' }
    if ($SkipActionConfirmation) { $arguments += '-SkipActionConfirmation' }
    $start = @{
        FilePath = Get-ToolkitPowerShellPath
        ArgumentList = (($arguments | ForEach-Object { ConvertTo-ToolkitArgument $_ }) -join ' ')
        WorkingDirectory = $env:SystemRoot
        PassThru = $true
        ErrorAction = 'Stop'
    }
    if ($Elevated) { $start.Verb = 'RunAs' }
    try { return Start-Process @start }
    catch [ComponentModel.Win32Exception] {
        if ($_.Exception.NativeErrorCode -eq 1223) { throw [OperationCanceledException]::new('The administrator prompt was cancelled.') }
        throw
    }
}

# Source: src/core/CustomScripts.ps1
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

# Source: src/core/ScriptLauncher.ps1
function New-ToolkitScriptStartInfo {
    param([object]$Command)
    $entry = Resolve-ToolkitCustomScript -Id $Command.id
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.UseShellExecute = $false; $info.CreateNoWindow = $false
    $info.WorkingDirectory = Split-Path $entry.path -Parent
    if ([IO.Path]::GetExtension($entry.path) -ieq '.ps1') {
        $info.FileName = Get-ToolkitPowerShellPath
        $info.Arguments = (@('-NoLogo','-NoProfile','-File',$entry.path) | ForEach-Object { ConvertTo-ToolkitArgument $_ }) -join ' '
    }
    else {
        $info.FileName = Get-ToolkitWindowsExecutable 'cmd.exe'
        $info.EnvironmentVariables['TOOLKIT_CUSTOM_SCRIPT_PATH'] = $entry.path
        # Expansion happens once inside quotes; CALL would introduce another parsing pass.
        $info.Arguments = '/d /v:off /s /c ""%TOOLKIT_CUSTOM_SCRIPT_PATH%""'
    }
    return $info
}

function Invoke-ToolkitScriptProcess {
    param([object]$Command)
    $process = [Diagnostics.Process]::Start((New-ToolkitScriptStartInfo $Command))
    try { $process.WaitForExit(); return $process.ExitCode }
    finally { $process.Dispose() }
}

function ConvertFrom-ToolkitPayload {
    param([string]$Data)
    if (-not $Data -or $Data.Length -gt 8192) { throw 'Invalid worker payload size.' }
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Data))
    $object = $json | ConvertFrom-Json -ErrorAction Stop
    if ($object -isnot [pscustomobject]) { throw 'Worker parameters must be a JSON object.' }
    $result = @{}
    foreach ($property in $object.PSObject.Properties) {
        if ($null -ne $property.Value -and $property.Value -isnot [string] -and $property.Value -isnot [int]) { throw 'Worker parameters must be scalar strings or integers.' }
        $result[$property.Name] = $property.Value
    }
    return $result
}

function Invoke-ToolkitConsoleWorker {
    param([string]$Id, [string]$Data, [switch]$RequireElevation, [switch]$SkipConfirmation)
    $exitCode = 1
    try {
        $values = ConvertFrom-ToolkitPayload $Data
        if ($Id.StartsWith('custom/', [StringComparison]::Ordinal)) {
            $command = Resolve-ToolkitCustomScript $Id
            if ($values.Count) { throw 'Custom scripts do not accept toolbox-supplied arguments.' }
        }
        else {
            $command = @($script:ToolkitRegistry.commands | Where-Object { $_.id -ceq $Id })
            if ($command.Count -ne 1) { throw 'Unknown worker command.' }
            $command = $command[0]
            $values = ConvertTo-ToolkitParameterMap $command $values
        }
        $admin = Test-ToolkitAdministrator
        if (($RequireElevation -or $command.requiresAdmin) -and -not $admin) { throw 'This operation requires an administrator token.' }
        $capability = Get-ToolkitCapability $command
        if (-not $capability.Available) { throw $capability.Reason }
        Write-Host "Windows Engineering Toolkit $($script:ToolkitVersion) | Operation console" -ForegroundColor Cyan
        Write-Host (ConvertTo-ToolkitSafeText $command.name) -ForegroundColor Cyan
        $privilegeColor = 'Gray'; if ($admin) { $privilegeColor = 'Yellow' }
        Write-Host "Privilege: $(if ($admin) { 'ADMINISTRATOR' } else { 'Standard user' })" -ForegroundColor $privilegeColor
        $riskColor = 'Green'
        if ($command.risk -eq 'SystemModification') { $riskColor = 'Yellow' }
        elseif ($command.risk -eq 'HighRisk') { $riskColor = 'Red' }
        Write-Host "Risk: $($command.risk)" -ForegroundColor $riskColor
        if ($SkipConfirmation) { Write-Host 'ACTION CONFIRMATIONS OFF: the selected operation will execute without a toolbox confirmation prompt.' -ForegroundColor Yellow }
        Write-Host (ConvertTo-ToolkitSafeText $command.consequences)
        if ($command.sourceKind -eq 'CustomScript') { Write-Host ('Script: ' + (ConvertTo-ToolkitSafeText $command.path)) }
        elseif ($values.Count) { $values | Format-Table -AutoSize | Out-Host }
        if ($command.id -in @('security.firewall-control','security.defender-control') -and $values.action -eq 'Disable') {
            if ($values.mode -eq 'Manual') { Write-Host 'MANUAL MODE: No automatic restoration will be scheduled.' }
            else { Write-Host "Automatic restoration requested after $($values.minutes) minutes. Recovery preflight must pass first." }
        }
        if ($command.id -eq 'updates.suspend') { Write-Host ('Estimated restore date: ' + [DateTimeOffset]::Now.AddMonths($values.months).ToString('yyyy-MM-dd HH:mm:ss zzz') + '. Exact deadline is recorded after preflight.') }
        if ($command.id -eq 'power.countdown') {
            Write-Host "Requested: $($values.action) after $($values.duration) $($values.unit), with $($values.closure) application closure. The countdown starts after recovery preflight."
            if ($values.closure -eq 'Force') { Write-Host 'FORCED CLOSURE: Unsaved data can be lost.' }
        }
        $preview = @()
        if ($command.id -eq 'repair.temp') {
            $preview = @(Get-ToolkitCleanupPreview)
            if ($preview.Count -eq 0) { Write-Host 'No eligible temporary files.'; return 0 }
            Write-Host "Preview: $($preview.Count) files. Every candidate is shown before confirmation."
            for ($index = 0; $index -lt $preview.Count; $index++) {
                Write-Host (ConvertTo-ToolkitSafeText $preview[$index].Path)
                if (-not $SkipConfirmation -and ($index + 1) % 20 -eq 0 -and $index + 1 -lt $preview.Count) { if ((Read-Host 'Enter for more; type cancel to stop') -eq 'cancel') { return 1223 } }
            }
        }
        $confirmation = ''
        if ($SkipConfirmation) { $confirmation = $command.id }
        elseif ($command.confirmation -eq 'TypeCommandId') {
            $confirmation = Read-Host "Type $($command.id) to execute; Enter cancels"
            if ($confirmation -cne $command.id) { Write-Host 'Cancelled.'; return 1223 }
        }
        elseif ($command.confirmation -eq 'Confirm') {
            if ((Read-Host 'Execute this operation? Type yes; Enter cancels') -cne 'yes') { Write-Host 'Cancelled.'; return 1223 }
        }
        if ($command.sourceKind -eq 'CustomScript') { $exitCode = Invoke-ToolkitScriptProcess $command }
        elseif ($command.id -eq 'repair.temp') { Invoke-ToolkitCleanup -Preview $preview -Confirmation $confirmation | Format-Table -AutoSize | Out-Host; $exitCode = 0 }
        elseif ($command.executionType -eq 'Native') {
            $spec = Get-ToolkitNativeSpec $command.targetId $values
            & $spec.FileName @($spec.Arguments)
            $exitCode = $LASTEXITCODE
        }
        elseif ($command.executionType -in @('Executable','Mmc','Settings')) {
            $spec = Get-ToolkitLaunchSpec $command.targetId
            $launch = @{ FilePath = $spec.FileName; ErrorAction = 'Stop' }
            if ($spec.Arguments.Count) { $launch.ArgumentList = (($spec.Arguments | ForEach-Object { ConvertTo-ToolkitArgument $_ }) -join ' ') }
            Start-Process @launch | Out-Null
            Write-Host 'Administrative interface launched. Subsequent actions are outside the toolkit.'
            $exitCode = 0
        }
        else { Invoke-ToolkitPowerShellAction $command.targetId $values | Format-List | Out-Host; $exitCode = 0 }
        Write-Host "Interpreter/operation exit code: $exitCode. Review the output; zero does not verify a repair."
    }
    catch { Write-Host ('Operation failed: ' + (ConvertTo-ToolkitSafeText $_.Exception.Message)) -ForegroundColor Red }
    finally { Read-Host 'Press Enter to close this operation console' | Out-Null }
    return $exitCode
}

# Source: src/modules/System.ps1
function Invoke-ToolkitSystemAction {
    param([string]$TargetId)
    switch ($TargetId) {
        'system.full-specs' { Get-ToolkitFullSpecification }
        'system.os' { Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 15 | Select-Object Caption,Version,BuildNumber,OSArchitecture,WindowsDirectory }
        'system.computer' { Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 15 | Select-Object Manufacturer,Model,TotalPhysicalMemory,DomainRole }
        'system.updates' { Microsoft.PowerShell.Management\Get-HotFix | Select-Object HotFixID,Description,InstalledOn }
        'system.uptime' {
            $boot = (Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 15).LastBootUpTime
            [pscustomobject]@{ LastBoot = $boot; Uptime = ((Get-Date) - $boot) }
        }
        'system.environment' {
            [pscustomobject]@{
                WindowsDirectory = $env:SystemRoot; ProgramFiles = $env:ProgramFiles
                LocalApplicationData = [Environment]::GetFolderPath('LocalApplicationData')
                PowerShellVersion = $PSVersionTable.PSVersion.ToString(); RuntimeVersion = [Environment]::Version.ToString()
                Is64BitOS = [Environment]::Is64BitOperatingSystem; Is64BitProcess = [Environment]::Is64BitProcess
            }
        }
        'system.locale' { Get-Culture; Get-UICulture; Get-TimeZone }
        default { throw 'Unknown system operation.' }
    }
}

# Source: src/modules/Network.ps1
function Invoke-ToolkitNetworkAction {
    param([string]$TargetId, [hashtable]$Values)
    switch ($TargetId) {
        'network.adapters' { NetAdapter\Get-NetAdapter | Select-Object Name,InterfaceDescription,Status,LinkSpeed,ifIndex }
        'network.dns' { DnsClient\Resolve-DnsName -Name $Values.host -Type $Values.recordType -DnsOnly -QuickTimeout }
        'network.loss' {
            $ping = New-Object Net.NetworkInformation.Ping
            $times = New-Object 'Collections.Generic.List[long]'
            $lastFailure = ''
            try {
                for ($index = 1; $index -le 20; $index++) {
                    try {
                        $reply = $ping.Send([string]$Values.host, 1000)
                        if ($reply.Status -eq [Net.NetworkInformation.IPStatus]::Success) { $times.Add($reply.RoundtripTime) }
                    }
                    catch [Net.NetworkInformation.PingException] { $lastFailure = $_.Exception.Message }
                    if ($index -lt 20) { Start-Sleep -Milliseconds 250 }
                }
                $stats = $times | Measure-Object -Minimum -Maximum -Average
                [pscustomobject]@{ Target = $Values.host; Sent = 20; Received = $times.Count; LossPercent = (20 - $times.Count) * 5; MinimumMs = $stats.Minimum; MaximumMs = $stats.Maximum; AverageMs = $stats.Average; LastProbeError = $lastFailure }
            }
            finally { $ping.Dispose() }
        }
        'network.port' {
            $client = New-Object Net.Sockets.TcpClient
            $async = $null
            try {
                $async = $client.BeginConnect([string]$Values.host, [int]$Values.port, $null, $null)
                if (-not $async.AsyncWaitHandle.WaitOne(5000)) { throw [TimeoutException]::new('The TCP connection wait exceeded five seconds.') }
                $client.EndConnect($async)
                [pscustomobject]@{ Target = $Values.host; Port = $Values.port; Connected = $true }
            }
            finally {
                $client.Close()
                if ($null -ne $async) { $async.AsyncWaitHandle.Close() }
            }
        }
        default { throw 'Unknown network operation.' }
    }
}

function Get-ToolkitNativeSpec {
    param([string]$TargetId, [hashtable]$Values)
    $name = ''; $arguments = @()
    switch ($TargetId) {
        'network.ip' { $name = 'ipconfig.exe'; $arguments = @('/all') }
        'network.ping' { $name = 'ping.exe'; $arguments = @('-n','4','-w','1000',$Values.host) }
        'network.trace' { $name = 'tracert.exe'; $arguments = @('-d','-h','15','-w','1000',$Values.host) }
        'network.arp' { $name = 'arp.exe'; $arguments = @('-a') }
        'network.routes' { $name = 'route.exe'; $arguments = @('print') }
        'network.connections' { $name = 'netstat.exe'; $arguments = @('-ano') }
        'network.flush-dns' { $name = 'ipconfig.exe'; $arguments = @('/flushdns') }
        'repair.sfc-verify' { $name = 'sfc.exe'; $arguments = @('/verifyonly') }
        'repair.sfc' { $name = 'sfc.exe'; $arguments = @('/scannow') }
        'repair.dism-check' { $name = 'dism.exe'; $arguments = @('/Online','/Cleanup-Image','/CheckHealth') }
        'repair.dism-scan' { $name = 'dism.exe'; $arguments = @('/Online','/Cleanup-Image','/ScanHealth') }
        'repair.dism-restore' {
            $name = 'dism.exe'; $arguments = @('/Online','/Cleanup-Image','/RestoreHealth','/LimitAccess')
            if ($Values.ContainsKey('source')) { $arguments += '/Source:' + (Test-ToolkitLocalPath $Values.source Directory) }
        }
        'repair.chkdsk' {
            $name = 'chkdsk.exe'
            if ([string]$Values.drive -notmatch '^[A-Za-z]$') { throw 'Invalid CHKDSK drive.' }
            $arguments = @($Values.drive + ':')
        }
        'repair.winsock' { $name = 'netsh.exe'; $arguments = @('winsock','reset') }
        default { throw 'Unknown native operation.' }
    }
    return [pscustomobject]@{ FileName = (Get-ToolkitWindowsExecutable $name); Arguments = [string[]]$arguments }
}

# Source: src/modules/Hardware.ps1
function Invoke-ToolkitHardwareAction {
    param([string]$TargetId)
    switch ($TargetId) {
        'hardware.cpu' { Get-CimInstance Win32_Processor -OperationTimeoutSec 15 | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed }
        'hardware.memory' { Get-CimInstance Win32_PhysicalMemory -OperationTimeoutSec 15 | Select-Object DeviceLocator,Capacity,Speed,Manufacturer,PartNumber }
        'hardware.gpu' { Get-CimInstance Win32_VideoController -OperationTimeoutSec 15 | Select-Object Name,DriverVersion,VideoModeDescription }
        'hardware.board' { Get-CimInstance Win32_BaseBoard -OperationTimeoutSec 15 | Select-Object Manufacturer,Product,Version }
        'hardware.bios' { Get-CimInstance Win32_BIOS -OperationTimeoutSec 15 | Select-Object Manufacturer,SMBIOSBIOSVersion,ReleaseDate }
        'hardware.disks' { Get-CimInstance Win32_DiskDrive -OperationTimeoutSec 15 | Select-Object Index,Model,InterfaceType,Size,Status }
        'hardware.disk-health' {
            foreach ($disk in (Storage\Get-PhysicalDisk)) {
                $disk | Select-Object FriendlyName,MediaType,HealthStatus,OperationalStatus,Size
                try {
                    $counter = $disk | Storage\Get-StorageReliabilityCounter -ErrorAction Stop
                    if ($null -eq $counter) { 'Reliability counters are unavailable for this device.' }
                    else { $counter | Select-Object Temperature,Wear,PowerOnHours,ReadErrorsTotal,WriteErrorsTotal }
                }
                catch { "Reliability counters unavailable: $($_.Exception.Message)" }
            }
        }
        default { throw 'Unknown hardware operation.' }
    }
}

# Source: src/modules/Storage.ps1
function Invoke-ToolkitStorageAction {
    param([string]$TargetId, [hashtable]$Values)
    switch ($TargetId) {
        'storage.layout' { Get-CimInstance Win32_DiskPartition -OperationTimeoutSec 15 | Select-Object DiskIndex,Index,DeviceID,Type,Size,StartingOffset,BootPartition }
        'storage.volumes' { Get-CimInstance Win32_LogicalDisk -OperationTimeoutSec 15 | Select-Object DeviceID,VolumeName,FileSystem,DriveType }
        'storage.space' { Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -OperationTimeoutSec 15 | Select-Object DeviceID,Size,FreeSpace }
        'storage.hash' {
            $hash = Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $Values.path -Algorithm SHA256
            if ($Values.ContainsKey('expected')) {
                [pscustomobject]@{ Path = $hash.Path; Algorithm = 'SHA256'; Hash = $hash.Hash; Expected = $Values.expected; Matches = ($hash.Hash -eq $Values.expected) }
                if ($hash.Hash -ne $Values.expected) { throw 'The computed checksum does not match the expected value.' }
            }
            else { $hash }
        }
        default { throw 'Unknown storage operation.' }
    }
}

# Source: src/modules/Processes.ps1
function Invoke-ToolkitProcessesAction {
    param([string]$TargetId)
    switch ($TargetId) {
        'processes.list' { Microsoft.PowerShell.Management\Get-Process | Select-Object Id,ProcessName,CPU,WorkingSet64 }
        'processes.services' { Microsoft.PowerShell.Management\Get-Service | Select-Object Name,DisplayName,Status }
        'processes.startup' { Get-CimInstance Win32_StartupCommand -OperationTimeoutSec 15 | Select-Object Name,Command,Location }
        default { throw 'Unknown process operation.' }
    }
}

# Source: src/modules/Repair.ps1
function Get-ToolkitTempRoot {
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    if (-not $local) { throw 'The local application-data folder is unavailable.' }
    $root = Test-ToolkitLocalPath -Path (Join-Path $local 'Temp') -Kind Directory
    $item = Get-Item -LiteralPath $root -Force
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Cleanup does not follow reparse points.' }
        $item = $item.Parent
    }
    return $root
}

function Get-ToolkitCleanupPreview {
    $root = Get-ToolkitTempRoot
    $cutoff = [DateTime]::UtcNow.AddDays(-7)
    $preview = New-Object 'Collections.Generic.List[object]'
    foreach ($path in [IO.Directory]::EnumerateFiles($root)) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($null -eq $item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.LastWriteTimeUtc -ge $cutoff) { continue }
        $preview.Add([pscustomobject]@{ Path = $item.FullName; Length = $item.Length; LastWriteTimeUtc = $item.LastWriteTimeUtc })
        if ($preview.Count -ge 200) { break }
    }
    return $preview.ToArray()
}

function Invoke-ToolkitCleanup {
    param([object[]]$Preview, [string]$Confirmation)
    if ($Confirmation -cne 'repair.temp') { throw 'Cleanup requires typed confirmation of this preview.' }
    $root = Get-ToolkitTempRoot
    if (@($Preview).Count -gt 200) { throw 'Cleanup batch exceeds the limit.' }
    foreach ($candidate in $Preview) {
        try {
            if (-not (Test-ToolkitContainedPath $root $candidate.Path) -or [IO.Path]::GetDirectoryName($candidate.Path) -ne $root) { throw 'Candidate is outside the immediate Temp directory.' }
            Test-ToolkitNoReparsePoint $root $candidate.Path
            $current = Get-Item -LiteralPath $candidate.Path -Force -ErrorAction Stop
            if ($current.PSIsContainer -or $current.Length -ne $candidate.Length -or $current.LastWriteTimeUtc -ne $candidate.LastWriteTimeUtc -or $current.LastWriteTimeUtc -ge [DateTime]::UtcNow.AddDays(-7)) { throw 'File changed after preview or is no longer eligible.' }
            Remove-Item -LiteralPath $current.FullName -ErrorAction Stop
            [pscustomobject]@{ Path = $candidate.Path; Status = 'Deleted'; Detail = '' }
        }
        catch { [pscustomobject]@{ Path = $candidate.Path; Status = 'Skipped'; Detail = $_.Exception.Message } }
    }
}

# Source: src/modules/Security.ps1
function Invoke-ToolkitSecurityAction {
    param([string]$TargetId)
    switch ($TargetId) {
        'security.defender' { Defender\Get-MpComputerStatus | Select-Object AMServiceEnabled,AntivirusEnabled,RealTimeProtectionEnabled,AntivirusSignatureLastUpdated,QuickScanEndTime }
        'security.firewall' { NetSecurity\Get-NetFirewallProfile | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction }
        'security.users' { Get-CimInstance Win32_UserAccount -Filter 'LocalAccount=True' -OperationTimeoutSec 15 | Select-Object Name,Disabled,Lockout,Status }
        default { throw 'Unknown security operation.' }
    }
}

# Source: src/modules/Troubleshooting.ps1
function Get-ToolkitFullSpecification {
    $sections = @(
        @{ Name = 'Windows'; Class = 'Win32_OperatingSystem'; Fields = @('Caption','Version','BuildNumber','OSArchitecture','LastBootUpTime') },
        @{ Name = 'Computer'; Class = 'Win32_ComputerSystem'; Fields = @('Manufacturer','Model','TotalPhysicalMemory','SystemType') },
        @{ Name = 'Processor'; Class = 'Win32_Processor'; Fields = @('Name','NumberOfCores','NumberOfLogicalProcessors','MaxClockSpeed') },
        @{ Name = 'Memory'; Class = 'Win32_PhysicalMemory'; Fields = @('DeviceLocator','Manufacturer','Capacity','Speed','PartNumber') },
        @{ Name = 'Graphics'; Class = 'Win32_VideoController'; Fields = @('Name','DriverVersion','CurrentHorizontalResolution','CurrentVerticalResolution') },
        @{ Name = 'Board'; Class = 'Win32_BaseBoard'; Fields = @('Manufacturer','Product','Version') },
        @{ Name = 'BIOS'; Class = 'Win32_BIOS'; Fields = @('Manufacturer','SMBIOSBIOSVersion','ReleaseDate') },
        @{ Name = 'Disk'; Class = 'Win32_DiskDrive'; Fields = @('Index','Model','Size','InterfaceType') },
        @{ Name = 'Partition'; Class = 'Win32_DiskPartition'; Fields = @('DeviceID','DiskIndex','Size','Type') },
        @{ Name = 'Volume'; Class = 'Win32_LogicalDisk'; Fields = @('DeviceID','VolumeName','FileSystem','Size','FreeSpace') },
        @{ Name = 'Adapter'; Class = 'Win32_NetworkAdapter'; Fields = @('Name','NetConnectionID','NetEnabled','Speed') }
    )
    foreach ($section in $sections) {
        try {
            $items = @(CimCmdlets\Get-CimInstance -ClassName $section.Class -OperationTimeoutSec 10 -ErrorAction Stop | Select-Object -First 64)
            if (-not $items.Count) { [pscustomobject]@{ Section = $section.Name; Field = ''; Value = 'No data'; Status = 'Unavailable' } }
            foreach ($item in $items) {
                foreach ($field in $section.Fields) { [pscustomobject]@{ Section = $section.Name; Field = $field; Value = $item.$field; Status = 'Reported' } }
            }
        }
        catch { [pscustomobject]@{ Section = $section.Name; Field = ''; Value = $_.Exception.Message; Status = 'Unavailable' } }
    }
    Get-ToolkitBatteryHealth
}

function Get-ToolkitBatteryHealth {
    try {
        $batteries = @(CimCmdlets\Get-CimInstance Win32_Battery -OperationTimeoutSec 10 -ErrorAction Stop)
        if (-not $batteries.Count) { return [pscustomobject]@{ Section = 'Battery'; Status = 'Unavailable'; Detail = 'No battery was reported.' } }
        $static = @(CimCmdlets\Get-CimInstance -Namespace root/wmi -ClassName BatteryStaticData -OperationTimeoutSec 10 -ErrorAction Stop)
        $full = @(CimCmdlets\Get-CimInstance -Namespace root/wmi -ClassName BatteryFullChargedCapacity -OperationTimeoutSec 10 -ErrorAction Stop)
        foreach ($battery in $static) {
            $capacity = $full | Where-Object InstanceName -eq $battery.InstanceName | Select-Object -First 1
            $health = $null
            if ($battery.DesignedCapacity -gt 0 -and $null -ne $capacity) { $health = [Math]::Round(100.0 * $capacity.FullChargedCapacity / $battery.DesignedCapacity, 1) }
            [pscustomobject]@{ Section = 'Battery'; DesignCapacity = $battery.DesignedCapacity; FullChargeCapacity = $capacity.FullChargedCapacity; HealthPercent = $health; Status = 'Firmware reported; not a calibrated measurement' }
        }
    }
    catch { [pscustomobject]@{ Section = 'Battery'; Status = 'Unavailable'; Detail = $_.Exception.Message } }
}

function Get-ToolkitUpdateDiagnostic {
    foreach ($name in @('wuauserv','BITS','UsoSvc')) {
        try { Get-Service -Name $name -ErrorAction Stop | Select-Object Name,Status,StartType }
        catch { [pscustomobject]@{ Name = $name; Detail = $_.Exception.Message } }
    }
    [pscustomobject]@{
        ComponentServicingRestart = (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
        WindowsUpdateRestart = (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        Note = 'These are local restart indicators, not a complete update-health diagnosis.'
    }
    try { Get-ToolkitSettingState Updates Automatic } catch { $_.Exception.Message }
    Get-ToolkitManagedSummary | Where-Object Kind -eq 'Updates'
}

function Invoke-ToolkitTroubleshootingAction {
    param([string]$TargetId, [hashtable]$Values)
    switch ($TargetId) {
        'troubleshooting.events' {
            foreach ($log in @('System','Application')) {
                try {
                    Get-WinEvent -FilterHashtable @{ LogName = $log; Level = @(1,2); StartTime = (Get-Date).AddHours(-[int]$Values.hours) } -MaxEvents 50 -ErrorAction Stop | Select-Object TimeCreated,LogName,ProviderName,Id,LevelDisplayName,Message
                }
                catch { [pscustomobject]@{ Log = $log; Detail = $_.Exception.Message } }
            }
        }
        'troubleshooting.devices' { CimCmdlets\Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode<>0' -OperationTimeoutSec 15 | Select-Object Name,PNPClass,ConfigManagerErrorCode,Status }
        'troubleshooting.battery' { Get-ToolkitBatteryHealth }
        'troubleshooting.updates' { Get-ToolkitUpdateDiagnostic }
        'troubleshooting.connectivity' {
            $routes = @(NetTCPIP\Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric)
            if ($routes.Count) {
                $route = $routes[0]
                [pscustomobject]@{ Step = 'Selected IPv4 gateway'; Gateway = $route.NextHop; InterfaceIndex = $route.InterfaceIndex }
                $ping = New-Object Net.NetworkInformation.Ping
                try { $reply = $ping.Send($route.NextHop, 1000); [pscustomobject]@{ Step = 'Gateway ICMP'; Status = $reply.Status; Note = 'ICMP filtering does not prove an outage.' } }
                catch { [pscustomobject]@{ Step = 'Gateway ICMP'; Detail = $_.Exception.Message } }
                finally { $ping.Dispose() }
            }
            else { 'No IPv4 default gateway was reported; IPv6 connectivity may still be available.' }
            try { DnsClient\Resolve-DnsName -Name $Values.host -DnsOnly -QuickTimeout -ErrorAction Stop | Select-Object Name,Type,IPAddress }
            catch { [pscustomobject]@{ Step = 'DNS'; Detail = $_.Exception.Message } }
            try { Invoke-ToolkitNetworkAction 'network.port' $Values }
            catch { [pscustomobject]@{ Step = 'TCP'; Detail = $_.Exception.Message } }
        }
        default { throw 'Unknown troubleshooting operation.' }
    }
}

# Source: src/core/ManagedChanges.ps1
function Get-ToolkitManagedRoot {
    return Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'WindowsEngineeringToolkit'
}

function Set-ToolkitProtectedAcl {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Recovery paths cannot be reparse points.' }
    $acl = New-Object Security.AccessControl.FileSecurity
    if ($item.PSIsContainer) { $acl = New-Object Security.AccessControl.DirectorySecurity }
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544','S-1-5-32-545')) {
        $rights = [Security.AccessControl.FileSystemRights]::ReadAndExecute
        if ($sid -ne 'S-1-5-32-545') { $rights = [Security.AccessControl.FileSystemRights]::FullControl }
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        if ($item.PSIsContainer) {
            $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, $rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        }
        else { $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, $rights, 'Allow') }
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Test-ToolkitProtectedPath {
    param([string]$Path)
    $root = Get-ToolkitManagedRoot
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -ne $root -and -not (Test-ToolkitContainedPath $root $full)) { throw 'Recovery path escapes protected storage.' }
    $current = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    while ($null -ne $current) {
        if ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Recovery paths cannot be reparse points.' }
        $acl = Get-Acl -LiteralPath $current.FullName -ErrorAction Stop
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($owner -notin @('S-1-5-18','S-1-5-32-544')) { throw 'Recovery storage has an unexpected owner.' }
        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            $writeMask = [Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
            if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544') -and ($rule.FileSystemRights -band $writeMask)) { throw 'Recovery storage grants write access to an unexpected identity.' }
        }
        if ($current.FullName -eq $root) { return }
        if ($current -is [IO.FileInfo]) { $current = $current.Directory } else { $current = $current.Parent }
    }
    throw 'Recovery root could not be verified.'
}

function Initialize-ToolkitProtectedDirectory {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { Test-ToolkitProtectedPath $Path; return }
    $root = Get-ToolkitManagedRoot
    if ($Path -ne $root) { Test-ToolkitProtectedPath (Split-Path $Path -Parent) }
    else {
        $ancestor = Get-Item -LiteralPath (Split-Path $root -Parent) -Force
        while ($null -ne $ancestor) {
            if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'ProgramData ancestry contains a reparse point.' }
            $ancestor = $ancestor.Parent
        }
    }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544','S-1-5-32-545')) {
        $rights = 'ReadAndExecute'; if ($sid -ne 'S-1-5-32-545') { $rights = 'FullControl' }
        $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), $rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    [IO.Directory]::CreateDirectory($Path, $acl) | Out-Null
    Test-ToolkitProtectedPath $Path
}

function Write-ToolkitProtectedText {
    param([string]$Path, [string]$Text)
    Test-ToolkitProtectedPath (Split-Path $Path -Parent)
    if (Test-Path -LiteralPath $Path) { Test-ToolkitProtectedPath $Path }
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($true)))
        Set-ToolkitProtectedAcl $temporary
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, $null) }
        else { [IO.File]::Move($temporary, $Path) }
        Test-ToolkitProtectedPath $Path
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -ErrorAction Stop } }
}

function Enter-ToolkitManagedLock {
    $path = Join-Path (Get-ToolkitManagedRoot) 'state.lock'
    Test-ToolkitProtectedPath $path
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        try { return [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] { Start-Sleep -Milliseconds 100 }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Another toolbox change is busy. Try again when it finishes.'
}

function Get-ToolkitJobPath {
    param([string]$Id)
    if ($Id -notmatch '^[a-f0-9]{32}$') { throw 'Invalid managed job identifier.' }
    return Join-Path (Join-Path (Get-ToolkitManagedRoot) 'jobs') ($Id + '.json')
}

function Test-ToolkitManagedJob {
    param([object]$Job)
    $fields = @('SchemaVersion','Id','Kind','Scope','Original','Applied','OwnerSid','CreatedUtc','ExpiresUtc','HelperVersion','Status','Detail','PowerAction','Force','BootId')
    Test-ToolkitObjectField $Job $fields $fields
    if ($Job.SchemaVersion -ne 1 -or $Job.Id -notmatch '^[a-f0-9]{32}$' -or $Job.HelperVersion -notmatch '^\d+\.\d+\.\d+$' -or $Job.OwnerSid -notmatch '^S-1-5-[0-9-]+$') { throw 'Invalid managed job identity.' }
    if ($Job.Kind -notin @('Probe','Firewall','Defender','Updates','Power')) { throw 'Invalid managed operation.' }
    if ($Job.Status -notin @('Prepared','ProbePassed','Active','Restoring','Restored','Cancelled','Expired','Failed','Conflict','Superseded','Executed')) { throw 'Invalid managed job status.' }
    [DateTimeOffset]::Parse($Job.CreatedUtc) | Out-Null
    if ($null -ne $Job.ExpiresUtc) { [DateTimeOffset]::Parse($Job.ExpiresUtc) | Out-Null }
    if ($Job.Force -isnot [bool] -or $Job.PowerAction -notin @('None','Shutdown','Restart')) { throw 'Invalid managed power action.' }
    if ($Job.Kind -ne 'Power' -and ($Job.PowerAction -ne 'None' -or $Job.Force)) { throw 'Power action is not allowed for this job.' }
    $expected = @()
    switch ($Job.Kind) {
        'Firewall' { if ($Job.Scope -notin @('Private','Public','Domain','All')) { throw 'Invalid firewall scope.' }; $expected = @($Job.Scope); if ($Job.Scope -eq 'All') { $expected = @('Domain','Private','Public') } }
        'Defender' { if ($Job.Scope -ne 'Realtime') { throw 'Invalid Defender scope.' }; $expected = @('Disabled') }
        'Updates' { if ($Job.Scope -ne 'Automatic') { throw 'Invalid update scope.' }; $expected = @('Exists','Value','ValueKind') }
        'Power' { if ($Job.Scope -ne 'Local' -or $null -eq $Job.ExpiresUtc -or $Job.PowerAction -eq 'None' -or -not $Job.BootId) { throw 'Invalid power deadline.' } }
        'Probe' { if ($Job.Scope -ne 'Local') { throw 'Invalid preflight scope.' } }
    }
    foreach ($state in @($Job.Original, $Job.Applied)) {
        Test-ToolkitObjectField $state $expected $expected
        foreach ($property in $state.PSObject.Properties) {
            if ($Job.Kind -eq 'Defender' -and $property.Value -isnot [bool]) { throw 'Defender snapshots must use boolean values.' }
            if ($Job.Kind -eq 'Firewall' -and $property.Value -notin @('True','False','NotConfigured')) { throw 'Invalid firewall snapshot.' }
        }
        if ($Job.Kind -eq 'Updates' -and ($state.Exists -isnot [bool] -or $state.Value -isnot [int] -or $state.Value -notin @(0,1) -or $state.ValueKind -notin @('None','DWord') -or ($state.Exists -and $state.ValueKind -ne 'DWord'))) { throw 'Invalid update snapshot.' }
    }
}

function Read-ToolkitManagedJob {
    param([string]$Id)
    $path = Get-ToolkitJobPath $Id
    Test-ToolkitProtectedPath $path
    if ((Get-Item -LiteralPath $path).Length -gt 65536) { throw 'Managed job is too large.' }
    $job = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    Test-ToolkitManagedJob $job
    if ($job.Id -cne $Id) { throw 'Managed job identity does not match its filename.' }
    return $job
}

function Save-ToolkitManagedJob {
    param([object]$Job)
    Test-ToolkitManagedJob $Job
    Write-ToolkitProtectedText (Get-ToolkitJobPath $Job.Id) (ConvertTo-Json -InputObject $Job -Depth 5)
}

function Get-ToolkitManagedJob {
    $directory = Join-Path (Get-ToolkitManagedRoot) 'jobs'
    if (-not (Test-Path -LiteralPath $directory)) { return }
    Test-ToolkitProtectedPath $directory
    foreach ($path in [IO.Directory]::EnumerateFiles($directory, '*.json')) {
        $id = [IO.Path]::GetFileNameWithoutExtension($path)
        Read-ToolkitManagedJob $id
    }
}

function Get-ToolkitManagedSummary {
    try {
        $jobs = @(Get-ToolkitManagedJob | Where-Object Kind -ne 'Probe')
        if (-not $jobs.Count) { 'No toolbox-managed changes or power actions have been recorded.' }
        foreach ($job in $jobs) {
            $taskState = 'Not scheduled'; $lastResult = $null; $taskDetail = ''
            if ($job.ExpiresUtc -and $job.Status -in @('Prepared','Active','Restoring','Failed','Conflict')) {
                try {
                    $task = Get-ScheduledTask -TaskName ('WET-' + $job.Id) -TaskPath '\WindowsEngineeringToolkit\' -ErrorAction Stop
                    $taskState = $task.State.ToString()
                    $lastResult = (Get-ScheduledTaskInfo -TaskName ('WET-' + $job.Id) -TaskPath '\WindowsEngineeringToolkit\' -ErrorAction Stop).LastTaskResult
                }
                catch { $taskState = 'Unavailable'; $taskDetail = $_.Exception.Message }
            }
            [pscustomobject]@{
                Id = $job.Id; Kind = $job.Kind; Scope = $job.Scope; Status = $job.Status
                Deadline = $(if ($job.ExpiresUtc) { ([DateTimeOffset]::Parse($job.ExpiresUtc)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz') } else { 'Manual: no automatic restoration' })
                Due = ($job.ExpiresUtc -and [DateTimeOffset]::UtcNow -ge [DateTimeOffset]::Parse($job.ExpiresUtc) -and $job.Status -in @('Prepared','Active','Restoring','Failed','Conflict'))
                TaskState = $taskState; LastTaskResult = $lastResult; Detail = $job.Detail; TaskQueryDetail = $taskDetail
            }
        }
    }
    catch { [pscustomobject]@{ Status = 'Unavailable'; Detail = $_.Exception.Message } }
}

function New-ToolkitManagedJob {
    param([string]$Kind, [string]$Scope, [object]$Original, [object]$Applied, [AllowNull()][object]$Deadline)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $sid = $identity.User.Value } finally { $identity.Dispose() }
    return [pscustomobject]@{
        SchemaVersion = 1; Id = [guid]::NewGuid().ToString('N'); Kind = $Kind; Scope = $Scope
        Original = $Original; Applied = $Applied; OwnerSid = $sid; CreatedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        ExpiresUtc = $(if ($null -ne $Deadline) { ([DateTimeOffset]$Deadline).ToUniversalTime().ToString('o') } else { $null })
        HelperVersion = $script:ToolkitVersion; Status = 'Prepared'; Detail = ''; PowerAction = 'None'; Force = $false; BootId = ''
    }
}

function Get-ToolkitHelperPath {
    param([string]$Version)
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid helper version.' }
    return Join-Path (Join-Path (Join-Path (Get-ToolkitManagedRoot) 'versions') $Version) 'Toolkit.ps1'
}

function Initialize-ToolkitRecovery {
    if (-not (Test-ToolkitAdministrator)) { throw 'Administrator privileges are required.' }
    if (-not $script:ToolkitStandalone) { throw 'Scheduled controls require the standalone dist/Toolkit.ps1; build it first.' }
    $root = Get-ToolkitManagedRoot
    Initialize-ToolkitProtectedDirectory $root
    foreach ($name in @('jobs','versions')) { Initialize-ToolkitProtectedDirectory (Join-Path $root $name) }
    $versionDirectory = Join-Path (Join-Path $root 'versions') $script:ToolkitVersion
    Initialize-ToolkitProtectedDirectory $versionDirectory
    $helper = Get-ToolkitHelperPath $script:ToolkitVersion
    if (Test-Path -LiteralPath $helper) {
        Test-ToolkitProtectedPath $helper
        if ((Get-FileHash -LiteralPath $helper).Hash -ne (Get-FileHash -LiteralPath $script:ToolkitEntryPath).Hash) { throw 'This helper version already exists with different content. Use a new application version.' }
    }
    else { Write-ToolkitProtectedText $helper ([IO.File]::ReadAllText($script:ToolkitEntryPath)) }
    $lockPath = Join-Path $root 'state.lock'
    if (-not (Test-Path -LiteralPath $lockPath)) { Write-ToolkitProtectedText $lockPath '' }
    Test-ToolkitProtectedPath $lockPath
    $probe = New-ToolkitManagedJob Probe Local ([pscustomobject]@{}) ([pscustomobject]@{}) $null
    Save-ToolkitManagedJob $probe
    try {
        Register-ToolkitManagedTask $probe -Probe
        Start-ScheduledTask -TaskName ('WET-' + $probe.Id) -TaskPath '\WindowsEngineeringToolkit\' -ErrorAction Stop
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            Start-Sleep -Milliseconds 250
            if ((Read-ToolkitManagedJob $probe.Id).Status -eq 'ProbePassed') { return }
        } while ([DateTime]::UtcNow -lt $deadline)
        throw 'Scheduled recovery preflight failed. No Windows setting was changed. Check task logon rights and execution policy for the scheduled account.'
    }
    finally {
        Remove-ToolkitManagedTask $probe.Id
        Remove-Item -LiteralPath (Get-ToolkitJobPath $probe.Id) -ErrorAction Stop
    }
}

function Get-ToolkitTaskFolder {
    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $sddl = 'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GR;;;BU)'
    try { $folder = $service.GetFolder('\WindowsEngineeringToolkit') }
    catch { $folder = $service.GetFolder('\').CreateFolder('WindowsEngineeringToolkit', $sddl) }
    $folder.SetSecurityDescriptor($sddl, 0)
    return $folder
}

function Register-ToolkitManagedTask {
    param([object]$Job, [switch]$Probe)
    Test-ToolkitManagedJob $Job
    $helper = Get-ToolkitHelperPath $Job.HelperVersion
    Test-ToolkitProtectedPath $helper
    $folder = Get-ToolkitTaskFolder
    $sddl = 'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;GR;;;BU)'
    $arguments = @('-NoLogo','-NoProfile','-File',$helper,'-ManagedJobId',$Job.Id,'-ManagedMode',$(if ($Probe) { 'Probe' } else { 'Execute' }))
    $action = New-ScheduledTaskAction -Execute (Get-ToolkitPowerShellPath) -Argument (($arguments | ForEach-Object { ConvertTo-ToolkitArgument $_ }) -join ' ')
    $principal = New-ScheduledTaskPrincipal -UserId $Job.OwnerSid -LogonType S4U -RunLevel Highest
    $settingParameters = @{ Disable = $true; AllowStartIfOnBatteries = $true; DontStopIfGoingOnBatteries = $true; ExecutionTimeLimit = (New-TimeSpan -Minutes 5); MultipleInstances = 'IgnoreNew' }
    if ($Job.Kind -ne 'Power' -and -not $Probe) { $settingParameters.RestartCount = 3; $settingParameters.RestartInterval = New-TimeSpan -Minutes 1 }
    $settings = New-ScheduledTaskSettingsSet @settingParameters
    $triggers = @()
    if (-not $Probe) {
        if (-not $Job.ExpiresUtc) { throw 'A scheduled operation requires a deadline.' }
        $triggers = @(New-ScheduledTaskTrigger -Once -At ([DateTimeOffset]::Parse($Job.ExpiresUtc)).LocalDateTime)
        if ($Job.Kind -ne 'Power') { $settings.StartWhenAvailable = $true; $triggers += New-ScheduledTaskTrigger -AtStartup }
    }
    $parameters = @{ TaskName = ('WET-' + $Job.Id); TaskPath = '\WindowsEngineeringToolkit\'; Action = $action; Principal = $principal; Settings = $settings; ErrorAction = 'Stop' }
    if ($triggers.Count) { $parameters.Trigger = $triggers }
    Register-ScheduledTask @parameters | Out-Null
    try {
        $folder.GetTask(('WET-' + $Job.Id)).SetSecurityDescriptor($sddl, 0x10)
        Enable-ScheduledTask -TaskName ('WET-' + $Job.Id) -TaskPath '\WindowsEngineeringToolkit\' -ErrorAction Stop | Out-Null
    }
    catch { Remove-ToolkitManagedTask $Job.Id; throw }
}

function Remove-ToolkitManagedTask {
    param([string]$Id)
    Get-ToolkitJobPath $Id | Out-Null
    $task = Get-ScheduledTask -TaskName ('WET-' + $Id) -TaskPath '\WindowsEngineeringToolkit\' -ErrorAction SilentlyContinue
    if ($null -ne $task) { Unregister-ScheduledTask -TaskName ('WET-' + $Id) -TaskPath '\WindowsEngineeringToolkit\' -Confirm:$false -ErrorAction Stop }
}

function Test-ToolkitStateEqual {
    param([object]$Left, [object]$Right)
    $names = @($Left.PSObject.Properties.Name)
    if ($names.Count -ne @($Right.PSObject.Properties.Name).Count) { return $false }
    foreach ($name in $names) { if ($null -eq $Right.PSObject.Properties[$name] -or $Left.$name -cne $Right.$name) { return $false } }
    return $true
}

# Source: src/modules/Controls.ps1
function Get-ToolkitFirewallScope {
    param([string]$Scope)
    if ($Scope -notin @('Private','Public','Domain','All')) { throw 'Invalid firewall profile selection.' }
    if ($Scope -eq 'All') { return @('Domain','Private','Public') }
    return @($Scope)
}

function Get-ToolkitUpdatePolicyKey {
    param([switch]$Writable)
    $view = [Microsoft.Win32.RegistryView]::Registry32
    if ([Environment]::Is64BitOperatingSystem) { $view = [Microsoft.Win32.RegistryView]::Registry64 }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
    try {
        if ($Writable) { return $base.CreateSubKey('SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU') }
        return $base.OpenSubKey('SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', $false)
    }
    finally { $base.Dispose() }
}

function Get-ToolkitSettingState {
    param([string]$Kind, [string]$Scope)
    switch ($Kind) {
        'Firewall' {
            $state = [ordered]@{}
            foreach ($name in (Get-ToolkitFirewallScope $Scope)) {
                $firewallProfile = NetSecurity\Get-NetFirewallProfile -Name $name -PolicyStore PersistentStore -ErrorAction Stop
                $value = $firewallProfile.Enabled.ToString()
                if ($value -notin @('True','False','NotConfigured')) { throw 'Unrecognized firewall configuration.' }
                $state[$name] = $value
            }
            return [pscustomobject]$state
        }
        'Defender' {
            $status = Defender\Get-MpComputerStatus -ErrorAction Stop
            if (-not $status.AMServiceEnabled -or -not $status.AntivirusEnabled) { throw 'Defender Antivirus is not active; its real-time setting cannot be managed here.' }
            return [pscustomobject]@{ Disabled = (-not [bool]$status.RealTimeProtectionEnabled) }
        }
        'Updates' {
            $key = Get-ToolkitUpdatePolicyKey
            try {
                if ($null -eq $key -or 'NoAutoUpdate' -notin $key.GetValueNames()) { return [pscustomobject]@{ Exists = $false; Value = 0; ValueKind = 'None' } }
                $kindName = $key.GetValueKind('NoAutoUpdate').ToString()
                $value = $key.GetValue('NoAutoUpdate')
                if ($kindName -ne 'DWord' -or $value -notin @(0,1)) { throw 'NoAutoUpdate has an unsupported value or type; it will not be overwritten.' }
                return [pscustomobject]@{ Exists = $true; Value = [int]$value; ValueKind = 'DWord' }
            }
            finally { if ($null -ne $key) { $key.Dispose() } }
        }
        default { throw 'Unknown managed setting.' }
    }
}

function Set-ToolkitSettingState {
    param([string]$Kind, [string]$Scope, [object]$State)
    switch ($Kind) {
        'Firewall' {
            foreach ($name in (Get-ToolkitFirewallScope $Scope)) {
                if ($State.$name -notin @('True','False','NotConfigured')) { throw 'Invalid firewall state.' }
                NetSecurity\Set-NetFirewallProfile -Name $name -Enabled $State.$name -PolicyStore PersistentStore -ErrorAction Stop
            }
        }
        'Defender' {
            if ($State.Disabled -isnot [bool]) { throw 'Invalid Defender state.' }
            $status = Get-ToolkitDefenderStatus
            if ($State.Disabled -and $status.IsTamperProtected) { throw 'Tamper Protection blocks this change. The toolbox will not bypass it.' }
            Set-ToolkitDefenderPreference $State.Disabled
        }
        'Updates' {
            $key = Get-ToolkitUpdatePolicyKey -Writable
            try {
                if ($State.Exists) {
                    if ($State.ValueKind -ne 'DWord' -or $State.Value -notin @(0,1)) { throw 'Invalid update policy state.' }
                    $key.SetValue('NoAutoUpdate', [int]$State.Value, [Microsoft.Win32.RegistryValueKind]::DWord)
                }
                else { $key.DeleteValue('NoAutoUpdate', $false) }
            }
            finally { $key.Dispose() }
        }
        default { throw 'Unknown managed setting.' }
    }
    $actual = Get-ToolkitSettingState $Kind $Scope
    if (-not (Test-ToolkitStateEqual $State $actual)) { throw 'Windows did not retain the requested setting. Review policy or Tamper Protection.' }
    if ($Kind -eq 'Firewall') {
        foreach ($name in (Get-ToolkitFirewallScope $Scope)) {
            if ($State.$name -eq 'NotConfigured') { continue }
            $effective = NetSecurity\Get-NetFirewallProfile -Name $name -PolicyStore ActiveStore -ErrorAction Stop
            if ($effective.Enabled.ToString() -ne $State.$name) { throw 'Firewall policy overrides the requested profile state.' }
        }
    }
}

function Get-ToolkitDefenderStatus {
    return Defender\Get-MpComputerStatus -ErrorAction Stop
}

function Set-ToolkitDefenderPreference {
    param([bool]$Disabled)
    Defender\Set-MpPreference -DisableRealtimeMonitoring $Disabled -ErrorAction Stop
}

function Get-ToolkitChangeDeadline {
    param([string]$Kind, [string]$Mode, [int]$Minutes, [int]$Months, [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    if ($Mode -notin @('Timed','Manual') -or $Minutes -lt 1 -or $Minutes -gt 1440 -or $Months -lt 1 -or $Months -gt 36) { throw 'Invalid change duration or mode.' }
    if ($Kind -eq 'Updates') { return $Now.AddMonths($Months).ToUniversalTime() }
    if ($Mode -eq 'Timed') { return $Now.ToUniversalTime().AddMinutes($Minutes) }
    return $null
}

function Test-ToolkitUpdateEdition {
    $edition = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID -ErrorAction Stop).EditionID
    return $edition -match '^(Professional|Enterprise|Education)'
}

function Test-ToolkitUpdateEligibility {
    if (-not (Test-ToolkitUpdateEdition)) { throw 'Long automatic-update suspension requires a validated Pro, Enterprise or Education edition. Home is not supported.' }
    $computer = CimCmdlets\Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 10 -ErrorAction Stop
    if ($computer.PartOfDomain) { throw 'Domain-managed update policy must be changed by the organization administrator.' }
    if (Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo') { throw 'An organization join was detected; update management must be reviewed by its administrator.' }
    $enrollments = Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue
    foreach ($enrollment in $enrollments) {
        $value = Get-ItemProperty -LiteralPath $enrollment.PSPath -ErrorAction Stop
        if ($value.EnrollmentState -eq 1 -and $value.ProviderID) { throw 'Active device management was detected; local update suspension is unavailable.' }
    }
    if ((Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue).WUServer) { throw 'An update server policy is already configured.' }
}

function Get-ToolkitActiveJob {
    param([string]$Kind)
    return @(Get-ToolkitManagedJob | Where-Object { $_.Kind -eq $Kind -and $_.Status -in @('Prepared','Active','Restoring','Failed','Conflict') })
}

function Restore-ToolkitManagedJob {
    param([object]$Job)
    if ($Job.Kind -notin @('Firewall','Defender','Updates')) { throw 'This is not a restorable setting change.' }
    $current = Get-ToolkitSettingState $Job.Kind $Job.Scope
    foreach ($property in $Job.Original.PSObject.Properties) {
        $name = $property.Name
        if ($current.$name -cne $property.Value -and $current.$name -cne $Job.Applied.$name) {
            $Job.Status = 'Conflict'; $Job.Detail = 'Current settings differ from both the original and toolbox-applied state. No values were overwritten.'
            Save-ToolkitManagedJob $Job
            throw $Job.Detail
        }
    }
    try {
        $Job.Status = 'Restoring'; Save-ToolkitManagedJob $Job
        if (-not (Test-ToolkitStateEqual $current $Job.Original)) { Set-ToolkitSettingState $Job.Kind $Job.Scope $Job.Original }
        $Job.Status = 'Restored'; $Job.Detail = 'Original setting restored and verified.'
        Save-ToolkitManagedJob $Job
        Remove-ToolkitManagedTask $Job.Id
    }
    catch {
        $Job.Status = 'Failed'; $Job.Detail = 'Restoration needs attention: ' + $_.Exception.Message
        Save-ToolkitManagedJob $Job
        throw
    }
}

function Start-ToolkitSettingChange {
    param([string]$Kind, [string]$Scope, [object]$Applied, [string]$Mode, [int]$Minutes = 30, [int]$Months = 1)
    if ($Mode -notin @('Timed','Manual') -or $Minutes -lt 1 -or $Minutes -gt 1440 -or $Months -lt 1 -or $Months -gt 36) { throw 'Invalid change duration or mode.' }
    if ($Kind -eq 'Updates') { Test-ToolkitUpdateEligibility }
    Initialize-ToolkitRecovery
    $lock = Enter-ToolkitManagedLock
    try {
        $existing = @(Get-ToolkitActiveJob $Kind)
        foreach ($job in $existing) {
            if ($Kind -ne 'Firewall' -or $Scope -eq 'All' -or $job.Scope -eq 'All' -or $Scope -eq $job.Scope) { throw 'An overlapping change already exists. Restore it before creating another.' }
        }
        $original = Get-ToolkitSettingState $Kind $Scope
        if (Test-ToolkitStateEqual $original $Applied) { 'The requested setting already exists; no change or restoration job was created.'; return }
        $deadline = Get-ToolkitChangeDeadline $Kind $Mode $Minutes $Months
        $job = New-ToolkitManagedJob $Kind $Scope $original $Applied $deadline
        Save-ToolkitManagedJob $job
        try {
            if ($null -ne $deadline) { Register-ToolkitManagedTask $job }
            Set-ToolkitSettingState $Kind $Scope $Applied
            $job.Status = 'Active'; $job.Detail = 'Applied and verified. Manual changes or organization policy can override this setting.'
            Save-ToolkitManagedJob $job
        }
        catch {
            $failure = $_.Exception.Message
            $job.Status = 'Failed'; $job.Detail = $failure; Save-ToolkitManagedJob $job
            try { Restore-ToolkitManagedJob $job }
            catch { throw "Change failed: $failure. Rollback also needs attention: $($_.Exception.Message). The recovery record was retained." }
            throw "Change failed and was rolled back: $failure"
        }
        Get-ToolkitManagedSummary | Where-Object Id -eq $job.Id
    }
    finally { $lock.Dispose() }
}

function Restore-ToolkitSetting {
    param([string]$Kind)
    $root = Get-ToolkitManagedRoot
    if (-not (Test-Path -LiteralPath (Join-Path $root 'state.lock'))) { 'No toolbox changes exist to restore.'; return }
    $lock = Enter-ToolkitManagedLock
    try {
        $jobs = @(Get-ToolkitActiveJob $Kind)
        if (-not $jobs.Count) { 'No active toolbox-owned changes exist for this setting.' }
        foreach ($job in $jobs) {
            try { Restore-ToolkitManagedJob $job; "Restored $($job.Id) ($($job.Scope))." }
            catch { "Restore failed for $($job.Id): $($_.Exception.Message)"; throw }
        }
    }
    finally { $lock.Dispose() }
}

function Enable-ToolkitProtection {
    param([string]$Kind, [string]$Scope)
    Initialize-ToolkitRecovery
    $lock = Enter-ToolkitManagedLock
    try {
        $jobs = @(Get-ToolkitActiveJob $Kind)
        foreach ($job in $jobs) {
            if ($Kind -eq 'Firewall' -and $job.Scope -eq 'All' -and $Scope -ne 'All') { throw 'Restore the existing All-profiles change first, then enable individual profiles.' }
        }
        $state = [pscustomobject]@{ Disabled = $false }
        if ($Kind -eq 'Firewall') {
            $stateMap = [ordered]@{}
            foreach ($name in (Get-ToolkitFirewallScope $Scope)) { $stateMap[$name] = 'True' }
            $state = [pscustomobject]$stateMap
        }
        Set-ToolkitSettingState $Kind $Scope $state
        foreach ($job in $jobs) {
            if ($Kind -ne 'Firewall' -or $Scope -eq 'All' -or $job.Scope -eq $Scope) {
                $job.Status = 'Superseded'; $job.Detail = 'Explicit Enable superseded the original restoration request.'
                Save-ToolkitManagedJob $job; Remove-ToolkitManagedTask $job.Id
            }
        }
        'Protection enabled and effective state verified.'
    }
    finally { $lock.Dispose() }
}

function Get-ToolkitBootId {
    return (CimCmdlets\Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 10 -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o')
}

function Get-ToolkitPowerSpec {
    param([string]$Action, [bool]$Force)
    if ($Action -notin @('Shutdown','Restart')) { throw 'Unknown power action.' }
    $arguments = @('/s','/t','0')
    if ($Action -eq 'Restart') { $arguments[0] = '/r' }
    if ($Force) { $arguments += '/f' }
    return [pscustomobject]@{ FileName = (Get-ToolkitWindowsExecutable 'shutdown.exe'); Arguments = $arguments }
}

function Invoke-ToolkitPowerRequest {
    param([string]$Action, [bool]$Force)
    $spec = Get-ToolkitPowerSpec $Action $Force
    & $spec.FileName @($spec.Arguments)
    if ($LASTEXITCODE -ne 0) { throw "Windows rejected the power request (exit code $LASTEXITCODE)." }
}

function Start-ToolkitPowerCountdown {
    param([hashtable]$Values)
    $multipliers = @{ Seconds = 1; Minutes = 60; Hours = 3600; Days = 86400 }
    if ($Values.unit -notin $multipliers.Keys -or $Values.action -notin @('Shutdown','Restart') -or $Values.closure -notin @('Normal','Force')) { throw 'Invalid countdown options.' }
    $seconds = [long]$Values.duration * $multipliers[$Values.unit]
    if ($seconds -lt 1 -or $seconds -gt 604800) { throw 'Countdown must be from one second through seven days.' }
    Initialize-ToolkitRecovery
    $lock = Enter-ToolkitManagedLock
    try {
        if (@(Get-ToolkitActiveJob Power).Count) { throw 'A power action already exists. Cancel it before scheduling another.' }
        $job = New-ToolkitManagedJob Power Local ([pscustomobject]@{}) ([pscustomobject]@{}) ([DateTimeOffset]::UtcNow.AddSeconds($seconds))
        $job.PowerAction = $Values.action; $job.Force = $Values.closure -eq 'Force'; $job.BootId = Get-ToolkitBootId
        $job.Status = 'Active'; $job.Detail = 'Survives console closure. Does not wake the PC. Missed deadlines and changed boot sessions expire.'
        Save-ToolkitManagedJob $job
        try {
            Register-ToolkitManagedTask $job
            if ([DateTimeOffset]::UtcNow -ge [DateTimeOffset]::Parse($job.ExpiresUtc)) { Start-ScheduledTask -TaskName ('WET-' + $job.Id) -TaskPath '\WindowsEngineeringToolkit\' -ErrorAction Stop }
        }
        catch {
            $job.Status = 'Failed'; $job.Detail = $_.Exception.Message
            try { Save-ToolkitManagedJob $job }
            finally { Remove-ToolkitManagedTask $job.Id }
            throw
        }
        Get-ToolkitManagedSummary | Where-Object Id -eq $job.Id
    }
    finally { $lock.Dispose() }
}

function Stop-ToolkitPowerCountdown {
    if (-not (Test-Path -LiteralPath (Join-Path (Get-ToolkitManagedRoot) 'state.lock'))) { 'No toolbox power countdown exists.'; return }
    $lock = Enter-ToolkitManagedLock
    try {
        $jobs = @(Get-ToolkitActiveJob Power)
        if (-not $jobs.Count) { 'No cancellable toolbox countdown exists. Already-issued Windows shutdown requests cannot be cancelled here.' }
        foreach ($job in $jobs) {
            $job.Status = 'Cancelled'; $job.Detail = 'Cancelled before the power request was issued.'
            Save-ToolkitManagedJob $job; Remove-ToolkitManagedTask $job.Id
            "Cancelled $($job.Id)."
        }
    }
    finally { $lock.Dispose() }
}

function Invoke-ToolkitManagedWorker {
    param([string]$Id, [ValidateSet('Probe','Execute')][string]$Mode)
    if (-not (Test-ToolkitAdministrator) -or -not $script:ToolkitStandalone) { throw 'Recovery requires the protected standalone helper and an elevated token.' }
    $job = Read-ToolkitManagedJob $Id
    $expectedHelper = Get-ToolkitHelperPath $job.HelperVersion
    if ([IO.Path]::GetFullPath($script:ToolkitEntryPath) -ine $expectedHelper) { throw 'Recovery may only run from the pinned protected helper.' }
    Test-ToolkitProtectedPath $expectedHelper
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { if ($identity.User.Value -ne $job.OwnerSid) { throw 'Scheduled account does not match the job owner.' } } finally { $identity.Dispose() }
    if ($Mode -eq 'Probe') {
        if ($job.Kind -ne 'Probe' -or $job.Status -ne 'Prepared') { throw 'Invalid recovery preflight.' }
        $job.Status = 'ProbePassed'; $job.Detail = 'Scheduled account, policy and protected storage checks passed.'; Save-ToolkitManagedJob $job
        return
    }
    if ($job.Kind -eq 'Probe') { throw 'Preflight jobs cannot execute operations.' }
    $lock = Enter-ToolkitManagedLock
    try {
        $job = Read-ToolkitManagedJob $Id
        if ($job.Status -notin @('Prepared','Active','Restoring','Failed','Conflict')) { return }
        if (-not $job.ExpiresUtc -or [DateTimeOffset]::UtcNow -lt [DateTimeOffset]::Parse($job.ExpiresUtc)) { return }
        if ($job.Kind -eq 'Power') {
            if ($job.Status -ne 'Active') { return }
            $lateSeconds = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($job.ExpiresUtc)).TotalSeconds
            if ($lateSeconds -gt 60 -or (Get-ToolkitBootId) -ne $job.BootId) {
                $job.Status = 'Expired'; $job.Detail = 'Missed deadline or changed boot session. No power request was issued.'
                Save-ToolkitManagedJob $job; Remove-ToolkitManagedTask $job.Id; return
            }
            # Persist before issuing the request so retries cannot repeat a power action.
            $job.Status = 'Executed'; $job.Detail = 'Power request issued; normal application closure may postpone or block it.'; Save-ToolkitManagedJob $job
            try { Invoke-ToolkitPowerRequest $job.PowerAction $job.Force }
            catch { $job.Detail = 'Power request failed: ' + $_.Exception.Message; Save-ToolkitManagedJob $job; throw }
            finally { Remove-ToolkitManagedTask $job.Id }
        }
        else { Restore-ToolkitManagedJob $job }
    }
    finally { $lock.Dispose() }
}

function Invoke-ToolkitControlAction {
    param([string]$TargetId, [hashtable]$Values)
    switch ($TargetId) {
        'security.firewall-control' {
            if ($Values.action -eq 'Enable') { Enable-ToolkitProtection Firewall $Values.profile }
            else {
                $state = [ordered]@{}; foreach ($name in (Get-ToolkitFirewallScope $Values.profile)) { $state[$name] = 'False' }
                Start-ToolkitSettingChange Firewall $Values.profile ([pscustomobject]$state) $Values.mode -Minutes $Values.minutes
            }
        }
        'security.defender-control' {
            if ($Values.action -eq 'Enable') { Enable-ToolkitProtection Defender Realtime }
            else { Start-ToolkitSettingChange Defender Realtime ([pscustomobject]@{ Disabled = $true }) $Values.mode -Minutes $Values.minutes }
        }
        'security.firewall-restore' { Restore-ToolkitSetting Firewall }
        'security.defender-restore' { Restore-ToolkitSetting Defender }
        'updates.suspend' { Start-ToolkitSettingChange Updates Automatic ([pscustomobject]@{ Exists = $true; Value = 1; ValueKind = 'DWord' }) Timed -Months $Values.months }
        'updates.resume' { Restore-ToolkitSetting Updates }
        'power.countdown' { Start-ToolkitPowerCountdown $Values }
        'power.cancel' { Stop-ToolkitPowerCountdown }
        'power.status' { Get-ToolkitManagedSummary | Where-Object { $_ -is [string] -or $_.Kind -eq 'Power' } }
        'power.force-restart' { Invoke-ToolkitPowerRequest Restart $true }
        default { throw 'Unknown control operation.' }
    }
}

# Source: src/core/Executor.ps1
function Get-ToolkitLaunchSpec {
    param([string]$TargetId)
    $name = ''; $snapIn = ''
    switch ($TargetId) {
        'processes.resource-monitor' { $name = 'resmon.exe' }
        'processes.task-manager' { $name = 'taskmgr.exe' }
        'storage.management' { $snapIn = 'diskmgmt.msc' }
        'processes.events' { $snapIn = 'eventvwr.msc' }
        'security.devices' { $snapIn = 'devmgmt.msc' }
        'security.computer-management' { $snapIn = 'compmgmt.msc' }
        'security.settings' { return [pscustomobject]@{ FileName = 'ms-settings:windowsdefender'; Arguments = @() } }
        default { throw 'Unknown Windows interface.' }
    }
    if ($snapIn) {
        $name = 'mmc.exe'
        $executable = Get-ToolkitWindowsExecutable $name
        return [pscustomobject]@{ FileName = $executable; Arguments = @(Join-Path (Split-Path $executable -Parent) $snapIn) }
    }
    return [pscustomobject]@{ FileName = (Get-ToolkitWindowsExecutable $name); Arguments = @() }
}

function Write-ToolkitQueueText {
    param([object]$Queue, [hashtable]$State, [AllowNull()][object]$Text)
    $value = [string]$Text
    if ($value.Length -gt 4096) { $value = $value.Substring(0, 4096); $State.Truncated = $true }
    if (-not $Queue.TryAdd($value)) {
        $discard = ''
        $Queue.TryTake([ref]$discard) | Out-Null
        $Queue.TryAdd($value) | Out-Null
        $State.Truncated = $true
    }
}

function Invoke-ToolkitPowerShellAction {
    param([string]$TargetId, [hashtable]$Values)
    switch -Wildcard ($TargetId) {
        'system.*' { Invoke-ToolkitSystemAction $TargetId }
        'network.*' { Invoke-ToolkitNetworkAction $TargetId $Values }
        'hardware.*' { Invoke-ToolkitHardwareAction $TargetId }
        'storage.*' { Invoke-ToolkitStorageAction $TargetId $Values }
        'processes.*' { Invoke-ToolkitProcessesAction $TargetId }
        'security.*' {
            if ($TargetId -in @('security.firewall-control','security.firewall-restore','security.defender-control','security.defender-restore')) { Invoke-ToolkitControlAction $TargetId $Values }
            else { Invoke-ToolkitSecurityAction $TargetId }
        }
        'troubleshooting.*' { Invoke-ToolkitTroubleshootingAction $TargetId $Values }
        'updates.*' { Invoke-ToolkitControlAction $TargetId $Values }
        'power.*' { Invoke-ToolkitControlAction $TargetId $Values }
        'maintenance.managed-changes' { Get-ToolkitManagedSummary }
        default { throw 'Unknown PowerShell operation.' }
    }
}

function Invoke-ToolkitNativeCaptured {
    param([object]$Spec, [object]$Queue, [hashtable]$State, [hashtable]$Control)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Spec.FileName
    $info.Arguments = (($Spec.Arguments | ForEach-Object { ConvertTo-ToolkitArgument $_ }) -join ' ')
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $encoding = [Text.Encoding]::GetEncoding((Get-Culture).TextInfo.OEMCodePage)
    $info.StandardOutputEncoding = $encoding; $info.StandardErrorEncoding = $encoding
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'The native process could not be started.' }
        $State.ProcessId = $process.Id
        $stdout = New-Object char[] 2048; $stderr = New-Object char[] 2048
        $outTask = $process.StandardOutput.ReadAsync($stdout, 0, $stdout.Length)
        $errTask = $process.StandardError.ReadAsync($stderr, 0, $stderr.Length)
        while ($null -ne $outTask -or $null -ne $errTask -or -not $process.HasExited) {
            if ($Control.Cancel -and -not $process.HasExited) { $process.Kill(); $State.Cancelled = $true }
            if ($null -ne $outTask -and $outTask.IsCompleted) {
                $count = $outTask.GetAwaiter().GetResult()
                if ($count -eq 0) { $outTask = $null }
                else {
                    Write-ToolkitQueueText $Queue $State (-join $stdout[0..($count - 1)])
                    $outTask = $process.StandardOutput.ReadAsync($stdout, 0, $stdout.Length)
                }
            }
            if ($null -ne $errTask -and $errTask.IsCompleted) {
                $count = $errTask.GetAwaiter().GetResult()
                if ($count -eq 0) { $errTask = $null }
                else {
                    Write-ToolkitQueueText $Queue $State (-join $stderr[0..($count - 1)])
                    $errTask = $process.StandardError.ReadAsync($stderr, 0, $stderr.Length)
                }
            }
            Start-Sleep -Milliseconds 25
        }
        $process.WaitForExit()
        $State.ExitCode = $process.ExitCode
        if ($process.ExitCode -ne 0 -and -not $State.Cancelled) { throw "Native utility returned exit code $($process.ExitCode). Review its output." }
    }
    finally {
        if (-not $process.HasExited) { $process.Kill(); $State.Cancelled = $true }
        $process.Dispose()
    }
}

function Invoke-ToolkitBackgroundAction {
    param([object]$Command, [hashtable]$Values, [object]$Queue, [hashtable]$State, [hashtable]$Control)
    $ErrorActionPreference = 'Stop'
    try {
        if ($Command.sourceKind -ne 'BuiltIn' -or $Command.risk -ne 'ReadOnly' -or $Command.requiresAdmin) { throw 'This operation must use the confirmed console path.' }
        if ($Command.executionType -eq 'Native') { Invoke-ToolkitNativeCaptured (Get-ToolkitNativeSpec $Command.targetId $Values) $Queue $State $Control }
        else {
            Invoke-ToolkitPowerShellAction $Command.targetId $Values | Format-List | Out-String -Stream -Width 120 | ForEach-Object { Write-ToolkitQueueText $Queue $State $_ }
        }
        $State.Status = 'Succeeded'
    }
    catch {
        $State.Status = 'Failed'
        if ($_.Exception -is [UnauthorizedAccessException] -or $_.FullyQualifiedErrorId -match 'AccessDenied|Unauthorized|80041003|PermissionDenied' -or $_.Exception.Message -match 'Access is denied|Access denied') { $State.Status = 'PermissionDenied' }
        if ($_.Exception -is [TimeoutException]) { $State.Status = 'TimedOut' }
        Write-ToolkitQueueText $Queue $State $_.Exception.Message
    }
    finally { if ($State.Cancelled) { $State.Status = 'Cancelled' }; $State.Done = $true }
}

function Start-ToolkitExecution {
    param([object]$Command, [hashtable]$Values)
    if ($Command.sourceKind -ne 'BuiltIn' -or $Command.risk -ne 'ReadOnly' -or $Command.requiresAdmin) { throw 'Only unelevated read-only diagnostics may use the background worker.' }
    $validated = ConvertTo-ToolkitParameterMap $Command $Values
    $session = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($function in (Get-Command -CommandType Function -Name '*-Toolkit*')) {
        $entry = New-Object Management.Automation.Runspaces.SessionStateFunctionEntry($function.Name, $function.Definition)
        $session.Commands.Add($entry)
    }
    $runspace = [runspacefactory]::CreateRunspace($session)
    $runspace.Open()
    $powershell = [powershell]::Create(); $powershell.Runspace = $runspace
    $queue = New-Object 'Collections.Concurrent.BlockingCollection[string]' 128
    $state = [hashtable]::Synchronized(@{ Done = $false; Status = 'Running'; ExitCode = $null; ProcessId = $null; Truncated = $false; Cancelled = $false })
    $control = [hashtable]::Synchronized(@{ Cancel = $false })
    $powershell.AddCommand('Invoke-ToolkitBackgroundAction').AddArgument($Command).AddArgument($validated).AddArgument($queue).AddArgument($state).AddArgument($control) | Out-Null
    $handle = $powershell.BeginInvoke()
    return [pscustomobject]@{ PowerShell = $powershell; Runspace = $runspace; Handle = $handle; Queue = $queue; State = $state; Control = $control; Started = [DateTime]::UtcNow; Command = $Command; StopHandle = $null; DeadlineExceeded = $false }
}

function Stop-ToolkitExecution {
    param([object]$Execution, [switch]$TimedOut)
    if ($Execution.Command.cancellation -eq 'Unavailable') { return }
    $Execution.State.Cancelled = -not $TimedOut
    $Execution.DeadlineExceeded = [bool]$TimedOut
    $Execution.Control.Cancel = $true
    if ($Execution.Command.executionType -ne 'Native' -and $null -eq $Execution.StopHandle) {
        $Execution.StopHandle = $Execution.PowerShell.BeginStop($null, $null)
    }
}

function Complete-ToolkitExecution {
    param([object]$Execution)
    if (-not $Execution.Handle.IsCompleted) { throw 'The worker is still stopping; do not dispose it synchronously.' }
    try {
        try { $Execution.PowerShell.EndInvoke($Execution.Handle) | Out-Null } catch { if (-not $Execution.State.Cancelled -and -not $Execution.DeadlineExceeded) { $Execution.State.Status = 'Failed' } }
        if ($null -ne $Execution.StopHandle) { $Execution.PowerShell.EndStop($Execution.StopHandle) }
        if ($Execution.DeadlineExceeded) { $Execution.State.Status = 'TimedOut' }
        elseif ($Execution.State.Cancelled) { $Execution.State.Status = 'Cancelled' }
        return [pscustomobject]@{ CommandId = $Execution.Command.id; ExecutionId = [guid]::NewGuid().ToString(); Started = $Execution.Started; Elapsed = ([DateTime]::UtcNow - $Execution.Started); Status = $Execution.State.Status; ExitCode = $Execution.State.ExitCode; Truncated = $Execution.State.Truncated }
    }
    finally { $Execution.PowerShell.Dispose(); $Execution.Runspace.Dispose(); $Execution.Queue.Dispose() }
}

# Source: src/ui/Terminal.ps1
$script:ToolkitTerminalState = $null

function Get-ToolkitTerminalSize {
    try {
        if ([Console]::IsOutputRedirected) { return $null }
        return [pscustomobject]@{ Width = [Console]::WindowWidth; Height = [Console]::WindowHeight; Left = [Console]::WindowLeft; Top = [Console]::WindowTop }
    }
    catch { return $null }
}

function Get-ToolkitGeometryKey {
    param([object]$Size)
    if ($null -eq $Size) { return 'unavailable' }
    return '{0}:{1}:{2}:{3}' -f $Size.Width, $Size.Height, $Size.Left, $Size.Top
}

function Initialize-ToolkitTerminal {
    param([switch]$Basic)
    $script:ToolkitTerminalState = [pscustomobject]@{
        ForcedBasic = ([bool]$Basic -or $Host.Name -ne 'ConsoleHost'); Failed = $false
        Administrator = (Test-ToolkitAdministrator); TrueColor = $false
        Foreground = $null; Background = $null; Cursor = $null
    }
    $script:ToolkitFrameCache = $null
    $script:ToolkitNotice = ''
    try {
        $script:ToolkitTerminalState.Foreground = [Console]::ForegroundColor
        $script:ToolkitTerminalState.Background = [Console]::BackgroundColor
        $script:ToolkitTerminalState.Cursor = [Console]::CursorVisible
        $script:ToolkitTerminalState.TrueColor = -not [Console]::IsOutputRedirected -and $Host.UI.SupportsVirtualTerminal -and ($env:WT_SESSION -or $env:COLORTERM -in @('truecolor','24bit'))
    }
    catch { $script:ToolkitTerminalState.ForcedBasic = $true }
    Update-ToolkitTerminalMode (Get-ToolkitTerminalSize)
    if (-not $script:ToolkitBasic) { try { [Console]::CursorVisible = $false } catch { $script:ToolkitTerminalState.Cursor = $null } }
}

function Update-ToolkitTerminalMode {
    param([object]$Size)
    if ($null -eq $script:ToolkitTerminalState) { return }
    $wasBasic = $script:ToolkitBasic
    $script:ToolkitBasic = $script:ToolkitTerminalState.ForcedBasic -or $script:ToolkitTerminalState.Failed -or $null -eq $Size -or $Size.Width -lt 60 -or $Size.Height -lt 12
    if ($wasBasic -and -not $script:ToolkitBasic -and $null -ne $script:ToolkitTerminalState.Cursor) {
        try { [Console]::CursorVisible = $false } catch { Write-Verbose 'The host cannot hide the cursor.' }
    }
}

function Restore-ToolkitTerminal {
    param([switch]$LeaveScreen)
    if ($null -eq $script:ToolkitTerminalState) { return }
    try {
        if ($script:ToolkitTerminalState.TrueColor) { [Console]::Write(([string][char]27 + '[0m')) }
        if ($null -ne $script:ToolkitTerminalState.Foreground) { [Console]::ForegroundColor = $script:ToolkitTerminalState.Foreground }
        if ($null -ne $script:ToolkitTerminalState.Background) { [Console]::BackgroundColor = $script:ToolkitTerminalState.Background }
        if ($null -ne $script:ToolkitTerminalState.Cursor) { [Console]::CursorVisible = $script:ToolkitTerminalState.Cursor }
        if ($LeaveScreen -and $null -ne $script:ToolkitFrameCache) {
            [Console]::SetCursorPosition([Console]::WindowLeft, [Console]::WindowTop + [Console]::WindowHeight - 1)
            [Console]::WriteLine()
        }
    }
    catch { Write-Verbose 'The host no longer exposes console appearance controls.' }
}

function Read-ToolkitKey {
    return [Console]::ReadKey($true)
}

function Read-ToolkitInput {
    param([string]$Prompt, [string[]]$Description = @())
    $value = ''; $pendingKey = $null; $streamEditing = $false
    while ($true) {
        $size = Get-ToolkitTerminalSize
        Update-ToolkitTerminalMode $size
        $shown = ConvertTo-ToolkitDisplayText $value
        $inputWidth = 70; if ($null -ne $size) { $inputWidth = [Math]::Max(1, $size.Width - 6) }
        if ($shown.Length -gt $inputWidth) { $shown = '...' + $shown.Substring($shown.Length - $inputWidth) }
        $frame = New-ToolkitTextFrame 'Input' (@($Description) + @($Prompt, '', ('> ' + $shown))) -Status 'Awaiting input' -Footer @('Enter: accept | Esc: cancel | Backspace: delete') -Size $size -PreserveAll
        $plain = $script:ToolkitBasic -or $frame.UseBasic
        if ($plain) { Restore-ToolkitTerminal -LeaveScreen }
        Show-ToolkitFrame -Frame $frame -Plain:$plain
        if (($plain -or $script:ToolkitBasic) -and -not $value.Length -and $null -eq $pendingKey -and -not $streamEditing) {
            $answer = Read-Host ((ConvertTo-ToolkitSafeText $Prompt) + ' (cancel to return)')
            if ($answer -ceq 'cancel') { return $null }
            return $answer
        }
        if ($plain) { $streamEditing = $true }
        if ($null -ne $pendingKey) { $key = $pendingKey; $pendingKey = $null }
        else {
            $key = Read-ToolkitKey
            if ((Get-ToolkitGeometryKey (Get-ToolkitTerminalSize)) -ne (Get-ToolkitGeometryKey $size)) { $pendingKey = $key; continue }
        }
        switch ($key.Key.ToString()) {
            'Escape' { return $null }
            'Enter' { return $value }
            'Backspace' { if ($value.Length) { $value = $value.Substring(0, $value.Length - 1) } }
            default { if (-not [char]::IsControl($key.KeyChar) -and $value.Length -lt 2048) { $value += $key.KeyChar } }
        }
    }
}

function Wait-ToolkitAcknowledgement {
    param([string]$Message)
    $frame = New-ToolkitTextFrame 'Result' @($Message) -Status $Message -Footer @('Press any key to return.') -Size (Get-ToolkitTerminalSize) -PreserveAll
    $plain = $script:ToolkitBasic -or $frame.UseBasic
    if ($plain) { Restore-ToolkitTerminal -LeaveScreen }
    Show-ToolkitFrame -Frame $frame -Plain:$plain
    if ($plain -or $script:ToolkitBasic) { Read-Host 'Enter to return' | Out-Null }
    else { Read-ToolkitKey | Out-Null }
}

# Source: src/ui/Navigation.ps1
function Get-ToolkitSelection {
    param([int]$Index, [int]$Count, [string]$Key, [int]$PageSize = 10)
    if ($Count -le 0) { return 0 }
    switch ($Key) {
        'UpArrow' { $Index-- }
        'DownArrow' { $Index++ }
        'Home' { $Index = 0 }
        'End' { $Index = $Count - 1 }
        'PageUp' { $Index -= $PageSize }
        'PageDown' { $Index += $PageSize }
    }
    return [Math]::Max(0, [Math]::Min($Count - 1, $Index))
}

function Read-ToolkitMenu {
    param([string]$Title, [object[]]$Items, [string[]]$Description = @(), [int]$InitialIndex = 0, [object]$Context)
    $selected = Get-ToolkitSelection $InitialIndex $Items.Count ''; $pendingKey = $null
    while ($true) {
        $size = Get-ToolkitTerminalSize
        Update-ToolkitTerminalMode $size
        if ($null -eq $size) { $script:ToolkitBasic = $true }
        $frame = New-ToolkitMenuFrame $Title $Items $Description $selected $size $Context
        $plain = $script:ToolkitBasic -or $frame.UseBasic
        if ($plain) { Restore-ToolkitTerminal -LeaveScreen }
        Show-ToolkitFrame -Frame $frame -Plain:$plain
        if (($plain -or $script:ToolkitBasic) -and $null -eq $pendingKey) {
            $answer = Read-Host 'Number, back, /search text, r or q'
            if ($answer -in @('back','cancel','')) { return [pscustomobject]@{ Action = 'Back'; Value = $null; Index = $selected } }
            if ($answer -eq 'q') { return [pscustomobject]@{ Action = 'Quit'; Value = $null; Index = $selected } }
            if ($answer -eq 'r') { return [pscustomobject]@{ Action = 'Refresh'; Value = $null; Index = $selected } }
            if ($answer.StartsWith('/')) { return [pscustomobject]@{ Action = 'Search'; Value = $answer.Substring(1); Index = $selected } }
            $number = 0
            if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Items.Count) { return [pscustomobject]@{ Action = 'Select'; Value = $Items[$number - 1].Value; Index = $number - 1 } }
            Write-Host 'Choose a listed number or back.'
        }
        else {
            if ($null -ne $pendingKey) { $key = $pendingKey; $pendingKey = $null }
            else {
                $key = Read-ToolkitKey
                if ((Get-ToolkitGeometryKey (Get-ToolkitTerminalSize)) -ne (Get-ToolkitGeometryKey $size)) { $pendingKey = $key; continue }
            }
            switch ($key.Key.ToString()) {
                'Escape' { return [pscustomobject]@{ Action = 'Back'; Value = $null; Index = $selected } }
                'Enter' { if ($Items.Count) { return [pscustomobject]@{ Action = 'Select'; Value = $Items[$selected].Value; Index = $selected } } }
                default {
                    if ($key.KeyChar -eq '/') { return [pscustomobject]@{ Action = 'Search'; Value = ''; Index = $selected } }
                    if ($key.KeyChar -in @('r','R')) { return [pscustomobject]@{ Action = 'Refresh'; Value = $null; Index = $selected } }
                    if ($key.KeyChar -in @('q','Q')) { return [pscustomobject]@{ Action = 'Quit'; Value = $null; Index = $selected } }
                    $selected = Get-ToolkitSelection $selected $Items.Count $key.Key.ToString() $frame.PageSize
                }
            }
        }
    }
}

function Show-ToolkitDiagnostic {
    param([object]$Command, [hashtable]$Values)
    $execution = Start-ToolkitExecution $Command $Values
    $lines = New-Object 'Collections.Generic.Queue[string]'
    $characters = 0; $truncated = $false; $painted = $false; $lastGeometry = ''
    try {
        while ($true) {
            $dirty = $false; $line = ''
            while ($execution.Queue.TryTake([ref]$line)) {
                foreach ($part in ($line -split "`r?`n")) {
                    $text = ConvertTo-ToolkitSafeText $part
                    $lines.Enqueue($text); $characters += $text.Length
                    while ($lines.Count -gt 2000 -or $characters -gt 1048576) { $characters -= $lines.Dequeue().Length; $truncated = $true }
                    if ($script:ToolkitBasic) { Write-Host $text }
                }
                $dirty = $true
            }
            $size = Get-ToolkitTerminalSize
            $wasBasic = $script:ToolkitBasic
            Update-ToolkitTerminalMode $size
            if ($script:ToolkitBasic -and -not $wasBasic) { Restore-ToolkitTerminal; $lines.ToArray() | ForEach-Object { Write-Host $_ } }
            $geometry = Get-ToolkitGeometryKey $size
            if (-not $script:ToolkitBasic -and ($dirty -or -not $painted -or $geometry -ne $lastGeometry)) {
                $height = 15; $width = 79
                if ($null -ne $size) { $height = [Math]::Max(1, $size.Height - 8); $width = [Math]::Max(1, $size.Width - 1) }
                $tail = @($lines.ToArray() | Select-Object -Last $height | ForEach-Object { Format-ToolkitText $_ $width -Display } | Select-Object -Last $height)
                $instruction = 'C: cancel | Waiting for output'
                if ($Command.cancellation -eq 'Unavailable') { $instruction = 'Cancellation unavailable; wait for completion.' }
                Show-ToolkitFrame -Frame (New-ToolkitTextFrame $Command.name $tail -Status 'Running' -Footer @($instruction) -Size $size)
                $painted = $true; $lastGeometry = $geometry
            }
            if ($execution.Handle.IsCompleted) { break }
            $limit = 60
            if ($Command.id -eq 'system.full-specs') { $limit = 180 }
            if (-not $execution.DeadlineExceeded -and $Command.id -ne 'storage.hash' -and ([DateTime]::UtcNow - $execution.Started).TotalSeconds -gt $limit) { Stop-ToolkitExecution $execution -TimedOut }
            if (-not $script:ToolkitBasic -and [Console]::KeyAvailable) {
                $key = Read-ToolkitKey
                if ($key.KeyChar -in @('c','C')) { Stop-ToolkitExecution $execution }
            }
            Start-Sleep -Milliseconds 100
        }
        # Drain the final batch before disposing the transport.
        $line = ''
        while ($execution.Queue.TryTake([ref]$line)) {
            foreach ($part in ($line -split "`r?`n")) {
                $text = ConvertTo-ToolkitSafeText $part
                $lines.Enqueue($text); $characters += $text.Length
                while ($lines.Count -gt 2000 -or $characters -gt 1048576) { $characters -= $lines.Dequeue().Length; $truncated = $true }
                if ($script:ToolkitBasic) { Write-Host $text }
            }
        }
        $result = Complete-ToolkitExecution $execution
        $summary = "$($result.Status) | $([Math]::Round($result.Elapsed.TotalSeconds, 2)) seconds"
        if ($truncated -or $result.Truncated) { $summary += ' | Output truncated' }
        if ($script:ToolkitBasic) { Wait-ToolkitAcknowledgement $summary }
        else {
            $offset = 0; $all = $lines.ToArray(); $wrapped = @(); $wrappedWidth = 0; $pendingKey = $null; $lineStarts = @()
            while ($true) {
                $size = Get-ToolkitTerminalSize
                Update-ToolkitTerminalMode $size
                if ($null -eq $size -or $script:ToolkitBasic) { $script:ToolkitBasic = $true; $all | ForEach-Object { Write-Host $_ }; Wait-ToolkitAcknowledgement $summary; break }
                $height = [Math]::Max(1, $size.Height - 8)
                if ($wrappedWidth -ne $size.Width) {
                    $sourceLine = 0; $column = 0
                    for ($index = 0; $index -lt $lineStarts.Count -and $lineStarts[$index] -le $offset; $index++) { $sourceLine = $index }
                    if ($lineStarts.Count) { $column = ($offset - $lineStarts[$sourceLine]) * ($wrappedWidth - 1) }
                    $outputRows = New-Object 'Collections.Generic.List[string]'; $starts = New-Object 'Collections.Generic.List[int]'
                    foreach ($text in $all) {
                        $starts.Add($outputRows.Count)
                        foreach ($part in (Format-ToolkitText $text ($size.Width - 1) -Display)) { $outputRows.Add($part) }
                    }
                    $wrapped = $outputRows.ToArray(); $lineStarts = $starts.ToArray()
                    if ($lineStarts.Count) { $offset = $lineStarts[$sourceLine] + [int][Math]::Floor($column / ($size.Width - 1)) }
                    $wrappedWidth = $size.Width
                }
                $offset = [Math]::Max(0, [Math]::Min($offset, [Math]::Max(0, $wrapped.Count - $height)))
                Show-ToolkitFrame -Frame (New-ToolkitTextFrame $Command.name @($wrapped | Select-Object -Skip $offset -First $height) -Status $summary -Footer @('Up/Down, PgUp/PgDn, Home/End: output', 'Enter/Esc: return') -Size $size)
                if ($null -ne $pendingKey) { $key = $pendingKey; $pendingKey = $null }
                else {
                    $key = Read-ToolkitKey
                    if ((Get-ToolkitGeometryKey (Get-ToolkitTerminalSize)) -ne (Get-ToolkitGeometryKey $size)) { $pendingKey = $key; continue }
                }
                if ($key.Key.ToString() -in @('Enter','Escape')) { break }
                $offset = Get-ToolkitSelection $offset ([Math]::Max(1, $wrapped.Count - $height + 1)) $key.Key.ToString() $height
            }
        }
    }
    finally {
        if (-not $execution.Handle.IsCompleted) { Stop-ToolkitExecution $execution }
    }
}

function Invoke-ToolkitSelectedCommand {
    param([object]$Command, [switch]$Elevated)
    $capability = Get-ToolkitCapability $Command
    if (-not $capability.Available) { Wait-ToolkitAcknowledgement ('Unavailable: ' + $capability.Reason); return }
    $values = @{}
    foreach ($parameter in $Command.parameters) {
        if ($Command.id -in @('security.firewall-control','security.defender-control')) {
            if ($parameter.name -in @('mode','minutes') -and $values.action -eq 'Enable') { continue }
            if ($parameter.name -eq 'minutes' -and $values.mode -eq 'Manual') { continue }
        }
        while ($true) {
            $prompt = $parameter.label
            if ($null -ne $parameter.default) { $prompt += ' [' + $parameter.default + ']' }
            $hints = @("Type: $($parameter.type) | Required: $($parameter.required)")
            if ($parameter.allowedValues.Count) { $hints += 'Choices: ' + ($parameter.allowedValues -join ', ') }
            if ($null -ne $parameter.minimum) { $hints += "Range: $($parameter.minimum)-$($parameter.maximum)" }
            $answer = Read-ToolkitInput $prompt -Description $hints
            if ($null -eq $answer) { return }
            try { $value = Test-ToolkitParameter $parameter $answer; if ($null -ne $value) { $values[$parameter.name] = $value }; break }
            catch { Wait-ToolkitAcknowledgement $_.Exception.Message }
        }
    }
    if ($Command.sourceKind -eq 'CustomScript' -or $Command.requiresAdmin -or $Command.risk -ne 'ReadOnly' -or $Elevated) {
        $process = Start-ToolkitConsole $Command.id $values -Elevated:($Command.requiresAdmin -or $Elevated) -SkipActionConfirmation:($script:ToolkitConfirmActions -eq $false)
        try {
            $lastGeometry = ''
            while (-not $process.HasExited) {
                $size = Get-ToolkitTerminalSize
                $geometry = Get-ToolkitGeometryKey $size
                if (-not $script:ToolkitBasic -and $geometry -ne $lastGeometry) {
                    $instruction = 'Review and confirm there. Waiting for that console to close.'
                    if ($script:ToolkitConfirmActions -eq $false) { $instruction = 'Action confirmations are OFF. The operation may execute immediately.' }
                    Show-ToolkitFrame -Frame (New-ToolkitTextFrame $Command.name @('Operation console is open.', $instruction) -Status 'Waiting for operation console to close' -Size $size -PreserveAll)
                    $lastGeometry = $geometry
                }
                Start-Sleep -Milliseconds 100
            }
            Wait-ToolkitAcknowledgement "Operation console closed (worker exit code $($process.ExitCode)). Detailed results were shown there."
        }
        finally { $process.Dispose() }
    }
    else { Show-ToolkitDiagnostic $Command $values }
}

function Set-ToolkitActionConfirmation {
    if ($script:ToolkitConfirmActions -eq $false) { $script:ToolkitConfirmActions = $true; return }
    $warning = @(
        'WARNING: DISABLE ACTION CONFIRMATIONS',
        '',
        'This skips toolbox yes/typed prompts for ALL modifying commands,',
        'high-risk commands and custom scripts. Selecting Run can immediately',
        'delete files, disable protection, alter updates or force a restart.',
        'Unsaved work can be lost. No per-action confirmation will be requested.',
        '',
        'Windows UAC, permissions, validation and recovery preflight still apply.',
        'Scripts may still ask for their own input. Output consoles remain open.',
        'This setting lasts for this toolkit session only.',
        ''
    )
    $answer = Read-ToolkitInput -Prompt 'Type OFF to disable confirmations; Esc/cancel keeps them on.' -Description $warning
    if ($answer -ceq 'OFF') { $script:ToolkitConfirmActions = $false }
}

function Start-ToolkitInterface {
    param([switch]$Basic)
    Initialize-ToolkitTerminal -Basic:$Basic
    try {
        $category = ''; $query = ''; $isSearch = $false; $selected = 0; $detail = $null; $settingsOpen = $false
        while ($true) {
            if ($settingsOpen) {
                $stateLabel = 'ON'; if ($script:ToolkitConfirmActions -eq $false) { $stateLabel = 'OFF' }
                $items = @([pscustomobject]@{ Label = "Action confirmations: $stateLabel (toggle)"; Value = 'Toggle' }, [pscustomobject]@{ Label = 'Back'; Value = 'Back' })
                $choice = Read-ToolkitMenu 'Settings' $items @('Applies to all modifying, high-risk and custom-script actions.', 'Session only. New toolkit launches start with confirmations ON.')
                if ($choice.Action -eq 'Select' -and $choice.Value -eq 'Toggle') { Set-ToolkitActionConfirmation; continue }
                if ($choice.Action -eq 'Back' -or ($choice.Action -eq 'Select' -and $choice.Value -eq 'Back')) { $settingsOpen = $false; continue }
            }
            elseif ($null -ne $detail) {
                $capability = Get-ToolkitCapability $detail
                $description = @(Get-ToolkitCommandContext $detail)
                if (-not $capability.Available) { $description += 'Unavailable: ' + $capability.Reason }
                $items = @()
                if ($capability.Available) {
                    $runLabel = 'Run (confirmation follows when required)'
                    if ($script:ToolkitConfirmActions -eq $false -and ($detail.risk -ne 'ReadOnly' -or $detail.sourceKind -eq 'CustomScript')) { $runLabel = 'Run now (action confirmations OFF)' }
                    $items += [pscustomobject]@{ Label = $runLabel; Value = 'Run' }
                    if ($detail.sourceKind -eq 'CustomScript' -and -not $detail.requiresAdmin) { $items += [pscustomobject]@{ Label = 'Run as administrator'; Value = 'Elevate' } }
                }
                $items += [pscustomobject]@{ Label = 'Back'; Value = 'Back' }
                $choice = Read-ToolkitMenu $detail.name $items $description -Context $detail
                if ($choice.Action -eq 'Select' -and $choice.Value -in @('Run','Elevate')) {
                    try { Invoke-ToolkitSelectedCommand $detail -Elevated:($choice.Value -eq 'Elevate') }
                    catch { Wait-ToolkitAcknowledgement ('Operation not started: ' + $_.Exception.Message) }
                    continue
                }
                $detail = $null
                if ($choice.Action -eq 'Select') { continue }
            }
            elseif (-not $category -and -not $isSearch) {
                $items = @($script:ToolkitRegistry.commands | Select-Object -ExpandProperty category -Unique | ForEach-Object { [pscustomobject]@{ Label = $_; Value = $_ } })
                $items += [pscustomobject]@{ Label = 'Custom Scripts'; Value = 'Custom Scripts' }
                $items += [pscustomobject]@{ Label = 'Search all commands'; Value = 'Search' }
                $items += [pscustomobject]@{ Label = 'Settings'; Value = 'Settings' }
                $choice = Read-ToolkitMenu 'Command library' $items
                if ($choice.Action -eq 'Select') {
                    if ($choice.Value -eq 'Settings') { $settingsOpen = $true; continue }
                    elseif ($choice.Value -eq 'Search') { $choice.Action = 'Search'; $choice.Value = '' }
                    else { $category = $choice.Value; $selected = 0; continue }
                }
                if ($choice.Action -eq 'Back') { break }
            }
            else {
                $commands = @(Get-ToolkitCatalog -IncludeCustom:($isSearch -or $category -eq 'Custom Scripts'))
                $title = $category
                if ($isSearch) { $commands = @(Find-ToolkitCommand $commands $query); $title = 'Search: ' + $query }
                else { $commands = @($commands | Where-Object category -eq $category) }
                $items = @($commands | ForEach-Object {
                    $label = $_.name
                    if ($_.sourceKind -eq 'CustomScript') { $label += ' [custom: ' + $_.relativePath + ']'; if (-not $_.available) { $label += ' [unavailable]' } }
                    [pscustomobject]@{ Label = $label; Value = $_ }
                })
                $description = @()
                if ($script:ToolkitCustomNotice) { $description = @($script:ToolkitCustomNotice) }
                $choice = Read-ToolkitMenu $title $items $description $selected
                $selected = $choice.Index
                if ($choice.Action -eq 'Select') { $detail = $choice.Value; continue }
                if ($choice.Action -eq 'Back') { $category = ''; $isSearch = $false; $selected = 0; continue }
            }
            if ($choice.Action -eq 'Quit') { break }
            if ($choice.Action -eq 'Refresh') {
                Update-ToolkitCustomCatalog
                $script:ToolkitNotice = "Custom scripts refreshed: $($script:ToolkitCustomCommands.Count) entries"
                if ($script:ToolkitCustomNotice) { $script:ToolkitNotice = 'Refresh incomplete; open Custom Scripts for details' }
                continue
            }
            if ($choice.Action -eq 'Search') {
                $searchText = $choice.Value
                if (-not $searchText) { $searchText = Read-ToolkitInput 'Search all commands' }
                if ($null -ne $searchText) { $query = $searchText; $isSearch = $true; $category = ''; $selected = 0; $settingsOpen = $false }
            }
        }
    }
    finally { Restore-ToolkitTerminal -LeaveScreen }
}

# Source: src/ui/Renderer.ps1
$script:ToolkitFrameCache = $null
$script:ToolkitEscape = [string][char]27
$script:ToolkitTheme = @{
    Background = @('0D1117', 'Black')
    Border = @('30363D', 'DarkGray', "$($script:ToolkitEscape)[38;2;48;54;61m$($script:ToolkitEscape)[48;2;13;17;23m")
    Primary = @('C9D1D9', 'Gray', "$($script:ToolkitEscape)[38;2;201;209;217m$($script:ToolkitEscape)[48;2;13;17;23m")
    Secondary = @('8B949E', 'DarkGray', "$($script:ToolkitEscape)[38;2;139;148;158m$($script:ToolkitEscape)[48;2;13;17;23m")
    Accent = @('79C5BA', 'Cyan', "$($script:ToolkitEscape)[38;2;121;197;186m$($script:ToolkitEscape)[48;2;13;17;23m")
    Selected = @('0D1117', 'Black', "$($script:ToolkitEscape)[38;2;13;17;23m$($script:ToolkitEscape)[48;2;121;197;186m")
    Success = @('7EE787', 'Green', "$($script:ToolkitEscape)[38;2;126;231;135m$($script:ToolkitEscape)[48;2;13;17;23m")
    Warning = @('D29922', 'Yellow', "$($script:ToolkitEscape)[38;2;210;153;34m$($script:ToolkitEscape)[48;2;13;17;23m")
    Danger = @('F85149', 'Red', "$($script:ToolkitEscape)[38;2;248;81;73m$($script:ToolkitEscape)[48;2;13;17;23m")
}

function ConvertTo-ToolkitDisplayText {
    param([AllowNull()][object]$Text)
    $safe = (ConvertTo-ToolkitSafeText $Text).Replace("`t", '    ').Replace("`r", ' ').Replace("`n", ' ')
    if ($safe -cmatch '^[\x20-\x7E]*$') { return $safe }
    # Positioned output cannot assume a font's Unicode cell widths. Plain output retains Unicode.
    return [regex]::Replace($safe, '[^\x20-\x7E]', { param($match) '\u{0:X4}' -f [int][char]$match.Value })
}

function Format-ToolkitText {
    param([string]$Text, [ValidateRange(1, 32767)][int]$Width = 76, [switch]$Display)
    $safe = (ConvertTo-ToolkitSafeText $Text).Replace("`t", '    ')
    foreach ($line in ($safe -split "`r\n|`r|`n")) {
        $remaining = $line
        if ($Display) { $remaining = ConvertTo-ToolkitDisplayText $remaining }
        while ($remaining.Length -gt $Width) {
            $break = $remaining.LastIndexOf(' ', $Width - 1, $Width)
            if ($break -lt 1) { $break = $Width }
            $remaining.Substring(0, $break)
            $remaining = $remaining.Substring($break).TrimStart()
        }
        $remaining
    }
}

function Format-ToolkitCell {
    param([AllowNull()][object]$Text, [int]$Width)
    if ($Width -le 0) { return '' }
    $value = ConvertTo-ToolkitDisplayText $Text
    if ($value.Length -gt $Width) {
        if ($Width -le 3) { return $value.Substring(0, $Width) }
        $value = $value.Substring(0, $Width - 3) + '...'
    }
    return $value.PadRight($Width)
}

function New-ToolkitRow {
    param([string]$Text = '', [string]$Role = 'Primary')
    return [pscustomobject]@{ Segments = @([pscustomobject]@{ Text = $Text; Role = $Role }) }
}

function Get-ToolkitLineRole {
    param([string]$Text)
    if ($Text -match '^(Failed|PermissionDenied|TimedOut|Unavailable:|Operation not started:|Risk: HighRisk)') { return 'Danger' }
    if ($Text -match '^(WARNING|ACTION CONFIRMATIONS OFF|Cancelled|Risk: SystemModification)') { return 'Warning' }
    if ($Text -match '^(Succeeded|Risk: ReadOnly)') { return 'Success' }
    return 'Primary'
}

function Format-ToolkitMenuLabel {
    param([object]$Item)
    if ($null -ne $Item.Value -and $Item.Value.PSObject.Properties['risk']) {
        $tag = 'Read'
        if ($Item.Value.risk -eq 'SystemModification') { $tag = 'Modify' }
        elseif ($Item.Value.risk -eq 'HighRisk') { $tag = 'High risk' }
        return "[$tag] $($Item.Label)"
    }
    return $Item.Label
}

function Get-ToolkitHeader {
    param([string]$Title, [int]$Width)
    $token = 'Standard user'
    if ($null -ne $script:ToolkitTerminalState -and $script:ToolkitTerminalState.Administrator) { $token = 'ADMINISTRATOR: children inherit' }
    $confirmation = 'Confirmations: ON'; $role = 'Secondary'
    if ($script:ToolkitConfirmActions -eq $false) { $confirmation = 'ACTION CONFIRMATIONS OFF'; $role = 'Warning' }
    elseif ($token.StartsWith('ADMINISTRATOR')) { $role = 'Warning' }
    New-ToolkitRow (Format-ToolkitCell "Windows Engineering Toolkit $($script:ToolkitVersion)" $Width) 'Accent'
    New-ToolkitRow (Format-ToolkitCell "$token | $confirmation" $Width) $role
    New-ToolkitRow (Format-ToolkitCell $Title $Width) 'Primary'
    New-ToolkitRow ('-' * $Width) 'Border'
}

function Get-ToolkitCommandContext {
    param([object]$Command)
    $Command.name
    $Command.description
    ''
    "Source: $($Command.sourceKind)"
    "Risk: $($Command.risk)"
    "Administrator requested: $($Command.requiresAdmin)"
    $confirmation = $Command.confirmation
    if ($script:ToolkitConfirmActions -eq $false -and $confirmation -ne 'None') { $confirmation = 'OFF for this session; execution may be immediate' }
    "Confirmation: $confirmation"
    "Cost: $($Command.cost)"
    foreach ($parameter in $Command.parameters) {
        $text = "Parameter: $($parameter.label) [$($parameter.type)]"
        if ($parameter.required) { $text += ' (required)' }
        if ($null -ne $parameter.default) { $text += "; default: $($parameter.default)" }
        if ($parameter.allowedValues.Count) { $text += '; choices: ' + ($parameter.allowedValues -join ', ') }
        if ($null -ne $parameter.minimum) { $text += "; range: $($parameter.minimum)-$($parameter.maximum)" }
        $text
    }
    ''
    $Command.consequences
    if ($Command.sourceKind -eq 'CustomScript') { 'File: ' + $Command.path }
}

function New-ToolkitMenuFrame {
    param([string]$Title, [object[]]$Items, [string[]]$Description, [int]$Selected, [object]$Size, [object]$Context)
    if ($null -eq $Size) { $Size = [pscustomobject]@{ Width = 80; Height = 24 } }
    $width = [Math]::Max(1, $Size.Width - 1); $bodyHeight = [Math]::Max(1, $Size.Height - 8)
    $wide = $Size.Width -ge 110 -and $Size.Height -ge 20
    $leftWidth = $width
    if ($wide) { $leftWidth = [Math]::Max(36, [Math]::Min(48, [int]($width * 0.4))) }
    $preview = @(); $item = $null
    if ($Items.Count) { $item = $Items[$Selected] }
    if ($null -ne $Context) { $preview = $Description }
    elseif ($null -ne $item -and $null -ne $item.Value -and $item.Value.PSObject.Properties['sourceKind']) {
        $preview = @($Description) + @(Get-ToolkitCommandContext $item.Value)
    }
    elseif ($null -ne $item) {
        $preview = @($Description) + @($item.Label)
        $categoryCommands = @($script:ToolkitRegistry.commands | Where-Object category -eq $item.Value)
        if ($categoryCommands.Count) { $preview += @("$($categoryCommands.Count) built-in commands", '') + @($categoryCommands.name) }
        elseif ($item.Value -eq 'Custom Scripts') {
            if ($script:ToolkitCustomLoaded) { $preview += @("$($script:ToolkitCustomCommands.Count) local scripts") + @($script:ToolkitCustomCommands.name) }
            else { $preview += 'Open to discover local scripts.' }
        }
        elseif ($item.Value -eq 'Search') { $preview += 'Search command names, descriptions, IDs and keywords.' }
    }
    else { $preview = @($Description) + @('No matching entries.', 'Use / to search again or Esc to return.') }
    $contextWidth = $width
    if ($wide) { $contextWidth = $width - $leftWidth - 3 }
    $wrapped = @($preview | ForEach-Object { Format-ToolkitText $_ $contextWidth -Display })
    $descriptionLines = @($Description | ForEach-Object { Format-ToolkitText $_ $width -Display })
    $useBasic = $false
    if ($null -ne $Context) {
        if ($wide) { $useBasic = $wrapped.Count -gt $bodyHeight }
        else { $useBasic = $descriptionLines.Count + $Items.Count -gt $bodyHeight }
    }
    elseif ($descriptionLines.Count -ge $bodyHeight) { $useBasic = $true }
    $contextRows = 0
    if (-not $wide) {
        if ($null -ne $Context) { $contextRows = $descriptionLines.Count }
        else { $contextRows = [Math]::Min(3, [Math]::Max(0, $bodyHeight - 2)) }
    }
    $pageSize = [Math]::Max(1, $bodyHeight - $contextRows)
    $start = [int][Math]::Floor($Selected / $pageSize) * $pageSize
    $rows = New-Object 'Collections.Generic.List[object]'
    foreach ($row in (Get-ToolkitHeader $Title $width)) { $rows.Add($row) }
    for ($rowIndex = 0; $rowIndex -lt $bodyHeight; $rowIndex++) {
        $label = ''; $role = 'Primary'; $index = $start + $rowIndex
        if ($rowIndex -lt $pageSize) {
            if ($Items.Count -eq 0 -and $rowIndex -eq 0) { $label = 'No matching entries.' }
            elseif ($index -lt $Items.Count) {
                $marker = '  '
                if ($index -eq $Selected) { $marker = '> '; $role = 'Selected' }
                $label = $marker + (Format-ToolkitMenuLabel $Items[$index])
                if ($role -ne 'Selected' -and $null -ne $Items[$index].Value -and $Items[$index].Value.PSObject.Properties['risk']) { $role = Get-ToolkitLineRole ('Risk: ' + $Items[$index].Value.risk) }
            }
        }
        if ($wide) {
            $right = ''; if ($rowIndex -lt $wrapped.Count) { $right = $wrapped[$rowIndex] }
            if ($wrapped.Count -gt $bodyHeight -and $rowIndex -eq $bodyHeight - 1) { $right = 'Open details for complete information.' }
            $rows.Add([pscustomobject]@{ Segments = @(
                [pscustomobject]@{ Text = (Format-ToolkitCell $label $leftWidth); Role = $role },
                [pscustomobject]@{ Text = ' | '; Role = 'Border' },
                [pscustomobject]@{ Text = (Format-ToolkitCell $right $contextWidth); Role = (Get-ToolkitLineRole $right) }
            ) })
        }
        else {
            if ($rowIndex -ge $pageSize) {
                $contextIndex = $rowIndex - $pageSize
                if ($null -ne $Context) { $label = $descriptionLines[$contextIndex] }
                elseif ($contextIndex -lt $wrapped.Count) { $label = $wrapped[$contextIndex] }
                $role = Get-ToolkitLineRole $label
            }
            $rows.Add((New-ToolkitRow (Format-ToolkitCell $label $width) $role))
        }
    }
    $range = '0 entries'
    if ($Items.Count) { $range = '{0}-{1} of {2}' -f ($start + 1), [Math]::Min($start + $pageSize, $Items.Count), $Items.Count }
    $status = 'Ready'; if ($script:ToolkitNotice) { $status = $script:ToolkitNotice }
    $rows.Add((New-ToolkitRow (Format-ToolkitCell "$status | $range | Home/End, PgUp/PgDn" $width) 'Secondary'))
    $rows.Add((New-ToolkitRow (Format-ToolkitCell 'Up/Down: navigate | Enter: select | Esc: back' $width) 'Secondary'))
    $rows.Add((New-ToolkitRow (Format-ToolkitCell '/: search | R: refresh | Q: exit' $width) 'Secondary'))
    $plain = @("Windows Engineering Toolkit $($script:ToolkitVersion)")
    $token = 'Standard user'
    if ($null -ne $script:ToolkitTerminalState -and $script:ToolkitTerminalState.Administrator) { $token = 'ADMINISTRATOR: children inherit this token' }
    $plain += $token
    if ($script:ToolkitConfirmActions -eq $false) { $plain += 'ACTION CONFIRMATIONS OFF' } else { $plain += 'Action confirmations: ON' }
    $plain += @($Title) + $Description
    if ($script:ToolkitNotice) { $plain += $script:ToolkitNotice }
    for ($index = 0; $index -lt $Items.Count; $index++) { $plain += ('{0}. {1}' -f ($index + 1), (Format-ToolkitMenuLabel $Items[$index])) }
    if (-not $Items.Count) { $plain += 'No matching entries.' }
    $plain += 'Number: select | back/cancel: return | /search text | r: refresh | q: exit'
    return [pscustomobject]@{ Rows = $rows.ToArray(); PlainLines = $plain; UseBasic = $useBasic; PageSize = $pageSize; Size = $Size }
}

function New-ToolkitTextFrame {
    param([string]$Title, [string[]]$Lines, [string]$Status = 'Ready', [string[]]$Footer = @(), [object]$Size, [switch]$PreserveAll)
    if ($null -eq $Size) { $Size = [pscustomobject]@{ Width = 80; Height = 24 } }
    $width = [Math]::Max(1, $Size.Width - 1); $height = [Math]::Max(1, $Size.Height - 8)
    $wrapped = @($Lines | ForEach-Object { Format-ToolkitText $_ $width -Display })
    $rows = New-Object 'Collections.Generic.List[object]'
    foreach ($row in (Get-ToolkitHeader $Title $width)) { $rows.Add($row) }
    for ($index = 0; $index -lt $height; $index++) {
        $text = ''; if ($index -lt $wrapped.Count) { $text = $wrapped[$index] }
        $rows.Add((New-ToolkitRow (Format-ToolkitCell $text $width) (Get-ToolkitLineRole $text)))
    }
    $rows.Add((New-ToolkitRow (Format-ToolkitCell $Status $width) (Get-ToolkitLineRole $Status)))
    for ($index = 0; $index -lt 2; $index++) {
        $text = ''; if ($index -lt $Footer.Count) { $text = $Footer[$index] }
        $rows.Add((New-ToolkitRow (Format-ToolkitCell $text $width) 'Secondary'))
    }
    $plain = @("Windows Engineering Toolkit $($script:ToolkitVersion)", $Title)
    if ($null -ne $script:ToolkitTerminalState -and $script:ToolkitTerminalState.Administrator) { $plain += 'ADMINISTRATOR: children inherit this token' }
    if ($script:ToolkitConfirmActions -eq $false) { $plain += 'ACTION CONFIRMATIONS OFF' }
    return [pscustomobject]@{ Rows = $rows.ToArray(); PlainLines = @($plain + $Lines + @($Status) + $Footer); UseBasic = ($PreserveAll -and $wrapped.Count -gt $height); Size = $Size }
}

function Write-ToolkitRow {
    param([object]$Row, [int]$Left, [int]$Top)
    [Console]::SetCursorPosition($Left, $Top)
    $trueColor = $null -ne $script:ToolkitTerminalState -and $script:ToolkitTerminalState.TrueColor
    if ($trueColor) {
        $builder = New-Object Text.StringBuilder
        $escape = [char]27
        foreach ($segment in $Row.Segments) {
            [void]$builder.Append($script:ToolkitTheme[$segment.Role][2])
            [void]$builder.Append($segment.Text)
        }
        [void]$builder.Append("$escape[0m")
        [Console]::Write($builder.ToString())
    }
    else {
        foreach ($segment in $Row.Segments) {
            $foreground = $script:ToolkitTheme[$segment.Role][1]; $background = 'Black'
            if ($segment.Role -eq 'Selected') { $foreground = 'Black'; $background = 'Cyan' }
            [Console]::ForegroundColor = $foreground; [Console]::BackgroundColor = $background
            [Console]::Write($segment.Text)
        }
    }
}

function Show-ToolkitFrame {
    param([string[]]$Lines, [object]$Frame, [switch]$Plain, [switch]$Retry)
    $size = Get-ToolkitTerminalSize
    if ($null -eq $Frame) { $Frame = New-ToolkitTextFrame 'Output' $Lines -Size $size -PreserveAll }
    if ($Plain -or $script:ToolkitBasic -or $null -eq $size -or $Frame.UseBasic) {
        $script:ToolkitFrameCache = $null
        foreach ($line in $Frame.PlainLines) { Write-Host (ConvertTo-ToolkitSafeText $line) }
        return
    }
    try {
        $geometry = Get-ToolkitGeometryKey $size
        if ((Get-ToolkitGeometryKey $Frame.Size) -ne $geometry) { $script:ToolkitFrameCache = $null; return }
        $previous = $script:ToolkitFrameCache
        $keys = New-Object 'Collections.Generic.List[string]'
        for ($index = 0; $index -lt [Math]::Min($Frame.Rows.Count, $size.Height - 1); $index++) {
            $row = $Frame.Rows[$index]
            $key = ($row.Segments | ForEach-Object { $_.Role + ':' + $_.Text }) -join [char]30
            $keys.Add($key)
            if ($null -eq $previous -or $previous.Geometry -ne $geometry -or $index -ge $previous.Keys.Count -or $previous.Keys[$index] -cne $key) {
                $left = 0; $top = 0
                if ($size.PSObject.Properties['Left']) { $left = $size.Left; $top = $size.Top }
                Write-ToolkitRow $row $left ($top + $index)
            }
        }
        $script:ToolkitFrameCache = [pscustomobject]@{ Geometry = $geometry; Keys = $keys.ToArray() }
    }
    catch {
        $script:ToolkitFrameCache = $null
        if (-not $Retry -and (Get-ToolkitGeometryKey (Get-ToolkitTerminalSize)) -eq $geometry) { Show-ToolkitFrame -Frame $Frame -Retry; return }
        if ($null -ne $script:ToolkitTerminalState) { $script:ToolkitTerminalState.Failed = $true }
        $script:ToolkitBasic = $true
        Restore-ToolkitTerminal
        Write-Host 'Console positioning unavailable; using numbered menus.'
        foreach ($line in $Frame.PlainLines) { Write-Host (ConvertTo-ToolkitSafeText $line) }
    }
}

$script:ToolkitRegistry = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('ewogICJzY2hlbWFWZXJzaW9uIjogMSwKICAiYXBwbGljYXRpb25WZXJzaW9uIjogIjAuMi4xIiwKICAiY29tbWFuZHMiOiBbCiAgICB7CiAgICAgICJpZCI6ICJzeXN0ZW0ub3MiLAogICAgICAibmFtZSI6ICJPcGVyYXRpbmcgc3lzdGVtIiwKICAgICAgImRlc2NyaXB0aW9uIjogIkVkaXRpb24sIGJ1aWxkLCBhcmNoaXRlY3R1cmUgYW5kIFdpbmRvd3MgZGlyZWN0b3J5LiIsCiAgICAgICJjYXRlZ29yeSI6ICJTeXN0ZW0gSW5mb3JtYXRpb24iLAogICAgICAia2V5d29yZHMiOiBbCiAgICAgICAgIm9zIgogICAgICBdLAogICAgICAic291cmNlS2luZCI6ICJCdWlsdEluIiwKICAgICAgImV4ZWN1dGlvblR5cGUiOiAiRnVuY3Rpb24iLAogICAgICAidGFyZ2V0SWQiOiAic3lzdGVtLm9zIiwKICAgICAgInBhcmFtZXRlcnMiOiBbXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiBmYWxzZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFtdCiAgICAgIH0sCiAgICAgICJyaXNrIjogIlJlYWRPbmx5IiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJOb25lIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJObyBpbnRlbnRpb25hbCBjb25maWd1cmF0aW9uIGNoYW5nZS4gV2luZG93cyBtYXkgd3JpdGUgb3BlcmF0aW9uYWwgbG9ncy4iLAogICAgICAiY29zdCI6ICJRdWljayIsCiAgICAgICJuZXR3b3JrQWNjZXNzIjogIk5vbmUiLAogICAgICAiY2FuY2VsbGF0aW9uIjogIkNvb3BlcmF0aXZlIgogICAgfSwKICAgIHsKICAgICAgImlkIjogInN5c3RlbS5jb21wdXRlciIsCiAgICAgICJuYW1lIjogIkNvbXB1dGVyIGluZm9ybWF0aW9uIiwKICAgICAgImRlc2NyaXB0aW9uIjogIk1hbnVmYWN0dXJlciwgbW9kZWwsIG1lbW9yeSBhbmQgY29tcHV0ZXIgcm9sZS4iLAogICAgICAiY2F0ZWdvcnkiOiAiU3lzdGVtIEluZm9ybWF0aW9uIiwKICAgICAgImtleXdvcmRzIjogWwogICAgICAgICJjb21wdXRlciIKICAgICAgXSwKICAgICAgInNvdXJjZUtpbmQiOiAiQnVpbHRJbiIsCiAgICAgICJleGVjdXRpb25UeXBlIjogIkZ1bmN0aW9uIiwKICAgICAgInRhcmdldElkIjogInN5c3RlbS5jb21wdXRlciIsCiAgICAgICJwYXJhbWV0ZXJzIjogW10sCiAgICAgICJyZXF1aXJlc0FkbWluIjogZmFsc2UsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbXQogICAgICB9LAogICAgICAicmlzayI6ICJSZWFkT25seSIsCiAgICAgICJjb25maXJtYXRpb24iOiAiTm9uZSIsCiAgICAgICJjb25zZXF1ZW5jZXMiOiAiTm8gaW50ZW50aW9uYWwgY29uZmlndXJhdGlvbiBjaGFuZ2UuIFdpbmRvd3MgbWF5IHdyaXRlIG9wZXJhdGlvbmFsIGxvZ3MuIiwKICAgICAgImNvc3QiOiAiUXVpY2siLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJDb29wZXJhdGl2ZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJzeXN0ZW0udXBkYXRlcyIsCiAgICAgICJuYW1lIjogIkluc3RhbGxlZCB1cGRhdGVzIiwKICAgICAgImRlc2NyaXB0aW9uIjogIlVwZGF0ZXMgcmVwb3J0ZWQgYnkgR2V0LUhvdEZpeDsgbm90IGEgY29tcGxldGUgc2VydmljaW5nIGhpc3RvcnkuIiwKICAgICAgImNhdGVnb3J5IjogIlN5c3RlbSBJbmZvcm1hdGlvbiIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAidXBkYXRlcyIKICAgICAgXSwKICAgICAgInNvdXJjZUtpbmQiOiAiQnVpbHRJbiIsCiAgICAgICJleGVjdXRpb25UeXBlIjogIkNtZGxldCIsCiAgICAgICJ0YXJnZXRJZCI6ICJzeXN0ZW0udXBkYXRlcyIsCiAgICAgICJwYXJhbWV0ZXJzIjogW10sCiAgICAgICJyZXF1aXJlc0FkbWluIjogZmFsc2UsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbXQogICAgICB9LAogICAgICAicmlzayI6ICJSZWFkT25seSIsCiAgICAgICJjb25maXJtYXRpb24iOiAiTm9uZSIsCiAgICAgICJjb25zZXF1ZW5jZXMiOiAiTm8gaW50ZW50aW9uYWwgY29uZmlndXJhdGlvbiBjaGFuZ2UuIFdpbmRvd3MgbWF5IHdyaXRlIG9wZXJhdGlvbmFsIGxvZ3MuIiwKICAgICAgImNvc3QiOiAiVmFyaWFibGUiLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJDb29wZXJhdGl2ZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJzeXN0ZW0udXB0aW1lIiwKICAgICAgIm5hbWUiOiAiU3lzdGVtIHVwdGltZSIsCiAgICAgICJkZXNjcmlwdGlvbiI6ICJUaW1lIHNpbmNlIHRoZSBsYXN0IG9wZXJhdGluZyBzeXN0ZW0gYm9vdC4iLAogICAgICAiY2F0ZWdvcnkiOiAiU3lzdGVtIEluZm9ybWF0aW9uIiwKICAgICAgImtleXdvcmRzIjogWwogICAgICAgICJ1cHRpbWUiCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJGdW5jdGlvbiIsCiAgICAgICJ0YXJnZXRJZCI6ICJzeXN0ZW0udXB0aW1lIiwKICAgICAgInBhcmFtZXRlcnMiOiBbXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiBmYWxzZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFtdCiAgICAgIH0sCiAgICAgICJyaXNrIjogIlJlYWRPbmx5IiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJOb25lIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJObyBpbnRlbnRpb25hbCBjb25maWd1cmF0aW9uIGNoYW5nZS4gV2luZG93cyBtYXkgd3JpdGUgb3BlcmF0aW9uYWwgbG9ncy4iLAogICAgICAiY29zdCI6ICJRdWljayIsCiAgICAgICJuZXR3b3JrQWNjZXNzIjogIk5vbmUiLAogICAgICAiY2FuY2VsbGF0aW9uIjogIkNvb3BlcmF0aXZlIgogICAgfSwKICAgIHsKICAgICAgImlkIjogInN5c3RlbS5lbnZpcm9ubWVudCIsCiAgICAgICJuYW1lIjogIkVudmlyb25tZW50IGluZm9ybWF0aW9uIiwKICAgICAgImRlc2NyaXB0aW9uIjogIkFsbG93bGlzdGVkIHBhdGhzLCBydW50aW1lIHZlcnNpb25zIGFuZCBwcm9jZXNzIGJpdG5lc3MuIiwKICAgICAgImNhdGVnb3J5IjogIlN5c3RlbSBJbmZvcm1hdGlvbiIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAiZW52aXJvbm1lbnQiCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJGdW5jdGlvbiIsCiAgICAgICJ0YXJnZXRJZCI6ICJzeXN0ZW0uZW52aXJvbm1lbnQiLAogICAgICAicGFyYW1ldGVycyI6IFtdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IGZhbHNlLAogICAgICAiY29tcGF0aWJpbGl0eSI6IHsKICAgICAgICAibWluaW11bUJ1aWxkIjogMTAyNDAsCiAgICAgICAgImFyY2hpdGVjdHVyZXMiOiBbCiAgICAgICAgICAieDg2IiwKICAgICAgICAgICJ4NjQiCiAgICAgICAgXSwKICAgICAgICAiY2FwYWJpbGl0aWVzIjogW10KICAgICAgfSwKICAgICAgInJpc2siOiAiUmVhZE9ubHkiLAogICAgICAiY29uZmlybWF0aW9uIjogIk5vbmUiLAogICAgICAiY29uc2VxdWVuY2VzIjogIk5vIGludGVudGlvbmFsIGNvbmZpZ3VyYXRpb24gY2hhbmdlLiBXaW5kb3dzIG1heSB3cml0ZSBvcGVyYXRpb25hbCBsb2dzLiIsCiAgICAgICJjb3N0IjogIlF1aWNrIiwKICAgICAgIm5ldHdvcmtBY2Nlc3MiOiAiTm9uZSIsCiAgICAgICJjYW5jZWxsYXRpb24iOiAiQ29vcGVyYXRpdmUiCiAgICB9LAogICAgewogICAgICAiaWQiOiAic3lzdGVtLmxvY2FsZSIsCiAgICAgICJuYW1lIjogIkxvY2FsZSBhbmQgdGltZSB6b25lIiwKICAgICAgImRlc2NyaXB0aW9uIjogIkN1bHR1cmUsIGRpc3BsYXkgbGFuZ3VhZ2UgYW5kIGxvY2FsIHRpbWUgem9uZS4iLAogICAgICAiY2F0ZWdvcnkiOiAiU3lzdGVtIEluZm9ybWF0aW9uIiwKICAgICAgImtleXdvcmRzIjogWwogICAgICAgICJsb2NhbGUiCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJGdW5jdGlvbiIsCiAgICAgICJ0YXJnZXRJZCI6ICJzeXN0ZW0ubG9jYWxlIiwKICAgICAgInBhcmFtZXRlcnMiOiBbXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiBmYWxzZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFtdCiAgICAgIH0sCiAgICAgICJyaXNrIjogIlJlYWRPbmx5IiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJOb25lIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJObyBpbnRlbnRpb25hbCBjb25maWd1cmF0aW9uIGNoYW5nZS4gV2luZG93cyBtYXkgd3JpdGUgb3BlcmF0aW9uYWwgbG9ncy4iLAogICAgICAiY29zdCI6ICJRdWljayIsCiAgICAgICJuZXR3b3JrQWNjZXNzIjogIk5vbmUiLAogICAgICAiY2FuY2VsbGF0aW9uIjogIkNvb3BlcmF0aXZlIgogICAgfSwKICAgIHsKICAgICAgImlkIjogIm5ldHdvcmsuaXAiLAogICAgICAibmFtZSI6ICJJUCBjb25maWd1cmF0aW9uIiwKICAgICAgImRlc2NyaXB0aW9uIjogIkZ1bGwgbG9jYWwgSVAgY29uZmlndXJhdGlvbi4iLAogICAgICAiY2F0ZWdvcnkiOiAiTmV0d29ya2luZyIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAiaXAiCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJOYXRpdmUiLAogICAgICAidGFyZ2V0SWQiOiAibmV0d29yay5pcCIsCiAgICAgICJwYXJhbWV0ZXJzIjogW10sCiAgICAgICJyZXF1aXJlc0FkbWluIjogZmFsc2UsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbCiAgICAgICAgICAiZXhlOmlwY29uZmlnLmV4ZSIKICAgICAgICBdCiAgICAgIH0sCiAgICAgICJyaXNrIjogIlJlYWRPbmx5IiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJOb25lIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJObyBpbnRlbnRpb25hbCBjb25maWd1cmF0aW9uIGNoYW5nZS4gV2luZG93cyBtYXkgd3JpdGUgb3BlcmF0aW9uYWwgbG9ncy4iLAogICAgICAiY29zdCI6ICJRdWljayIsCiAgICAgICJuZXR3b3JrQWNjZXNzIjogIk5vbmUiLAogICAgICAiY2FuY2VsbGF0aW9uIjogIlRlcm1pbmF0ZU93bmVkUHJvY2VzcyIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJuZXR3b3JrLnBpbmciLAogICAgICAibmFtZSI6ICJQaW5nIiwKICAgICAgImRlc2NyaXB0aW9uIjogIkZvdXIgSUNNUCBwcm9iZXMgdG8gYSB0YXJnZXQgeW91IHByb3ZpZGUuIiwKICAgICAgImNhdGVnb3J5IjogIk5ldHdvcmtpbmciLAogICAgICAia2V5d29yZHMiOiBbCiAgICAgICAgInBpbmciLAogICAgICAgICJpY21wIiwKICAgICAgICAibGF0ZW5jeSIKICAgICAgXSwKICAgICAgInNvdXJjZUtpbmQiOiAiQnVpbHRJbiIsCiAgICAgICJleGVjdXRpb25UeXBlIjogIk5hdGl2ZSIsCiAgICAgICJ0YXJnZXRJZCI6ICJuZXR3b3JrLnBpbmciLAogICAgICAicGFyYW1ldGVycyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJob3N0IiwKICAgICAgICAgICJ0eXBlIjogIkhvc3QiLAogICAgICAgICAgImxhYmVsIjogIlRhcmdldCBob3N0bmFtZSBvciBJUCIsCiAgICAgICAgICAicmVxdWlyZWQiOiB0cnVlLAogICAgICAgICAgImRlZmF1bHQiOiBudWxsLAogICAgICAgICAgIm1pbmltdW0iOiBudWxsLAogICAgICAgICAgIm1heGltdW0iOiBudWxsLAogICAgICAgICAgImFsbG93ZWRWYWx1ZXMiOiBbXQogICAgICAgIH0KICAgICAgXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiBmYWxzZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFsKICAgICAgICAgICJleGU6cGluZy5leGUiCiAgICAgICAgXQogICAgICB9LAogICAgICAicmlzayI6ICJSZWFkT25seSIsCiAgICAgICJjb25maXJtYXRpb24iOiAiTm9uZSIsCiAgICAgICJjb25zZXF1ZW5jZXMiOiAiTm8gaW50ZW50aW9uYWwgY29uZmlndXJhdGlvbiBjaGFuZ2UuIFdpbmRvd3MgbWF5IHdyaXRlIG9wZXJhdGlvbmFsIGxvZ3MuIiwKICAgICAgImNvc3QiOiAiVmFyaWFibGUiLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJVc2VyVGFyZ2V0IiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJUZXJtaW5hdGVPd25lZFByb2Nlc3MiCiAgICB9LAogICAgewogICAgICAiaWQiOiAibmV0d29yay50cmFjZSIsCiAgICAgICJuYW1lIjogIlRyYWNlcm91dGUiLAogICAgICAiZGVzY3JpcHRpb24iOiAiQm91bmRlZCByb3V0ZSB0cmFjaW5nIHdpdGhvdXQgcmV2ZXJzZSBETlMgbG9va3Vwcy4iLAogICAgICAiY2F0ZWdvcnkiOiAiTmV0d29ya2luZyIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAidHJhY2UiCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJOYXRpdmUiLAogICAgICAidGFyZ2V0SWQiOiAibmV0d29yay50cmFjZSIsCiAgICAgICJwYXJhbWV0ZXJzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogImhvc3QiLAogICAgICAgICAgInR5cGUiOiAiSG9zdCIsCiAgICAgICAgICAibGFiZWwiOiAiVGFyZ2V0IGhvc3RuYW1lIG9yIElQIiwKICAgICAgICAgICJyZXF1aXJlZCI6IHRydWUsCiAgICAgICAgICAiZGVmYXVsdCI6IG51bGwsCiAgICAgICAgICAibWluaW11bSI6IG51bGwsCiAgICAgICAgICAibWF4aW11bSI6IG51bGwsCiAgICAgICAgICAiYWxsb3dlZFZhbHVlcyI6IFtdCiAgICAgICAgfQogICAgICBdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IGZhbHNlLAogICAgICAiY29tcGF0aWJpbGl0eSI6IHsKICAgICAgICAibWluaW11bUJ1aWxkIjogMTAyNDAsCiAgICAgICAgImFyY2hpdGVjdHVyZXMiOiBbCiAgICAgICAgICAieDg2IiwKICAgICAgICAgICJ4NjQiCiAgICAgICAgXSwKICAgICAgICAiY2FwYWJpbGl0aWVzIjogWwogICAgICAgICAgImV4ZTp0cmFjZXJ0LmV4ZSIKICAgICAgICBdCiAgICAgIH0sCiAgICAgICJyaXNrIjogIlJlYWRPbmx5IiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJOb25lIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJObyBpbnRlbnRpb25hbCBjb25maWd1cmF0aW9uIGNoYW5nZS4gV2luZG93cyBtYXkgd3JpdGUgb3BlcmF0aW9uYWwgbG9ncy4iLAogICAgICAiY29zdCI6ICJWYXJpYWJsZSIsCiAgICAgICJuZXR3b3JrQWNjZXNzIjogIlVzZXJUYXJnZXQiLAogICAgICAiY2FuY2VsbGF0aW9uIjogIlRlcm1pbmF0ZU93bmVkUHJvY2VzcyIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJuZXR3b3JrLmxvc3MiLAogICAgICAibmFtZSI6ICJQYWNrZXQgbG9zcyB0ZXN0IiwKICAgICAgImRlc2NyaXB0aW9uIjogIlR3ZW50eSBJQ01QIHByb2JlcyB3aXRoIGEgbG9zcyBhbmQgbGF0ZW5jeSBzdW1tYXJ5LiIsCiAgICAgICJjYXRlZ29yeSI6ICJOZXR3b3JraW5nIiwKICAgICAgImtleXdvcmRzIjogWwogICAgICAgICJsb3NzIgogICAgICBdLAogICAgICAic291cmNlS2luZCI6ICJCdWlsdEluIiwKICAgICAgImV4ZWN1dGlvblR5cGUiOiAiRnVuY3Rpb24iLAogICAgICAidGFyZ2V0SWQiOiAibmV0d29yay5sb3NzIiwKICAgICAgInBhcmFtZXRlcnMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAiaG9zdCIsCiAgICAgICAgICAidHlwZSI6ICJIb3N0IiwKICAgICAgICAgICJsYWJlbCI6ICJUYXJnZXQgaG9zdG5hbWUgb3IgSVAiLAogICAgICAgICAgInJlcXVpcmVkIjogdHJ1ZSwKICAgICAgICAgICJkZWZhdWx0IjogbnVsbCwKICAgICAgICAgICJtaW5pbXVtIjogbnVsbCwKICAgICAgICAgICJtYXhpbXVtIjogbnVsbCwKICAgICAgICAgICJhbGxvd2VkVmFsdWVzIjogW10KICAgICAgICB9CiAgICAgIF0sCiAgICAgICJyZXF1aXJlc0FkbWluIjogZmFsc2UsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbXQogICAgICB9LAogICAgICAicmlzayI6ICJSZWFkT25seSIsCiAgICAgICJjb25maXJtYXRpb24iOiAiTm9uZSIsCiAgICAgICJjb25zZXF1ZW5jZXMiOiAiTm8gaW50ZW50aW9uYWwgY29uZmlndXJhdGlvbiBjaGFuZ2UuIFdpbmRvd3MgbWF5IHdyaXRlIG9wZXJhdGlvbmFsIGxvZ3MuIiwKICAgICAgImNvc3QiOiAiVmFyaWFibGUiLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJVc2VyVGFyZ2V0IiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJDb29wZXJhdGl2ZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJuZXR3b3JrLmRucyIsCiAgICAgICJuYW1lIjogIkROUyBsb29rdXAiLAogICAgICAiZGVzY3JpcHRpb24iOiAiUXVlcnkgeW91ciBjb25maWd1cmVkIEROUyBzZXJ2aWNlIGZvciBhIG5hbWUgYW5kIHJlY29yZCB0eXBlLiIsCiAgICAgICJjYXRlZ29yeSI6ICJOZXR3b3JraW5nIiwKICAgICAgImtleXdvcmRzIjogWwogICAgICAgICJkbnMiCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJDbWRsZXQiLAogICAgICAidGFyZ2V0SWQiOiAibmV0d29yay5kbnMiLAogICAgICAicGFyYW1ldGVycyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJob3N0IiwKICAgICAgICAgICJ0eXBlIjogIkhvc3QiLAogICAgICAgICAgImxhYmVsIjogIkROUyBuYW1lIiwKICAgICAgICAgICJyZXF1aXJlZCI6IHRydWUsCiAgICAgICAgICAiZGVmYXVsdCI6IG51bGwsCiAgICAgICAgICAibWluaW11bSI6IG51bGwsCiAgICAgICAgICAibWF4aW11bSI6IG51bGwsCiAgICAgICAgICAiYWxsb3dlZFZhbHVlcyI6IFtdCiAgICAgICAgfSwKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJyZWNvcmRUeXBlIiwKICAgICAgICAgICJ0eXBlIjogIkNob2ljZSIsCiAgICAgICAgICAibGFiZWwiOiAiUmVjb3JkIHR5cGUiLAogICAgICAgICAgInJlcXVpcmVkIjogdHJ1ZSwKICAgICAgICAgICJkZWZhdWx0IjogIkEiLAogICAgICAgICAgIm1pbmltdW0iOiBudWxsLAogICAgICAgICAgIm1heGltdW0iOiBudWxsLAogICAgICAgICAgImFsbG93ZWRWYWx1ZXMiOiBbCiAgICAgICAgICAgICJBIiwKICAgICAgICAgICAgIkFBQUEiLAogICAgICAgICAgICAiQ05BTUUiLAogICAgICAgICAgICAiTVgiLAogICAgICAgICAgICAiTlMiLAogICAgICAgICAgICAiVFhUIiwKICAgICAgICAgICAgIlBUUiIKICAgICAgICAgIF0KICAgICAgICB9CiAgICAgIF0sCiAgICAgICJyZXF1aXJlc0FkbWluIjogZmFsc2UsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbCiAgICAgICAgICAiY21kbGV0OlJlc29sdmUtRG5zTmFtZSIKICAgICAgICBdCiAgICAgIH0sCiAgICAgICJyaXNrIjogIlJlYWRPbmx5IiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJOb25lIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJObyBpbnRlbnRpb25hbCBjb25maWd1cmF0aW9uIGNoYW5nZS4gV2luZG93cyBtYXkgd3JpdGUgb3BlcmF0aW9uYWwgbG9ncy4iLAogICAgICAiY29zdCI6ICJWYXJpYWJsZSIsCiAgICAgICJuZXR3b3JrQWNjZXNzIjogIlVzZXJUYXJnZXQiLAogICAgICAiY2FuY2VsbGF0aW9uIjogIkNvb3BlcmF0aXZlIgogICAgfSwKICAgIHsKICAgICAgImlkIjogIm5ldHdvcmsuYXJwIiwKICAgICAgIm5hbWUiOiAiQVJQIHRhYmxlIiwKICAgICAgImRlc2NyaXB0aW9uIjogIkN1cnJlbnQgSVB2NCBuZWlnaGJvciBjYWNoZS4iLAogICAgICAiY2F0ZWdvcnkiOiAiTmV0d29ya2luZyIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAiYXJwIgogICAgICBdLAogICAgICAic291cmNlS2luZCI6ICJCdWlsdEluIiwKICAgICAgImV4ZWN1dGlvblR5cGUiOiAiTmF0aXZlIiwKICAgICAgInRhcmdldElkIjogIm5ldHdvcmsuYXJwIiwKICAgICAgInBhcmFtZXRlcnMiOiBbXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiBmYWxzZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFsKICAgICAgICAgICJleGU6YXJwLmV4ZSIKICAgICAgICBdCiAgICAgIH0sCiAgICAgICJyaXNrIjogIlJlYWRPbmx5IiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJOb25lIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJObyBpbnRlbnRpb25hbCBjb25maWd1cmF0aW9uIGNoYW5nZS4gV2luZG93cyBtYXkgd3JpdGUgb3BlcmF0aW9uYWwgbG9ncy4iLAogICAgICAiY29zdCI6ICJRdWljayIsCiAgICAgICJuZXR3b3JrQWNjZXNzIjogIk5vbmUiLAogICAgICAiY2FuY2VsbGF0aW9uIjogIlRlcm1pbmF0ZU93bmVkUHJvY2VzcyIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJuZXR3b3JrLnJvdXRlcyIsCiAgICAgICJuYW1lIjogIlJvdXRpbmcgdGFibGUiLAogICAgICAiZGVzY3JpcHRpb24iOiAiQ3VycmVudCBJUHY0IGFuZCBJUHY2IHJvdXRpbmcgdGFibGVzLiIsCiAgICAgICJjYXRlZ29yeSI6ICJOZXR3b3JraW5nIiwKICAgICAgImtleXdvcmRzIjogWwogICAgICAgICJyb3V0ZXMiCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJOYXRpdmUiLAogICAgICAidGFyZ2V0SWQiOiAibmV0d29yay5yb3V0ZXMiLAogICAgICAicGFyYW1ldGVycyI6IFtdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IGZhbHNlLAogICAgICAiY29tcGF0aWJpbGl0eSI6IHsKICAgICAgICAibWluaW11bUJ1aWxkIjogMTAyNDAsCiAgICAgICAgImFyY2hpdGVjdHVyZXMiOiBbCiAgICAgICAgICAieDg2IiwKICAgICAgICAgICJ4NjQiCiAgICAgICAgXSwKICAgICAgICAiY2FwYWJpbGl0aWVzIjogWwogICAgICAgICAgImV4ZTpyb3V0ZS5leGUiCiAgICAgICAgXQogICAgICB9LAogICAgICAicmlzayI6ICJSZWFkT25seSIsCiAgICAgICJjb25maXJtYXRpb24iOiAiTm9uZSIsCiAgICAgICJjb25zZXF1ZW5jZXMiOiAiTm8gaW50ZW50aW9uYWwgY29uZmlndXJhdGlvbiBjaGFuZ2UuIFdpbmRvd3MgbWF5IHdyaXRlIG9wZXJhdGlvbmFsIGxvZ3MuIiwKICAgICAgImNvc3QiOiAiUXVpY2siLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJUZXJtaW5hdGVPd25lZFByb2Nlc3MiCiAgICB9LAogICAgewogICAgICAiaWQiOiAibmV0d29yay5jb25uZWN0aW9ucyIsCiAgICAgICJuYW1lIjogIk5ldHdvcmsgY29ubmVjdGlvbnMiLAogICAgICAiZGVzY3JpcHRpb24iOiAiQ29ubmVjdGlvbnMgYW5kIGxpc3RlbmluZyBwb3J0cyB3aXRoIHByb2Nlc3MgSURzLiIsCiAgICAgICJjYXRlZ29yeSI6ICJOZXR3b3JraW5nIiwKICAgICAgImtleXdvcmRzIjogWwogICAgICAgICJjb25uZWN0aW9ucyIKICAgICAgXSwKICAgICAgInNvdXJjZUtpbmQiOiAiQnVpbHRJbiIsCiAgICAgICJleGVjdXRpb25UeXBlIjogIk5hdGl2ZSIsCiAgICAgICJ0YXJnZXRJZCI6ICJuZXR3b3JrLmNvbm5lY3Rpb25zIiwKICAgICAgInBhcmFtZXRlcnMiOiBbXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiBmYWxzZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFsKICAgICAgICAgICJleGU6bmV0c3RhdC5leGUiCiAgICAgICAgXQogICAgICB9LAogICAgICAicmlzayI6ICJSZWFkT25seSIsCiAgICAgICJjb25maXJtYXRpb24iOiAiTm9uZSIsCiAgICAgICJjb25zZXF1ZW5jZXMiOiAiTm8gaW50ZW50aW9uYWwgY29uZmlndXJhdGlvbiBjaGFuZ2UuIFdpbmRvd3MgbWF5IHdyaXRlIG9wZXJhdGlvbmFsIGxvZ3MuIiwKICAgICAgImNvc3QiOiAiUXVpY2siLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJUZXJtaW5hdGVPd25lZFByb2Nlc3MiCiAgICB9LAogICAgewogICAgICAiaWQiOiAibmV0d29yay5wb3J0IiwKICAgICAgIm5hbWUiOiAiVENQIHBvcnQgdGVzdCIsCiAgICAgICJkZXNjcmlwdGlvbiI6ICJUcnkgYSBUQ1AgY29ubmVjdGlvbiB0byB5b3VyIHRhcmdldCwgd2l0aCBhIGZpdmUtc2Vjb25kIGNvbm5lY3Rpb24gd2FpdC4iLAogICAgICAiY2F0ZWdvcnkiOiAiTmV0d29ya2luZyIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAicG9ydCIKICAgICAgXSwKICAgICAgInNvdXJjZUtpbmQiOiAiQnVpbHRJbiIsCiAgICAgICJleGVjdXRpb25UeXBlIjogIkZ1bmN0aW9uIiwKICAgICAgInRhcmdldElkIjogIm5ldHdvcmsucG9ydCIsCiAgICAgICJwYXJhbWV0ZXJzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogImhvc3QiLAogICAgICAgICAgInR5cGUiOiAiSG9zdCIsCiAgICAgICAgICAibGFiZWwiOiAiVGFyZ2V0IGhvc3RuYW1lIG9yIElQIiwKICAgICAgICAgICJyZXF1aXJlZCI6IHRydWUsCiAgICAgICAgICAiZGVmYXVsdCI6IG51bGwsCiAgICAgICAgICAibWluaW11bSI6IG51bGwsCiAgICAgICAgICAibWF4aW11bSI6IG51bGwsCiAgICAgICAgICAiYWxsb3dlZFZhbHVlcyI6IFtdCiAgICAgICAgfSwKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJwb3J0IiwKICAgICAgICAgICJ0eXBlIjogIkludGVnZXIiLAogICAgICAgICAgImxhYmVsIjogIlRDUCBwb3J0IiwKICAgICAgICAgICJyZXF1aXJlZCI6IHRydWUsCiAgICAgICAgICAiZGVmYXVsdCI6IG51bGwsCiAgICAgICAgICAibWluaW11bSI6IDEsCiAgICAgICAgICAibWF4aW11bSI6IDY1NTM1LAogICAgICAgICAgImFsbG93ZWRWYWx1ZXMiOiBbXQogICAgICAgIH0KICAgICAgXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiBmYWxzZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFtdCiAgICAgIH0sCiAgICAgICJyaXNrIjogIlJlYWRPbmx5IiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJOb25lIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJObyBpbnRlbnRpb25hbCBjb25maWd1cmF0aW9uIGNoYW5nZS4gV2luZG93cyBtYXkgd3JpdGUgb3BlcmF0aW9uYWwgbG9ncy4iLAogICAgICAiY29zdCI6ICJWYXJpYWJsZSIsCiAgICAgICJuZXR3b3JrQWNjZXNzIjogIlVzZXJUYXJnZXQiLAogICAgICAiY2FuY2VsbGF0aW9uIjogIkNvb3BlcmF0aXZlIgogICAgfSwKICAgIHsKICAgICAgImlkIjogIm5ldHdvcmsuYWRhcHRlcnMiLAogICAgICAibmFtZSI6ICJOZXR3b3JrIGFkYXB0ZXJzIiwKICAgICAgImRlc2NyaXB0aW9uIjogIkFkYXB0ZXIgc3RhdGUsIGludGVyZmFjZSBpZGVudGl0eSBhbmQgbGluayBzcGVlZC4iLAogICAgICAiY2F0ZWdvcnkiOiAiTmV0d29ya2luZyIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAiYWRhcHRlcnMiCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJDbWRsZXQiLAogICAgICAidGFyZ2V0SWQiOiAibmV0d29yay5hZGFwdGVycyIsCiAgICAgICJwYXJhbWV0ZXJzIjogW10sCiAgICAgICJyZXF1aXJlc0FkbWluIjogZmFsc2UsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbCiAgICAgICAgICAiY21kbGV0OkdldC1OZXRBZGFwdGVyIgogICAgICAgIF0KICAgICAgfSwKICAgICAgInJpc2siOiAiUmVhZE9ubHkiLAogICAgICAiY29uZmlybWF0aW9uIjogIk5vbmUiLAogICAgICAiY29uc2VxdWVuY2VzIjogIk5vIGludGVudGlvbmFsIGNvbmZpZ3VyYXRpb24gY2hhbmdlLiBXaW5kb3dzIG1heSB3cml0ZSBvcGVyYXRpb25hbCBsb2dzLiIsCiAgICAgICJjb3N0IjogIlF1aWNrIiwKICAgICAgIm5ldHdvcmtBY2Nlc3MiOiAiTm9uZSIsCiAgICAgICJjYW5jZWxsYXRpb24iOiAiQ29vcGVyYXRpdmUiCiAgICB9LAogICAgewogICAgICAiaWQiOiAibmV0d29yay5mbHVzaC1kbnMiLAogICAgICAibmFtZSI6ICJGbHVzaCBETlMgY2FjaGUiLAogICAgICAiZGVzY3JpcHRpb24iOiAiQ2xlYXIgdGhlIGxvY2FsIEROUyByZXNvbHZlciBjYWNoZS4iLAogICAgICAiY2F0ZWdvcnkiOiAiTmV0d29ya2luZyIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAiZmx1c2gtZG5zIgogICAgICBdLAogICAgICAic291cmNlS2luZCI6ICJCdWlsdEluIiwKICAgICAgImV4ZWN1dGlvblR5cGUiOiAiTmF0aXZlIiwKICAgICAgInRhcmdldElkIjogIm5ldHdvcmsuZmx1c2gtZG5zIiwKICAgICAgInBhcmFtZXRlcnMiOiBbXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiB0cnVlLAogICAgICAiY29tcGF0aWJpbGl0eSI6IHsKICAgICAgICAibWluaW11bUJ1aWxkIjogMTAyNDAsCiAgICAgICAgImFyY2hpdGVjdHVyZXMiOiBbCiAgICAgICAgICAieDg2IiwKICAgICAgICAgICJ4NjQiCiAgICAgICAgXSwKICAgICAgICAiY2FwYWJpbGl0aWVzIjogWwogICAgICAgICAgImV4ZTppcGNvbmZpZy5leGUiCiAgICAgICAgXQogICAgICB9LAogICAgICAicmlzayI6ICJTeXN0ZW1Nb2RpZmljYXRpb24iLAogICAgICAiY29uZmlybWF0aW9uIjogIkNvbmZpcm0iLAogICAgICAiY29uc2VxdWVuY2VzIjogIkNsZWFyIHRoZSBsb2NhbCBETlMgcmVzb2x2ZXIgY2FjaGUuIiwKICAgICAgImNvc3QiOiAiUXVpY2siLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJVbmF2YWlsYWJsZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJoYXJkd2FyZS5jcHUiLAogICAgICAibmFtZSI6ICJDUFUgaW5mb3JtYXRpb24iLAogICAgICAiZGVzY3JpcHRpb24iOiAiUHJvY2Vzc29yIG1vZGVsLCBjb3JlcyBhbmQgbG9naWNhbCBwcm9jZXNzb3JzLiIsCiAgICAgICJjYXRlZ29yeSI6ICJIYXJkd2FyZSBEaWFnbm9zdGljcyIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAiY3B1IgogICAgICBdLAogICAgICAic291cmNlS2luZCI6ICJCdWlsdEluIiwKICAgICAgImV4ZWN1dGlvblR5cGUiOiAiRnVuY3Rpb24iLAogICAgICAidGFyZ2V0SWQiOiAiaGFyZHdhcmUuY3B1IiwKICAgICAgInBhcmFtZXRlcnMiOiBbXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiBmYWxzZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFtdCiAgICAgIH0sCiAgICAgICJyaXNrIjogIlJlYWRPbmx5IiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJOb25lIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJObyBpbnRlbnRpb25hbCBjb25maWd1cmF0aW9uIGNoYW5nZS4gV2luZG93cyBtYXkgd3JpdGUgb3BlcmF0aW9uYWwgbG9ncy4iLAogICAgICAiY29zdCI6ICJRdWljayIsCiAgICAgICJuZXR3b3JrQWNjZXNzIjogIk5vbmUiLAogICAgICAiY2FuY2VsbGF0aW9uIjogIkNvb3BlcmF0aXZlIgogICAgfSwKICAgIHsKICAgICAgImlkIjogImhhcmR3YXJlLm1lbW9yeSIsCiAgICAgICJuYW1lIjogIlJBTSBpbmZvcm1hdGlvbiIsCiAgICAgICJkZXNjcmlwdGlvbiI6ICJQaHlzaWNhbCBtZW1vcnkgbW9kdWxlIGNhcGFjaXR5LCBzcGVlZCBhbmQgbG9jYXRpb24uIiwKICAgICAgImNhdGVnb3J5IjogIkhhcmR3YXJlIERpYWdub3N0aWNzIiwKICAgICAgImtleXdvcmRzIjogWwogICAgICAgICJtZW1vcnkiCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJGdW5jdGlvbiIsCiAgICAgICJ0YXJnZXRJZCI6ICJoYXJkd2FyZS5tZW1vcnkiLAogICAgICAicGFyYW1ldGVycyI6IFtdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IGZhbHNlLAogICAgICAiY29tcGF0aWJpbGl0eSI6IHsKICAgICAgICAibWluaW11bUJ1aWxkIjogMTAyNDAsCiAgICAgICAgImFyY2hpdGVjdHVyZXMiOiBbCiAgICAgICAgICAieDg2IiwKICAgICAgICAgICJ4NjQiCiAgICAgICAgXSwKICAgICAgICAiY2FwYWJpbGl0aWVzIjogW10KICAgICAgfSwKICAgICAgInJpc2siOiAiUmVhZE9ubHkiLAogICAgICAiY29uZmlybWF0aW9uIjogIk5vbmUiLAogICAgICAiY29uc2VxdWVuY2VzIjogIk5vIGludGVudGlvbmFsIGNvbmZpZ3VyYXRpb24gY2hhbmdlLiBXaW5kb3dzIG1heSB3cml0ZSBvcGVyYXRpb25hbCBsb2dzLiIsCiAgICAgICJjb3N0IjogIlF1aWNrIiwKICAgICAgIm5ldHdvcmtBY2Nlc3MiOiAiTm9uZSIsCiAgICAgICJjYW5jZWxsYXRpb24iOiAiQ29vcGVyYXRpdmUiCiAgICB9LAogICAgewogICAgICAiaWQiOiAiaGFyZHdhcmUuZ3B1IiwKICAgICAgIm5hbWUiOiAiR1BVIGluZm9ybWF0aW9uIiwKICAgICAgImRlc2NyaXB0aW9uIjogIkRpc3BsYXkgYWRhcHRlcnMgYW5kIGRyaXZlciB2ZXJzaW9ucy4iLAogICAgICAiY2F0ZWdvcnkiOiAiSGFyZHdhcmUgRGlhZ25vc3RpY3MiLAogICAgICAia2V5d29yZHMiOiBbCiAgICAgICAgImdwdSIKICAgICAgXSwKICAgICAgInNvdXJjZUtpbmQiOiAiQnVpbHRJbiIsCiAgICAgICJleGVjdXRpb25UeXBlIjogIkZ1bmN0aW9uIiwKICAgICAgInRhcmdldElkIjogImhhcmR3YXJlLmdwdSIsCiAgICAgICJwYXJhbWV0ZXJzIjogW10sCiAgICAgICJyZXF1aXJlc0FkbWluIjogZmFsc2UsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbXQogICAgICB9LAogICAgICAicmlzayI6ICJSZWFkT25seSIsCiAgICAgICJjb25maXJtYXRpb24iOiAiTm9uZSIsCiAgICAgICJjb25zZXF1ZW5jZXMiOiAiTm8gaW50ZW50aW9uYWwgY29uZmlndXJhdGlvbiBjaGFuZ2UuIFdpbmRvd3MgbWF5IHdyaXRlIG9wZXJhdGlvbmFsIGxvZ3MuIiwKICAgICAgImNvc3QiOiAiUXVpY2siLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJDb29wZXJhdGl2ZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJoYXJkd2FyZS5ib2FyZCIsCiAgICAgICJuYW1lIjogIk1vdGhlcmJvYXJkIGluZm9ybWF0aW9uIiwKICAgICAgImRlc2NyaXB0aW9uIjogIkJvYXJkIG1hbnVmYWN0dXJlciBhbmQgbW9kZWwuIiwKICAgICAgImNhdGVnb3J5IjogIkhhcmR3YXJlIERpYWdub3N0aWNzIiwKICAgICAgImtleXdvcmRzIjogWwogICAgICAgICJib2FyZCIKICAgICAgXSwKICAgICAgInNvdXJjZUtpbmQiOiAiQnVpbHRJbiIsCiAgICAgICJleGVjdXRpb25UeXBlIjogIkZ1bmN0aW9uIiwKICAgICAgInRhcmdldElkIjogImhhcmR3YXJlLmJvYXJkIiwKICAgICAgInBhcmFtZXRlcnMiOiBbXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiBmYWxzZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFtdCiAgICAgIH0sCiAgICAgICJyaXNrIjogIlJlYWRPbmx5IiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJOb25lIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJObyBpbnRlbnRpb25hbCBjb25maWd1cmF0aW9uIGNoYW5nZS4gV2luZG93cyBtYXkgd3JpdGUgb3BlcmF0aW9uYWwgbG9ncy4iLAogICAgICAiY29zdCI6ICJRdWljayIsCiAgICAgICJuZXR3b3JrQWNjZXNzIjogIk5vbmUiLAogICAgICAiY2FuY2VsbGF0aW9uIjogIkNvb3BlcmF0aXZlIgogICAgfSwKICAgIHsKICAgICAgImlkIjogImhhcmR3YXJlLmJpb3MiLAogICAgICAibmFtZSI6ICJCSU9TIGluZm9ybWF0aW9uIiwKICAgICAgImRlc2NyaXB0aW9uIjogIkZpcm13YXJlIG1hbnVmYWN0dXJlciwgdmVyc2lvbiBhbmQgcmVsZWFzZSBkYXRlLiIsCiAgICAgICJjYXRlZ29yeSI6ICJIYXJkd2FyZSBEaWFnbm9zdGljcyIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAiYmlvcyIKICAgICAgXSwKICAgICAgInNvdXJjZUtpbmQiOiAiQnVpbHRJbiIsCiAgICAgICJleGVjdXRpb25UeXBlIjogIkZ1bmN0aW9uIiwKICAgICAgInRhcmdldElkIjogImhhcmR3YXJlLmJpb3MiLAogICAgICAicGFyYW1ldGVycyI6IFtdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IGZhbHNlLAogICAgICAiY29tcGF0aWJpbGl0eSI6IHsKICAgICAgICAibWluaW11bUJ1aWxkIjogMTAyNDAsCiAgICAgICAgImFyY2hpdGVjdHVyZXMiOiBbCiAgICAgICAgICAieDg2IiwKICAgICAgICAgICJ4NjQiCiAgICAgICAgXSwKICAgICAgICAiY2FwYWJpbGl0aWVzIjogW10KICAgICAgfSwKICAgICAgInJpc2siOiAiUmVhZE9ubHkiLAogICAgICAiY29uZmlybWF0aW9uIjogIk5vbmUiLAogICAgICAiY29uc2VxdWVuY2VzIjogIk5vIGludGVudGlvbmFsIGNvbmZpZ3VyYXRpb24gY2hhbmdlLiBXaW5kb3dzIG1heSB3cml0ZSBvcGVyYXRpb25hbCBsb2dzLiIsCiAgICAgICJjb3N0IjogIlF1aWNrIiwKICAgICAgIm5ldHdvcmtBY2Nlc3MiOiAiTm9uZSIsCiAgICAgICJjYW5jZWxsYXRpb24iOiAiQ29vcGVyYXRpdmUiCiAgICB9LAogICAgewogICAgICAiaWQiOiAiaGFyZHdhcmUuZGlza3MiLAogICAgICAibmFtZSI6ICJQaHlzaWNhbCBkaXNrIGluZm9ybWF0aW9uIiwKICAgICAgImRlc2NyaXB0aW9uIjogIkRldmljZSBtb2RlbCwgaW50ZXJmYWNlIGFuZCBjYXBhY2l0eS4iLAogICAgICAiY2F0ZWdvcnkiOiAiSGFyZHdhcmUgRGlhZ25vc3RpY3MiLAogICAgICAia2V5d29yZHMiOiBbCiAgICAgICAgImRpc2tzIgogICAgICBdLAogICAgICAic291cmNlS2luZCI6ICJCdWlsdEluIiwKICAgICAgImV4ZWN1dGlvblR5cGUiOiAiRnVuY3Rpb24iLAogICAgICAidGFyZ2V0SWQiOiAiaGFyZHdhcmUuZGlza3MiLAogICAgICAicGFyYW1ldGVycyI6IFtdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IGZhbHNlLAogICAgICAiY29tcGF0aWJpbGl0eSI6IHsKICAgICAgICAibWluaW11bUJ1aWxkIjogMTAyNDAsCiAgICAgICAgImFyY2hpdGVjdHVyZXMiOiBbCiAgICAgICAgICAieDg2IiwKICAgICAgICAgICJ4NjQiCiAgICAgICAgXSwKICAgICAgICAiY2FwYWJpbGl0aWVzIjogW10KICAgICAgfSwKICAgICAgInJpc2siOiAiUmVhZE9ubHkiLAogICAgICAiY29uZmlybWF0aW9uIjogIk5vbmUiLAogICAgICAiY29uc2VxdWVuY2VzIjogIk5vIGludGVudGlvbmFsIGNvbmZpZ3VyYXRpb24gY2hhbmdlLiBXaW5kb3dzIG1heSB3cml0ZSBvcGVyYXRpb25hbCBsb2dzLiIsCiAgICAgICJjb3N0IjogIlF1aWNrIiwKICAgICAgIm5ldHdvcmtBY2Nlc3MiOiAiTm9uZSIsCiAgICAgICJjYW5jZWxsYXRpb24iOiAiQ29vcGVyYXRpdmUiCiAgICB9LAogICAgewogICAgICAiaWQiOiAiaGFyZHdhcmUuZGlzay1oZWFsdGgiLAogICAgICAibmFtZSI6ICJTdG9yYWdlIGhlYWx0aCBpbmRpY2F0b3JzIiwKICAgICAgImRlc2NyaXB0aW9uIjogIkRyaXZlci1wcm92aWRlZCBzdGF0dXMgYW5kIHJlbGlhYmlsaXR5IGNvdW50ZXJzOyBtaXNzaW5nIHZhbHVlcyBkbyBub3QgaW1wbHkgaGVhbHRoLiIsCiAgICAgICJjYXRlZ29yeSI6ICJIYXJkd2FyZSBEaWFnbm9zdGljcyIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAiZGlzay1oZWFsdGgiCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJGdW5jdGlvbiIsCiAgICAgICJ0YXJnZXRJZCI6ICJoYXJkd2FyZS5kaXNrLWhlYWx0aCIsCiAgICAgICJwYXJhbWV0ZXJzIjogW10sCiAgICAgICJyZXF1aXJlc0FkbWluIjogdHJ1ZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFsKICAgICAgICAgICJjbWRsZXQ6R2V0LVBoeXNpY2FsRGlzayIKICAgICAgICBdCiAgICAgIH0sCiAgICAgICJyaXNrIjogIlJlYWRPbmx5IiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJOb25lIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJObyBpbnRlbnRpb25hbCBjb25maWd1cmF0aW9uIGNoYW5nZS4gV2luZG93cyBtYXkgd3JpdGUgb3BlcmF0aW9uYWwgbG9ncy4iLAogICAgICAiY29zdCI6ICJWYXJpYWJsZSIsCiAgICAgICJuZXR3b3JrQWNjZXNzIjogIk5vbmUiLAogICAgICAiY2FuY2VsbGF0aW9uIjogIkNvb3BlcmF0aXZlIgogICAgfSwKICAgIHsKICAgICAgImlkIjogInN0b3JhZ2UubGF5b3V0IiwKICAgICAgIm5hbWUiOiAiUGFydGl0aW9uIGxheW91dCIsCiAgICAgICJkZXNjcmlwdGlvbiI6ICJMb2NhbCBkaXNrIHBhcnRpdGlvbnMgYW5kIGRpc2sgYXNzb2NpYXRpb25zLiIsCiAgICAgICJjYXRlZ29yeSI6ICJTdG9yYWdlIE1hbmFnZW1lbnQiLAogICAgICAia2V5d29yZHMiOiBbCiAgICAgICAgImxheW91dCIKICAgICAgXSwKICAgICAgInNvdXJjZUtpbmQiOiAiQnVpbHRJbiIsCiAgICAgICJleGVjdXRpb25UeXBlIjogIkZ1bmN0aW9uIiwKICAgICAgInRhcmdldElkIjogInN0b3JhZ2UubGF5b3V0IiwKICAgICAgInBhcmFtZXRlcnMiOiBbXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiBmYWxzZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFtdCiAgICAgIH0sCiAgICAgICJyaXNrIjogIlJlYWRPbmx5IiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJOb25lIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJObyBpbnRlbnRpb25hbCBjb25maWd1cmF0aW9uIGNoYW5nZS4gV2luZG93cyBtYXkgd3JpdGUgb3BlcmF0aW9uYWwgbG9ncy4iLAogICAgICAiY29zdCI6ICJRdWljayIsCiAgICAgICJuZXR3b3JrQWNjZXNzIjogIk5vbmUiLAogICAgICAiY2FuY2VsbGF0aW9uIjogIkNvb3BlcmF0aXZlIgogICAgfSwKICAgIHsKICAgICAgImlkIjogInN0b3JhZ2Uudm9sdW1lcyIsCiAgICAgICJuYW1lIjogIlZvbHVtZSBpbmZvcm1hdGlvbiIsCiAgICAgICJkZXNjcmlwdGlvbiI6ICJEcml2ZSBsYWJlbHMsIGZpbGVzeXN0ZW0gdHlwZXMgYW5kIGRyaXZlIHR5cGVzLiIsCiAgICAgICJjYXRlZ29yeSI6ICJTdG9yYWdlIE1hbmFnZW1lbnQiLAogICAgICAia2V5d29yZHMiOiBbCiAgICAgICAgInZvbHVtZXMiCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJGdW5jdGlvbiIsCiAgICAgICJ0YXJnZXRJZCI6ICJzdG9yYWdlLnZvbHVtZXMiLAogICAgICAicGFyYW1ldGVycyI6IFtdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IGZhbHNlLAogICAgICAiY29tcGF0aWJpbGl0eSI6IHsKICAgICAgICAibWluaW11bUJ1aWxkIjogMTAyNDAsCiAgICAgICAgImFyY2hpdGVjdHVyZXMiOiBbCiAgICAgICAgICAieDg2IiwKICAgICAgICAgICJ4NjQiCiAgICAgICAgXSwKICAgICAgICAiY2FwYWJpbGl0aWVzIjogW10KICAgICAgfSwKICAgICAgInJpc2siOiAiUmVhZE9ubHkiLAogICAgICAiY29uZmlybWF0aW9uIjogIk5vbmUiLAogICAgICAiY29uc2VxdWVuY2VzIjogIk5vIGludGVudGlvbmFsIGNvbmZpZ3VyYXRpb24gY2hhbmdlLiBXaW5kb3dzIG1heSB3cml0ZSBvcGVyYXRpb25hbCBsb2dzLiIsCiAgICAgICJjb3N0IjogIlF1aWNrIiwKICAgICAgIm5ldHdvcmtBY2Nlc3MiOiAiTm9uZSIsCiAgICAgICJjYW5jZWxsYXRpb24iOiAiQ29vcGVyYXRpdmUiCiAgICB9LAogICAgewogICAgICAiaWQiOiAic3RvcmFnZS5zcGFjZSIsCiAgICAgICJuYW1lIjogIkF2YWlsYWJsZSBkaXNrIHNwYWNlIiwKICAgICAgImRlc2NyaXB0aW9uIjogIkZpeGVkIGxvY2FsIHZvbHVtZSBzaXplIGFuZCBmcmVlIHNwYWNlLiIsCiAgICAgICJjYXRlZ29yeSI6ICJTdG9yYWdlIE1hbmFnZW1lbnQiLAogICAgICAia2V5d29yZHMiOiBbCiAgICAgICAgInNwYWNlIgogICAgICBdLAogICAgICAic291cmNlS2luZCI6ICJCdWlsdEluIiwKICAgICAgImV4ZWN1dGlvblR5cGUiOiAiRnVuY3Rpb24iLAogICAgICAidGFyZ2V0SWQiOiAic3RvcmFnZS5zcGFjZSIsCiAgICAgICJwYXJhbWV0ZXJzIjogW10sCiAgICAgICJyZXF1aXJlc0FkbWluIjogZmFsc2UsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbXQogICAgICB9LAogICAgICAicmlzayI6ICJSZWFkT25seSIsCiAgICAgICJjb25maXJtYXRpb24iOiAiTm9uZSIsCiAgICAgICJjb25zZXF1ZW5jZXMiOiAiTm8gaW50ZW50aW9uYWwgY29uZmlndXJhdGlvbiBjaGFuZ2UuIFdpbmRvd3MgbWF5IHdyaXRlIG9wZXJhdGlvbmFsIGxvZ3MuIiwKICAgICAgImNvc3QiOiAiUXVpY2siLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJDb29wZXJhdGl2ZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJzdG9yYWdlLmhhc2giLAogICAgICAibmFtZSI6ICJWZXJpZnkgZmlsZSBjaGVja3N1bSIsCiAgICAgICJkZXNjcmlwdGlvbiI6ICJDb21wdXRlIFNIQS0yNTYgYW5kIG9wdGlvbmFsbHkgY29tcGFyZSBhbiBleHBlY3RlZCBjaGVja3N1bS4iLAogICAgICAiY2F0ZWdvcnkiOiAiU3RvcmFnZSBNYW5hZ2VtZW50IiwKICAgICAgImtleXdvcmRzIjogWwogICAgICAgICJoYXNoIgogICAgICBdLAogICAgICAic291cmNlS2luZCI6ICJCdWlsdEluIiwKICAgICAgImV4ZWN1dGlvblR5cGUiOiAiQ21kbGV0IiwKICAgICAgInRhcmdldElkIjogInN0b3JhZ2UuaGFzaCIsCiAgICAgICJwYXJhbWV0ZXJzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogInBhdGgiLAogICAgICAgICAgInR5cGUiOiAiTG9jYWxGaWxlIiwKICAgICAgICAgICJsYWJlbCI6ICJMb2NhbCBmaWxlIiwKICAgICAgICAgICJyZXF1aXJlZCI6IHRydWUsCiAgICAgICAgICAiZGVmYXVsdCI6IG51bGwsCiAgICAgICAgICAibWluaW11bSI6IG51bGwsCiAgICAgICAgICAibWF4aW11bSI6IG51bGwsCiAgICAgICAgICAiYWxsb3dlZFZhbHVlcyI6IFtdCiAgICAgICAgfSwKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJleHBlY3RlZCIsCiAgICAgICAgICAidHlwZSI6ICJTaGEyNTYiLAogICAgICAgICAgImxhYmVsIjogIkV4cGVjdGVkIFNIQS0yNTYgKG9wdGlvbmFsKSIsCiAgICAgICAgICAicmVxdWlyZWQiOiBmYWxzZSwKICAgICAgICAgICJkZWZhdWx0IjogbnVsbCwKICAgICAgICAgICJtaW5pbXVtIjogbnVsbCwKICAgICAgICAgICJtYXhpbXVtIjogbnVsbCwKICAgICAgICAgICJhbGxvd2VkVmFsdWVzIjogW10KICAgICAgICB9CiAgICAgIF0sCiAgICAgICJyZXF1aXJlc0FkbWluIjogZmFsc2UsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbCiAgICAgICAgICAiY21kbGV0OkdldC1GaWxlSGFzaCIKICAgICAgICBdCiAgICAgIH0sCiAgICAgICJyaXNrIjogIlJlYWRPbmx5IiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJOb25lIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJObyBpbnRlbnRpb25hbCBjb25maWd1cmF0aW9uIGNoYW5nZS4gV2luZG93cyBtYXkgd3JpdGUgb3BlcmF0aW9uYWwgbG9ncy4iLAogICAgICAiY29zdCI6ICJWYXJpYWJsZSIsCiAgICAgICJuZXR3b3JrQWNjZXNzIjogIk5vbmUiLAogICAgICAiY2FuY2VsbGF0aW9uIjogIkNvb3BlcmF0aXZlIgogICAgfSwKICAgIHsKICAgICAgImlkIjogInN0b3JhZ2UubWFuYWdlbWVudCIsCiAgICAgICJuYW1lIjogIkRpc2sgTWFuYWdlbWVudCIsCiAgICAgICJkZXNjcmlwdGlvbiI6ICJPcGVuIHRoZSBXaW5kb3dzIHBhcnRpdGlvbiBhbmQgdm9sdW1lIGFkbWluaXN0cmF0aW9uIHRvb2wuIiwKICAgICAgImNhdGVnb3J5IjogIlN0b3JhZ2UgTWFuYWdlbWVudCIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAibWFuYWdlbWVudCIKICAgICAgXSwKICAgICAgInNvdXJjZUtpbmQiOiAiQnVpbHRJbiIsCiAgICAgICJleGVjdXRpb25UeXBlIjogIk1tYyIsCiAgICAgICJ0YXJnZXRJZCI6ICJzdG9yYWdlLm1hbmFnZW1lbnQiLAogICAgICAicGFyYW1ldGVycyI6IFtdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IGZhbHNlLAogICAgICAiY29tcGF0aWJpbGl0eSI6IHsKICAgICAgICAibWluaW11bUJ1aWxkIjogMTAyNDAsCiAgICAgICAgImFyY2hpdGVjdHVyZXMiOiBbCiAgICAgICAgICAieDg2IiwKICAgICAgICAgICJ4NjQiCiAgICAgICAgXSwKICAgICAgICAiY2FwYWJpbGl0aWVzIjogWwogICAgICAgICAgImV4ZTptbWMuZXhlIgogICAgICAgIF0KICAgICAgfSwKICAgICAgInJpc2siOiAiSGlnaFJpc2siLAogICAgICAiY29uZmlybWF0aW9uIjogIlR5cGVDb21tYW5kSWQiLAogICAgICAiY29uc2VxdWVuY2VzIjogIk9wZW5zIGFuIGFkbWluaXN0cmF0aXZlIGludGVyZmFjZSB3aG9zZSBjb250cm9scyBjYW4gbW9kaWZ5IFdpbmRvd3MuIEl0cyBzdWJzZXF1ZW50IGFjdGlvbnMgYXJlIG91dHNpZGUgdGhlIHRvb2xraXQuIiwKICAgICAgImNvc3QiOiAiUXVpY2siLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJVbmF2YWlsYWJsZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJwcm9jZXNzZXMubGlzdCIsCiAgICAgICJuYW1lIjogIlJ1bm5pbmcgcHJvY2Vzc2VzIiwKICAgICAgImRlc2NyaXB0aW9uIjogIlNuYXBzaG90IG9mIFBJRCwgY3VtdWxhdGl2ZSBDUFUgdGltZSBhbmQgd29ya2luZyBzZXQsIG5vdCBsaXZlIENQVSBwZXJjZW50YWdlLiIsCiAgICAgICJjYXRlZ29yeSI6ICJQcm9jZXNzZXMgYW5kIFNlcnZpY2VzIiwKICAgICAgImtleXdvcmRzIjogWwogICAgICAgICJsaXN0IgogICAgICBdLAogICAgICAic291cmNlS2luZCI6ICJCdWlsdEluIiwKICAgICAgImV4ZWN1dGlvblR5cGUiOiAiQ21kbGV0IiwKICAgICAgInRhcmdldElkIjogInByb2Nlc3Nlcy5saXN0IiwKICAgICAgInBhcmFtZXRlcnMiOiBbXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiBmYWxzZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFsKICAgICAgICAgICJjbWRsZXQ6R2V0LVByb2Nlc3MiCiAgICAgICAgXQogICAgICB9LAogICAgICAicmlzayI6ICJSZWFkT25seSIsCiAgICAgICJjb25maXJtYXRpb24iOiAiTm9uZSIsCiAgICAgICJjb25zZXF1ZW5jZXMiOiAiTm8gaW50ZW50aW9uYWwgY29uZmlndXJhdGlvbiBjaGFuZ2UuIFdpbmRvd3MgbWF5IHdyaXRlIG9wZXJhdGlvbmFsIGxvZ3MuIiwKICAgICAgImNvc3QiOiAiUXVpY2siLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJDb29wZXJhdGl2ZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJwcm9jZXNzZXMucmVzb3VyY2UtbW9uaXRvciIsCiAgICAgICJuYW1lIjogIlJlc291cmNlIE1vbml0b3IiLAogICAgICAiZGVzY3JpcHRpb24iOiAiT3BlbiBXaW5kb3dzIFJlc291cmNlIE1vbml0b3I7IGl0cyBjb250cm9scyBjYW4gbW9kaWZ5IHJ1bm5pbmcgcHJvY2Vzc2VzLiIsCiAgICAgICJjYXRlZ29yeSI6ICJQcm9jZXNzZXMgYW5kIFNlcnZpY2VzIiwKICAgICAgImtleXdvcmRzIjogWwogICAgICAgICJyZXNvdXJjZS1tb25pdG9yIgogICAgICBdLAogICAgICAic291cmNlS2luZCI6ICJCdWlsdEluIiwKICAgICAgImV4ZWN1dGlvblR5cGUiOiAiRXhlY3V0YWJsZSIsCiAgICAgICJ0YXJnZXRJZCI6ICJwcm9jZXNzZXMucmVzb3VyY2UtbW9uaXRvciIsCiAgICAgICJwYXJhbWV0ZXJzIjogW10sCiAgICAgICJyZXF1aXJlc0FkbWluIjogZmFsc2UsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbCiAgICAgICAgICAiZXhlOnJlc21vbi5leGUiCiAgICAgICAgXQogICAgICB9LAogICAgICAicmlzayI6ICJTeXN0ZW1Nb2RpZmljYXRpb24iLAogICAgICAiY29uZmlybWF0aW9uIjogIkNvbmZpcm0iLAogICAgICAiY29uc2VxdWVuY2VzIjogIk9wZW5zIGFuIGFkbWluaXN0cmF0aXZlIGludGVyZmFjZSB3aG9zZSBjb250cm9scyBjYW4gbW9kaWZ5IFdpbmRvd3MuIEl0cyBzdWJzZXF1ZW50IGFjdGlvbnMgYXJlIG91dHNpZGUgdGhlIHRvb2xraXQuIiwKICAgICAgImNvc3QiOiAiUXVpY2siLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJVbmF2YWlsYWJsZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJwcm9jZXNzZXMudGFzay1tYW5hZ2VyIiwKICAgICAgIm5hbWUiOiAiVGFzayBNYW5hZ2VyIiwKICAgICAgImRlc2NyaXB0aW9uIjogIk9wZW4gVGFzayBNYW5hZ2VyOyBpdHMgY29udHJvbHMgY2FuIHRlcm1pbmF0ZSBwcm9ncmFtcy4iLAogICAgICAiY2F0ZWdvcnkiOiAiUHJvY2Vzc2VzIGFuZCBTZXJ2aWNlcyIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAidGFzay1tYW5hZ2VyIgogICAgICBdLAogICAgICAic291cmNlS2luZCI6ICJCdWlsdEluIiwKICAgICAgImV4ZWN1dGlvblR5cGUiOiAiRXhlY3V0YWJsZSIsCiAgICAgICJ0YXJnZXRJZCI6ICJwcm9jZXNzZXMudGFzay1tYW5hZ2VyIiwKICAgICAgInBhcmFtZXRlcnMiOiBbXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiBmYWxzZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFsKICAgICAgICAgICJleGU6dGFza21nci5leGUiCiAgICAgICAgXQogICAgICB9LAogICAgICAicmlzayI6ICJTeXN0ZW1Nb2RpZmljYXRpb24iLAogICAgICAiY29uZmlybWF0aW9uIjogIkNvbmZpcm0iLAogICAgICAiY29uc2VxdWVuY2VzIjogIk9wZW5zIGFuIGFkbWluaXN0cmF0aXZlIGludGVyZmFjZSB3aG9zZSBjb250cm9scyBjYW4gbW9kaWZ5IFdpbmRvd3MuIEl0cyBzdWJzZXF1ZW50IGFjdGlvbnMgYXJlIG91dHNpZGUgdGhlIHRvb2xraXQuIiwKICAgICAgImNvc3QiOiAiUXVpY2siLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJVbmF2YWlsYWJsZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJwcm9jZXNzZXMuc2VydmljZXMiLAogICAgICAibmFtZSI6ICJXaW5kb3dzIHNlcnZpY2VzIiwKICAgICAgImRlc2NyaXB0aW9uIjogIkxpc3Qgc2VydmljZSBzdGF0dXMgd2l0aG91dCBjaGFuZ2luZyBzZXJ2aWNlcy4iLAogICAgICAiY2F0ZWdvcnkiOiAiUHJvY2Vzc2VzIGFuZCBTZXJ2aWNlcyIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAic2VydmljZXMiCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJDbWRsZXQiLAogICAgICAidGFyZ2V0SWQiOiAicHJvY2Vzc2VzLnNlcnZpY2VzIiwKICAgICAgInBhcmFtZXRlcnMiOiBbXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiBmYWxzZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFsKICAgICAgICAgICJjbWRsZXQ6R2V0LVNlcnZpY2UiCiAgICAgICAgXQogICAgICB9LAogICAgICAicmlzayI6ICJSZWFkT25seSIsCiAgICAgICJjb25maXJtYXRpb24iOiAiTm9uZSIsCiAgICAgICJjb25zZXF1ZW5jZXMiOiAiTm8gaW50ZW50aW9uYWwgY29uZmlndXJhdGlvbiBjaGFuZ2UuIFdpbmRvd3MgbWF5IHdyaXRlIG9wZXJhdGlvbmFsIGxvZ3MuIiwKICAgICAgImNvc3QiOiAiUXVpY2siLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJDb29wZXJhdGl2ZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJwcm9jZXNzZXMuc3RhcnR1cCIsCiAgICAgICJuYW1lIjogIlN0YXJ0dXAgcHJvZ3JhbXMiLAogICAgICAiZGVzY3JpcHRpb24iOiAiU3RhcnR1cCBjb21tYW5kIHJlZ2lzdHJhdGlvbnMgcmVwb3J0ZWQgYnkgV2luZG93cy4iLAogICAgICAiY2F0ZWdvcnkiOiAiUHJvY2Vzc2VzIGFuZCBTZXJ2aWNlcyIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAic3RhcnR1cCIKICAgICAgXSwKICAgICAgInNvdXJjZUtpbmQiOiAiQnVpbHRJbiIsCiAgICAgICJleGVjdXRpb25UeXBlIjogIkZ1bmN0aW9uIiwKICAgICAgInRhcmdldElkIjogInByb2Nlc3Nlcy5zdGFydHVwIiwKICAgICAgInBhcmFtZXRlcnMiOiBbXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiBmYWxzZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFtdCiAgICAgIH0sCiAgICAgICJyaXNrIjogIlJlYWRPbmx5IiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJOb25lIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJObyBpbnRlbnRpb25hbCBjb25maWd1cmF0aW9uIGNoYW5nZS4gV2luZG93cyBtYXkgd3JpdGUgb3BlcmF0aW9uYWwgbG9ncy4iLAogICAgICAiY29zdCI6ICJRdWljayIsCiAgICAgICJuZXR3b3JrQWNjZXNzIjogIk5vbmUiLAogICAgICAiY2FuY2VsbGF0aW9uIjogIkNvb3BlcmF0aXZlIgogICAgfSwKICAgIHsKICAgICAgImlkIjogInByb2Nlc3Nlcy5ldmVudHMiLAogICAgICAibmFtZSI6ICJFdmVudCBWaWV3ZXIiLAogICAgICAiZGVzY3JpcHRpb24iOiAiT3BlbiBXaW5kb3dzIGV2ZW50IGFkbWluaXN0cmF0aW9uOyBsb2dzIGNhbiBiZSBjbGVhcmVkIGZyb20gdGhpcyB0b29sLiIsCiAgICAgICJjYXRlZ29yeSI6ICJQcm9jZXNzZXMgYW5kIFNlcnZpY2VzIiwKICAgICAgImtleXdvcmRzIjogWwogICAgICAgICJldmVudHMiCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJNbWMiLAogICAgICAidGFyZ2V0SWQiOiAicHJvY2Vzc2VzLmV2ZW50cyIsCiAgICAgICJwYXJhbWV0ZXJzIjogW10sCiAgICAgICJyZXF1aXJlc0FkbWluIjogZmFsc2UsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbCiAgICAgICAgICAiZXhlOm1tYy5leGUiCiAgICAgICAgXQogICAgICB9LAogICAgICAicmlzayI6ICJTeXN0ZW1Nb2RpZmljYXRpb24iLAogICAgICAiY29uZmlybWF0aW9uIjogIkNvbmZpcm0iLAogICAgICAiY29uc2VxdWVuY2VzIjogIk9wZW5zIGFuIGFkbWluaXN0cmF0aXZlIGludGVyZmFjZSB3aG9zZSBjb250cm9scyBjYW4gbW9kaWZ5IFdpbmRvd3MuIEl0cyBzdWJzZXF1ZW50IGFjdGlvbnMgYXJlIG91dHNpZGUgdGhlIHRvb2xraXQuIiwKICAgICAgImNvc3QiOiAiUXVpY2siLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJVbmF2YWlsYWJsZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJyZXBhaXIuc2ZjLXZlcmlmeSIsCiAgICAgICJuYW1lIjogIlNGQyB2ZXJpZmljYXRpb24iLAogICAgICAiZGVzY3JpcHRpb24iOiAiVmVyaWZ5IHByb3RlY3RlZCBzeXN0ZW0gZmlsZXMgd2l0aG91dCByZXBhaXJpbmcgdGhlbS4iLAogICAgICAiY2F0ZWdvcnkiOiAiV2luZG93cyBSZXBhaXIgYW5kIE1haW50ZW5hbmNlIiwKICAgICAgImtleXdvcmRzIjogWwogICAgICAgICJzZmMtdmVyaWZ5IgogICAgICBdLAogICAgICAic291cmNlS2luZCI6ICJCdWlsdEluIiwKICAgICAgImV4ZWN1dGlvblR5cGUiOiAiTmF0aXZlIiwKICAgICAgInRhcmdldElkIjogInJlcGFpci5zZmMtdmVyaWZ5IiwKICAgICAgInBhcmFtZXRlcnMiOiBbXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiB0cnVlLAogICAgICAiY29tcGF0aWJpbGl0eSI6IHsKICAgICAgICAibWluaW11bUJ1aWxkIjogMTAyNDAsCiAgICAgICAgImFyY2hpdGVjdHVyZXMiOiBbCiAgICAgICAgICAieDg2IiwKICAgICAgICAgICJ4NjQiCiAgICAgICAgXSwKICAgICAgICAiY2FwYWJpbGl0aWVzIjogWwogICAgICAgICAgImV4ZTpzZmMuZXhlIgogICAgICAgIF0KICAgICAgfSwKICAgICAgInJpc2siOiAiUmVhZE9ubHkiLAogICAgICAiY29uZmlybWF0aW9uIjogIk5vbmUiLAogICAgICAiY29uc2VxdWVuY2VzIjogIk5vIGludGVudGlvbmFsIGNvbmZpZ3VyYXRpb24gY2hhbmdlLiBXaW5kb3dzIG1heSB3cml0ZSBvcGVyYXRpb25hbCBsb2dzLiIsCiAgICAgICJjb3N0IjogIkhlYXZ5IiwKICAgICAgIm5ldHdvcmtBY2Nlc3MiOiAiTm9uZSIsCiAgICAgICJjYW5jZWxsYXRpb24iOiAiVW5hdmFpbGFibGUiCiAgICB9LAogICAgewogICAgICAiaWQiOiAicmVwYWlyLnNmYyIsCiAgICAgICJuYW1lIjogIlNGQyByZXBhaXIiLAogICAgICAiZGVzY3JpcHRpb24iOiAiU2NhbiBhbmQgcmVwYWlyIHByb3RlY3RlZCBzeXN0ZW0gZmlsZXMuIiwKICAgICAgImNhdGVnb3J5IjogIldpbmRvd3MgUmVwYWlyIGFuZCBNYWludGVuYW5jZSIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAic2ZjIgogICAgICBdLAogICAgICAic291cmNlS2luZCI6ICJCdWlsdEluIiwKICAgICAgImV4ZWN1dGlvblR5cGUiOiAiTmF0aXZlIiwKICAgICAgInRhcmdldElkIjogInJlcGFpci5zZmMiLAogICAgICAicGFyYW1ldGVycyI6IFtdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IHRydWUsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbCiAgICAgICAgICAiZXhlOnNmYy5leGUiCiAgICAgICAgXQogICAgICB9LAogICAgICAicmlzayI6ICJTeXN0ZW1Nb2RpZmljYXRpb24iLAogICAgICAiY29uZmlybWF0aW9uIjogIkNvbmZpcm0iLAogICAgICAiY29uc2VxdWVuY2VzIjogIlNjYW4gYW5kIHJlcGFpciBwcm90ZWN0ZWQgc3lzdGVtIGZpbGVzLiIsCiAgICAgICJjb3N0IjogIkhlYXZ5IiwKICAgICAgIm5ldHdvcmtBY2Nlc3MiOiAiTm9uZSIsCiAgICAgICJjYW5jZWxsYXRpb24iOiAiVW5hdmFpbGFibGUiCiAgICB9LAogICAgewogICAgICAiaWQiOiAicmVwYWlyLmRpc20tY2hlY2siLAogICAgICAibmFtZSI6ICJESVNNIHF1aWNrIGhlYWx0aCBjaGVjayIsCiAgICAgICJkZXNjcmlwdGlvbiI6ICJSZWFkIHJlY29yZGVkIGNvbXBvbmVudC1zdG9yZSBoZWFsdGg7IHNlcnZpY2luZyBjYW4gdXBkYXRlIG1ldGFkYXRhLiIsCiAgICAgICJjYXRlZ29yeSI6ICJXaW5kb3dzIFJlcGFpciBhbmQgTWFpbnRlbmFuY2UiLAogICAgICAia2V5d29yZHMiOiBbCiAgICAgICAgImRpc20tY2hlY2siCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJOYXRpdmUiLAogICAgICAidGFyZ2V0SWQiOiAicmVwYWlyLmRpc20tY2hlY2siLAogICAgICAicGFyYW1ldGVycyI6IFtdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IHRydWUsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbCiAgICAgICAgICAiZXhlOmRpc20uZXhlIgogICAgICAgIF0KICAgICAgfSwKICAgICAgInJpc2siOiAiU3lzdGVtTW9kaWZpY2F0aW9uIiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJDb25maXJtIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJSZWFkIHJlY29yZGVkIGNvbXBvbmVudC1zdG9yZSBoZWFsdGg7IHNlcnZpY2luZyBjYW4gdXBkYXRlIG1ldGFkYXRhLiIsCiAgICAgICJjb3N0IjogIlF1aWNrIiwKICAgICAgIm5ldHdvcmtBY2Nlc3MiOiAiTm9uZSIsCiAgICAgICJjYW5jZWxsYXRpb24iOiAiVW5hdmFpbGFibGUiCiAgICB9LAogICAgewogICAgICAiaWQiOiAicmVwYWlyLmRpc20tc2NhbiIsCiAgICAgICJuYW1lIjogIkRJU00gaGVhbHRoIHNjYW4iLAogICAgICAiZGVzY3JpcHRpb24iOiAiU2NhbiB0aGUgY29tcG9uZW50IHN0b3JlOyBzZXJ2aWNpbmcgY2FuIHVwZGF0ZSBtZXRhZGF0YS4iLAogICAgICAiY2F0ZWdvcnkiOiAiV2luZG93cyBSZXBhaXIgYW5kIE1haW50ZW5hbmNlIiwKICAgICAgImtleXdvcmRzIjogWwogICAgICAgICJkaXNtLXNjYW4iCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJOYXRpdmUiLAogICAgICAidGFyZ2V0SWQiOiAicmVwYWlyLmRpc20tc2NhbiIsCiAgICAgICJwYXJhbWV0ZXJzIjogW10sCiAgICAgICJyZXF1aXJlc0FkbWluIjogdHJ1ZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFsKICAgICAgICAgICJleGU6ZGlzbS5leGUiCiAgICAgICAgXQogICAgICB9LAogICAgICAicmlzayI6ICJTeXN0ZW1Nb2RpZmljYXRpb24iLAogICAgICAiY29uZmlybWF0aW9uIjogIkNvbmZpcm0iLAogICAgICAiY29uc2VxdWVuY2VzIjogIlNjYW4gdGhlIGNvbXBvbmVudCBzdG9yZTsgc2VydmljaW5nIGNhbiB1cGRhdGUgbWV0YWRhdGEuIiwKICAgICAgImNvc3QiOiAiSGVhdnkiLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJVbmF2YWlsYWJsZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJyZXBhaXIuZGlzbS1yZXN0b3JlIiwKICAgICAgIm5hbWUiOiAiRElTTSByZXBhaXIgKGxvY2FsIHNvdXJjZXMpIiwKICAgICAgImRlc2NyaXB0aW9uIjogIlJlcGFpciB0aGUgY29tcG9uZW50IHN0b3JlIHdpdGggV2luZG93cyBVcGRhdGUgZmFsbGJhY2sgZGlzYWJsZWQuIiwKICAgICAgImNhdGVnb3J5IjogIldpbmRvd3MgUmVwYWlyIGFuZCBNYWludGVuYW5jZSIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAiZGlzbS1yZXN0b3JlIgogICAgICBdLAogICAgICAic291cmNlS2luZCI6ICJCdWlsdEluIiwKICAgICAgImV4ZWN1dGlvblR5cGUiOiAiTmF0aXZlIiwKICAgICAgInRhcmdldElkIjogInJlcGFpci5kaXNtLXJlc3RvcmUiLAogICAgICAicGFyYW1ldGVycyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJzb3VyY2UiLAogICAgICAgICAgInR5cGUiOiAiTG9jYWxEaXJlY3RvcnkiLAogICAgICAgICAgImxhYmVsIjogIk1vdW50ZWQgV2luZG93cyByZXBhaXIgZGlyZWN0b3J5IChvcHRpb25hbCkiLAogICAgICAgICAgInJlcXVpcmVkIjogZmFsc2UsCiAgICAgICAgICAiZGVmYXVsdCI6IG51bGwsCiAgICAgICAgICAibWluaW11bSI6IG51bGwsCiAgICAgICAgICAibWF4aW11bSI6IG51bGwsCiAgICAgICAgICAiYWxsb3dlZFZhbHVlcyI6IFtdCiAgICAgICAgfQogICAgICBdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IHRydWUsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbCiAgICAgICAgICAiZXhlOmRpc20uZXhlIgogICAgICAgIF0KICAgICAgfSwKICAgICAgInJpc2siOiAiU3lzdGVtTW9kaWZpY2F0aW9uIiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJDb25maXJtIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJSZXBhaXIgdGhlIGNvbXBvbmVudCBzdG9yZSB3aXRoIFdpbmRvd3MgVXBkYXRlIGZhbGxiYWNrIGRpc2FibGVkLiIsCiAgICAgICJjb3N0IjogIkhlYXZ5IiwKICAgICAgIm5ldHdvcmtBY2Nlc3MiOiAiTm9uZSIsCiAgICAgICJjYW5jZWxsYXRpb24iOiAiVW5hdmFpbGFibGUiCiAgICB9LAogICAgewogICAgICAiaWQiOiAicmVwYWlyLmNoa2RzayIsCiAgICAgICJuYW1lIjogIlJlYWQtb25seSBmaWxlc3lzdGVtIGNoZWNrIiwKICAgICAgImRlc2NyaXB0aW9uIjogIkNIS0RTSyB3aXRob3V0IHJlcGFpciBzd2l0Y2hlcy4gQWN0aXZlLXZvbHVtZSByZXBvcnRzIG1heSBiZSBtaXNsZWFkaW5nLiIsCiAgICAgICJjYXRlZ29yeSI6ICJXaW5kb3dzIFJlcGFpciBhbmQgTWFpbnRlbmFuY2UiLAogICAgICAia2V5d29yZHMiOiBbCiAgICAgICAgImNoa2RzayIKICAgICAgXSwKICAgICAgInNvdXJjZUtpbmQiOiAiQnVpbHRJbiIsCiAgICAgICJleGVjdXRpb25UeXBlIjogIk5hdGl2ZSIsCiAgICAgICJ0YXJnZXRJZCI6ICJyZXBhaXIuY2hrZHNrIiwKICAgICAgInBhcmFtZXRlcnMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAiZHJpdmUiLAogICAgICAgICAgInR5cGUiOiAiRHJpdmVMZXR0ZXIiLAogICAgICAgICAgImxhYmVsIjogIkxvY2FsIGRyaXZlIGxldHRlciIsCiAgICAgICAgICAicmVxdWlyZWQiOiB0cnVlLAogICAgICAgICAgImRlZmF1bHQiOiAiQyIsCiAgICAgICAgICAibWluaW11bSI6IG51bGwsCiAgICAgICAgICAibWF4aW11bSI6IG51bGwsCiAgICAgICAgICAiYWxsb3dlZFZhbHVlcyI6IFtdCiAgICAgICAgfQogICAgICBdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IHRydWUsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbCiAgICAgICAgICAiZXhlOmNoa2Rzay5leGUiCiAgICAgICAgXQogICAgICB9LAogICAgICAicmlzayI6ICJSZWFkT25seSIsCiAgICAgICJjb25maXJtYXRpb24iOiAiTm9uZSIsCiAgICAgICJjb25zZXF1ZW5jZXMiOiAiTm8gaW50ZW50aW9uYWwgY29uZmlndXJhdGlvbiBjaGFuZ2UuIFdpbmRvd3MgbWF5IHdyaXRlIG9wZXJhdGlvbmFsIGxvZ3MuIiwKICAgICAgImNvc3QiOiAiSGVhdnkiLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJVbmF2YWlsYWJsZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJyZXBhaXIud2luc29jayIsCiAgICAgICJuYW1lIjogIlJlc2V0IFdpbnNvY2siLAogICAgICAiZGVzY3JpcHRpb24iOiAiUmVzZXQgc29ja2V0IHByb3ZpZGVyczsgbmV0d29ya2luZyBzb2Z0d2FyZSBtYXkgYmUgYWZmZWN0ZWQgYW5kIGEgcmVzdGFydCBtYXkgYmUgbmVlZGVkLiIsCiAgICAgICJjYXRlZ29yeSI6ICJXaW5kb3dzIFJlcGFpciBhbmQgTWFpbnRlbmFuY2UiLAogICAgICAia2V5d29yZHMiOiBbCiAgICAgICAgIndpbnNvY2siCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJOYXRpdmUiLAogICAgICAidGFyZ2V0SWQiOiAicmVwYWlyLndpbnNvY2siLAogICAgICAicGFyYW1ldGVycyI6IFtdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IHRydWUsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbCiAgICAgICAgICAiZXhlOm5ldHNoLmV4ZSIKICAgICAgICBdCiAgICAgIH0sCiAgICAgICJyaXNrIjogIkhpZ2hSaXNrIiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJUeXBlQ29tbWFuZElkIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJSZW1vdmVzIGN1c3RvbSBXaW5zb2NrIHByb3ZpZGVycy4gQ29ubmVjdGl2aXR5IGFuZCBuZXR3b3JraW5nIHNvZnR3YXJlIG1heSBiZSBhZmZlY3RlZC4gQSByZXN0YXJ0IG1heSBiZSBuZWVkZWQ7IG5vbmUgd2lsbCBiZSBzY2hlZHVsZWQuIiwKICAgICAgImNvc3QiOiAiUXVpY2siLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJVbmF2YWlsYWJsZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJyZXBhaXIudGVtcCIsCiAgICAgICJuYW1lIjogIlByZXZpZXcgdGVtcG9yYXJ5LWZpbGUgY2xlYW51cCIsCiAgICAgICJkZXNjcmlwdGlvbiI6ICJQcmV2aWV3IGF0IG1vc3QgMjAwIHJlZ3VsYXIgZmlsZXMgb2xkZXIgdGhhbiBzZXZlbiBkYXlzIGluIHlvdXIgbG9jYWwgVGVtcCBkaXJlY3RvcnkuIiwKICAgICAgImNhdGVnb3J5IjogIldpbmRvd3MgUmVwYWlyIGFuZCBNYWludGVuYW5jZSIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAidGVtcCIKICAgICAgXSwKICAgICAgInNvdXJjZUtpbmQiOiAiQnVpbHRJbiIsCiAgICAgICJleGVjdXRpb25UeXBlIjogIkZ1bmN0aW9uIiwKICAgICAgInRhcmdldElkIjogInJlcGFpci50ZW1wIiwKICAgICAgInBhcmFtZXRlcnMiOiBbXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiBmYWxzZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFtdCiAgICAgIH0sCiAgICAgICJyaXNrIjogIkhpZ2hSaXNrIiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJUeXBlQ29tbWFuZElkIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJQZXJtYW5lbnRseSBkZWxldGVzIG9ubHkgdGhlIHByZXZpZXdlZCBlbGlnaWJsZSBmaWxlcy4gVGhlcmUgaXMgbm8gdW5kby4iLAogICAgICAiY29zdCI6ICJWYXJpYWJsZSIsCiAgICAgICJuZXR3b3JrQWNjZXNzIjogIk5vbmUiLAogICAgICAiY2FuY2VsbGF0aW9uIjogIlVuYXZhaWxhYmxlIgogICAgfSwKICAgIHsKICAgICAgImlkIjogInNlY3VyaXR5LmRlZmVuZGVyIiwKICAgICAgIm5hbWUiOiAiV2luZG93cyBEZWZlbmRlciBzdGF0dXMiLAogICAgICAiZGVzY3JpcHRpb24iOiAiUXVlcnkgRGVmZW5kZXIgc3RhdHVzIHdoZW4gaXRzIFdpbmRvd3MgbW9kdWxlIGlzIGF2YWlsYWJsZS4iLAogICAgICAiY2F0ZWdvcnkiOiAiU2VjdXJpdHkgYW5kIEFkbWluaXN0cmF0aW9uIiwKICAgICAgImtleXdvcmRzIjogWwogICAgICAgICJkZWZlbmRlciIKICAgICAgXSwKICAgICAgInNvdXJjZUtpbmQiOiAiQnVpbHRJbiIsCiAgICAgICJleGVjdXRpb25UeXBlIjogIkNtZGxldCIsCiAgICAgICJ0YXJnZXRJZCI6ICJzZWN1cml0eS5kZWZlbmRlciIsCiAgICAgICJwYXJhbWV0ZXJzIjogW10sCiAgICAgICJyZXF1aXJlc0FkbWluIjogdHJ1ZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFsKICAgICAgICAgICJjbWRsZXQ6R2V0LU1wQ29tcHV0ZXJTdGF0dXMiCiAgICAgICAgXQogICAgICB9LAogICAgICAicmlzayI6ICJSZWFkT25seSIsCiAgICAgICJjb25maXJtYXRpb24iOiAiTm9uZSIsCiAgICAgICJjb25zZXF1ZW5jZXMiOiAiTm8gaW50ZW50aW9uYWwgY29uZmlndXJhdGlvbiBjaGFuZ2UuIFdpbmRvd3MgbWF5IHdyaXRlIG9wZXJhdGlvbmFsIGxvZ3MuIiwKICAgICAgImNvc3QiOiAiUXVpY2siLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJDb29wZXJhdGl2ZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJzZWN1cml0eS5maXJld2FsbCIsCiAgICAgICJuYW1lIjogIkZpcmV3YWxsIHN0YXR1cyIsCiAgICAgICJkZXNjcmlwdGlvbiI6ICJRdWVyeSBXaW5kb3dzIGZpcmV3YWxsIHByb2ZpbGVzIHdpdGhvdXQgY2hhbmdpbmcgdGhlbS4iLAogICAgICAiY2F0ZWdvcnkiOiAiU2VjdXJpdHkgYW5kIEFkbWluaXN0cmF0aW9uIiwKICAgICAgImtleXdvcmRzIjogWwogICAgICAgICJmaXJld2FsbCIKICAgICAgXSwKICAgICAgInNvdXJjZUtpbmQiOiAiQnVpbHRJbiIsCiAgICAgICJleGVjdXRpb25UeXBlIjogIkNtZGxldCIsCiAgICAgICJ0YXJnZXRJZCI6ICJzZWN1cml0eS5maXJld2FsbCIsCiAgICAgICJwYXJhbWV0ZXJzIjogW10sCiAgICAgICJyZXF1aXJlc0FkbWluIjogZmFsc2UsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbCiAgICAgICAgICAiY21kbGV0OkdldC1OZXRGaXJld2FsbFByb2ZpbGUiCiAgICAgICAgXQogICAgICB9LAogICAgICAicmlzayI6ICJSZWFkT25seSIsCiAgICAgICJjb25maXJtYXRpb24iOiAiTm9uZSIsCiAgICAgICJjb25zZXF1ZW5jZXMiOiAiTm8gaW50ZW50aW9uYWwgY29uZmlndXJhdGlvbiBjaGFuZ2UuIFdpbmRvd3MgbWF5IHdyaXRlIG9wZXJhdGlvbmFsIGxvZ3MuIiwKICAgICAgImNvc3QiOiAiUXVpY2siLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJDb29wZXJhdGl2ZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJzZWN1cml0eS51c2VycyIsCiAgICAgICJuYW1lIjogIkxvY2FsIHVzZXIgYWNjb3VudHMiLAogICAgICAiZGVzY3JpcHRpb24iOiAiUXVlcnkgbG9jYWwgYWNjb3VudHMgd2l0aG91dCB0aGUgYXJjaGl0ZWN0dXJlLXNwZWNpZmljIExvY2FsQWNjb3VudHMgbW9kdWxlLiIsCiAgICAgICJjYXRlZ29yeSI6ICJTZWN1cml0eSBhbmQgQWRtaW5pc3RyYXRpb24iLAogICAgICAia2V5d29yZHMiOiBbCiAgICAgICAgInVzZXJzIgogICAgICBdLAogICAgICAic291cmNlS2luZCI6ICJCdWlsdEluIiwKICAgICAgImV4ZWN1dGlvblR5cGUiOiAiRnVuY3Rpb24iLAogICAgICAidGFyZ2V0SWQiOiAic2VjdXJpdHkudXNlcnMiLAogICAgICAicGFyYW1ldGVycyI6IFtdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IGZhbHNlLAogICAgICAiY29tcGF0aWJpbGl0eSI6IHsKICAgICAgICAibWluaW11bUJ1aWxkIjogMTAyNDAsCiAgICAgICAgImFyY2hpdGVjdHVyZXMiOiBbCiAgICAgICAgICAieDg2IiwKICAgICAgICAgICJ4NjQiCiAgICAgICAgXSwKICAgICAgICAiY2FwYWJpbGl0aWVzIjogW10KICAgICAgfSwKICAgICAgInJpc2siOiAiUmVhZE9ubHkiLAogICAgICAiY29uZmlybWF0aW9uIjogIk5vbmUiLAogICAgICAiY29uc2VxdWVuY2VzIjogIk5vIGludGVudGlvbmFsIGNvbmZpZ3VyYXRpb24gY2hhbmdlLiBXaW5kb3dzIG1heSB3cml0ZSBvcGVyYXRpb25hbCBsb2dzLiIsCiAgICAgICJjb3N0IjogIlF1aWNrIiwKICAgICAgIm5ldHdvcmtBY2Nlc3MiOiAiTm9uZSIsCiAgICAgICJjYW5jZWxsYXRpb24iOiAiQ29vcGVyYXRpdmUiCiAgICB9LAogICAgewogICAgICAiaWQiOiAic2VjdXJpdHkuZGV2aWNlcyIsCiAgICAgICJuYW1lIjogIkRldmljZSBNYW5hZ2VyIiwKICAgICAgImRlc2NyaXB0aW9uIjogIk9wZW4gZGV2aWNlIGFkbWluaXN0cmF0aW9uOyBjaGFuZ2luZyBkZXZpY2VzIGNhbiBkaXNydXB0IHRoZSBzeXN0ZW0uIiwKICAgICAgImNhdGVnb3J5IjogIlNlY3VyaXR5IGFuZCBBZG1pbmlzdHJhdGlvbiIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAiZGV2aWNlcyIKICAgICAgXSwKICAgICAgInNvdXJjZUtpbmQiOiAiQnVpbHRJbiIsCiAgICAgICJleGVjdXRpb25UeXBlIjogIk1tYyIsCiAgICAgICJ0YXJnZXRJZCI6ICJzZWN1cml0eS5kZXZpY2VzIiwKICAgICAgInBhcmFtZXRlcnMiOiBbXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiBmYWxzZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFsKICAgICAgICAgICJleGU6bW1jLmV4ZSIKICAgICAgICBdCiAgICAgIH0sCiAgICAgICJyaXNrIjogIkhpZ2hSaXNrIiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJUeXBlQ29tbWFuZElkIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJPcGVucyBhbiBhZG1pbmlzdHJhdGl2ZSBpbnRlcmZhY2Ugd2hvc2UgY29udHJvbHMgY2FuIG1vZGlmeSBXaW5kb3dzLiBJdHMgc3Vic2VxdWVudCBhY3Rpb25zIGFyZSBvdXRzaWRlIHRoZSB0b29sa2l0LiIsCiAgICAgICJjb3N0IjogIlF1aWNrIiwKICAgICAgIm5ldHdvcmtBY2Nlc3MiOiAiTm9uZSIsCiAgICAgICJjYW5jZWxsYXRpb24iOiAiVW5hdmFpbGFibGUiCiAgICB9LAogICAgewogICAgICAiaWQiOiAic2VjdXJpdHkuY29tcHV0ZXItbWFuYWdlbWVudCIsCiAgICAgICJuYW1lIjogIkNvbXB1dGVyIE1hbmFnZW1lbnQiLAogICAgICAiZGVzY3JpcHRpb24iOiAiT3BlbiBXaW5kb3dzIGFkbWluaXN0cmF0aW9uIHRvb2xzIHdpdGggYnJvYWQgbW9kaWZpY2F0aW9uIGNhcGFiaWxpdGllcy4iLAogICAgICAiY2F0ZWdvcnkiOiAiU2VjdXJpdHkgYW5kIEFkbWluaXN0cmF0aW9uIiwKICAgICAgImtleXdvcmRzIjogWwogICAgICAgICJjb21wdXRlci1tYW5hZ2VtZW50IgogICAgICBdLAogICAgICAic291cmNlS2luZCI6ICJCdWlsdEluIiwKICAgICAgImV4ZWN1dGlvblR5cGUiOiAiTW1jIiwKICAgICAgInRhcmdldElkIjogInNlY3VyaXR5LmNvbXB1dGVyLW1hbmFnZW1lbnQiLAogICAgICAicGFyYW1ldGVycyI6IFtdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IGZhbHNlLAogICAgICAiY29tcGF0aWJpbGl0eSI6IHsKICAgICAgICAibWluaW11bUJ1aWxkIjogMTAyNDAsCiAgICAgICAgImFyY2hpdGVjdHVyZXMiOiBbCiAgICAgICAgICAieDg2IiwKICAgICAgICAgICJ4NjQiCiAgICAgICAgXSwKICAgICAgICAiY2FwYWJpbGl0aWVzIjogWwogICAgICAgICAgImV4ZTptbWMuZXhlIgogICAgICAgIF0KICAgICAgfSwKICAgICAgInJpc2siOiAiSGlnaFJpc2siLAogICAgICAiY29uZmlybWF0aW9uIjogIlR5cGVDb21tYW5kSWQiLAogICAgICAiY29uc2VxdWVuY2VzIjogIk9wZW5zIGFuIGFkbWluaXN0cmF0aXZlIGludGVyZmFjZSB3aG9zZSBjb250cm9scyBjYW4gbW9kaWZ5IFdpbmRvd3MuIEl0cyBzdWJzZXF1ZW50IGFjdGlvbnMgYXJlIG91dHNpZGUgdGhlIHRvb2xraXQuIiwKICAgICAgImNvc3QiOiAiUXVpY2siLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJVbmF2YWlsYWJsZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJzZWN1cml0eS5zZXR0aW5ncyIsCiAgICAgICJuYW1lIjogIldpbmRvd3Mgc2VjdXJpdHkgc2V0dGluZ3MiLAogICAgICAiZGVzY3JpcHRpb24iOiAiT3BlbiB0aGUgV2luZG93cyBTZWN1cml0eSBzZXR0aW5ncyBwYWdlLiIsCiAgICAgICJjYXRlZ29yeSI6ICJTZWN1cml0eSBhbmQgQWRtaW5pc3RyYXRpb24iLAogICAgICAia2V5d29yZHMiOiBbCiAgICAgICAgInNldHRpbmdzIgogICAgICBdLAogICAgICAic291cmNlS2luZCI6ICJCdWlsdEluIiwKICAgICAgImV4ZWN1dGlvblR5cGUiOiAiU2V0dGluZ3MiLAogICAgICAidGFyZ2V0SWQiOiAic2VjdXJpdHkuc2V0dGluZ3MiLAogICAgICAicGFyYW1ldGVycyI6IFtdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IGZhbHNlLAogICAgICAiY29tcGF0aWJpbGl0eSI6IHsKICAgICAgICAibWluaW11bUJ1aWxkIjogMTAyNDAsCiAgICAgICAgImFyY2hpdGVjdHVyZXMiOiBbCiAgICAgICAgICAieDg2IiwKICAgICAgICAgICJ4NjQiCiAgICAgICAgXSwKICAgICAgICAiY2FwYWJpbGl0aWVzIjogW10KICAgICAgfSwKICAgICAgInJpc2siOiAiU3lzdGVtTW9kaWZpY2F0aW9uIiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJDb25maXJtIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJPcGVucyBhbiBhZG1pbmlzdHJhdGl2ZSBpbnRlcmZhY2Ugd2hvc2UgY29udHJvbHMgY2FuIG1vZGlmeSBXaW5kb3dzLiBJdHMgc3Vic2VxdWVudCBhY3Rpb25zIGFyZSBvdXRzaWRlIHRoZSB0b29sa2l0LiIsCiAgICAgICJjb3N0IjogIlF1aWNrIiwKICAgICAgIm5ldHdvcmtBY2Nlc3MiOiAiTm9uZSIsCiAgICAgICJjYW5jZWxsYXRpb24iOiAiVW5hdmFpbGFibGUiCiAgICB9LAogICAgewogICAgICAiaWQiOiAic3lzdGVtLmZ1bGwtc3BlY3MiLAogICAgICAibmFtZSI6ICJGdWxsIHNwZWNpZmljYXRpb25zIiwKICAgICAgImRlc2NyaXB0aW9uIjogIkNvbWJpbmVkIHNwZWNpZmljYXRpb24gcmVwb3J0LiBVbmF2YWlsYWJsZSBzZWN0aW9ucyBkbyBub3QgZGlzY2FyZCBzdWNjZXNzZnVsIHNlY3Rpb25zLiIsCiAgICAgICJjYXRlZ29yeSI6ICJTeXN0ZW0gSW5mb3JtYXRpb24iLAogICAgICAia2V5d29yZHMiOiBbCiAgICAgICAgInN5c3RlbSIsCiAgICAgICAgImZ1bGwiLAogICAgICAgICJzcGVjcyIKICAgICAgXSwKICAgICAgInNvdXJjZUtpbmQiOiAiQnVpbHRJbiIsCiAgICAgICJleGVjdXRpb25UeXBlIjogIkZ1bmN0aW9uIiwKICAgICAgInRhcmdldElkIjogInN5c3RlbS5mdWxsLXNwZWNzIiwKICAgICAgInBhcmFtZXRlcnMiOiBbXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiBmYWxzZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFtdCiAgICAgIH0sCiAgICAgICJyaXNrIjogIlJlYWRPbmx5IiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJOb25lIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJRdWVyaWVzIGxvY2FsIGluZm9ybWF0aW9uIHdpdGhvdXQgYXBwbHlpbmcgcmVwYWlycy4iLAogICAgICAiY29zdCI6ICJIZWF2eSIsCiAgICAgICJuZXR3b3JrQWNjZXNzIjogIk5vbmUiLAogICAgICAiY2FuY2VsbGF0aW9uIjogIkNvb3BlcmF0aXZlIgogICAgfSwKICAgIHsKICAgICAgImlkIjogInRyb3VibGVzaG9vdGluZy5ldmVudHMiLAogICAgICAibmFtZSI6ICJSZWNlbnQgY3JpdGljYWwgYW5kIGVycm9yIGV2ZW50cyIsCiAgICAgICJkZXNjcmlwdGlvbiI6ICJVcCB0byA1MCBjcml0aWNhbC9lcnJvciBldmVudHMgcGVyIFN5c3RlbSBhbmQgQXBwbGljYXRpb24gbG9nLiIsCiAgICAgICJjYXRlZ29yeSI6ICJUcm91Ymxlc2hvb3RpbmciLAogICAgICAia2V5d29yZHMiOiBbCiAgICAgICAgInRyb3VibGVzaG9vdGluZyIsCiAgICAgICAgImV2ZW50cyIKICAgICAgXSwKICAgICAgInNvdXJjZUtpbmQiOiAiQnVpbHRJbiIsCiAgICAgICJleGVjdXRpb25UeXBlIjogIkZ1bmN0aW9uIiwKICAgICAgInRhcmdldElkIjogInRyb3VibGVzaG9vdGluZy5ldmVudHMiLAogICAgICAicGFyYW1ldGVycyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJob3VycyIsCiAgICAgICAgICAidHlwZSI6ICJJbnRlZ2VyIiwKICAgICAgICAgICJsYWJlbCI6ICJMb29rIGJhY2sgaG91cnMiLAogICAgICAgICAgInJlcXVpcmVkIjogdHJ1ZSwKICAgICAgICAgICJkZWZhdWx0IjogMjQsCiAgICAgICAgICAibWluaW11bSI6IDEsCiAgICAgICAgICAibWF4aW11bSI6IDE2OCwKICAgICAgICAgICJhbGxvd2VkVmFsdWVzIjogW10KICAgICAgICB9CiAgICAgIF0sCiAgICAgICJyZXF1aXJlc0FkbWluIjogZmFsc2UsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbXQogICAgICB9LAogICAgICAicmlzayI6ICJSZWFkT25seSIsCiAgICAgICJjb25maXJtYXRpb24iOiAiTm9uZSIsCiAgICAgICJjb25zZXF1ZW5jZXMiOiAiUXVlcmllcyBsb2NhbCBpbmZvcm1hdGlvbiB3aXRob3V0IGFwcGx5aW5nIHJlcGFpcnMuIiwKICAgICAgImNvc3QiOiAiVmFyaWFibGUiLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJDb29wZXJhdGl2ZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJ0cm91Ymxlc2hvb3RpbmcuZGV2aWNlcyIsCiAgICAgICJuYW1lIjogIlByb2JsZW0gZGV2aWNlcyIsCiAgICAgICJkZXNjcmlwdGlvbiI6ICJEZXZpY2VzIHJlcG9ydGluZyBjb25maWd1cmF0aW9uIG9yIGRyaXZlciBlcnJvcnMuIiwKICAgICAgImNhdGVnb3J5IjogIlRyb3VibGVzaG9vdGluZyIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAidHJvdWJsZXNob290aW5nIiwKICAgICAgICAiZGV2aWNlcyIKICAgICAgXSwKICAgICAgInNvdXJjZUtpbmQiOiAiQnVpbHRJbiIsCiAgICAgICJleGVjdXRpb25UeXBlIjogIkZ1bmN0aW9uIiwKICAgICAgInRhcmdldElkIjogInRyb3VibGVzaG9vdGluZy5kZXZpY2VzIiwKICAgICAgInBhcmFtZXRlcnMiOiBbXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiBmYWxzZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFtdCiAgICAgIH0sCiAgICAgICJyaXNrIjogIlJlYWRPbmx5IiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJOb25lIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJRdWVyaWVzIGxvY2FsIGluZm9ybWF0aW9uIHdpdGhvdXQgYXBwbHlpbmcgcmVwYWlycy4iLAogICAgICAiY29zdCI6ICJWYXJpYWJsZSIsCiAgICAgICJuZXR3b3JrQWNjZXNzIjogIk5vbmUiLAogICAgICAiY2FuY2VsbGF0aW9uIjogIkNvb3BlcmF0aXZlIgogICAgfSwKICAgIHsKICAgICAgImlkIjogInRyb3VibGVzaG9vdGluZy5iYXR0ZXJ5IiwKICAgICAgIm5hbWUiOiAiQmF0dGVyeSBoZWFsdGggaW5kaWNhdG9ycyIsCiAgICAgICJkZXNjcmlwdGlvbiI6ICJGaXJtd2FyZS1yZXBvcnRlZCBkZXNpZ24gYW5kIGZ1bGwtY2hhcmdlIGNhcGFjaXRpZXMgd2hlcmUgYXZhaWxhYmxlLiIsCiAgICAgICJjYXRlZ29yeSI6ICJUcm91Ymxlc2hvb3RpbmciLAogICAgICAia2V5d29yZHMiOiBbCiAgICAgICAgInRyb3VibGVzaG9vdGluZyIsCiAgICAgICAgImJhdHRlcnkiCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJGdW5jdGlvbiIsCiAgICAgICJ0YXJnZXRJZCI6ICJ0cm91Ymxlc2hvb3RpbmcuYmF0dGVyeSIsCiAgICAgICJwYXJhbWV0ZXJzIjogW10sCiAgICAgICJyZXF1aXJlc0FkbWluIjogZmFsc2UsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbXQogICAgICB9LAogICAgICAicmlzayI6ICJSZWFkT25seSIsCiAgICAgICJjb25maXJtYXRpb24iOiAiTm9uZSIsCiAgICAgICJjb25zZXF1ZW5jZXMiOiAiUXVlcmllcyBsb2NhbCBpbmZvcm1hdGlvbiB3aXRob3V0IGFwcGx5aW5nIHJlcGFpcnMuIiwKICAgICAgImNvc3QiOiAiVmFyaWFibGUiLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJDb29wZXJhdGl2ZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJ0cm91Ymxlc2hvb3RpbmcudXBkYXRlcyIsCiAgICAgICJuYW1lIjogIldpbmRvd3MgVXBkYXRlIGRpYWdub3N0aWNzIiwKICAgICAgImRlc2NyaXB0aW9uIjogIkxvY2FsIHVwZGF0ZSBzZXJ2aWNlcywgcmVzdGFydCBpbmRpY2F0b3JzLCBwb2xpY3kgYW5kIHRvb2xib3ggc3VzcGVuc2lvbiBzdGF0ZS4gTm8gdXBkYXRlIHNjYW4gaXMgc3RhcnRlZC4iLAogICAgICAiY2F0ZWdvcnkiOiAiVHJvdWJsZXNob290aW5nIiwKICAgICAgImtleXdvcmRzIjogWwogICAgICAgICJ0cm91Ymxlc2hvb3RpbmciLAogICAgICAgICJ1cGRhdGVzIgogICAgICBdLAogICAgICAic291cmNlS2luZCI6ICJCdWlsdEluIiwKICAgICAgImV4ZWN1dGlvblR5cGUiOiAiRnVuY3Rpb24iLAogICAgICAidGFyZ2V0SWQiOiAidHJvdWJsZXNob290aW5nLnVwZGF0ZXMiLAogICAgICAicGFyYW1ldGVycyI6IFtdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IGZhbHNlLAogICAgICAiY29tcGF0aWJpbGl0eSI6IHsKICAgICAgICAibWluaW11bUJ1aWxkIjogMTAyNDAsCiAgICAgICAgImFyY2hpdGVjdHVyZXMiOiBbCiAgICAgICAgICAieDg2IiwKICAgICAgICAgICJ4NjQiCiAgICAgICAgXSwKICAgICAgICAiY2FwYWJpbGl0aWVzIjogW10KICAgICAgfSwKICAgICAgInJpc2siOiAiUmVhZE9ubHkiLAogICAgICAiY29uZmlybWF0aW9uIjogIk5vbmUiLAogICAgICAiY29uc2VxdWVuY2VzIjogIlF1ZXJpZXMgbG9jYWwgaW5mb3JtYXRpb24gd2l0aG91dCBhcHBseWluZyByZXBhaXJzLiIsCiAgICAgICJjb3N0IjogIlZhcmlhYmxlIiwKICAgICAgIm5ldHdvcmtBY2Nlc3MiOiAiTm9uZSIsCiAgICAgICJjYW5jZWxsYXRpb24iOiAiQ29vcGVyYXRpdmUiCiAgICB9LAogICAgewogICAgICAiaWQiOiAidHJvdWJsZXNob290aW5nLmNvbm5lY3Rpdml0eSIsCiAgICAgICJuYW1lIjogIkNvbm5lY3Rpdml0eSBkaWFnbm9zdGljIiwKICAgICAgImRlc2NyaXB0aW9uIjogIkluc3BlY3QgdGhlIElQdjQgZ2F0ZXdheSwgRE5TIHJlc29sdXRpb24gYW5kIFRDUCBjb25uZWN0aXZpdHkgdG8geW91ciBleHBsaWNpdCB0YXJnZXQuIiwKICAgICAgImNhdGVnb3J5IjogIlRyb3VibGVzaG9vdGluZyIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAidHJvdWJsZXNob290aW5nIiwKICAgICAgICAiY29ubmVjdGl2aXR5IgogICAgICBdLAogICAgICAic291cmNlS2luZCI6ICJCdWlsdEluIiwKICAgICAgImV4ZWN1dGlvblR5cGUiOiAiRnVuY3Rpb24iLAogICAgICAidGFyZ2V0SWQiOiAidHJvdWJsZXNob290aW5nLmNvbm5lY3Rpdml0eSIsCiAgICAgICJwYXJhbWV0ZXJzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogImhvc3QiLAogICAgICAgICAgInR5cGUiOiAiSG9zdCIsCiAgICAgICAgICAibGFiZWwiOiAiVGFyZ2V0IGhvc3RuYW1lIG9yIElQIiwKICAgICAgICAgICJyZXF1aXJlZCI6IHRydWUsCiAgICAgICAgICAiZGVmYXVsdCI6IG51bGwsCiAgICAgICAgICAibWluaW11bSI6IG51bGwsCiAgICAgICAgICAibWF4aW11bSI6IG51bGwsCiAgICAgICAgICAiYWxsb3dlZFZhbHVlcyI6IFtdCiAgICAgICAgfSwKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJwb3J0IiwKICAgICAgICAgICJ0eXBlIjogIkludGVnZXIiLAogICAgICAgICAgImxhYmVsIjogIlRhcmdldCBUQ1AgcG9ydCIsCiAgICAgICAgICAicmVxdWlyZWQiOiB0cnVlLAogICAgICAgICAgImRlZmF1bHQiOiA0NDMsCiAgICAgICAgICAibWluaW11bSI6IDEsCiAgICAgICAgICAibWF4aW11bSI6IDY1NTM1LAogICAgICAgICAgImFsbG93ZWRWYWx1ZXMiOiBbXQogICAgICAgIH0KICAgICAgXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiBmYWxzZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFtdCiAgICAgIH0sCiAgICAgICJyaXNrIjogIlJlYWRPbmx5IiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJOb25lIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJRdWVyaWVzIGxvY2FsIGluZm9ybWF0aW9uIHdpdGhvdXQgYXBwbHlpbmcgcmVwYWlycy4iLAogICAgICAiY29zdCI6ICJWYXJpYWJsZSIsCiAgICAgICJuZXR3b3JrQWNjZXNzIjogIlVzZXJUYXJnZXQiLAogICAgICAiY2FuY2VsbGF0aW9uIjogIkNvb3BlcmF0aXZlIgogICAgfSwKICAgIHsKICAgICAgImlkIjogInNlY3VyaXR5LmZpcmV3YWxsLWNvbnRyb2wiLAogICAgICAibmFtZSI6ICJGaXJld2FsbCBlbmFibGUgLyBkaXNhYmxlIiwKICAgICAgImRlc2NyaXB0aW9uIjogIkVuYWJsZSBwcm90ZWN0aW9uIG9yIGRpc2FibGUgc2VsZWN0ZWQgcHJvZmlsZXMgaW4gdGltZWQvbWFudWFsIG1vZGUuIEVmZmVjdGl2ZSBwb2xpY3kgaXMgdmVyaWZpZWQuIiwKICAgICAgImNhdGVnb3J5IjogIlNlY3VyaXR5IGFuZCBBZG1pbmlzdHJhdGlvbiIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAic2VjdXJpdHkiLAogICAgICAgICJmaXJld2FsbCIsCiAgICAgICAgImNvbnRyb2wiCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJGdW5jdGlvbiIsCiAgICAgICJ0YXJnZXRJZCI6ICJzZWN1cml0eS5maXJld2FsbC1jb250cm9sIiwKICAgICAgInBhcmFtZXRlcnMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAicHJvZmlsZSIsCiAgICAgICAgICAidHlwZSI6ICJDaG9pY2UiLAogICAgICAgICAgImxhYmVsIjogIkZpcmV3YWxsIHByb2ZpbGVzIiwKICAgICAgICAgICJyZXF1aXJlZCI6IHRydWUsCiAgICAgICAgICAiZGVmYXVsdCI6ICJQcml2YXRlIiwKICAgICAgICAgICJtaW5pbXVtIjogbnVsbCwKICAgICAgICAgICJtYXhpbXVtIjogbnVsbCwKICAgICAgICAgICJhbGxvd2VkVmFsdWVzIjogWwogICAgICAgICAgICAiUHJpdmF0ZSIsCiAgICAgICAgICAgICJQdWJsaWMiLAogICAgICAgICAgICAiRG9tYWluIiwKICAgICAgICAgICAgIkFsbCIKICAgICAgICAgIF0KICAgICAgICB9LAogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogImFjdGlvbiIsCiAgICAgICAgICAidHlwZSI6ICJDaG9pY2UiLAogICAgICAgICAgImxhYmVsIjogIkFjdGlvbiIsCiAgICAgICAgICAicmVxdWlyZWQiOiB0cnVlLAogICAgICAgICAgImRlZmF1bHQiOiAiRGlzYWJsZSIsCiAgICAgICAgICAibWluaW11bSI6IG51bGwsCiAgICAgICAgICAibWF4aW11bSI6IG51bGwsCiAgICAgICAgICAiYWxsb3dlZFZhbHVlcyI6IFsKICAgICAgICAgICAgIkRpc2FibGUiLAogICAgICAgICAgICAiRW5hYmxlIgogICAgICAgICAgXQogICAgICAgIH0sCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAibW9kZSIsCiAgICAgICAgICAidHlwZSI6ICJDaG9pY2UiLAogICAgICAgICAgImxhYmVsIjogIlJlc3RvcmUgbW9kZSIsCiAgICAgICAgICAicmVxdWlyZWQiOiB0cnVlLAogICAgICAgICAgImRlZmF1bHQiOiAiVGltZWQiLAogICAgICAgICAgIm1pbmltdW0iOiBudWxsLAogICAgICAgICAgIm1heGltdW0iOiBudWxsLAogICAgICAgICAgImFsbG93ZWRWYWx1ZXMiOiBbCiAgICAgICAgICAgICJUaW1lZCIsCiAgICAgICAgICAgICJNYW51YWwiCiAgICAgICAgICBdCiAgICAgICAgfSwKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJtaW51dGVzIiwKICAgICAgICAgICJ0eXBlIjogIkludGVnZXIiLAogICAgICAgICAgImxhYmVsIjogIlRpbWVkIHJlc3RvcmF0aW9uIGluIG1pbnV0ZXMiLAogICAgICAgICAgInJlcXVpcmVkIjogdHJ1ZSwKICAgICAgICAgICJkZWZhdWx0IjogMzAsCiAgICAgICAgICAibWluaW11bSI6IDEsCiAgICAgICAgICAibWF4aW11bSI6IDE0NDAsCiAgICAgICAgICAiYWxsb3dlZFZhbHVlcyI6IFtdCiAgICAgICAgfQogICAgICBdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IHRydWUsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbCiAgICAgICAgICAiY21kbGV0OlJlZ2lzdGVyLVNjaGVkdWxlZFRhc2siCiAgICAgICAgXQogICAgICB9LAogICAgICAicmlzayI6ICJIaWdoUmlzayIsCiAgICAgICJjb25maXJtYXRpb24iOiAiVHlwZUNvbW1hbmRJZCIsCiAgICAgICJjb25zZXF1ZW5jZXMiOiAiRW5hYmxlIHByb3RlY3Rpb24gb3IgZGlzYWJsZSBzZWxlY3RlZCBwcm9maWxlcyBpbiB0aW1lZC9tYW51YWwgbW9kZS4gRWZmZWN0aXZlIHBvbGljeSBpcyB2ZXJpZmllZC4gQ2hhbmdlcyBydW4gb25seSBhZnRlciBjb25maXJtYXRpb247IHNjaGVkdWxlZCBmZWF0dXJlcyBjcmVhdGUgcHJvdGVjdGVkIHJlY292ZXJ5IGZpbGVzIGFuZCBXaW5kb3dzIHRhc2tzLiIsCiAgICAgICJjb3N0IjogIlZhcmlhYmxlIiwKICAgICAgIm5ldHdvcmtBY2Nlc3MiOiAiTm9uZSIsCiAgICAgICJjYW5jZWxsYXRpb24iOiAiVW5hdmFpbGFibGUiCiAgICB9LAogICAgewogICAgICAiaWQiOiAic2VjdXJpdHkuZmlyZXdhbGwtcmVzdG9yZSIsCiAgICAgICJuYW1lIjogIlJlc3RvcmUgdG9vbGJveCBmaXJld2FsbCBjaGFuZ2VzIiwKICAgICAgImRlc2NyaXB0aW9uIjogIlJlc3RvcmUgb3JpZ2luYWwgcHJvZmlsZSBzZXR0aW5ncyBmcm9tIHRvb2xib3ggc25hcHNob3RzLiBDb25mbGljdGluZyBleHRlcm5hbCBjaGFuZ2VzIGFyZSBub3Qgb3ZlcndyaXR0ZW4uIiwKICAgICAgImNhdGVnb3J5IjogIlNlY3VyaXR5IGFuZCBBZG1pbmlzdHJhdGlvbiIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAic2VjdXJpdHkiLAogICAgICAgICJmaXJld2FsbCIsCiAgICAgICAgInJlc3RvcmUiCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJGdW5jdGlvbiIsCiAgICAgICJ0YXJnZXRJZCI6ICJzZWN1cml0eS5maXJld2FsbC1yZXN0b3JlIiwKICAgICAgInBhcmFtZXRlcnMiOiBbXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiB0cnVlLAogICAgICAiY29tcGF0aWJpbGl0eSI6IHsKICAgICAgICAibWluaW11bUJ1aWxkIjogMTAyNDAsCiAgICAgICAgImFyY2hpdGVjdHVyZXMiOiBbCiAgICAgICAgICAieDg2IiwKICAgICAgICAgICJ4NjQiCiAgICAgICAgXSwKICAgICAgICAiY2FwYWJpbGl0aWVzIjogW10KICAgICAgfSwKICAgICAgInJpc2siOiAiSGlnaFJpc2siLAogICAgICAiY29uZmlybWF0aW9uIjogIlR5cGVDb21tYW5kSWQiLAogICAgICAiY29uc2VxdWVuY2VzIjogIlJlc3RvcmUgb3JpZ2luYWwgcHJvZmlsZSBzZXR0aW5ncyBmcm9tIHRvb2xib3ggc25hcHNob3RzLiBDb25mbGljdGluZyBleHRlcm5hbCBjaGFuZ2VzIGFyZSBub3Qgb3ZlcndyaXR0ZW4uIENoYW5nZXMgcnVuIG9ubHkgYWZ0ZXIgY29uZmlybWF0aW9uOyBzY2hlZHVsZWQgZmVhdHVyZXMgY3JlYXRlIHByb3RlY3RlZCByZWNvdmVyeSBmaWxlcyBhbmQgV2luZG93cyB0YXNrcy4iLAogICAgICAiY29zdCI6ICJWYXJpYWJsZSIsCiAgICAgICJuZXR3b3JrQWNjZXNzIjogIk5vbmUiLAogICAgICAiY2FuY2VsbGF0aW9uIjogIlVuYXZhaWxhYmxlIgogICAgfSwKICAgIHsKICAgICAgImlkIjogInNlY3VyaXR5LmRlZmVuZGVyLWNvbnRyb2wiLAogICAgICAibmFtZSI6ICJEZWZlbmRlciByZWFsLXRpbWUgcHJvdGVjdGlvbiIsCiAgICAgICJkZXNjcmlwdGlvbiI6ICJFbmFibGUgb3IgZGlzYWJsZSByZWFsLXRpbWUgcHJvdGVjdGlvbiBpbiB0aW1lZC9tYW51YWwgbW9kZS4gVGFtcGVyIFByb3RlY3Rpb24gaXMgbmV2ZXIgYnlwYXNzZWQuIiwKICAgICAgImNhdGVnb3J5IjogIlNlY3VyaXR5IGFuZCBBZG1pbmlzdHJhdGlvbiIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAic2VjdXJpdHkiLAogICAgICAgICJkZWZlbmRlciIsCiAgICAgICAgImNvbnRyb2wiCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJGdW5jdGlvbiIsCiAgICAgICJ0YXJnZXRJZCI6ICJzZWN1cml0eS5kZWZlbmRlci1jb250cm9sIiwKICAgICAgInBhcmFtZXRlcnMiOiBbCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAiYWN0aW9uIiwKICAgICAgICAgICJ0eXBlIjogIkNob2ljZSIsCiAgICAgICAgICAibGFiZWwiOiAiQWN0aW9uIiwKICAgICAgICAgICJyZXF1aXJlZCI6IHRydWUsCiAgICAgICAgICAiZGVmYXVsdCI6ICJEaXNhYmxlIiwKICAgICAgICAgICJtaW5pbXVtIjogbnVsbCwKICAgICAgICAgICJtYXhpbXVtIjogbnVsbCwKICAgICAgICAgICJhbGxvd2VkVmFsdWVzIjogWwogICAgICAgICAgICAiRGlzYWJsZSIsCiAgICAgICAgICAgICJFbmFibGUiCiAgICAgICAgICBdCiAgICAgICAgfSwKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJtb2RlIiwKICAgICAgICAgICJ0eXBlIjogIkNob2ljZSIsCiAgICAgICAgICAibGFiZWwiOiAiUmVzdG9yZSBtb2RlIiwKICAgICAgICAgICJyZXF1aXJlZCI6IHRydWUsCiAgICAgICAgICAiZGVmYXVsdCI6ICJUaW1lZCIsCiAgICAgICAgICAibWluaW11bSI6IG51bGwsCiAgICAgICAgICAibWF4aW11bSI6IG51bGwsCiAgICAgICAgICAiYWxsb3dlZFZhbHVlcyI6IFsKICAgICAgICAgICAgIlRpbWVkIiwKICAgICAgICAgICAgIk1hbnVhbCIKICAgICAgICAgIF0KICAgICAgICB9LAogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogIm1pbnV0ZXMiLAogICAgICAgICAgInR5cGUiOiAiSW50ZWdlciIsCiAgICAgICAgICAibGFiZWwiOiAiVGltZWQgcmVzdG9yYXRpb24gaW4gbWludXRlcyIsCiAgICAgICAgICAicmVxdWlyZWQiOiB0cnVlLAogICAgICAgICAgImRlZmF1bHQiOiAzMCwKICAgICAgICAgICJtaW5pbXVtIjogMSwKICAgICAgICAgICJtYXhpbXVtIjogMTQ0MCwKICAgICAgICAgICJhbGxvd2VkVmFsdWVzIjogW10KICAgICAgICB9CiAgICAgIF0sCiAgICAgICJyZXF1aXJlc0FkbWluIjogdHJ1ZSwKICAgICAgImNvbXBhdGliaWxpdHkiOiB7CiAgICAgICAgIm1pbmltdW1CdWlsZCI6IDEwMjQwLAogICAgICAgICJhcmNoaXRlY3R1cmVzIjogWwogICAgICAgICAgIng4NiIsCiAgICAgICAgICAieDY0IgogICAgICAgIF0sCiAgICAgICAgImNhcGFiaWxpdGllcyI6IFsKICAgICAgICAgICJjbWRsZXQ6UmVnaXN0ZXItU2NoZWR1bGVkVGFzayIKICAgICAgICBdCiAgICAgIH0sCiAgICAgICJyaXNrIjogIkhpZ2hSaXNrIiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJUeXBlQ29tbWFuZElkIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJFbmFibGUgb3IgZGlzYWJsZSByZWFsLXRpbWUgcHJvdGVjdGlvbiBpbiB0aW1lZC9tYW51YWwgbW9kZS4gVGFtcGVyIFByb3RlY3Rpb24gaXMgbmV2ZXIgYnlwYXNzZWQuIENoYW5nZXMgcnVuIG9ubHkgYWZ0ZXIgY29uZmlybWF0aW9uOyBzY2hlZHVsZWQgZmVhdHVyZXMgY3JlYXRlIHByb3RlY3RlZCByZWNvdmVyeSBmaWxlcyBhbmQgV2luZG93cyB0YXNrcy4iLAogICAgICAiY29zdCI6ICJWYXJpYWJsZSIsCiAgICAgICJuZXR3b3JrQWNjZXNzIjogIk5vbmUiLAogICAgICAiY2FuY2VsbGF0aW9uIjogIlVuYXZhaWxhYmxlIgogICAgfSwKICAgIHsKICAgICAgImlkIjogInNlY3VyaXR5LmRlZmVuZGVyLXJlc3RvcmUiLAogICAgICAibmFtZSI6ICJSZXN0b3JlIHRvb2xib3ggRGVmZW5kZXIgY2hhbmdlIiwKICAgICAgImRlc2NyaXB0aW9uIjogIlJlc3RvcmUgdGhlIG9yaWdpbmFsIHJlYWwtdGltZSBwcm90ZWN0aW9uIHN0YXRlIGZyb20gdGhlIHRvb2xib3ggc25hcHNob3QuIiwKICAgICAgImNhdGVnb3J5IjogIlNlY3VyaXR5IGFuZCBBZG1pbmlzdHJhdGlvbiIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAic2VjdXJpdHkiLAogICAgICAgICJkZWZlbmRlciIsCiAgICAgICAgInJlc3RvcmUiCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJGdW5jdGlvbiIsCiAgICAgICJ0YXJnZXRJZCI6ICJzZWN1cml0eS5kZWZlbmRlci1yZXN0b3JlIiwKICAgICAgInBhcmFtZXRlcnMiOiBbXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiB0cnVlLAogICAgICAiY29tcGF0aWJpbGl0eSI6IHsKICAgICAgICAibWluaW11bUJ1aWxkIjogMTAyNDAsCiAgICAgICAgImFyY2hpdGVjdHVyZXMiOiBbCiAgICAgICAgICAieDg2IiwKICAgICAgICAgICJ4NjQiCiAgICAgICAgXSwKICAgICAgICAiY2FwYWJpbGl0aWVzIjogW10KICAgICAgfSwKICAgICAgInJpc2siOiAiSGlnaFJpc2siLAogICAgICAiY29uZmlybWF0aW9uIjogIlR5cGVDb21tYW5kSWQiLAogICAgICAiY29uc2VxdWVuY2VzIjogIlJlc3RvcmUgdGhlIG9yaWdpbmFsIHJlYWwtdGltZSBwcm90ZWN0aW9uIHN0YXRlIGZyb20gdGhlIHRvb2xib3ggc25hcHNob3QuIENoYW5nZXMgcnVuIG9ubHkgYWZ0ZXIgY29uZmlybWF0aW9uOyBzY2hlZHVsZWQgZmVhdHVyZXMgY3JlYXRlIHByb3RlY3RlZCByZWNvdmVyeSBmaWxlcyBhbmQgV2luZG93cyB0YXNrcy4iLAogICAgICAiY29zdCI6ICJWYXJpYWJsZSIsCiAgICAgICJuZXR3b3JrQWNjZXNzIjogIk5vbmUiLAogICAgICAiY2FuY2VsbGF0aW9uIjogIlVuYXZhaWxhYmxlIgogICAgfSwKICAgIHsKICAgICAgImlkIjogInVwZGF0ZXMuc3VzcGVuZCIsCiAgICAgICJuYW1lIjogIlN1c3BlbmQgYXV0b21hdGljIHVwZGF0ZXMgKDEtMzYgbW9udGhzKSIsCiAgICAgICJkZXNjcmlwdGlvbiI6ICJBcHBseSBsb2NhbCBhdXRvbWF0aWMtdXBkYXRlIHBvbGljeSBvbiBzdXBwb3J0ZWQgdW5tYW5hZ2VkIGVkaXRpb25zLiBNYW51YWwgdXBkYXRlcyByZW1haW4gYXZhaWxhYmxlLiBBIGRhdGVkIHJlc3RvcmF0aW9uIHRhc2sgaXMgcmVxdWlyZWQuIiwKICAgICAgImNhdGVnb3J5IjogIldpbmRvd3MgUmVwYWlyIGFuZCBNYWludGVuYW5jZSIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAidXBkYXRlcyIsCiAgICAgICAgInN1c3BlbmQiCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJGdW5jdGlvbiIsCiAgICAgICJ0YXJnZXRJZCI6ICJ1cGRhdGVzLnN1c3BlbmQiLAogICAgICAicGFyYW1ldGVycyI6IFsKICAgICAgICB7CiAgICAgICAgICAibmFtZSI6ICJtb250aHMiLAogICAgICAgICAgInR5cGUiOiAiSW50ZWdlciIsCiAgICAgICAgICAibGFiZWwiOiAiQ2FsZW5kYXIgbW9udGhzIHRvIHN1c3BlbmQgYXV0b21hdGljIHVwZGF0ZXMiLAogICAgICAgICAgInJlcXVpcmVkIjogdHJ1ZSwKICAgICAgICAgICJkZWZhdWx0IjogMSwKICAgICAgICAgICJtaW5pbXVtIjogMSwKICAgICAgICAgICJtYXhpbXVtIjogMzYsCiAgICAgICAgICAiYWxsb3dlZFZhbHVlcyI6IFtdCiAgICAgICAgfQogICAgICBdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IHRydWUsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbCiAgICAgICAgICAiY21kbGV0OlJlZ2lzdGVyLVNjaGVkdWxlZFRhc2siCiAgICAgICAgXQogICAgICB9LAogICAgICAicmlzayI6ICJIaWdoUmlzayIsCiAgICAgICJjb25maXJtYXRpb24iOiAiVHlwZUNvbW1hbmRJZCIsCiAgICAgICJjb25zZXF1ZW5jZXMiOiAiQXBwbHkgbG9jYWwgYXV0b21hdGljLXVwZGF0ZSBwb2xpY3kgb24gc3VwcG9ydGVkIHVubWFuYWdlZCBlZGl0aW9ucy4gTWFudWFsIHVwZGF0ZXMgcmVtYWluIGF2YWlsYWJsZS4gQSBkYXRlZCByZXN0b3JhdGlvbiB0YXNrIGlzIHJlcXVpcmVkLiBDaGFuZ2VzIHJ1biBvbmx5IGFmdGVyIGNvbmZpcm1hdGlvbjsgc2NoZWR1bGVkIGZlYXR1cmVzIGNyZWF0ZSBwcm90ZWN0ZWQgcmVjb3ZlcnkgZmlsZXMgYW5kIFdpbmRvd3MgdGFza3MuIiwKICAgICAgImNvc3QiOiAiVmFyaWFibGUiLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJVbmF2YWlsYWJsZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJ1cGRhdGVzLnJlc3VtZSIsCiAgICAgICJuYW1lIjogIlJlc3VtZSBwcmV2aW91cyBhdXRvbWF0aWMtdXBkYXRlIHBvbGljeSIsCiAgICAgICJkZXNjcmlwdGlvbiI6ICJSZXN0b3JlIHRoZSBleGFjdCBvcmlnaW5hbCBOb0F1dG9VcGRhdGUgdmFsdWUgb3IgcmVtb3ZlIHRoZSB0b29sYm94LWNyZWF0ZWQgdmFsdWUuIiwKICAgICAgImNhdGVnb3J5IjogIldpbmRvd3MgUmVwYWlyIGFuZCBNYWludGVuYW5jZSIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAidXBkYXRlcyIsCiAgICAgICAgInJlc3VtZSIKICAgICAgXSwKICAgICAgInNvdXJjZUtpbmQiOiAiQnVpbHRJbiIsCiAgICAgICJleGVjdXRpb25UeXBlIjogIkZ1bmN0aW9uIiwKICAgICAgInRhcmdldElkIjogInVwZGF0ZXMucmVzdW1lIiwKICAgICAgInBhcmFtZXRlcnMiOiBbXSwKICAgICAgInJlcXVpcmVzQWRtaW4iOiB0cnVlLAogICAgICAiY29tcGF0aWJpbGl0eSI6IHsKICAgICAgICAibWluaW11bUJ1aWxkIjogMTAyNDAsCiAgICAgICAgImFyY2hpdGVjdHVyZXMiOiBbCiAgICAgICAgICAieDg2IiwKICAgICAgICAgICJ4NjQiCiAgICAgICAgXSwKICAgICAgICAiY2FwYWJpbGl0aWVzIjogW10KICAgICAgfSwKICAgICAgInJpc2siOiAiSGlnaFJpc2siLAogICAgICAiY29uZmlybWF0aW9uIjogIlR5cGVDb21tYW5kSWQiLAogICAgICAiY29uc2VxdWVuY2VzIjogIlJlc3RvcmUgdGhlIGV4YWN0IG9yaWdpbmFsIE5vQXV0b1VwZGF0ZSB2YWx1ZSBvciByZW1vdmUgdGhlIHRvb2xib3gtY3JlYXRlZCB2YWx1ZS4gQ2hhbmdlcyBydW4gb25seSBhZnRlciBjb25maXJtYXRpb247IHNjaGVkdWxlZCBmZWF0dXJlcyBjcmVhdGUgcHJvdGVjdGVkIHJlY292ZXJ5IGZpbGVzIGFuZCBXaW5kb3dzIHRhc2tzLiIsCiAgICAgICJjb3N0IjogIlZhcmlhYmxlIiwKICAgICAgIm5ldHdvcmtBY2Nlc3MiOiAiTm9uZSIsCiAgICAgICJjYW5jZWxsYXRpb24iOiAiVW5hdmFpbGFibGUiCiAgICB9LAogICAgewogICAgICAiaWQiOiAicG93ZXIuY291bnRkb3duIiwKICAgICAgIm5hbWUiOiAiU2NoZWR1bGUgc2h1dGRvd24gLyByZXN0YXJ0IiwKICAgICAgImRlc2NyaXB0aW9uIjogIlNjaGVkdWxlIGEgbG9jYWwgcG93ZXIgYWN0aW9uIGZyb20gb25lIHNlY29uZCB0aHJvdWdoIHNldmVuIGRheXMuIEl0IGNvbnRpbnVlcyBhZnRlciBjbG9zaW5nIHRoZSB0b29sYm94LiBGb3JjZSBjYW4gbG9zZSB1bnNhdmVkIGRhdGEuIiwKICAgICAgImNhdGVnb3J5IjogIlBvd2VyIGFuZCBTY2hlZHVsaW5nIiwKICAgICAgImtleXdvcmRzIjogWwogICAgICAgICJwb3dlciIsCiAgICAgICAgImNvdW50ZG93biIKICAgICAgXSwKICAgICAgInNvdXJjZUtpbmQiOiAiQnVpbHRJbiIsCiAgICAgICJleGVjdXRpb25UeXBlIjogIkZ1bmN0aW9uIiwKICAgICAgInRhcmdldElkIjogInBvd2VyLmNvdW50ZG93biIsCiAgICAgICJwYXJhbWV0ZXJzIjogWwogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogImFjdGlvbiIsCiAgICAgICAgICAidHlwZSI6ICJDaG9pY2UiLAogICAgICAgICAgImxhYmVsIjogIlBvd2VyIGFjdGlvbiIsCiAgICAgICAgICAicmVxdWlyZWQiOiB0cnVlLAogICAgICAgICAgImRlZmF1bHQiOiAiU2h1dGRvd24iLAogICAgICAgICAgIm1pbmltdW0iOiBudWxsLAogICAgICAgICAgIm1heGltdW0iOiBudWxsLAogICAgICAgICAgImFsbG93ZWRWYWx1ZXMiOiBbCiAgICAgICAgICAgICJTaHV0ZG93biIsCiAgICAgICAgICAgICJSZXN0YXJ0IgogICAgICAgICAgXQogICAgICAgIH0sCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAiZHVyYXRpb24iLAogICAgICAgICAgInR5cGUiOiAiSW50ZWdlciIsCiAgICAgICAgICAibGFiZWwiOiAiRHVyYXRpb24iLAogICAgICAgICAgInJlcXVpcmVkIjogdHJ1ZSwKICAgICAgICAgICJkZWZhdWx0IjogNSwKICAgICAgICAgICJtaW5pbXVtIjogMSwKICAgICAgICAgICJtYXhpbXVtIjogNjA0ODAwLAogICAgICAgICAgImFsbG93ZWRWYWx1ZXMiOiBbXQogICAgICAgIH0sCiAgICAgICAgewogICAgICAgICAgIm5hbWUiOiAidW5pdCIsCiAgICAgICAgICAidHlwZSI6ICJDaG9pY2UiLAogICAgICAgICAgImxhYmVsIjogIkR1cmF0aW9uIHVuaXQiLAogICAgICAgICAgInJlcXVpcmVkIjogdHJ1ZSwKICAgICAgICAgICJkZWZhdWx0IjogIk1pbnV0ZXMiLAogICAgICAgICAgIm1pbmltdW0iOiBudWxsLAogICAgICAgICAgIm1heGltdW0iOiBudWxsLAogICAgICAgICAgImFsbG93ZWRWYWx1ZXMiOiBbCiAgICAgICAgICAgICJTZWNvbmRzIiwKICAgICAgICAgICAgIk1pbnV0ZXMiLAogICAgICAgICAgICAiSG91cnMiLAogICAgICAgICAgICAiRGF5cyIKICAgICAgICAgIF0KICAgICAgICB9LAogICAgICAgIHsKICAgICAgICAgICJuYW1lIjogImNsb3N1cmUiLAogICAgICAgICAgInR5cGUiOiAiQ2hvaWNlIiwKICAgICAgICAgICJsYWJlbCI6ICJBcHBsaWNhdGlvbiBjbG9zdXJlIiwKICAgICAgICAgICJyZXF1aXJlZCI6IHRydWUsCiAgICAgICAgICAiZGVmYXVsdCI6ICJOb3JtYWwiLAogICAgICAgICAgIm1pbmltdW0iOiBudWxsLAogICAgICAgICAgIm1heGltdW0iOiBudWxsLAogICAgICAgICAgImFsbG93ZWRWYWx1ZXMiOiBbCiAgICAgICAgICAgICJOb3JtYWwiLAogICAgICAgICAgICAiRm9yY2UiCiAgICAgICAgICBdCiAgICAgICAgfQogICAgICBdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IHRydWUsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbCiAgICAgICAgICAiY21kbGV0OlJlZ2lzdGVyLVNjaGVkdWxlZFRhc2siCiAgICAgICAgXQogICAgICB9LAogICAgICAicmlzayI6ICJIaWdoUmlzayIsCiAgICAgICJjb25maXJtYXRpb24iOiAiVHlwZUNvbW1hbmRJZCIsCiAgICAgICJjb25zZXF1ZW5jZXMiOiAiU2NoZWR1bGUgYSBsb2NhbCBwb3dlciBhY3Rpb24gZnJvbSBvbmUgc2Vjb25kIHRocm91Z2ggc2V2ZW4gZGF5cy4gSXQgY29udGludWVzIGFmdGVyIGNsb3NpbmcgdGhlIHRvb2xib3guIEZvcmNlIGNhbiBsb3NlIHVuc2F2ZWQgZGF0YS4gQ2hhbmdlcyBydW4gb25seSBhZnRlciBjb25maXJtYXRpb247IHNjaGVkdWxlZCBmZWF0dXJlcyBjcmVhdGUgcHJvdGVjdGVkIHJlY292ZXJ5IGZpbGVzIGFuZCBXaW5kb3dzIHRhc2tzLiIsCiAgICAgICJjb3N0IjogIlZhcmlhYmxlIiwKICAgICAgIm5ldHdvcmtBY2Nlc3MiOiAiTm9uZSIsCiAgICAgICJjYW5jZWxsYXRpb24iOiAiVW5hdmFpbGFibGUiCiAgICB9LAogICAgewogICAgICAiaWQiOiAicG93ZXIuY2FuY2VsIiwKICAgICAgIm5hbWUiOiAiQ2FuY2VsIHRvb2xib3ggcG93ZXIgY291bnRkb3duIiwKICAgICAgImRlc2NyaXB0aW9uIjogIkNhbmNlbCBhIHBlbmRpbmcgdG9vbGJveC1vd25lZCBwb3dlciBhY3Rpb24gYmVmb3JlIFdpbmRvd3MgaXMgYXNrZWQgdG8gc2h1dCBkb3duLiBPdGhlciBhcHBsaWNhdGlvbnMnIHNodXRkb3ducyBhcmUgdW50b3VjaGVkLiIsCiAgICAgICJjYXRlZ29yeSI6ICJQb3dlciBhbmQgU2NoZWR1bGluZyIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAicG93ZXIiLAogICAgICAgICJjYW5jZWwiCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJGdW5jdGlvbiIsCiAgICAgICJ0YXJnZXRJZCI6ICJwb3dlci5jYW5jZWwiLAogICAgICAicGFyYW1ldGVycyI6IFtdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IHRydWUsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbXQogICAgICB9LAogICAgICAicmlzayI6ICJTeXN0ZW1Nb2RpZmljYXRpb24iLAogICAgICAiY29uZmlybWF0aW9uIjogIkNvbmZpcm0iLAogICAgICAiY29uc2VxdWVuY2VzIjogIkNhbmNlbCBhIHBlbmRpbmcgdG9vbGJveC1vd25lZCBwb3dlciBhY3Rpb24gYmVmb3JlIFdpbmRvd3MgaXMgYXNrZWQgdG8gc2h1dCBkb3duLiBPdGhlciBhcHBsaWNhdGlvbnMnIHNodXRkb3ducyBhcmUgdW50b3VjaGVkLiBDaGFuZ2VzIHJ1biBvbmx5IGFmdGVyIGNvbmZpcm1hdGlvbjsgc2NoZWR1bGVkIGZlYXR1cmVzIGNyZWF0ZSBwcm90ZWN0ZWQgcmVjb3ZlcnkgZmlsZXMgYW5kIFdpbmRvd3MgdGFza3MuIiwKICAgICAgImNvc3QiOiAiVmFyaWFibGUiLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJVbmF2YWlsYWJsZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJwb3dlci5zdGF0dXMiLAogICAgICAibmFtZSI6ICJQb3dlciBjb3VudGRvd24gc3RhdHVzIiwKICAgICAgImRlc2NyaXB0aW9uIjogIkRpc3BsYXkgcmVjb3JkZWQgdG9vbGJveCBwb3dlciBkZWFkbGluZXMgYW5kIHN0YXRlLiIsCiAgICAgICJjYXRlZ29yeSI6ICJQb3dlciBhbmQgU2NoZWR1bGluZyIsCiAgICAgICJrZXl3b3JkcyI6IFsKICAgICAgICAicG93ZXIiLAogICAgICAgICJzdGF0dXMiCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJGdW5jdGlvbiIsCiAgICAgICJ0YXJnZXRJZCI6ICJwb3dlci5zdGF0dXMiLAogICAgICAicGFyYW1ldGVycyI6IFtdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IGZhbHNlLAogICAgICAiY29tcGF0aWJpbGl0eSI6IHsKICAgICAgICAibWluaW11bUJ1aWxkIjogMTAyNDAsCiAgICAgICAgImFyY2hpdGVjdHVyZXMiOiBbCiAgICAgICAgICAieDg2IiwKICAgICAgICAgICJ4NjQiCiAgICAgICAgXSwKICAgICAgICAiY2FwYWJpbGl0aWVzIjogW10KICAgICAgfSwKICAgICAgInJpc2siOiAiUmVhZE9ubHkiLAogICAgICAiY29uZmlybWF0aW9uIjogIk5vbmUiLAogICAgICAiY29uc2VxdWVuY2VzIjogIlF1ZXJpZXMgbG9jYWwgaW5mb3JtYXRpb24gd2l0aG91dCBhcHBseWluZyByZXBhaXJzLiIsCiAgICAgICJjb3N0IjogIlZhcmlhYmxlIiwKICAgICAgIm5ldHdvcmtBY2Nlc3MiOiAiTm9uZSIsCiAgICAgICJjYW5jZWxsYXRpb24iOiAiQ29vcGVyYXRpdmUiCiAgICB9LAogICAgewogICAgICAiaWQiOiAicG93ZXIuZm9yY2UtcmVzdGFydCIsCiAgICAgICJuYW1lIjogIkZvcmNlIHJlc3RhcnQgbm93IiwKICAgICAgImRlc2NyaXB0aW9uIjogIkltbWVkaWF0ZWx5IHJlcXVlc3QgYSBmb3JjZWQgcmVzdGFydC4gQXBwbGljYXRpb25zIGNsb3NlIHdpdGhvdXQgc2F2aW5nOyB1bnNhdmVkIHdvcmsgY2FuIGJlIGxvc3QuIiwKICAgICAgImNhdGVnb3J5IjogIlBvd2VyIGFuZCBTY2hlZHVsaW5nIiwKICAgICAgImtleXdvcmRzIjogWwogICAgICAgICJwb3dlciIsCiAgICAgICAgImZvcmNlIiwKICAgICAgICAicmVzdGFydCIKICAgICAgXSwKICAgICAgInNvdXJjZUtpbmQiOiAiQnVpbHRJbiIsCiAgICAgICJleGVjdXRpb25UeXBlIjogIkZ1bmN0aW9uIiwKICAgICAgInRhcmdldElkIjogInBvd2VyLmZvcmNlLXJlc3RhcnQiLAogICAgICAicGFyYW1ldGVycyI6IFtdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IHRydWUsCiAgICAgICJjb21wYXRpYmlsaXR5IjogewogICAgICAgICJtaW5pbXVtQnVpbGQiOiAxMDI0MCwKICAgICAgICAiYXJjaGl0ZWN0dXJlcyI6IFsKICAgICAgICAgICJ4ODYiLAogICAgICAgICAgIng2NCIKICAgICAgICBdLAogICAgICAgICJjYXBhYmlsaXRpZXMiOiBbCiAgICAgICAgICAiZXhlOnNodXRkb3duLmV4ZSIKICAgICAgICBdCiAgICAgIH0sCiAgICAgICJyaXNrIjogIkhpZ2hSaXNrIiwKICAgICAgImNvbmZpcm1hdGlvbiI6ICJUeXBlQ29tbWFuZElkIiwKICAgICAgImNvbnNlcXVlbmNlcyI6ICJJbW1lZGlhdGVseSByZXF1ZXN0IGEgZm9yY2VkIHJlc3RhcnQuIEFwcGxpY2F0aW9ucyBjbG9zZSB3aXRob3V0IHNhdmluZzsgdW5zYXZlZCB3b3JrIGNhbiBiZSBsb3N0LiBDaGFuZ2VzIHJ1biBvbmx5IGFmdGVyIGNvbmZpcm1hdGlvbjsgc2NoZWR1bGVkIGZlYXR1cmVzIGNyZWF0ZSBwcm90ZWN0ZWQgcmVjb3ZlcnkgZmlsZXMgYW5kIFdpbmRvd3MgdGFza3MuIiwKICAgICAgImNvc3QiOiAiVmFyaWFibGUiLAogICAgICAibmV0d29ya0FjY2VzcyI6ICJOb25lIiwKICAgICAgImNhbmNlbGxhdGlvbiI6ICJVbmF2YWlsYWJsZSIKICAgIH0sCiAgICB7CiAgICAgICJpZCI6ICJtYWludGVuYW5jZS5tYW5hZ2VkLWNoYW5nZXMiLAogICAgICAibmFtZSI6ICJUb29sYm94IGNoYW5nZXMgYW5kIHJlc3RvcmF0aW9uIHN0YXR1cyIsCiAgICAgICJkZXNjcmlwdGlvbiI6ICJJbnNwZWN0IHJlY29yZGVkIGNoYW5nZXMsIGRlYWRsaW5lcywgbWFudWFsIG1vZGVzLCByZXN0b3JhdGlvbiBmYWlsdXJlcyBhbmQgY29uZmxpY3RzLiIsCiAgICAgICJjYXRlZ29yeSI6ICJXaW5kb3dzIFJlcGFpciBhbmQgTWFpbnRlbmFuY2UiLAogICAgICAia2V5d29yZHMiOiBbCiAgICAgICAgIm1haW50ZW5hbmNlIiwKICAgICAgICAibWFuYWdlZCIsCiAgICAgICAgImNoYW5nZXMiCiAgICAgIF0sCiAgICAgICJzb3VyY2VLaW5kIjogIkJ1aWx0SW4iLAogICAgICAiZXhlY3V0aW9uVHlwZSI6ICJGdW5jdGlvbiIsCiAgICAgICJ0YXJnZXRJZCI6ICJtYWludGVuYW5jZS5tYW5hZ2VkLWNoYW5nZXMiLAogICAgICAicGFyYW1ldGVycyI6IFtdLAogICAgICAicmVxdWlyZXNBZG1pbiI6IGZhbHNlLAogICAgICAiY29tcGF0aWJpbGl0eSI6IHsKICAgICAgICAibWluaW11bUJ1aWxkIjogMTAyNDAsCiAgICAgICAgImFyY2hpdGVjdHVyZXMiOiBbCiAgICAgICAgICAieDg2IiwKICAgICAgICAgICJ4NjQiCiAgICAgICAgXSwKICAgICAgICAiY2FwYWJpbGl0aWVzIjogW10KICAgICAgfSwKICAgICAgInJpc2siOiAiUmVhZE9ubHkiLAogICAgICAiY29uZmlybWF0aW9uIjogIk5vbmUiLAogICAgICAiY29uc2VxdWVuY2VzIjogIlF1ZXJpZXMgbG9jYWwgaW5mb3JtYXRpb24gd2l0aG91dCBhcHBseWluZyByZXBhaXJzLiIsCiAgICAgICJjb3N0IjogIlZhcmlhYmxlIiwKICAgICAgIm5ldHdvcmtBY2Nlc3MiOiAiTm9uZSIsCiAgICAgICJjYW5jZWxsYXRpb24iOiAiQ29vcGVyYXRpdmUiCiAgICB9CiAgXQp9Cg==')) | ConvertFrom-Json
$script:ToolkitVersion = '0.2.1'

$script:ToolkitCustomLoaded = $false
$script:ToolkitCustomCommands = @()
$script:ToolkitCustomNotice = ''
$script:ToolkitConfirmActions = $true
try {
    if ($Version) { Write-Output $script:ToolkitVersion; return }
    Test-ToolkitRegistry $script:ToolkitRegistry
    if ($ManagedJobId) { Invoke-ToolkitManagedWorker -Id $ManagedJobId -Mode $ManagedMode; return }
    if ($WorkerId) { $workerExit = Invoke-ToolkitConsoleWorker $WorkerId $ParameterData -RequireElevation:$RequireElevation -SkipConfirmation:$SkipActionConfirmation; exit $workerExit }
    if ($ParameterData -or $RequireElevation -or $SkipActionConfirmation) { throw 'Worker options require a valid operation ID.' }
    if ($ListCommands) { Get-ToolkitCatalog -IncludeCustom; return }
    if ($Check) {
        foreach ($command in (Get-ToolkitCatalog -IncludeCustom)) {
            $capability = Get-ToolkitCapability $command
            [pscustomobject]@{ Id = $command.id; Source = $command.sourceKind; Available = $capability.Available; RequiresAdmin = $command.requiresAdmin; Detail = $capability.Reason }
        }
        if ($script:ToolkitCustomNotice) { Write-Warning $script:ToolkitCustomNotice }
        return
    }
    if ([Console]::IsInputRedirected) { throw 'Interactive input is unavailable. Use -ListCommands, -Check or -Version; open a console to use the menus.' }
    Start-ToolkitInterface -Basic:$Basic
}
catch { Write-Error -Message $_.Exception.Message -ErrorAction Continue; exit 1 }
