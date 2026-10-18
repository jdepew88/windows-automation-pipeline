# Implementation report: Milestone 1

## Built

- **Engine** (`src/engine`, framework-agnostic):
  - Zod profile schema v1 with a migration framework
  - Owner-default profile, import/export with secrets stripped by default, profile diff
  - Deterministic name derivation
  - Namespace-aware, ASCII-safe XML serializer/parser
  - Upstream-style staged script pipeline: Specialize / DefaultUser / UserOnce / FirstLogon
  - Advanced-component merge with conflict detection
  - Structural self-checks on every generated file
- **Settings registry**: 118 settings across 18 sections. Each has a type/control, choices, the owner
  default (from `profiles/owner-default.json`), description, applicability, caveat, stage(s), a
  traceable mapping and a mechanism status. `docs/settings-mapping.md` is generated from it.
- **Features**: setup/region/edition, accounts and naming, security (UAC levels, AppLocker),
  privacy, Windows Update, system tweaks, Explorer, taskbar, desktop, Start, personalization (visual
  effects, sticky keys), tri-state app removal (62 apps), virtualization/VM guest tools, Wi-Fi
  (interactive/skip/SSID/XML), four custom-script stages, additional XML components, output name,
  and deferred extension points.
- **UI**: a responsive Vite + TypeScript app.
  - Basic/Advanced views
  - Field-level errors and warnings
  - Live username/computer-name preview
  - Security warning for empty-password auto-login
  - Review with summary, owner-default diff, XML preview, embedded-file viewer and download
  - Import/export/reset
- **Docs**: README, architecture, settings mapping, testing (with the WSIM/VM procedure), roadmap,
  upstream attribution, third-party notices, sample file.

## Tested (automated, all passing at commit time)

- `npm run typecheck`, `npm run lint`: clean.
- `npm test`: 121 Vitest tests in 9 files, including snapshots of the owner default, arm64 fan-out,
  a minimal profile and a custom component.
- `npm run test:e2e`: 9 Playwright scenarios × 2 projects (desktop and Pixel 7 Chromium) = 18 passing.
- `npm run build`: production bundle about 440 kB (118 kB gzip).

## Not tested / unverified

- **WSIM catalog validation**: not run. No Windows ADK in this environment.
- **VM installs with and without Internet**: not run. The local-account flow, manual partition stop,
  FirstLogon timing, and app removal on the real image are **unverified**.
- Mechanisms marked `unverified` in the mapping:
  - persistent auto-logon (removing `AutoLogonCount` at first logon)
  - shortcut-arrow overlay (`Shell Icons\29`, undocumented)
  - `Enable-ComputerRestore` at first logon
- Mechanisms marked `documented` follow Microsoft documentation but were not observed on a target
  build here: UAC values, Windows Update AU policy, driver exclusion, telemetry/advertising/location/
  inking/Recall/WER/Insider policies, HideOnlineAccountScreens.
- Whether OOBE skips the Microsoft-account page when online depends on the build. It must be
  confirmed per ISO.

## Decisions where the specification was silent (please confirm)

| Setting | Chosen default | Reason |
|---|---|---|
| Bypass Windows 11 requirements | Off | Not requested. Owner targets supported hardware. Enable it for VMs without TPM |
| `HideOnlineAccountScreens` | true | Reinforces "no Microsoft account regardless of network" |
| Bing results in Start | Disabled | "Maximum practical privacy" |
| System Restore | Explicitly enabled at first logon | Windows does not always enable it on fresh installs |
| Diagnostic data | Required (policy, AllowTelemetry=1) | Minimum available on Pro |
| Time zone | Windows-determined | Not specified. Note that location services are off |
| Lockout/password expiration | Windows defaults | As specified |
| Keep sensitive files | Off (Panther copies deleted at first logon) | Upstream default; protects keys/passwords |
| Person's name | Empty | Must be entered. Generation is blocked until it is |

## Blockers

None for code. Hardware/VM validation needs a Windows machine with Windows ADK and a hypervisor; it
is the owner's next step.

## Sample

`docs/samples/autounattend.sample.xml`: owner defaults with the name "Alex". Regenerate it with
`npm run generate:sample -- <Name>`.

## Next milestone steps

1. Run `docs/testing.md` A and B, then log the results in `docs/validation-log.md`.
2. Fix findings and confirm the three unverified mechanisms.
3. Design the M3 bundle: staged `setup.ps1` with a state file, retry queue and connectivity checks;
   WinGet JSON; PowerShell 7.
