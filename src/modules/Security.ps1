function Invoke-ToolkitSecurityAction {
    param([string]$TargetId, [hashtable]$Values = @{})
    switch ($TargetId) {
        'security.defender' { Defender\Get-MpComputerStatus | Select-Object AMServiceEnabled,AntivirusEnabled,RealTimeProtectionEnabled,AntivirusSignatureLastUpdated,QuickScanEndTime }
        'security.firewall' { NetSecurity\Get-NetFirewallProfile | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction }
        'security.users' { Get-CimInstance Win32_UserAccount -Filter 'LocalAccount=True' -OperationTimeoutSec 15 | Select-Object Name,Disabled,Lockout,Status }
        'security.local-admins' {
            $sid = 'S-1-5-32-544'
            if (Get-Command -Name 'Get-LocalGroupMember' -ErrorAction SilentlyContinue) {
                return (Get-LocalGroupMember -SID $sid -ErrorAction Stop | Select-Object Name,ObjectClass,PrincipalSource)
            }
            $account = (New-Object Security.Principal.SecurityIdentifier($sid)).Translate([Security.Principal.NTAccount]).Value
            $groupName = ($account -split '\\')[-1]
            $group = [ADSI]("WinNT://./$groupName,group")
            foreach ($member in @($group.Invoke('Members'))) {
                $path = $member.GetType().InvokeMember('AdsPath', 'GetProperty', $null, $member, $null)
                $class = $member.GetType().InvokeMember('Class', 'GetProperty', $null, $member, $null)
                [pscustomobject]@{ Name = $path; ObjectClass = $class; PrincipalSource = 'WinNT' }
            }
        }
        'security.certificates' {
            $days = 90; if ($Values -and $Values.ContainsKey('days')) { $days = [int]$Values.days }
            $now = Get-Date
            $cutoff = $now.AddDays($days)
            $results = New-Object 'Collections.Generic.List[object]'
            foreach ($store in @('Cert:\LocalMachine\My','Cert:\CurrentUser\My')) {
                foreach ($cert in (Get-ChildItem -Path $store -ErrorAction SilentlyContinue)) {
                    if ($cert.NotAfter -le $cutoff) {
                        $remaining = [int][Math]::Floor(($cert.NotAfter - $now).TotalDays)
                        $status = 'ExpiringSoon'; if ($cert.NotAfter -lt $now) { $status = 'Expired' }
                        $results.Add([pscustomobject]@{
                            Store = $store; Status = $status; NotAfter = $cert.NotAfter
                            DaysRemaining = $remaining; Subject = $cert.Subject; Thumbprint = $cert.Thumbprint
                        })
                    }
                }
            }
            if (-not $results.Count) { return "No personal certificates are expired or expiring within $days days." }
            $results | Sort-Object NotAfter | Select-Object -First 100
        }
        default { throw 'Unknown security operation.' }
    }
}
