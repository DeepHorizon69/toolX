# Release checklist

- [x] Pinned modules imported; source and bundle pass PowerShell 5.1 parsing and analyzer rules.
- [x] All automated tests pass; artifacts and checksum generated only after passing checks.
- [x] Repeated builds produce identical script hashes.
- [x] Isolated script works without repository/configuration files.
- [ ] All 66 built-in details, availability and keyboard paths exercised on the target platform (automated presentation coverage is recorded separately).
- [ ] Custom `.ps1`, `.bat`, `.cmd`, metadata, refresh, helper exclusion and confirmation exercised.
- [ ] v0.2 live managed-change recovery tested in a disposable VM: S4U while logged out, existing execution policy, USB removal, missed triggers, restore conflict and account changes.
- [ ] v0.2 live security/update controls and power actions tested in a disposable VM. Automated coverage uses mocks only.
- [ ] Normal/elevated launch and cancelled UAC exercised in a disposable environment.
- [ ] Console Host, Windows Terminal, basic mode, resize and redirected input verified.
- [ ] Windows 10 x86/x64 and Windows 11 x64 matrix recorded with exact builds.
- [ ] Physical USB and read-only media behavior verified.
- [ ] Performance targets measured on the stated baseline; exceptions documented.

Unchecked items are not claims of completed verification. See `Verification.md` for evidence obtained in the development environment.
