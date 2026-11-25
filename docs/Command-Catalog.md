# Built-in command catalog (v0.2)

66 built-in entries. Runtime availability depends on Windows features, edition, policy and permissions. Read-only describes intent; Windows may write operational logs. Administrative interfaces allow changes outside toolkit control.

| ID | Name | Administrator | Risk | Cost |
|---|---|---|---|---|
| system.os | Operating system | Current token / external tool | ReadOnly | Quick |
| system.computer | Computer information | Current token / external tool | ReadOnly | Quick |
| system.updates | Installed updates | Current token / external tool | ReadOnly | Variable |
| system.uptime | System uptime | Current token / external tool | ReadOnly | Quick |
| system.environment | Environment information | Current token / external tool | ReadOnly | Quick |
| system.locale | Locale and time zone | Current token / external tool | ReadOnly | Quick |
| network.ip | IP configuration | Current token / external tool | ReadOnly | Quick |
| network.ping | Ping | Current token / external tool | ReadOnly | Variable |
| network.trace | Traceroute | Current token / external tool | ReadOnly | Variable |
| network.loss | Packet loss test | Current token / external tool | ReadOnly | Variable |
| network.dns | DNS lookup | Current token / external tool | ReadOnly | Variable |
| network.arp | ARP table | Current token / external tool | ReadOnly | Quick |
| network.routes | Routing table | Current token / external tool | ReadOnly | Quick |
| network.connections | Network connections | Current token / external tool | ReadOnly | Quick |
| network.port | TCP port test | Current token / external tool | ReadOnly | Variable |
| network.adapters | Network adapters | Current token / external tool | ReadOnly | Quick |
| network.flush-dns | Flush DNS cache | Required | SystemModification | Quick |
| hardware.cpu | CPU information | Current token / external tool | ReadOnly | Quick |
| hardware.memory | RAM information | Current token / external tool | ReadOnly | Quick |
| hardware.gpu | GPU information | Current token / external tool | ReadOnly | Quick |
| hardware.board | Motherboard information | Current token / external tool | ReadOnly | Quick |
| hardware.bios | BIOS information | Current token / external tool | ReadOnly | Quick |
| hardware.disks | Physical disk information | Current token / external tool | ReadOnly | Quick |
| hardware.disk-health | Storage health indicators | Required | ReadOnly | Variable |
| storage.layout | Partition layout | Current token / external tool | ReadOnly | Quick |
| storage.volumes | Volume information | Current token / external tool | ReadOnly | Quick |
| storage.space | Available disk space | Current token / external tool | ReadOnly | Quick |
| storage.hash | Verify file checksum | Current token / external tool | ReadOnly | Variable |
| storage.management | Disk Management | Current token / external tool | HighRisk | Quick |
| processes.list | Running processes | Current token / external tool | ReadOnly | Quick |
| processes.resource-monitor | Resource Monitor | Current token / external tool | SystemModification | Quick |
| processes.task-manager | Task Manager | Current token / external tool | SystemModification | Quick |
| processes.services | Windows services | Current token / external tool | ReadOnly | Quick |
| processes.startup | Startup programs | Current token / external tool | ReadOnly | Quick |
| processes.events | Event Viewer | Current token / external tool | SystemModification | Quick |
| repair.sfc-verify | SFC verification | Required | ReadOnly | Heavy |
| repair.sfc | SFC repair | Required | SystemModification | Heavy |
| repair.dism-check | DISM quick health check | Required | SystemModification | Quick |
| repair.dism-scan | DISM health scan | Required | SystemModification | Heavy |
| repair.dism-restore | DISM repair (local sources) | Required | SystemModification | Heavy |
| repair.chkdsk | Read-only filesystem check | Required | ReadOnly | Heavy |
| repair.winsock | Reset Winsock | Required | HighRisk | Quick |
| repair.temp | Preview temporary-file cleanup | Current token / external tool | HighRisk | Variable |
| security.defender | Windows Defender status | Required | ReadOnly | Quick |
| security.firewall | Firewall status | Current token / external tool | ReadOnly | Quick |
| security.users | Local user accounts | Current token / external tool | ReadOnly | Quick |
| security.devices | Device Manager | Current token / external tool | HighRisk | Quick |
| security.computer-management | Computer Management | Current token / external tool | HighRisk | Quick |
| security.settings | Windows security settings | Current token / external tool | SystemModification | Quick |
| system.full-specs | Full specifications | Current token / external tool | ReadOnly | Heavy |
| troubleshooting.events | Recent critical and error events | Current token / external tool | ReadOnly | Variable |
| troubleshooting.devices | Problem devices | Current token / external tool | ReadOnly | Variable |
| troubleshooting.battery | Battery health indicators | Current token / external tool | ReadOnly | Variable |
| troubleshooting.updates | Windows Update diagnostics | Current token / external tool | ReadOnly | Variable |
| troubleshooting.connectivity | Connectivity diagnostic | Current token / external tool | ReadOnly | Variable |
| security.firewall-control | Firewall enable / disable | Required | HighRisk | Variable |
| security.firewall-restore | Restore toolbox firewall changes | Required | HighRisk | Variable |
| security.defender-control | Defender real-time protection | Required | HighRisk | Variable |
| security.defender-restore | Restore toolbox Defender change | Required | HighRisk | Variable |
| updates.suspend | Suspend automatic updates (1-36 months) | Required | HighRisk | Variable |
| updates.resume | Resume previous automatic-update policy | Required | HighRisk | Variable |
| power.countdown | Schedule shutdown / restart | Required | HighRisk | Variable |
| power.cancel | Cancel toolbox power countdown | Required | SystemModification | Variable |
| power.status | Power countdown status | Current token / external tool | ReadOnly | Variable |
| power.force-restart | Force restart now | Required | HighRisk | Variable |
| maintenance.managed-changes | Toolbox changes and restoration status | Current token / external tool | ReadOnly | Variable |

Metadata lives in `src/config/commands.json`. Target policies and handlers must be updated together for new capabilities. The TUI needs no command-specific dispatch changes. Custom scripts occupy their own namespace.
