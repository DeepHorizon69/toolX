# TOOLX native rewrite, Alpha 0.2.3

The C# implementation is in `native/`. It has a WPF desktop interface, a console interface, a shared engine and Windows providers, and a compiled elevated/recovery worker. The 91 built-in command IDs remain the same. Built-ins do not launch PowerShell or load System.Management.Automation. Optional user scripts still use their original interpreters and policies.

## Run the portable package

Extract the entire ZIP into a writable local folder or USB drive. Keep the EXEs, DLLs and runtime files together. Open `Toolkit.exe` for the desktop interface, or `Toolkit.CLI.exe` for the terminal menu. Runtime downloads and .NET installation are not required. Use x86 on 32-bit Windows and x64 on 64-bit Windows. ARM64-native builds are outside this release.

The compatibility target is Windows 10 build 14393 (1607/LTSC 2016) and later, x86/x64, and Windows 11 x64. A compatibility target is not verification on every Windows edition or a claim of Microsoft support for an out-of-support Windows release. See `docs/Native-Verification.md` in the repository for actual evidence and outstanding VM checks.

The interface supports Indonesian and English, plus System, Light, Dark, and Windows High Contrast themes. Language and theme choices last for the session. Action confirmations start ON each launch. Disabling them requires an OFF acknowledgement and does not bypass UAC, parameter validation or recovery preflight.

## Console examples

```text
Toolkit.CLI.exe -Version
Toolkit.CLI.exe -Check
Toolkit.CLI.exe -ListCommands -Language id
Toolkit.CLI.exe -Run storage.hash -Param path=C:\Support\file.zip
Toolkit.CLI.exe -RunCheck general -Export report.json -Format json
Toolkit.CLI.exe -RunCheck network -Target example.com -Export report.html -Format html
Toolkit.CLI.exe -Compare before.json after.json
Toolkit.CLI.exe -ImportLocal C:\Support\Check.ps1 -ImportFolder IT-Support
```

Modifying commands require an interactive console. Network checks require an explicit target. Batch checks continue after individual failures and do not request UAC automatically. Reports are exported only when selected by the user; they contain device information and diagnostic data, so review them before sharing. HTML exports are standalone and escape diagnostic text. Comparison uses command and item identities and omits capture timestamps.

## Administration and recovery

The main app runs with the token used to launch it. Administrative operations request UAC through `Toolkit.Worker.exe`, with a per-request named pipe restricted to the initiating Windows user and verification of both peer process IDs. Workers revalidate the catalog operation, arguments and confirmations. Separate processes are not a sandbox.

Requested persistent operations use protected storage under `%ProgramData%\WindowsEngineeringToolkit\native`. A versioned copy of the compiled worker and runtime remains available after removing the portable drive. Task Scheduler runs recovery as the confirming administrator with S4U and no saved password. A harmless scheduled probe must succeed before a change is applied. Recovery preserves external changes as conflicts rather than overwriting them. Power deadlines expire after reboot or when over 60 seconds late. No permanent service is installed.

Legacy jobs under the original `jobs` directory are displayed and left pinned to their original PowerShell helper. Finish them with the original TOOLX before creating native managed changes. Do not delete protected helper files while jobs remain active.

Smart App Control, App Control, antivirus decisions and organization policy still apply to EXEs. These builds do not change execution policy or security settings at startup. Without a supplied signing certificate, development packages are unsigned.

## Build

Use the SDK version pinned in `global.json`. Either install it normally or extract the verified official SDK ZIP into ignored `.tools/dotnet`. The SDK is a development dependency only.

```text
native\build.cmd
native\publish.cmd
```

`build.cmd` builds Release and runs the fixture/read-only host test runner plus isolated WPF layout checks. `publish.cmd` also publishes separate self-contained x86/x64 ZIP packages under ignored `artifacts/`, with checksums. It preserves the existing PowerShell `dist` release until the native acceptance matrix is verified. Shared runtime files come from the GUI publish to retain the complete Windows Desktop assemblies.

Optional release signing: set `TOOLX_SIGN_CERT_SHA1` to a certificate thumbprint already installed in the signing environment, and `TOOLX_SIGNTOOL` to the Windows SDK signtool executable. Signing occurs before checksums and packaging; no private keys or certificate passwords are stored in the repo.

The source catalog schema v1 remains the legacy reference. Native `CommandDefinition.Handler` resolves the same IDs directly, and the native catalog contract reports schema v2. Custom-script sidecars and published manifest schema v1 remain compatible. Add a new built-in by updating catalog metadata, its trusted handler, localized name and tests together.
