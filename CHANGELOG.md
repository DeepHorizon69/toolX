# Changes

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
