# TOOLX Windows Edition (Alpha 0.2.3) | by ALSA

**Alpha 0.2.3, major change:** TOOLX has been rewritten in C#/.NET with a WPF GUI, CLI, compiled recovery worker and IT support reports. Source is in [`native/`](native/). See [build/run instructions](docs/Native-Rewrite.md) and [verification status](docs/Native-Verification.md). Run `native\publish.cmd` to generate self-contained x86/x64 ZIP packages under ignored `artifacts/`. This remains a preview while native Windows-version, UAC and recovery acceptance checks are completed.

## Legacy PowerShell distribution (Alpha 0.2.2)

A portable Windows PowerShell toolbox with graphical and terminal interfaces, 91 built-in diagnostics, controls and administrative shortcuts, plus local custom PowerShell and batch scripts. There are no third-party runtime downloads, telemetry, or automatic updates. Requested persistent controls create protected local recovery files and Windows scheduled tasks.

## Legacy build

**Current build: TOOLX Windows Edition Alpha 0.2.2 (by ALSA), compact portable executables**, November 26, 2026. The `dist` folder ships two standalone `.exe` binaries (`Toolkit.exe` for GUI and `Toolkit.CLI.exe` for terminal) plus a portable `Scripts` folder (`IT-Support` and `Tinkerer`). Each launch extracts its embedded script to a unique session folder in `%TEMP%`, verifies its SHA-256, and attempts to remove the folder on exit. Explicitly requested persistent controls also create the recovery files and scheduled tasks described below.

Compare the executables against their SHA-256 checksum files:

```powershell
Get-FileHash -LiteralPath .\Toolkit.exe, .\Toolkit.CLI.exe -Algorithm SHA256
Get-Content -LiteralPath .\Toolkit.exe.sha256, .\Toolkit.CLI.exe.sha256
```

The latest verification passed all 203 Pester tests after explicitly loading the ZIP assembly, parsed 52 PowerShell files without errors, and found no analyzer warnings or errors in the 31 build-gate files. Both EXE checksums match their published checksum files. The importer has three confirmed open issues; see [known importer issues](docs/Script-Publishing.md#known-importer-issues) before importing. Earlier read-only GUI dispatcher checks, unverified desktop/platform scenarios, and the test setup caveat are recorded in [verification](docs/Verification.md).

## Run

- **GUI (default):** Double-click `dist\Toolkit.exe` (or run `.\dist\Toolkit.exe`). Click **Terminal** in the top bar or run `.\dist\Toolkit.exe -Terminal` to launch the terminal interface. See the [GUI guide](docs/GUI.md).
- **Terminal (native console):** Run `.\dist\Toolkit.CLI.exe` from Windows Terminal, PowerShell, or Command Prompt:

```powershell
.\dist\Toolkit.CLI.exe
.\dist\Toolkit.CLI.exe -Basic
.\dist\Toolkit.CLI.exe -ListCommands
.\dist\Toolkit.CLI.exe -Check
.\dist\Toolkit.CLI.exe -Version
.\dist\Toolkit.CLI.exe -Gui
.\dist\Toolkit.CLI.exe -ImportLocal 'C:\MyTools\MyScript.ps1' -ImportFolder IT-Support
.\dist\Toolkit.CLI.exe -ImportUrl https://example.com/Tool.ps1 -ImportSha256 <64-HEX>
```

Both executables run independently without a separate `Toolkit.ps1` file. Copy `Toolkit.exe` and/or `Toolkit.CLI.exe` (plus your `Scripts` folder when needed) to a local drive or USB. Script execution must already be permitted by Windows policy. The toolkit never installs services, changes execution policy, unblocks scripts, or leaves runtime files in `%LocalAppData%` or the registry.

## Import and publish scripts

Use **Import** in the GUI sidebar (or **Custom Scripts -> [Import script]** in the terminal, or `-ImportLocal` / `-ImportUrl` in `Toolkit.CLI.exe`) to import local `.ps1`/`.bat`/`.cmd`/`.zip` files, `https://` script URLs, or published `manifest.json` catalogs into your portable `Scripts` folder. See [script publishing](docs/Script-Publishing.md).

Use Up/Down and Enter to browse, Escape to return, `/` to search, and `R` to refresh custom scripts. Details show risk, permission, cost, and consequences before running. The basic menu uses numbers, `back`, `cancel`, and `/search text`.

The terminal interface uses a command list and metadata preview on wide screens, a stacked layout on narrower screens, and numbered menus below 60 columns or 12 rows. Resize takes effect on the next key without resetting selection or input. Home/End and PageUp/PageDown navigate lists and completed diagnostic output. Command rows show Read, Modify, or High risk labels; administrator inheritance and disabled confirmations remain visible.

Color uses the supplied technical palette on recognized true-color terminals and native console colors elsewhere. Chrome is ASCII; uncertain Unicode cells appear as `\uXXXX` in positioned views, while numbered menus and operation consoles retain Unicode text. Long details and warnings use complete scrollback text when they cannot fit. No terminal font, window dimensions, encoding, or persistent settings are changed.

## Confirmation toggle

Open **Settings -> Action confirmations**. Confirmations start **ON** on every launch. To switch them off, read the warning, then type **OFF** in the terminal or use the GUI's two-step disable confirmation. The setting applies to every modifying/high-risk action and every custom script, including the Task Manager yes prompt. The menu shows **ACTION CONFIRMATIONS OFF**, and action buttons say **Run now** while disabled. Switch the same setting back on at any time.

With confirmations off, selecting Run may immediately delete files, change security/update settings, or force a restart. This preference lasts only for the current toolkit session. It does not bypass Windows UAC, administrator permissions, capability/argument checks, recovery preflight, or a custom script's own prompts. Separate operation consoles and their final output acknowledgement remain available.

## Add your scripts

Place `.ps1`, `.bat`, or `.cmd` files in a `Scripts` folder beside `Toolkit.exe` or `Toolkit.CLI.exe`, either directly inside `Scripts` or one subfolder below it. For the source entrypoint `src\Main.ps1`, use the repository's `Scripts` folder.

```text
Toolkit.exe
Toolkit.CLI.exe
Scripts/
  QuickCheck.ps1
  Network/
    Check.cmd
    Check.cmd.json
    _support/
      settings.txt
```

Open Custom Scripts and refresh. A JSON file is optional; the complete script filename plus `.json` associates it unambiguously:

```json
{
  "schemaVersion": 1,
  "name": "Network check",
  "description": "My local network troubleshooting script.",
  "requiresAdmin": false,
  "enabled": true
}
```

Scripts run in their own console and handle their own prompts/configuration. This version supplies no arguments. Keep helper entrypoints in `_support` or deeper folders. Discovery disables entries with invalid metadata. The importer currently skips oversized local metadata, so check the [importer limitations](docs/Script-Publishing.md#known-importer-issues) when copying scripts through Import. Custom scripts require typed confirmation when Action confirmations is ON. They run with the displayed Windows permissions; separate processes are not a sandbox. Scripts can use networking, change files, or depend on software not included with Windows.

The original script and directory are preserved. Its directory is its working directory. PowerShell scripts retain `$PSScriptRoot`; batch scripts retain `%~dp0`. External dependencies are not downloaded or installed. If the main toolkit is already elevated, its children inherit elevation and the interface states this.

## Troubleshooting and scheduled controls

Version 0.2 adds full specifications, recent critical/error events, problem devices, battery indicators, update diagnostics, and explicit-target gateway/DNS/TCP testing. Missing or denied specification sections are reported independently. No report file or update scan is created automatically.

Open **System Information -> Full specifications -> Run** to choose a specification scope. Enter `Full` (or press Enter for the default), `Hardware`, `Firmware`, `Windows`, `Storage`, or `Network`. Only providers for the selected scope are queried; results appear in the terminal.

Specification results use compact device blocks arranged across the available terminal width. Wider windows show additional columns; narrow windows show one column. Long values wrap without clipping, capacities use GiB/MiB, and repeated devices are numbered. Resize the completed report to reflow the columns on the next key. Up/Down, PageUp/PageDown and Home/End still scroll longer reports. Basic mode prints the same layout using the width available when the result completes.

- **Full:** all existing specification sections.
- **Hardware:** computer, CPU, RAM, GPU, motherboard, physical disks, network adapters and battery indicators.
- **Firmware:** motherboard identity/version and BIOS information reported by Windows. This does not enumerate firmware for every device.
- **Windows:** Windows version/build/architecture/boot time and computer information.
- **Storage:** physical disks, partitions and volumes, including available space.
- **Network:** network adapter identity, connection name, enabled state and reported link speed.

Firewall and Defender controls offer Enable, timed Disable (default 30 minutes, 1-1440 minutes), and manual Disable. Firewall profiles are selected explicitly. Manual mode has no automatic restoration. Restore returns toolbox-owned changes to their original state, including mixed firewall profiles. Defender control changes real-time protection only; it does not uninstall Defender or bypass Tamper Protection.

Automatic-update suspension accepts 1-36 calendar months on supported unmanaged Pro, Enterprise and Education editions. It preserves the original `NoAutoUpdate` policy value and registers dated restoration. Manual Windows updates remain available. Home, detected organization management, conflicting policy and failed recovery preflight are reported rather than overridden. This is not a promise that servicing or an administrator cannot change the policy.

Power and Scheduling offers shutdown/restart countdowns, status, cancellation and Force Restart Now. Choose seconds, minutes, hours or days, with a total of one second through seven days. Countdowns survive closing the toolbox. Normal application closure is the default; Force may lose unsaved data. Missed deadlines (more than 60 seconds late) or a changed boot session expire without a power request. The tool does not cancel shutdowns scheduled by other applications. Normal applications can still block a shutdown request.

Persistent features use the standalone script embedded in either executable. Only after selecting and confirming a control does the toolkit prepare `%ProgramData%\WindowsEngineeringToolkit`, an administrator-protected versioned helper and job snapshots. Recovery runs as the confirming administrator using S4U (no stored password). A harmless scheduled preflight must pass under that account's existing execution policy before settings are changed. Timed restoration survives removing the original USB drive, but depends on Windows scheduling, the account and applicable policy. It does not wake the computer. Restore tasks can catch up on resume/startup; power actions do not replay after reboot.

Use **Toolbox changes and restoration status** to inspect deadlines, last task results and conflicts. Failed restoration records are retained for retry. External changes are not overwritten automatically. Do not delete recovery files or remove the task account while changes are active. Changing helper code requires a new version; active jobs keep their pinned helper. No service is installed and execution policy is never modified.

## Develop and build

Development-only tools are pinned to Pester 5.7.1 and PSScriptAnalyzer 1.24.0. GUI launcher compilation also uses the installed .NET Framework C# compiler. Prepare the pinned tools explicitly (downloads from PowerShell Gallery into ignored `.tools`), then build in Windows PowerShell 5.1 STA:

```powershell
.\tools\Initialize-Development.ps1
.\Build.ps1
.\src\Main.ps1
```

Build checks PowerShell 5.1 syntax, registry policy, static analysis, unit tests, real harmless interpreter fixtures, and standalone execution before updating `dist`. It stages a deterministic UTF-8-with-BOM script below 500,000 bytes in `.build`, embeds it into the two executables, and publishes the EXEs and their SHA-256 files to `dist`. It never downloads dependencies automatically or executes real repairs. A checksum detects changes; it does not establish publisher identity.

Generated test results, logs, previews and development modules stay in ignored local folders. The repository includes test source files so developers can reproduce the checks; see [testing](docs/Testing.md) for the clean-shell ZIP assembly setup.

See [architecture](docs/Architecture.md), [testing](docs/Testing.md), and the [release checklist](docs/Release-Checklist.md). Compatibility targets are Windows 10 x86/x64 and Windows 11 x64. A target is not a claim that every environment has been tested; verification evidence is recorded separately.
