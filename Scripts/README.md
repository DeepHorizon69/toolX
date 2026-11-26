# Local scripts

For source execution through `src/Main.ps1`, put custom scripts here. For the portable release, copy or create scripts inside a `Scripts` folder beside `Toolkit.exe` or `Toolkit.CLI.exe` (the repository's release copy is `dist/Scripts`).

Included starter folders (`IT-Support` and `Tinkerer`) provide editable `.ps1` utilities with companion `.ps1.json` metadata:
- `IT-Support/Export-SupportReport.ps1`: Export a timestamped diagnostic summary `.txt` file for support tickets.
- `IT-Support/Show-WifiPassword.ps1`: Interactively inspect the security key of one selected saved Wi-Fi profile.
- `Tinkerer/Switch-PowerPlan.ps1`: View and switch the active Windows power plan interactively.
- `Tinkerer/Inspect-PortOwner.ps1`: Inspect the owning process path and command line for a TCP/UDP port, with optional confirmed termination.
- `Tinkerer/Launch-WinUtil.ps1`: Download and launch the upstream Chris Titus Tech Windows Utility (`https://christitus.com/win`) after explicit confirmation.
- `Tinkerer/Launch-MAS.ps1`: Download and open the interactive Microsoft Activation Scripts menu (`https://massgrave.dev/`, launcher: `https://get.activated.win`) with administrator permissions after typing `yes`. This script-owned confirmation remains required when toolkit confirmations are off.

Use `.ps1`, `.bat`, or `.cmd` in this folder or one immediate subfolder. Keep supporting files in `_support`. Refresh Custom Scripts in the toolbox (`F5` or **Refresh scripts**). Optional metadata uses the full script filename plus `.json`. See the root README for the format.

Alpha 0.2.2 has known importer issues: use absolute local source paths, avoid importing over existing scripts, and verify that local metadata is a regular file no larger than 64 KiB before importing. See [script publishing](../docs/Script-Publishing.md#known-importer-issues) for details.
