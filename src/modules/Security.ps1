function Invoke-ToolkitSecurityAction {
    param([string]$TargetId)
    switch ($TargetId) {
        'security.defender' { Defender\Get-MpComputerStatus | Select-Object AMServiceEnabled,AntivirusEnabled,RealTimeProtectionEnabled,AntivirusSignatureLastUpdated,QuickScanEndTime }
        'security.firewall' { NetSecurity\Get-NetFirewallProfile | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction }
        'security.users' { Get-CimInstance Win32_UserAccount -Filter 'LocalAccount=True' -OperationTimeoutSec 15 | Select-Object Name,Disabled,Lockout,Status }
        default { throw 'Unknown security operation.' }
    }
}
