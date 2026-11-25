# Verification and benchmarks

`Build.ps1` is the release gate. Tests run with Pester 5.7.1; all modifying built-in operations are mocked. Integration tests execute only test-owned scripts, environment inspection, and isolated copies of the bundle. Never substitute real repair/reset operations into automated fixtures.

Coverage includes metadata policy, dispatch rejection, parameter boundaries, payload validation, search ordering, confirmation refusal, privilege refusal, bounded output, restricted cleanup, invalid/missing custom metadata, helper exclusion, stable IDs, deleted files, entry limits, batch literal paths, PowerShell working directory/exit code, asynchronous operation, deterministic bundle content, and isolated execution.

Version 0.2 adds mocked transaction, recovery and scheduling tests: preflight failure before mutation, registration failure, mixed/tristate firewall rollback, original update value versus absence, manual mode, overlap rejection, explicit enable, external conflicts, failed restore retention, Tamper Protection, ignored preference changes, 1/36-month calendar arithmetic, pinned helper identity, cancelled/expired/previous-boot countdowns, single power dispatch, S4U/ACL registration order, no wake/missed-run power behavior and declined Force Restart. Windows-setting setters, task registration, COM ACL operations and power requests are mocked. Diagnostic fixtures cover partial provider failures, missing battery data and bounded event queries.

Version 0.2.1 adds warning acknowledgement/cancellation and re-enable tests, explicit child-switch propagation, selected-command propagation, Task Manager yes-prompt suppression, high-risk/custom-script typed-prompt suppression, bounded cleanup preview without paging prompts, and retained permission/argument/availability checks. All dispatched changes, Task Manager launching, custom-script execution and power requests in these new tests are mocked.

Platform acceptance requires Windows 10 x86, Windows 10 x64, Windows 11 x64 and a 32-bit host on x64 Windows. Record exact builds, Windows features and policy. Test Console Host, Windows Terminal, basic mode, resize, redirected streams, standard/admin tokens, UAC cancellation, missing providers, offline execution, USB media, read-only distribution locations, Unicode and space-containing paths.

## Terminal regression coverage

Renderer tests cover compact/wide boundaries, row bounds, selected-row visibility, complete warning/detail fallback, metadata-only previews, all 66 built-in detail presentations, risk/status labels, control sanitization, Unicode cell fallback, changed-row writes, viewport offsets, positioning failure, resize key consumption and preservation of partially typed values. Existing navigation, parameter, confirmation, custom-script and execution tests remain part of the release gate.

Use the development-only UI harness to compare a preserved baseline and candidate:

```powershell
.\tools\Measure-ToolkitUI.ps1 -ToolkitPath .\dist\Toolkit.ps1 -Live -OutputPath .\.build\ui-live.json
.\tools\Measure-ToolkitUI.ps1 -ToolkitPath .\dist\Toolkit.ps1 -Width 120 -Height 30 -OutputPath .\.build\ui-synthetic.json
```

Live mode paints the actual first menu and supplies Q, repeating bundle entry in the same process. It includes source loading and registry validation, but excludes process launch. Synthetic mode suppresses painting and measures composition with fixed geometry; it is not evidence of terminal painting or input latency. Samples include the initial observation; report it separately from median/p95. Keep baseline and candidate sequential on the same terminal/hardware. The separate catalog benchmark remains a process-start proxy.

## Performance procedure

Use a dual-core Windows 10 computer with 2 GB RAM, SATA HDD and USB 2.0 storage. Windows 11 uses at least its supported 4 GB RAM baseline. Keep security software enabled. Record hardware, OS, shell architecture, storage and antivirus configuration.

Run 20 warm starts and five first launches after reboot. Report process launch-to-first-menu and toolkit entry-to-first-menu separately. The optional `tools/Measure-Toolkit.ps1` measures process start through catalog output and exit; it is an automated proxy, **not** first-menu timing. Record median/p95 and individual cold observations.

Measure idle CPU externally for 60 seconds and working set against an equivalent empty PowerShell host. Repeat after a diagnostic and after 20 sequential operations. Observe worker disposal and output-flood memory bounds. Idle menus block on input; active operations poll at no more than ten UI checks per second.

Targets: core below 500,000 bytes (hard gate), first menu below two seconds where practical, idle CPU below 1% of one logical processor, incremental idle working set below 30 MiB. These are targets until measured. Core size excludes user-owned scripts. Custom discovery and interpreter launch costs must be measured separately.

Real modification/UAC tests require a disposable VM and explicit operator intent. Do not infer physical USB or Windows 10 compatibility from a local directory or mocked test.
