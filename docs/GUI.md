# TOOLX Windows Edition (Alpha 0.2.2, by ALSA) - Portable GUI

Open `dist/Toolkit.exe` (single portable executable with no permanent installation). Keep your `Scripts` folder beside `Toolkit.exe` when copying it to another PC or USB drive. `dist/Toolkit.CLI.exe` provides the standalone production terminal executable, or select **Terminal** in the GUI top bar (or run `Toolkit.exe -Terminal`).

The GUI requires Windows PowerShell 5.1, .NET Framework WPF and permission to run local PowerShell scripts. At launch, `Toolkit.exe` extracts its embedded script into a unique temporary session folder under `%TEMP%`, verifies its SHA-256, and passes `-AppRoot` pointing to the executable's own directory. The host retries temporary-folder cleanup when the session exits. Startup adds no permanent cache, installer, web view, telemetry or settings file. Explicitly requested persistent controls create their documented protected recovery files and scheduled tasks.

## Using the window

- Browse usage-grouped categories (**Inspect and monitor**, **Troubleshoot and repair**, **Security and power**, **Custom and external**) or type a literal search (`Ctrl+K` or `Ctrl+F`), and clear search with the inline clear button or `Esc`. Clearing or changing search clears the previous selection so Run cannot target a hidden old command.
- Toggle the command library sidebar (`Ctrl+B` or the top-left button) to give wide diagnostic output or multi-column specifications full window width.
- From the initial workbench screen, start common read-only checks directly (`Full specifications`, `IP configuration`, `Available disk space`, `Critical and error events`).
- Review command ID, risk/privilege/cost/route tags and consequences. Choice parameters use dropdowns; other values use labeled text fields with inline requirements, defaults and the same validation as the terminal. Irrelevant security-control fields are hidden, and parameter panels collapse when a command takes no parameters.
- Run ordinary diagnostics inside the window (`Ctrl+Enter` or **Run**). Specifications are selectable device blocks that reflow into columns; other output is selectable, bounded monospace text. Use **Copy** in the viewport header to copy the active output or specification blocks to the clipboard. Cancel (`Esc` or **Cancel**) is available only for an active GUI diagnostic.
- Administrator queries, modifications, external management interfaces and custom scripts open the existing operation console. Prompts and detailed results remain there. The GUI reports when it closes without claiming a successful repair.
- Use **Import** in the sidebar footer to import `.ps1`/`.bat`/`.cmd`/`.zip` files, `https://` script URLs, or published `manifest.json` catalogs into `Scripts` beside the executable. Refresh scripts (`F5` or **Refresh**) reloads local metadata without executing a script.
- **Terminal** in the top bar launches the standalone terminal interface in a separate console window.
- **Settings** controls the session-only confirmation preference. Disabling requires confirming twice via the two-step button confirmation (`Disable confirmations (1/2)` -> `Confirm disable (2/2)`) after reading the warning; cancelling keeps the current setting. A new toolkit launch starts ON. UAC and worker validation remain independent.

Only one operation runs at a time. Navigation, parameters, quick diagnostics, import, refresh and Settings are disabled while it is active. The window itself stays available for layout, sidebar toggling and cancellation. Closing during a GUI diagnostic requests cancellation and waits asynchronously for cleanup; closing while an independent operation console is open leaves it running.

The sidebar can be resized with its divider or collapsed cleanly. Labels and values wrap, long forms scroll inside custom dark scrollbars, and specification columns adapt to the result width. Native keyboard navigation and selection/copy are retained. Focus and status are visible without relying solely on color. The application applies native dark title bar attributes via DWM when supported, adopts Windows High Contrast colors on activation, and respects the system client-area animation preference on the progress indicator. Physical DPI and high-contrast transitions have not yet been verified.

## Implementation and verification

The GUI is bundled in `src/ui/Gui.ps1`; the compact production host source is `src/launcher/ToolkitHost.cs` (compiled into `Toolkit.exe` and `Toolkit.CLI.exe`). WPF is loaded only when constructing a GUI. `-Gui` cannot be combined with other non-AppRoot entrypoint options. The GUI consumes the same command registry, parameter validators, capabilities, background worker, structured specifications and confirmed console launcher.

A dispatcher timer runs every 100 ms only while work is active, updating elapsed runtime on the status bar without extra timers or animation loops. Diagnostic timeouts match the terminal: 60 seconds normally, 180 seconds for full specifications, and no fixed deadline for file hashing. Cancellation remains cooperative where the underlying operation requires it. GUI text retention is limited to 2,000 lines/1 MiB; specification records retain the engine's 4,096-record bound. Truncation remains explicit.

Build uses the installed .NET Framework compiler, embeds GZip-compressed `Toolkit.ps1` with SHA-256 verification into `Toolkit.exe` and `Toolkit.CLI.exe`, runs all tests and updates `dist` only after success. SHA-256 files cover both executables. A checksum detects changed bytes; it does not establish publisher identity.

Run `tools/Test-ToolkitGui.ps1` for a development-only dispatcher/render check. It creates PNG previews under ignored `.build/gui-preview` (welcome, parameters, high-risk, wide/narrow specifications, diagnostic output, settings and import) and executes only full specification and environment diagnostics.

The latest review passed 203 automated tests after explicitly loading the ZIP assembly and verified current EXE sizes/checksums and staged bundle consistency. Earlier verification exercised real read-only GUI dispatcher diagnostics and rendered wide/narrow previews; the current documentation review did not repeat that harness. Physical mouse/keyboard click-through, Windows 10 x86/x64, actual monitor DPI, real high-contrast transitions and UAC interactions remain unverified. The three importer defects remain open; see [verification](Verification.md) and [script publishing](Script-Publishing.md#known-importer-issues).
