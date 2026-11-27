# Native rewrite verification

Date: November 27, 2026. This is an Alpha 0.2.3 preview, not a completed platform certification. The PowerShell Alpha 0.2.2 distribution remains intact. The native rewrite was originally developed under the provisional 0.3.0 label and is published as 0.2.3 at the project owner's request.

## Automated evidence

The solution builds in Release with SDK 10.0.404, zero warnings and zero errors. The runtime in the portable packages is .NET 10.0.15. Packages are self-contained, separate x64/x86 distributions with shared Windows Desktop runtime files and optional Scripts. No SDK or runtime installation is needed on the target machine.

The test runner passed 115 checks, zero failures, on this Windows 11 x64 host (build 26300). Run:

```text
.tools\dotnet\dotnet.exe run --project native\ToolX.Tests -c Release -- --live --diagnostics
```

Coverage includes all 91 catalog IDs having native handlers; argument boundaries; rejecting unknown commands/executables; confirmation refusal; cancellation; script discovery; metadata; hash verification; ZIP traversal; preserving support assets; rolling back a partially failed pack; failed overwrite preserving existing content; report round trips, HTML escaping, schema checks and comparison; bounded worker messages; protected helper path validation; mixed firewall snapshots; interrupted partial application; preserving external changes; and late/rebooted/executed/prepared power-job decisions.

An in-memory HTTP handler also verifies an HTTPS manifest import through the real download/import pipeline, generated schema-v1 sidecar casing, rejection of HTTPS-to-HTTP redirects, and oversized responses. These tests contact no external host. A harmless batch fixture in a path containing spaces, ampersands and percent signs was also launched through the custom-script CLI console: it printed its marker, reported exit code 23 and retained the outer console for acknowledgement.

Live tests execute ordinary local diagnostics, with no repair, security changes, task registration, power actions or automatic Internet probes. Hardware/provider absence and permission denial are valid diagnosed outcomes in the broader catalog exercise, not evidence that every provider returned data. Source review and native handler coverage are not proof of every Windows API setter.

The x64 portable CLI passed `-Check` and reports 91 built-ins and no missing handlers. The x86 portable CLI started successfully on the x64 host. Native environment and locale diagnostics also succeeded with `PSExecutionPolicyPreference` set to Restricted and AllSigned in a disposable test shell. These checks do not claim WDAC/AppLocker approval or full Group Policy simulation; no persistent execution policy was changed.

## Desktop observations

The native x64 GUI was opened using Computer Use. Observed paths:

- Startup opens the command catalog, category tree, toolbar and status bar.
- Search for `system.environment` filters the list; selecting its result opens command metadata and actions.
- Run executes the environment diagnostic and shows Succeeded with actual runtime and process information.
- System/dark mode was inspected. Initial native WPF color conflicts were found and corrected with shared brushes and control templates; the corrected dark view was inspected again.
- Selecting Light changes the command list, navigation, inputs and output to readable light colors.
- Selecting Indonesia changes navigation, command names, risk labels, controls and status text.
- Opening Pemeriksaan and running Pemeriksaan umum completes local specification/update/event/device/storage/service checks, retaining per-section outcomes.
- Export JSON opens the native Save As dialog; cancellation returns to the toolkit. End-to-end portable CLI export generated a general-check JSON report, and comparing that report against itself returned an empty difference list.

The export buttons were moved before the results after inspection showed that long batch output pushed them below the visible area. Buttons wrap at narrow desktop widths. The report viewer now bounds its output independently of the page scroll area.

An isolated WPF test process also builds all 91 parameter forms and seven pages in English/Indonesian, Light/Dark, and 1180/640-pixel desktop widths: 784 layout cases passed without invoking system actions. It checks parameter controls, Run actions, finite layout sizes and WCAG AA text/selection contrast using the actual resource brushes. Rendered previews are in ignored `.build/native-ui-layout/`. This is a layout test, not a replacement for physical DPI or full action click-through testing.

Inactive native selection brushes are also overridden and contrast-checked, so selecting a navigation item does not leave white text on a native light selection background in Dark mode. Additional rendered Checks previews cover that state. Cancel is disabled while idle or during operations that cannot be safely cancelled; navigation is disabled while an operation is active.

The approved direction is recorded in `native/DESIGN.md`: MMC utility layout, Segoe UI/Consolas, neutral surfaces and one blue accent, ENERGY 1 / RHYTHM 2 / MOTION 1, with no decorative animation or invented health scores.

## Remaining release acceptance

These checks need a disposable Windows VM matrix and/or a signing environment; they have not been claimed as passed:

- Windows 10 1607/LTSC 2016, 1809, 21H2 and 22H2, x86/x64; additional Windows 11 versions; real x86 Windows rather than WOW64 only.
- UAC acceptance/cancellation, cross-elevation named-pipe handshake, and refusal of a mismatched peer/account.
- Real firewall/Defender/update setter behavior and effective state verification, failure rollback, S4U recovery preflight, recovery after reboot/removal of USB, and power countdown expiration/cancellation. Exercise these only in disposable VMs.
- Full GUI click-through of every operation type and file dialog, physical resizing, 100/150/200% DPI and actual Windows High Contrast. Basic page/handler inspection does not replace this acceptance matrix.
- Publisher signing and testing under Smart App Control, WDAC/AppLocker and organization policy. Development packages remain unsigned without a supplied signing certificate.
- Controlled full-GUI startup and retained-memory comparison with the PowerShell version. No speed or memory improvement is claimed without those measurements.

Do not replace the legacy release or mark platform acceptance complete until these checks are recorded. Neither the app nor its documentation suggests disabling Windows protections as a generic fix.
