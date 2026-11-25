# UI refinement evidence

The refinement preserves Categories -> Commands -> Details -> Parameters -> Execution -> Acknowledgement. Wide layouts use one active list and a passive metadata preview. There are no pane-focus shortcuts, runtime dependencies, network requests for rendering, timers while idle, animations, or persistent terminal changes.

## Implementation

- Terminal captures/restores appearance, caches privilege and color capability, and retains blocking keyboard input. A size-driven numbered fallback can recover; explicit Basic or unsupported-console fallback stays basic.
- Renderer separates semantic rows from console writes. It pads rows, caches the previous frame and writes only changed rows. Colors are precomputed; ASCII text avoids Unicode callback allocation. Positioning failure gets one retry before basic output.
- Navigation supplies existing metadata and retains command/search ordering, clamped selection, parameter defaults/validation, safety settings, and execution routing. Preview selection performs no capability checks or script discovery.
- Command rows label Read, Modify or High risk from existing metadata. Headers show actual administrator inheritance and session confirmation state. Complete details/warnings use scrollback if they cannot fit.
- Diagnostic output keeps the existing queue/retention bounds and cancellation/timeouts. Wrapping is cached per output width; reflow preserves the source-line/column anchor. Parent feedback describes a closed worker console and its exit code, not a verified repair.

## Measured performance

Host: Windows PowerShell 5.1.26100.9818, x64; reported Windows version 10.0.26300.0. Baseline is the original 210,073-byte v0.2.1 bundle extracted from the project restore archive. Measurements are local developer-host observations, not low-resource Windows 10 certification.

| Measurement, 20 samples | Baseline median / p95 | Refined median / p95 |
|---|---:|---:|
| Same-process entry to first painted menu, 80x24 | 57.84 / 80.58 ms | 81.16 / 106.49 ms |
| Process launch through catalog output and exit | 628.79 / 645.80 ms | 639.46 / 664.58 ms |
| Synthetic 120x30 menu composition, no painting | 0.97 / 5.00 ms | 24.98 / 32.57 ms |
| Read-only diagnostic worker elapsed, 20 sequential operations | 38.82 / 45.22 ms | 35.56 / 43.31 ms |

Live entry measurements include bundle loading and registry validation, then supply Q after painting. They exclude process launch. Initial live observations were 277.09 ms baseline and 433.61 ms refined. These are distinct from reboot-cold launch measurements. Synthetic composition and live first-menu painting do not establish actual key-to-paint latency.

The first-menu median/p95 increases remain below the planned 100 ms allowance. Distribution size is 231,366 bytes, below the 500,000-byte gate. Before optimization, live menu-stage median was 40.95 ms; the final cached-color/ASCII path measures 26.30 ms.

The optimized true-color menu used 0 ms additional CPU over a measured 60.08-second idle interval (0% of one logical processor). Working set at the end was 164.29 MiB. Baseline and empty-host snapshots were approximately 133 MiB and 73 MiB respectively. The inherited <30 MiB increment target is missed by both toolkit versions. The observed additional UI footprint is approximately 31 MiB in these single-process snapshots. This is a material limitation, not a statistically controlled memory regression result. No forced garbage collection was added to the product to improve these numbers.

Raw JSON samples live under `.build`: ui-baseline-live, ui-candidate-live, ui-baseline-synthetic, ui-candidate-synthetic, startup-baseline, startup-candidate, idle-candidate and memory-comparison. The release log is ui-release-build.log. They are development evidence, not runtime dependencies.

Separate headless worker-loop checks executed Environment information 20 times per version, discarded output without logging paths, verified Succeeded and a Closed runspace each time, and recorded working set. Baseline grew from 120.02 to 135.72 MiB; refined grew from 125.00 to 140.14 MiB. Growth was similar (15.70/15.14 MiB), and final refined overhead was 4.42 MiB in this worker-only scenario. These are short observations including runtime warmup, not proof of zero long-term leaks or a full UI retention benchmark. Raw data: `.build/operations-baseline.json` and `.build/operations-candidate.json`.

## Functional evidence

- Native terminal: launch -> menu; / -> editable search; system.environment -> matching result; Enter -> full metadata/actions; Run -> read-only diagnostic Succeeded; Enter -> details; Escape -> search; Escape -> categories; End -> Settings; Enter -> confirmation setting; toggle -> complete warning; Escape -> setting still ON; Q -> restored cursor/colors and exit.
- True-color terminal: transient true-color signal -> correct 24-bit foreground/background and selected-row palette. No font, window-size, encoding or persistent terminal setting changes.
- Basic: launch -> numbered categories; /nonexistent-ui-smoke -> empty search; r -> refreshed custom-script count; q -> exit.
- Automated: all 66 built-in detail presentations retain complete consequences/risk and reachable actions; registry and execution gates remain covered; resize/pending-key and partial-input fallback tests pass; equal frames emit zero positioned writes; selection changes skip unchanged header/footer; simulated positioning failure restores appearance and retains output.

Risky operations, live OFF activation, UAC, security/update controls, deletion, task registration and power actions were not performed. Their existing mocked regression tests pass.

## Remaining verification

- Physical classic Console Host and Windows Terminal windows, actual resize, and user-customized console palettes.
- Windows 10 x86/x64, other Windows 11 builds, and a 32-bit host on x64 Windows.
- Low-resource hardware, reboot-cold/full-process first-menu timing, real key latency, physical USB and read-only media.
- Statistically controlled working-set and full-UI retention comparison. The 20-worker disposal check passes, but the absolute working-set target is not met in current snapshots.
- Real managed-change recovery and UAC scenarios remain disposable-VM work, as before this refinement.

## Safety observations outside presentation changes

Confirmations OFF intentionally skips toolkit prompts for all modifying/high-risk/custom actions. Custom scripts are unreviewed code with their displayed Windows token, including inherited elevation; they are not sandboxed. A worker exit code does not verify repair success. These existing semantics were preserved, made visible, and not weakened.
