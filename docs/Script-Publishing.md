# Publishing and Importing Scripts

Users can import scripts into the portable `Scripts` folder without rebuilding `Toolkit.exe` or `Toolkit.CLI.exe`. Import saves files beside the executables and does not execute them. A script can change Windows when the user later runs it; its metadata does not certify its behavior.

## Import sources

1. **Local file or ZIP pack:** `.ps1`, `.bat`, `.cmd`, or a `.zip` archive (maximum 100 file entries and 5 MiB uncompressed, maximum 1 subfolder level, no path traversal). Each script must contain 1 byte through 512 KiB; companion metadata is limited to 64 KiB.
2. **Published HTTPS script URL:** Any `https://` script URL (for example a raw GitHub file) up to 512 KiB, with optional SHA-256 checksum verification.
3. **Published manifest URL (`manifest.json`):** A JSON catalog listing multiple scripts with mandatory SHA-256 hashes.

## Published manifest format (`manifest.json`)

Host a UTF-8 JSON file (up to 256 KiB, listing 1-100 scripts) over HTTPS. Replace the example URL and checksum below with the actual published script and its hash:

```json
{
  "schemaVersion": 1,
  "publisher": "YourName",
  "scripts": [
    {
      "name": "Network Quick Audit",
      "description": "Checks active adapters, gateway and DNS resolution.",
      "folder": "IT-Support",
      "fileName": "Network-QuickAudit.ps1",
      "url": "https://raw.githubusercontent.com/owner/repo/main/Network-QuickAudit.ps1",
      "sha256": "REPLACE_WITH_64_HEX_SHA256",
      "requiresAdmin": false
    }
  ]
}
```

Generate the SHA-256 hash on Windows PowerShell before publishing:

```powershell
(Get-FileHash -LiteralPath .\Network-QuickAudit.ps1 -Algorithm SHA256).Hash
```

## Importing from GUI or CLI

- **GUI:** Select **Import** in the bottom-left sidebar footer, pick the source mode, optionally set a subfolder/checksum, and confirm.
- **Terminal menu:** Open **Custom Scripts -> [Import script from file, ZIP or HTTPS URL]**.
- **CLI arguments:**
  ```powershell
  .\Toolkit.CLI.exe -ImportLocal 'C:\MyTools\MyPack.zip' -ImportFolder IT-Support
  .\Toolkit.CLI.exe -ImportUrl https://example.com/Tool.ps1 -ImportFolder Tinkerer -ImportSha256 <64-HEX>
  ```

Use an absolute source path for local CLI imports. The current EXE host resolves relative paths from its own directory. Scripts remain in `Scripts` beside the EXE, regardless of the source location.

Local single-file imports copy a sibling `<script filename>.json` when accepted and no display-name, description or administrator override was supplied. Discovery supports `schemaVersion`, `name`, `description`, `requiresAdmin` and `enabled`. ZIP packs associate metadata by the complete script filename plus `.json` in the same folder. File and folder names accepted by the importer contain only ASCII letters, digits, periods, underscores and hyphens, and cannot start with a period or underscore.

## Known importer issues

These defects were reproduced with isolated fixture files on November 26, 2026 and remain open in Alpha 0.2.2:

1. **Failed overwrite can delete an existing script and its metadata.** The importer writes the replacement before completing descriptor validation, then deletes the destination if validation fails. Back up existing files and import under a new name or folder instead of enabling overwrite.
2. **Oversized local metadata is skipped.** A sibling JSON file above 64 KiB is ignored during local single-file import. The imported entry can therefore default to `enabled: true` and `requiresAdmin: false` even when the source metadata says otherwise. Verify the sidecar is a regular file within the size limit, then inspect the imported metadata and displayed permissions before running. Oversized metadata placed directly in Scripts is rejected by discovery.
3. **Relative CLI source paths use the EXE directory.** `-ImportLocal .\Check.ps1` searches beside `Toolkit.CLI.exe`, even when the calling terminal is in another folder. Supply an absolute source path as in the example above.

ZIP and manifest imports save entries sequentially. If a later entry fails, files imported earlier can remain; inspect the destination before retrying. A checksum checks content integrity against the supplied hash and does not establish publisher identity. Imports never execute the saved script automatically.
