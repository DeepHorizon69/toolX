# Verification evidence

## Current build: Alpha 0.2.2, November 26, 2026

The workspace review checked the current source and existing compact distribution without rebuilding or changing Windows settings. Modifying operations in the automated suite use mocks. The review used Windows PowerShell 5.1.26100.9711.

- The registry contains 91 built-in commands: 64 ReadOnly, 13 SystemModification and 14 HighRisk.
- All 52 PowerShell source, tool, test and starter-script files parsed without errors. PSScriptAnalyzer 1.24.0 reported zero warnings/errors across the 31 files in the build analyzer's scope.
- The first direct Pester 5.7.1 run passed 202 of 203 tests. The ZIP fixture failed because `System.IO.Compression.ZipArchiveMode` was unavailable in the fresh shell. After explicitly loading `System.IO.Compression`, all 203 tests passed with zero failures/skips in 30.31 seconds. The four importer tests also passed separately with that setup. See [test instructions](Testing.md#running-the-current-suite).
- Regenerating bundle text from the current source matched `.build/Toolkit.ps1` exactly. Both distribution EXEs matched their staged counterparts and their `.sha256` files. This check did not regenerate the executables or perform a fresh full release build.
- `dist/Toolkit.exe`: 90,112 bytes; SHA-256 `42DB7D1044B0ED7C660C84EAADFB24F17E2E6E468384BD9E9E14D75406689163`.
- `dist/Toolkit.CLI.exe`: 91,136 bytes; SHA-256 `322DAD613E68F2D46F8EA8F759D0468B62FE79B6B666701B4613388CA41A3A3D`.
- Isolated fixture checks reproduced three open importer defects: failed overwrite deleted an existing script and sidecar; oversized local metadata changed a disabled/admin-requesting source into an enabled entry without an admin request; a relative local CLI path searched the EXE directory instead of the caller's directory. The temporary fixtures were removed. [Importer workarounds](Script-Publishing.md#known-importer-issues) document the current behavior; these defects remain unfixed.

Physical GUI mouse/keyboard interaction, monitor DPI/high-contrast transitions, UAC, Windows 10 x86/x64, the broader host/terminal matrix, physical USB/read-only media, and real managed-change recovery remain unverified beyond the historical evidence below. The review made no new live repair, security-control, scheduling, power-action or performance measurements. Earlier GUI dispatcher evidence and memory-target limitations remain applicable.

Generated XML results, raw logs, benchmark samples, GUI previews, fixture files and development modules stay local in ignored directories. Test and harness source files remain part of the repository.

## Previous build: 0.2.1 portable GUI

- Release gate: 179 tests passed, zero failures/skips; PowerShell 5.1 parsing, pinned static analysis, native launcher compilation and standalone packaging passed. PS1: 277,501 bytes, SHA-256 `B6ABEA02201ED99752A1F6BF7B6C15B680D57C677C58C8C95082B069A0C9EDC8`. GUI EXE: 6,656 bytes, SHA-256 `06DFA098A70913DB8A0C4121C3C12CA42CFE4C2573C612BA8A91831EB9B66904`.
- Added GUI coverage includes every built-in form, accessible input names, literal search/selection clearing, defaults and conditional security fields, disabled commands, console routing/confirmation flags, structured results, text limits, exact OFF acknowledgement/restoration, pending-close cleanup and external-console exit wording. Modifying operations remain mocked.
- Portable EXE fixture starts an adjacent test-owned script with -Gui and STA from a path containing spaces, Unicode and shell characters. Combining -Gui with -Version is rejected. A real packaged launch exposed a responsive PowerShell-hosted window titled Windows Engineering Toolkit; the task-owned preview was then stopped without executing an operation.
- Real WPF control-event/dispatcher harness: selected Full specifications in the tree, raised Run, collected 30 device blocks with Succeeded; Environment information also completed with Succeeded through the Run event. Initial direct diagnostics and subsequent dispatcher checks agreed. No modifying diagnostics were run.
- Inspected WPF RenderTargetBitmap previews at 1120x720 and 760x580, plus the parameter and settings views. Corrected dropdown contrast and parameter wrapping. Previews are under ignored `.build/gui-preview`; these are rendered controls, not desktop screenshots or proof of physical DPI/resize behavior.
- Computed contrast: primary/background 12.26:1, primary/raised 9.18:1, muted/surface 7.16:1, muted/raised 5.86:1, accent/raised 7.09:1, accent/background 9.47:1, danger/background 9.03:1, success/background 12.32:1. Control borders against raised surfaces are 3.70:1 (non-text threshold 3:1). High Contrast uses system colors; its real transition remains untested.
- Native desktop automation failed with `Computer Use native pipe is unavailable` after retry and kernel recovery. Manual mouse/keyboard click-through, actual DPI/high-contrast changes, UAC and Windows 10 x86/x64 remain pending. Existing platform, recovery and memory limitations below remain applicable. See the [GUI guide](GUI.md). The generated delivery review remains local.

## Previous build: 0.2.1 multicolumn specifications

- Release gate: 164 tests passed, zero failures/skips; PowerShell 5.1 parsing, pinned static analysis and standalone packaging passed. Bundle: 241,161 bytes, SHA-256 `336E0F41E3A4F011D72D9CD5B330635385131986A608A8B1ADE1D84029EC2204`.
- Real standard-user full-report runspace: Succeeded, 118 structured records, Truncated=False. Formatting the same records at usable widths 79/119/149/199 produced 178/89/60/47 rows respectively, with maximum row lengths 52/113/144/194. These are output geometry observations on this host, not performance or other-hardware claims.
- Live Basic menu: search system.full-specs -> details -> Run -> Windows -> compact Windows and Computer blocks -> Succeeded without truncation -> acknowledgement -> Q, exit 0.
- Fixtures cover widths 35/59/79/89/119/149/199, repeated memory devices, unavailable providers/battery, zero/false/missing values, units/dates, long/Unicode values, a 700-record burst without loss, and explicit truncation beyond 4,096 records. A completed-report navigation fixture reflows through 120/150/80 terminal columns with End/Home/Escape consumed once each.
- The existing text queue and its loss reporting remain unchanged for other diagnostics. Specifications use a separate bounded record result so layout can be regenerated on width changes. Physical-window resize and wider live terminal hosts remain unverified beyond the existing compatibility limits below.

## Previous build: 0.2.1 double-click launcher

- The release gate passes 151 tests, zero failures and zero skipped cases, with PowerShell 5.1 parsing and pinned static analysis. Three added launcher integration cases cover an adjacent script in a portable path with spaces, Unicode and shell characters, preserved failure output/exit code, and a missing toolkit file. The portable-path case also starts with delayed expansion enabled and an unrelated script in the working directory.
- Build stages `tools/Toolkit.cmd` beside the candidate PS1, tests it, then copies it to `dist/Toolkit.cmd` after the test gate passes. The PS1 remains 232,959 bytes with the same SHA-256 recorded below.
- Live standard-user ConPTY check: invoking the packaged `dist/Toolkit.cmd` opened the normal colored command library. Q closed the toolkit and launcher with exit code 0 and no error pause. This verifies command invocation of the launcher; Windows Explorer double-click and desktop shortcut UI were not exercised directly.
- The launcher uses installed Windows PowerShell, does not forward arbitrary arguments, and does not modify execution policy or automatically elevate. Failure acknowledgement uses the built-in Windows `pause` command. Prior platform and performance limitations still apply.

## Previous build: 0.2.1 specification scopes

- The release gate passes 148 tests, zero failures and zero skipped cases, with PowerShell 5.1 parsing and pinned static analysis. Eight added cases cover all six scope provider sets through parameter validation and dispatch, omitted/blank defaults, invalid scopes, and partial firmware-provider failure.
- `dist/Toolkit.ps1`: 232,959 bytes; SHA-256 `18F5ACBD83DECFB289A6F489EF45D2E6B3935370B387FD383D0EE203BF13C003`. Built using `Build.ps1`; standalone execution and deterministic bundling pass. Version and built-in inventory remain 0.2.1 and 66.
- Live Windows PowerShell 5.1 standard-user ConPTY check with `-Basic`: search `system.full-specs`, open details, Run, inspect the six scope choices and Full default, reject `other`, retry `Firmware`, receive only Board/BIOS results with Succeeded, acknowledge, Run again, cancel the scope prompt, and Q exit with code 0.
- All six scope provider sets were exercised with mocked hardware data. This update does not establish additional live OS/hardware compatibility or performance measurements. Execution policy was not modified.
- The generated scoped delivery review remains local. Prior UI, memory and platform limitations below still apply.

## Previous build: 0.2.1 UI refinement

- The complete release gate passes 140 tests, zero failures and zero skipped cases, with PowerShell 5.1 parsing and pinned static analysis. Modifying, elevated, security, scheduling and custom-script dispatch remains mocked.
- `dist/Toolkit.ps1`: 231,366 bytes; SHA-256 `881AEAA3FACBCA87A103D45D73BBEA5390289AEB68E1B634A674ABDAF3B618AA`. Standalone execution, deterministic bundling and checksum checks pass. The version remains 0.2.1. Repository history records publication; this document records validation rather than a separate GitHub Release.
- Registry, entrypoint, executor, privileges, custom discovery, managed changes and command modules match the verified project restore point. ScriptLauncher changes are limited to toolkit-owned operation headings and risk/privilege colors.
- Interactive Windows PowerShell 5.1 ConPTY checks: native-color menu, literal global search, command details, read-only Environment information execution (Succeeded), completed-output return, Escape/back, End to Settings, complete confirmation warning, cancellation retaining ON, and Q exit. The true-color path was separately observed with transient COLORTERM=truecolor, including 24-bit palette/selection sequences and restoration on exit.
- Explicit Basic mode: numbered menu, literal search with no matches, R refresh reporting zero local scripts, and Q exit. The UI unit suite covers resized geometry, next-key reflow, pending-key consumption, partial-input preservation, minimum-size recovery and failure fallback. It does not establish physical-window resize behavior across all target terminals.
- Twenty-run same-process live first-menu entry benchmark at 80x24: baseline median/p95 57.84/80.58 ms; refined 81.16/106.49 ms. Added median/p95 is 23.32/25.92 ms, within the planned 100 ms allowance. This excludes process launch and supplies Q through a development harness. Initial observations were 277.09 ms baseline and 433.61 ms refined; these are not reboot-cold measurements.
- Twenty-run menu composition measurements at 120x30 (no console painting): refined median/p95 24.98/32.57 ms. Actual wide-terminal painting and key-to-paint latency on low-resource hardware remain unmeasured.
- Twenty-run process-start/catalog/exit proxy: baseline median/p95 628.79/645.80 ms; refined 639.46/664.58 ms. This is not launch-to-first-menu timing.
- The optimized true-color build used 0 ms additional CPU over 60.08 seconds idle, with 164.29 MiB working set at the end. Neither baseline nor refined working-set snapshots meet the existing <30 MiB increment target relative to an empty host; no memory-target PASS is claimed.
- Twenty sequential harmless Environment information workers per version all succeeded and closed their runspaces. Median/p95 worker elapsed was 38.82/45.22 ms baseline and 35.56/43.31 ms refined. Headless working-set growth was similar (15.70/15.14 MiB); this does not establish long-term full-UI retention.
- See [UI refinement evidence and limitations](UI-Refinement.md) and [post-implementation UI audit](../anti-slop/audit-001-2026-11-25.md). Raw local samples and the release log are under ignored `.build`.

## Repository packaging, November 26, 2026

- The repository includes source, tests, build tools, documentation and the current standalone PS1/checksum. Local restore archives, downloaded development modules, temporary test results and raw benchmark samples are excluded.
- The distribution PS1 is exempt from Git text normalization so a raw GitHub download preserves the exact bytes covered by its SHA-256 file. PowerShell source files retain the existing CRLF checkout convention.
- Published performance figures come from the UI-refinement measurements above. A documentation/publication update does not establish new terminal or hardware verification.

## Previous baseline: 0.2.1

- PowerShell 5.1 parsing, pinned static analysis and all 113 automated tests passed with zero failures. New high-risk/GUI/custom dispatch tests use mocks and do not execute those actions.
- `dist/Toolkit.ps1`: 210,073 bytes; SHA-256 `D48B00650A1D6BDCA5E4EB21D114901C35CF02170AB6F0108C303FC469989574`. The checksum file and 0.2.1 version output were verified.
- Actual terminal check: Settings appeared, Action confirmations started ON, selecting its toggle displayed the complete risk warning and explicit OFF acknowledgement prompt, cancellation retained ON, and Q exited cleanly.
- Live OFF activation was not performed. OFF mode, re-enabling, child propagation and retained validation/permission checks passed mocked tests.
- The preference is session-only; no settings file or persistent machine protection change was made. Windows UAC, script-owned prompts, recovery preflight and final output acknowledgement are outside this toggle's scope.

## Previous release: 0.2.0

- Full release gate passed 98 tests with no failures or skipped cases, plus PowerShell 5.1 parsing and the pinned analyzer checks.
- `dist/Toolkit.ps1`: 206,621 bytes; SHA-256 `A67B3E58B4AA00AD3E96C65596D4B3E05169B307A2EB9AF63961B4E7DF6BC6F0`. The checksum file was verified.
- Standalone version/catalog commands returned 0.2.0 and 66 built-in entries. Source-independent execution is included in the automated suite.
- Read-only full specification inspection returned Windows, Computer, Processor, Memory, Graphics, Board, BIOS, Disk, Partition, Volume, Adapter and Battery sections on this host. Only section counts were printed during verification.
- Real terminal smoke test: new Troubleshooting and Power and Scheduling categories appeared; Power category and Force Restart details showed risk, administrator requirement and unsaved-data consequences; Back and Quit exited normally. Run was not selected.
- Security changes, update policy writes, task registration/ACL operations and power requests were mocked in tests. No real protection changes, update suspension, countdown, restart, or shutdown was performed. The ProgramData recovery directory was absent after verification.
- Coverage includes preflight and registration failures before mutation, rollback, original values/absence, tristate firewall snapshots, manual/timed modes, overlap, conflicts, restore failure retention, Tamper Protection, calendar month ends/local date boundaries, task options, failed/cancelled/expired/previous-boot jobs and single power dispatch.
- Live recovery preflight, logged-out S4U execution, UAC, reboot/sleep recovery, real security controls and power actions still require a disposable VM. A mocked test is not a claim that these live scenarios were performed.

## Previous release: 0.1.0

Date: 2026-11-25. Development shell: Windows PowerShell 5.1.26100.9818, x64 Windows host. The sandbox reports a restricted default policy; the approved host shell already has CurrentUser RemoteSigned. No execution-policy changes were performed.

## Completed

- All existing PowerShell source/test/tool files parsed with the Windows PowerShell 5.1 parser.
- Pester 5.7.1: full release build passed 53 tests, zero failures or skipped tests. Includes keyboard-navigation and standalone tests.
- Runtime fixtures: two tests cover real `.cmd`/`.bat` launches with spaces, Unicode and `%`, `!`, `&`, parentheses in paths, plus PowerShell working directory and explicit exit code.
- One real asynchronous runspace test passed, using only allowlisted environment inspection.
- Real modifying built-ins were not executed. Cleanup deletions and dangerous dispatch paths were mocked.
- Development tools were downloaded into ignored `.tools`; none are runtime dependencies.
- Source and standalone bundle passed the pinned PSScriptAnalyzer gate without errors or warnings.
- Built `dist/Toolkit.ps1`, 130,256 bytes, with its SHA-256 file. Two complete builds produced the same hash: BC8E867C3FD02839B0FBFA1543FDB8D67455051DF2258F0C23A36196E4916B40.
- Actual terminal smoke test: exact `./dist/Toolkit.ps1` launch rendered the full menu; Down/Enter opened Networking; global search found Environment information; Q exited normally.
- Actual basic-menu smoke test: System Information -> Environment information -> Run returned a successful read-only result; acknowledgement, back navigation and exit worked.

## Pending

- Windows 10 x86/x64, other Windows 11 builds, 32-bit host on x64 Windows, physical USB, real UAC interaction, terminal matrix and baseline performance measurements.

The standalone prototype is available. Completed local tests do not establish the untested platform and hardware scenarios listed above. No live repair/reset/deletion operations were used to verify the release.
