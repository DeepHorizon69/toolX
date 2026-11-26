# Changes

## Alpha 0.2.2 (by ALSA), November 26, 2026

- Branded the toolkit as **TOOLX Windows Edition**, bumped version to **Alpha 0.2.2**, and added the **by ALSA** signature across the GUI window/title bar, Terminal header, operation console banner, `-Version` / `-Help` output, support reports, and compiled PE `VersionInfo` assembly metadata (`Toolkit.exe` and `Toolkit.CLI.exe`).
- Packaged `Toolkit.exe` and `Toolkit.CLI.exe` with an embedded compressed script and SHA-256 verification. The hosts extract into unique `%TEMP%` session directories and attempt cleanup on exit; portable Scripts discovery uses the executable directory. The current catalog has 91 built-in commands and a local/HTTPS/catalog script importer.
- Updated executable usage, script placement, architecture, test instructions and release checklist. Recorded 203 passing tests with explicit ZIP assembly setup, zero parser/analyzer findings in the stated scopes, and current EXE hashes/sizes.
- Documented three confirmed open importer defects: failed overwrite can delete existing files, oversized local metadata is skipped, and relative CLI import paths resolve from the EXE directory. This documentation update does not fix those defects.
- Kept generated test outputs and development tools local; expanded ignore rules for test-result directories, coverage output, logs, audit reports and Windows shortcuts. Test source files remain versioned.

## Portable GUI, November 26, 2026

- Added `Toolkit.GUI.exe` and `-Gui`: a dark WPF interface for categories, literal search, all 66 built-in forms, Custom Scripts refresh, session confirmation settings and diagnostic results. The GUI loads WPF only when selected; the terminal entrypoint remains available.
- Read-only diagnostics reuse the asynchronous engine and render specifications as responsive device blocks. Other operations retain their existing confirmed console/UAC path. The GUI polls only during active work, cancels diagnostics before closing, and leaves independent operation consoles running.
- The portable launcher starts installed Windows PowerShell in STA without a primary console and shows startup errors in a dialog. Build compiles, stages and tests it before publishing the PS1, EXE and checksums to local dist.
- Release gate: 179 passing tests. Real GUI dispatcher diagnostics and rendered wide/narrow views pass; physical desktop interaction, Windows 10 and real DPI/high-contrast changes remain pending.

## Multicolumn specifications, November 26, 2026

- Specification output now uses device blocks with one label/value per line, arranged into as many columns as the terminal width permits. Long values wrap, multiple devices are numbered, and completed reports reflow on resize.
- Specification workers retain structured results separately from the lossy text queue, preventing a burst of formatted rows from discarding earlier specification data. The 4,096-record limit remains explicit through Output truncated when exceeded; other diagnostics retain their existing text transport.
- Added coverage for narrow/wide layouts, repeated devices, missing data, Unicode, value formatting, result bursts, record limits and resize/key navigation. The release gate passes 164 tests.

## Double-click launcher, November 26, 2026

- Added optional `dist/Toolkit.cmd`: double-click to open the toolkit without entering a PowerShell command. Keep it beside Toolkit.ps1; the launcher supports portable paths and retains startup errors until acknowledged.
- Build stages and tests the launcher before publishing it to dist. No execution-policy changes, automatic elevation or runtime downloads.

## Specification scopes, November 26, 2026

- Full specifications now offers Full (default), Hardware, Firmware, Windows, Storage and Network scopes using the existing parameter prompt. Only selected providers are queried; partial results and provider timeouts are retained.
- Firmware covers motherboard and BIOS information. The 66-command inventory and existing report format are retained.

## 0.2.1 refined build, November 26, 2026

- Adaptive terminal interface: active list and passive preview at 110x20 or larger, stacked/compact views below that, and numbered menus below 60x12 or in unsupported console environments.
- Metadata previews, readable risk labels, administrator inheritance and confirmation-state headers, contextual keyboard help, and refresh feedback.
- Changed-row rendering, cached colors, and blocking idle input. Resize is handled on the next key while retaining selection and input.
- Complete scrollback presentation when details or warnings cannot fit. Existing parameter validation, confirmation mechanisms and operation-console workflows are preserved.
- All 66 built-ins and local PowerShell/batch custom scripts remain available through the existing registry and execution engine. No new runtime dependencies or persistent terminal changes.
- 140 passing automated tests, standalone packaging below 500,000 bytes, and a checksum that also matches the raw repository artifact.

This build retains the session-only Action confirmations setting introduced in 0.2.1. It starts ON, requires the exact OFF acknowledgement to disable, and does not bypass UAC, permission/argument checks or recovery preflight.

Known limits: the idle working-set target is not met by either baseline or refined snapshots; additional Windows/terminal, low-resource hardware and disposable-VM recovery tests remain pending. See [verification](docs/Verification.md) and [UI evidence](docs/UI-Refinement.md).

## Earlier local baselines

- **0.2.1:** Session-only action-confirmation preference and its regression tests.
- **0.2.0:** Expanded diagnostics, troubleshooting, protected managed-change recovery and power scheduling, bringing the inventory to 66 built-ins.
- **0.1.0:** Initial portable toolkit, registry validation, read-only workers and custom-script adapters.

These entries describe local project baselines; they do not imply that earlier versions were published as GitHub Releases.
