# Testing: Phase 3 (WinGet provisioning)

## Automated (results on 2026-10-19, development PC, Windows 11 Insider 26220)

| Command | Result |
|---|---|
| `npm run typecheck`, `npm run lint` | clean |
| `npm test` | **268** Vitest tests in 13 files pass. This includes the Windows-only PowerShell bridge: parse check of every generated `.ps1`, both PowerShell suites, schema validation of engine output, and TypeScript/PowerShell parity. |
| `npm run test:ps` | `Engine.Tests.ps1` **25/25** (22 Phase 2 + 3 coordination); `Applications.Tests.ps1` **45/45** |
| `npm run test:e2e` | **32/32** (16 scenarios × desktop and mobile Chromium) |
| `npm run build` | passes (670 kB JS) |

### What is covered, by requirement

| Requirement | Where |
|---|---|
| Importing WinGet JSON (real format, BOM, versions, scopes, sources) | `applications-model.test.ts` › WinGet JSON import |
| Schema validation (every rule of packages.schema.2.0.json) | same, 12 rejection cases |
| Exporting valid WinGet JSON; round trip | › WinGet JSON export |
| Profile creation, duplication, rename, delete, composition, inheritance, cycles | › profile composition / profile operations |
| Duplicate detection by identifier + source (not by name; case-insensitive) | › profile composition |
| Invalid identifiers, injection attempts, missing or spoofed sources | › import; `applications-generate.test.ts` › validation |
| Empty profiles; owner defaults empty; nothing generated without a selection | › composition; `profiles.test.ts`; `applications-generate.test.ts` |
| Malicious JSON: prototype pollution, unknown members (credentials), oversize, deep nesting, injected installer arguments | `applications-model.test.ts` |
| Installation command generation; display names never on command lines | `applications-generate.test.ts`; `powershell.test.ts` (TypeScript = PowerShell commands) |
| PowerShell syntax | `powershell.test.ts` (parser over all embedded scripts) |
| Installer failure handling, retries, non-retryable codes, timeouts | `Applications.Tests.ps1` |
| Restart and resume (to finish, before install, installer-initiated, policy never, limit) | `Applications.Tests.ps1` |
| Already-installed applications; idempotent reruns | `Applications.Tests.ps1` |
| Offline conditions (Offline final, late network) | `Applications.Tests.ps1` |
| WinGet bootstrap (healthy, check-only, registration, signed and unsigned offline package, online repair, SYSTEM, outdated) | `Applications.Tests.ps1` |
| Coordination: gate, lock both ways, restart marker, lock held mid-install, pending restart | `Applications.Tests.ps1`, `Engine.Tests.ps1` |
| Results contract (every `result.json` from the scenarios matches the published schema) | `powershell.test.ts` |
| Exit-code table identical in TypeScript and PowerShell | `powershell.test.ts` |
| Coordination block identical in both engines | `applications-generate.test.ts` |
| Additional Software validation and safe execution path | `applications-generate.test.ts`, `Applications.Tests.ps1` |
| Basic/Advanced interface behaviour, import/export, profiles, manual IDs, order preview | `tests/e2e/app.spec.ts` (Phase 3 block) |
| Desktop and mobile layouts (no horizontal scroll) | e2e on both projects |
| Backward compatibility: Milestone 1 byte-identical XML; v1 and v2 profiles; Phase 2 scenarios | `windows-update.test.ts`, `applications-generate.test.ts`, `Engine.Tests.ps1` |

The scenario tests dot-source the engines, which only defines their functions, and replace every
system adapter: WinGet, network, Task Scheduler, restarts, time, signatures and hashes. **Nothing
is installed, registered or restarted.** A mutation check (forcing the update gate open and
disabling retries) made 5 scenarios fail as expected.

## Real Windows, read-only (development PC)

| Check | Result |
|---|---|
| `WinGetBootstrap.ps1 -Mode Check` | `Healthy (WinGet 1.29.250)`, nothing repaired |
| `ApplicationEngine.ps1 -Mode Plan` with the illustrative sample (5 packages, winget + msstore) | 8 s: 4 already installed, Whiteboard available to install, exact commands shown. Nothing installed or written (no `ProgramData` folder created). |
| Catalog identifiers | `winget show --id … --exact` for 48 entries: 47 found, `LaunchBox.LaunchBox` not found, so the entry is listed as unresolved |
| `winget import` of a builder-generated file | Accepted, exit 0 (the file contained only identifiers that `winget show` had confirmed do not exist, so nothing could be installed). A malformed file is rejected with `0x8A150036` for comparison. |
| Builder importer on this PC's real `winget export` | 165 packages, none rejected, exact round trip (file kept outside the repository) |
| `winget list` / `winget show` exit code for a missing package | `0x8A150014`, as the engine expects |

## Not tested: needs a disposable VM (status: UNVERIFIED)

Use the VM from `docs/testing.md` B and C, with Internet, owner defaults plus a small selection
(for example Git, 7-Zip, VLC and one Store app), and Windows Update automation on.

1. After the first sign-in:
   - [ ] `FirstLogon.log` order: FirstLogon.ps1, then Install-UpdateEngine.ps1, then
         Install-ApplicationEngine.ps1, which reports "Application engine is running".
   - [ ] Task Scheduler: `\WindowsDeploymentBuilder\Applications` runs as the user, "Run only when
         user is logged on", highest privileges, no stored password.
   - [ ] `Applications\logs\engine.log` shows preparation (WinGet check, availability) and then
         "Waiting for Windows Update to finish".
   - [ ] WinGet availability right after first sign-in: does the check report `Healthy`, or is
         registration needed? Record which.
2. While Windows Update runs:
   - [ ] `state\install.lock` changes hands; there are no overlapping installations in the two logs.
   - [ ] Every Windows Update restart is preceded by `restart-pending.json`.
   - [ ] After the WU marker (`windows-update.done`) appears, applications install one at a time.
3. End:
   - [ ] `Applications\result.json` is `Succeeded`, `applications.done` exists, the task is gone,
         and events 2000/2100 appear.
   - [ ] The apps work, and per-machine installs are in Program Files.
   - [ ] Run the installer script again: everything becomes `AlreadyInstalled`; nothing is
         reinstalled.
4. Negative runs (fresh VM each):
   - [ ] A package that needs a restart (for example `Microsoft.WSL` on a clean image): restart,
         then verified.
   - [ ] No network for the whole run: `Offline`, packages `Pending`, no marker.
   - [ ] App Installer de-registered for the user before first sign-in, or a Windows edition
         without it: the registration and offline paths work. Supply a Microsoft-signed bundle in
         `offline\`.
   - [ ] Microsoft Store package with the Store present, and with no Microsoft account signed in.
   - [ ] Standard-user selection is blocked in the UI; automatic sign-in off means the installation
         waits for sign-in.
   - [ ] Pull the network during an installation: the package is retried and the run still ends in
         a final state.
5. Record everything in `docs/validation-log.md`.

Also unverified: whether `--silent` is honoured by every selected installer (WinGet passes the
manifest's silent switches; some installers ignore them), and per-user (`scope: user`) installers
running in the elevated context.
