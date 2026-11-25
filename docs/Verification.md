# Verification evidence

## Current build: 0.2.1 UI refinement

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
