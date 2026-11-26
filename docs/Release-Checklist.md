# Release checklist

Current scope: Alpha 0.2.2, reviewed November 26, 2026. This checklist records the inspected workspace and existing distribution; the review did not perform a fresh full release build.

- [x] All 52 PowerShell files parse; the 31 build-gate analyzer files have zero warnings/errors with the pinned analyzer.
- [x] All 203 Pester tests pass after explicitly loading `System.IO.Compression`; the initial clean-shell ZIP-fixture failure is recorded in `Testing.md`.
- [x] Current source bundle text matches the staged script; both distribution EXEs match staged EXEs and their checksum files.
- [x] Integration fixtures verify isolated script execution and compact CLI execution/discovery without original repository files.
- [x] Current executable layout, 91-command inventory, importer limits and known defects are documented.
- [ ] Fix failed-overwrite data loss, oversized local metadata handling and relative CLI import paths; add regression coverage.
- [ ] Make the ZIP fixture independent of previously loaded assemblies.
- [ ] Run the full release gate after fixes and regenerate/recheck both executables and checksums.
- [ ] All 91 built-in details, availability and keyboard paths exercised on the target platform (automated presentation coverage is recorded separately).
- [ ] Custom `.ps1`, `.bat`, `.cmd`, metadata, refresh, helper exclusion and confirmation exercised.
- [ ] v0.2 live managed-change recovery tested in a disposable VM: S4U while logged out, existing execution policy, USB removal, missed triggers, restore conflict and account changes.
- [ ] v0.2 live security/update controls and power actions tested in a disposable VM. Automated coverage uses mocks only.
- [ ] Normal/elevated launch and cancelled UAC exercised in a disposable environment.
- [ ] Console Host, Windows Terminal, basic mode, resize and redirected input verified.
- [ ] Windows 10 x86/x64 and Windows 11 x64 matrix recorded with exact builds.
- [ ] Physical USB and read-only media behavior verified.
- [ ] Performance targets measured on the stated baseline; exceptions documented.
- [x] Review publication snapshot paths: include source/tests and intended distribution files; exclude generated test results, logs, previews, benchmarks, downloaded modules, new audit reports and local shortcuts.

Unchecked items are not claims of completed verification. See `Verification.md` for evidence obtained in the development environment.
