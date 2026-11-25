# Architecture

The core is a modular monolith bundled into one script. `Build.Manifest.json` determines source order. Only `Main.ps1` owns entrypoint parameters and startup. Runtime metadata is embedded as inert Base64-encoded JSON, then validated without invoking code strings.

Version 0.2 adds 17 built-ins (66 total) and dedicated Troubleshooting, Controls and ManagedChanges components. The registry and target policy remain the sole entrypoint for interactive commands. Read-only diagnostics use the existing worker; elevated changes stay behind typed confirmation. The scheduled helper exposes only Probe and Execute modes for validated protected job records, not arbitrary commands.

The built-in registry is checked against explicit target policies. Category modules dispatch only known operations. New metadata can reuse trusted targets; a genuinely new capability requires a handler/policy entry. Navigation has no category-specific dispatch logic.

Version 0.2.1 adds a session-only Action confirmations preference, initialized ON by the main entrypoint. An explicit OFF acknowledgement in Settings disables toolkit yes/typed-ID prompts for modifying, high-risk and custom-script actions. Registry risk/confirmation metadata stays unchanged. The parent passes a dedicated switch only to the selected operation worker; worker parameters remain independently validated. This preference does not alter Windows UAC, permission checks, recovery scheduling or script-owned input. Cleanup still lists the bounded preview and performs all deletion checks; OFF mode skips its paging/typed prompts and supplies the known operation ID internally. Final output acknowledgement remains. No preference file is written.

Custom discovery is separate: local `Scripts` root plus immediate non-support subdirectories, at most 500 entries, no reparse points, no recursive helper discovery. Metadata is UTF-8, at most 64 KiB, and accepts only version, name, description, administrator request and enabled state. No runtime plugin modules, command strings, interpreter overrides or path redirects are supported. Names do not replace IDs; custom IDs occupy the `custom/` namespace.

The executor runs ordinary read-only diagnostics in one on-demand runspace. Native output uses concurrent asynchronous character reads into a bounded queue. Rendering retains a bounded tail. Modification, administrative interfaces, elevated diagnostics and custom scripts use a dedicated console worker. The worker revalidates the entry and obtains confirmation before dispatch. The main interface does not claim to capture the child's detailed operation result.

Custom PowerShell files run in a nested original Windows PowerShell process. Batch files run using trusted `cmd.exe`, AutoRun disabled and delayed expansion initially disabled; a fixed quoted template expands the script path from a child-only environment variable exactly once. No `CALL`, supplied arguments or shell-expression input is accepted. The outer operation console survives an ordinary script `exit` and shows the interpreter exit code.

Trust remains with the selected user script. Path containment and reparse rejection prevent ordinary registration escapes; they do not prevent all file replacement races or restrict a script's Windows permissions. The toolkit does not inspect source to certify safety. Native or custom children spawned independently by a script are not managed by the toolkit.

The core deliberately creates no reports, logs, network checks, services or scheduled work at startup. Optional Windows features are checked on demand. Permission denial and missing capabilities are distinct. CIM restrictions can exist even for ordinary information queries.

SFC verification and plain CHKDSK are read-only in intention, though Windows may write logs. DISM checks are conservatively treated as modifications to servicing metadata. RestoreHealth always uses `/LimitAccess`; a compatible local mounted Windows source can be supplied. No boot repair scheduling, forced dismount, repair switches for CHKDSK, automatic reboot, or security disabling is provided.

Cleanup targets only immediate regular files older than seven days under the current user's canonical local Temp directory. Every candidate in a maximum-200-file preview is displayed; confirmation is followed by containment, reparse, age, length and timestamp revalidation. There is no recursion, wildcard deletion or user-selected cleanup root.

## Terminal presentation

The UI remains in Terminal, Navigation and Renderer. Terminal caches session privilege/color capabilities, captures appearance, and owns blocking key input and restoration. Navigation retains the existing category/search/details/parameter/execution transitions. Renderer builds logical rows with semantic color segments and compares them with the last painted frame. Identical frames write nothing; changed rows include padding to erase old content. Viewport origins and size changes invalidate the cache. One retry is allowed for positioning failures before numbered-menu fallback.

At least 110x20 cells enables list plus passive preview; 60 columns and 12 rows is the minimum positioned layout. Smaller screens temporarily use numbered menus; explicit Basic and failed/unsupported console modes remain basic. Idle menus do not poll for resize. The next key causes reflow before it is consumed once. Partially typed input retains its raw value across reflow and temporary fallback. Completed output is wrapped once per width and retains a source-line/column anchor on reflow.

Previews use registry or already-loaded custom metadata. They do not perform capability checks, discovery, hardware queries or network access. Capability checks remain at details/execution boundaries. Details and warnings that do not fit are printed completely in scrollback before a numbered or text response. Native/custom output remains in the operation console; a closed worker is not presented as a successful repair.

VT styling requires interactive output and affirmative host support. True color additionally requires WT_SESSION or COLORTERM truecolor/24bit; other hosts use native ConsoleColor mappings. ASCII chrome and escaped uncertain Unicode cells keep positioned widths deterministic without changing original identifiers or paths. Foreground/background and cursor visibility are restored on return, failure and exit. No console mode, font, window size, encoding or persistent preference is changed.

The queue and retained-output limits remain unchanged. Active operations retain their existing 100 ms checks, but unchanged waiting/running screens are not repainted. There is no added runtime library, resize timer, animation, service or rendering network request.

## Managed changes

The portable core makes no persistent changes at startup. Explicit security/update/power controls are the exception: canonical ProgramData storage, Administrators/SYSTEM ownership and write access, Users read/execute only, no reparse points, atomic file replacement, bounded typed JSON, and an exclusive state-file lock. Files include versioned standalone helpers and snapshots of original/applied settings. Firewall snapshots preserve True/False/NotConfigured per profile; update snapshots preserve absence, DWORD type and value.

Tasks use the confirming administrator SID, S4U, highest privileges, fixed native PowerShell and `-File` without any policy override. Registration is disabled until its ACL is restricted to Administrators/SYSTEM modification; then it is enabled. A unique harmless Probe job must complete before changing Windows. Probe tasks and records are removed. Failure leaves Windows settings untouched, though prepared protected helper files can remain for inspection/reuse. Existing versions with different content are refused.

Security/update jobs register before applying changes, verify effective state, and roll back partial failures. Prepared/Restoring records are recoverable after interruption. Expiry/startup triggers restore due changes; they do not poll or run a service. Conflicts and failures retain snapshots/tasks for manual retry. The status command reports due/overdue state, current task state and last result; it does not infer success from registration alone. A deleted account or later policy changes can prevent recovery.

Power jobs wait in Task Scheduler, never in a persistent console loop. They bind to a boot ID, skip execution more than 60 seconds late, and are marked Executed before issuing a power request to prevent duplicate retries. Cancellation serializes with execution. Commands use `/t 0`; `/f` is explicit only for forced closure. No wake-to-run, startup trigger or missed-run catch-up is configured for power jobs.
