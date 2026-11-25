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
