# Windows Engineering Toolkit 0.2.1

A portable Windows PowerShell toolbox with 66 built-in diagnostics, controls and administrative shortcuts, plus local custom PowerShell and batch scripts. The core has no runtime dependencies, telemetry, or automatic updates. Requested persistent controls create protected local recovery files and Windows scheduled tasks.

## Latest build

**0.2.1, with the refined terminal interface**, published from the current project on November 26, 2026. It retains all 66 built-in commands, the existing execution engine, custom scripts, and session-only confirmation settings.

Download [Toolkit.ps1](https://raw.githubusercontent.com/DeepHorizon69/toolX/main/dist/Toolkit.ps1) and its [SHA-256 checksum](https://raw.githubusercontent.com/DeepHorizon69/toolX/main/dist/Toolkit.ps1.sha256), or clone this repository. Save the script locally before running it. Only the PS1 is required at runtime; keep your own `Scripts` folder beside it when needed.

Compare the downloaded script with the checksum file:

```powershell
Get-FileHash -LiteralPath .\Toolkit.ps1 -Algorithm SHA256
Get-Content -LiteralPath .\Toolkit.ps1.sha256
```

The current build passes 140 automated tests and PowerShell 5.1 parsing/static analysis. Terminal smoke tests cover native colors, true color, basic menus, search, details, a harmless diagnostic and confirmation cancellation. The working-set target remains unmet, and the complete Windows/terminal compatibility matrix remains pending. See [verification](docs/Verification.md), [UI measurements and limitations](docs/UI-Refinement.md), and [changes](CHANGELOG.md).

## Run

Open Windows PowerShell 5.1 in a console and run:

```powershell
.\dist\Toolkit.ps1
.\dist\Toolkit.ps1 -Basic
.\dist\Toolkit.ps1 -ListCommands
.\dist\Toolkit.ps1 -Check
.\dist\Toolkit.ps1 -Version
```

The single file `dist\Toolkit.ps1` runs independently of this repository. Copy it to a local drive or USB. Script execution must already be permitted by your organization and Windows policy. The toolkit never changes execution policy, unblocks scripts, or bypasses application control. Launch it as a standard user; only selected operations request elevation.

Use Up/Down and Enter to browse, Escape to return, `/` to search, and `R` to refresh custom scripts. Details show risk, permission, cost, and consequences before running. The basic menu uses numbers, `back`, `cancel`, and `/search text`.

The terminal interface uses a command list and metadata preview on wide screens, a stacked layout on narrower screens, and numbered menus below 60 columns or 12 rows. Resize takes effect on the next key without resetting selection or input. Home/End and PageUp/PageDown navigate lists and completed diagnostic output. Command rows show Read, Modify, or High risk labels; administrator inheritance and disabled confirmations remain visible.

Color uses the supplied technical palette on recognized true-color terminals and native console colors elsewhere. Chrome is ASCII; uncertain Unicode cells appear as `\uXXXX` in positioned views, while numbered menus and operation consoles retain Unicode text. Long details and warnings use complete scrollback text when they cannot fit. No terminal font, window dimensions, encoding, or persistent settings are changed.

## Confirmation toggle

Open **Settings -> Action confirmations**. Confirmations start **ON** on every launch. To switch them off, read the warning and type **OFF** once. The setting applies to every modifying/high-risk action and every custom script, including the Task Manager yes prompt. The menu shows **ACTION CONFIRMATIONS OFF**, and action buttons say **Run now** while disabled. Switch the same setting back on at any time.

With confirmations off, selecting Run may immediately delete files, change security/update settings, or force a restart. This preference lasts only for the current toolkit session. It does not bypass Windows UAC, administrator permissions, capability/argument checks, recovery preflight, or a custom script's own prompts. Separate operation consoles and their final output acknowledgement remain available.

## Add your scripts

Place `.ps1`, `.bat`, or `.cmd` files in a `Scripts` folder beside the **copy of Toolkit.ps1 you run**, or one folder level below it. For the source entrypoint `src\Main.ps1`, use the repository's `Scripts` folder.

```text
Toolkit.ps1
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

Scripts run in their own console and handle their own prompts/configuration. This version supplies no arguments. Keep helper entrypoints in `_support` or deeper folders. Invalid metadata disables its entry rather than falling back to defaults. Custom scripts require typed confirmation when Action confirmations is ON. They run with the displayed Windows permissions; separate processes are not a sandbox. Scripts can use networking, change files, or depend on software not included with Windows.

The original script and directory are preserved. Its directory is its working directory. PowerShell scripts retain `$PSScriptRoot`; batch scripts retain `%~dp0`. External dependencies are not downloaded or installed. If the main toolkit is already elevated, its children inherit elevation and the interface states this.

## Troubleshooting and scheduled controls

Version 0.2 adds full specifications, recent critical/error events, problem devices, battery indicators, update diagnostics, and explicit-target gateway/DNS/TCP testing. Missing or denied specification sections are reported independently. No report file or update scan is created automatically.

Firewall and Defender controls offer Enable, timed Disable (default 30 minutes, 1-1440 minutes), and manual Disable. Firewall profiles are selected explicitly. Manual mode has no automatic restoration. Restore returns toolbox-owned changes to their original state, including mixed firewall profiles. Defender control changes real-time protection only; it does not uninstall Defender or bypass Tamper Protection.

Automatic-update suspension accepts 1-36 calendar months on supported unmanaged Pro, Enterprise and Education editions. It preserves the original `NoAutoUpdate` policy value and registers dated restoration. Manual Windows updates remain available. Home, detected organization management, conflicting policy and failed recovery preflight are reported rather than overridden. This is not a promise that servicing or an administrator cannot change the policy.

Power and Scheduling offers shutdown/restart countdowns, status, cancellation and Force Restart Now. Choose seconds, minutes, hours or days, with a total of one second through seven days. Countdowns survive closing the toolbox. Normal application closure is the default; Force may lose unsaved data. Missed deadlines (more than 60 seconds late) or a changed boot session expire without a power request. The tool does not cancel shutdowns scheduled by other applications. Normal applications can still block a shutdown request.

Persistent features require the standalone `Toolkit.ps1`. Only after selecting and confirming a control does the toolkit prepare `%ProgramData%\WindowsEngineeringToolkit`, an administrator-protected versioned helper and job snapshots. Recovery runs as the confirming administrator using S4U (no stored password). A harmless scheduled preflight must pass under that account's existing execution policy before settings are changed. Timed restoration survives removing the original USB drive, but depends on Windows scheduling, the account and applicable policy. It does not wake the computer. Restore tasks can catch up on resume/startup; power actions do not replay after reboot.

Use **Toolbox changes and restoration status** to inspect deadlines, last task results and conflicts. Failed restoration records are retained for retry. External changes are not overwritten automatically. Do not delete recovery files or remove the task account while changes are active. Changing helper code requires a new version; active jobs keep their pinned helper. No service is installed and execution policy is never modified.

## Develop and build

Development-only tools are pinned to Pester 5.7.1 and PSScriptAnalyzer 1.24.0. Prepare them explicitly (downloads from PowerShell Gallery into ignored `.tools`), then build:

```powershell
.\tools\Initialize-Development.ps1
.\Build.ps1
.\src\Main.ps1
```

Build checks PowerShell 5.1 syntax, registry policy, static analysis, unit tests, real harmless interpreter fixtures, and standalone execution before updating `dist`. It generates a deterministic UTF-8-with-BOM script below 500,000 bytes and a SHA-256 file. It never downloads dependencies automatically or executes real repairs. A checksum detects changes; it does not establish publisher identity.

See [architecture](docs/Architecture.md), [testing](docs/Testing.md), and the [release checklist](docs/Release-Checklist.md). Compatibility targets are Windows 10 x86/x64 and Windows 11 x64. A target is not a claim that every environment has been tested; verification evidence is recorded separately.
