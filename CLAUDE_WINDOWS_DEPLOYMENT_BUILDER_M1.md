# Claude Implementation Handoff — Windows Deployment Builder, Milestone 1

**Status:** Approved requirements and implementation brief  
**Project:** Windows Deployment Builder  
**Platform:** Windows 11 Pro installation media; local, browser-based authoring application  
**Implementation:** TypeScript throughout the web app and generator (no C# runtime dependency)  
**Delivery:** A working, tested Milestone 1 repository, not merely mockups.

## Mission

Build a locally runnable TypeScript web application based on the capabilities and configuration structure of Christoph Schneegans' Windows Unattend Generator. It must produce a valid `autounattend.xml` for Windows 11 Pro with the owner's detailed preferred defaults, while still exposing supported alternatives. The user is building an extensible *generator*, not a hardcoded XML template. Specialized settings should appear behind Advanced toggles, not be removed.

**Required reading before coding:**

- Live generator: https://schneegans.de/windows/unattend-generator/
- Official upstream source: https://github.com/cschneegans/unattend-generator
- Upstream license: https://github.com/cschneegans/unattend-generator/blob/master/LICENSE.txt (verify current path/license and preserve attribution for copied MIT-licensed code)
- Windows unattended reference: https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/
- Windows Setup automation: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/automate-windows-setup
- FirstLogonCommands: https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-firstlogoncommands
- Windows System Image Manager (Windows ADK) for catalog-based answer file validation.

Review actual upstream code, XML patterns, execution stages and supported options; do not assume the public webpage's assets share the published library's license. Reimplement relevant logic in TypeScript. Document any code adapted under applicable copyright/license terms. Capture the upstream revision used for reference.

## Non-negotiable UX and scope

- **Milestone 1:** Local responsive Vite + TypeScript app; typed configurable profile; generation/preview/download of `autounattend.xml`; profile JSON import/export; user-defined script entry support for the four stages; testing and documentation.
- **Not Milestone 1:** Full WinGet package management, package searches, installing applications, full ZIP orchestration, boot media editing, ISO manipulation, unattended disk formatting, ongoing background software deployment. Provide clean extension points, not pretend implementations.
- **Later destination:** One downloadable `Windows-Deployment.zip` with `autounattend.xml`, WinGet-native JSON, scripts, `setup.ps1`, ancillary config and README. User places XML onto installation media manually. Scripts must eventually be staged onto disk and first-logon orchestration must be durable, idempotent and connectivity-aware.
- Basic view exposes ordinary choices. Advanced view expands rare ones. Custom scripts: **FirstLogon visible**; **System, DefaultUser, UserOnce under Advanced**. Additional XML components under Advanced, blank initially.
- All settings in an implemented section remain changeable even where a particular owner default is selected. Do not delete the bloatware options when defaults say Keep.
- Each setting has type, allowed choices, default, description, Windows applicability, risk/caveat, implementation stage, and traceable XML/policy mapping.
- No auto-run script or destructive disk action in browser. Do not claim success on untested physical hardware.
- Do not persist imported WinGet lists automatically between sessions. Default package list empty. JSON profiles must support manual import/export. Reset only to **owner's defaults**, not a second reset-to-Windows-defaults button.
- The final review offers Basic summary and Advanced full diff and XML preview. Show validation failures and actionable issues rather than generating invalid output. Earlier voice discussion briefly declined optional *extra* conflict warnings; nevertheless hard validation errors must always be shown.
- Local/offline generator operation; dependency/update checks in a future opt-in/notify-only area must not affect generation or modify owner defaults.

## Suggested implementation plan

Use Vite + TypeScript, Zod (schema and cross-field validation), XMLBuilder2 or equivalent XML writer with namespace correctness, Vitest and browser tests (Playwright recommended). Keep `/src/engine` framework-agnostic. Define schema version and migrations for imported JSON. Use declarative, centrally registered settings with per-setting transform functions and unit tests. Map operations to valid unattend passes (`windowsPE`, `specialize`, `oobeSystem`) or correctly staged setup scripts; not everything belongs directly in unattend XML. **Do not hallucinate unattend component names or unsupported policy settings.** Follow Windows ADK/WSIM rules and upstream tested structures.

Suggested modules: `/src/features/{setup,accounts,privacy,system,explorer,taskbar,desktop,start,bloatware,virtualization,wifi,personalization,scripts,advanced-xml}`, `/src/engine/{schema,xml,stages,profiles,validation}`, `/profiles/owner-default.json`, `/tests`, `/docs`.

## Owner default profile — decisions recorded in conversation

### Setup, region, computer identity

- English (United States), United States region, US keyboard; remove unnecessary language selectors from Basic (advanced alternatives only if implemented).
- Install **Windows 11 Pro** selected with generic *installation-only* key `VK7JG-NPHTM-C97JM-9MPGT-3V66T`; never represent this as a license or activation method.
- Windows PE remains **interactive for target drive selection and partitioning**. Never automatically select/clean/format a disk. Setup should reach disk selection quickly; user will prepare drive manually.
- Input one person's name. Derive local username and `Name-Computer` machine name (hyphen); sanitize Windows restrictions and enforce maximum 15 characters for broad compatibility, preserving `-Computer` where possible; handle collisions and edge names.
- Create **local Administrator** user, no Microsoft account, empty password, **automatic desktop login**. Keep UAC enabled. Warn clearly that this configuration exposes an administrator session to anyone with physical access and does not ensure BitLocker protection at login. Use secure unattended mechanisms validated on actual Windows 11 media; network connectivity must not change account creation behavior.
- Account lockout at Windows default; password/expiration defaults unchanged. Do not store secrets in Git.

### Security and privacy

- Defender Antivirus and Firewall enabled with default protections. SmartScreen enabled. Smart App Control remain enabled where supported. System Restore enabled. Do not disable device encryption/BitLocker support.
- UAC enabled at second-lowest slider, normal desktop prompt without dimming. Desired effective settings: `EnableLUA=1`, `ConsentPromptBehaviorAdmin=5`, `PromptOnSecureDesktop=0` (confirm correct hive/staging and reboot implications).
- Remote Desktop disabled. AppLocker unconfigured by default (advanced custom policy option). Audit process creation disabled. Windows Insider enrollment disabled.
- Maximum practical privacy: disable optional diagnostic personalization, advertising ID, optional inking/typing collection, tailored experiences, location services, Microsoft promotional/sponsored content, user-facing suggested apps, Copilot and Recall optional features where supported. Keep basic functionality, Defender, Firewall, updates. No false claims that Windows 11 Pro can eliminate all required telemetry.
- Express Settings: **Disable All** optional express privacy options.
- Do not disable Smart App Control, SmartScreen, or core security in service of debloating.
- Updates configurable by person, **owner default to user-controlled installation where supported**; support automatic alternative, with limitations clearly stated. Do not fully disable Windows Update. Exclude automatic driver delivery via Windows Update by default. Do not block Windows-initiated restart by unsupportable global workaround.

### System tweaks

- Fast Startup **off**, hibernation **on**. Preserve dependency and don't implement `powercfg /h off` merely to disable Fast Startup.
- Windows Error Reporting disabled by owner default (recognize support/diagnostic tradeoff).
- PowerShell script execution `RemoteSigned`; PowerShell 7 selected for later installation integration (make separation clear: XML-only M1 cannot promise installation without staged downloads or script execution).
- Harden ACLs: unchanged. Long paths: unchecked. Hidden compatibility junction-point deletion: unchecked. NTFS last-access timestamp: Windows default. System sounds: keep. Prevent Windows Update restarts: unchecked. Prevent device encryption: unchecked.
- Edge first-run experience suppressed; Edge Startup Boost and background mode disabled; **do not** uninstall Edge or change it to be uninstallable by default.
- Mouse pointer acceleration / Enhance Pointer Precision disabled. Automatic `Windows.old` cleanup unchecked. Automatic sign-in after update restarts at default/unchecked (separate from initial login). Ignore Windows Platform Binary Table unchecked. Sponsored/hardware-triggered suggested app installation prevented. Process creation auditing off.

### Explorer, taskbar, desktop and Start

- File extensions **shown**. Hidden files **hidden**, protected OS files **hidden**. Explorer opens **This PC**. Native Windows 11 context menu kept. Thumbnail icon overlay at default. Desktop shortcut arrows removed (confirm documented mechanism and warn where shell tweaks may not be robust).
- Taskbar left-aligned; Search **icon only**, Task View **visible**, Widgets **hidden**, obsolete Chat **absent/hidden**, don't try to restore it.
- Desktop icons option **Show These** with **Recycle Bin only**; This PC, user files, Network, Control Panel hidden. Remove Edge desktop shortcut. Distinguish desktop This PC visibility from Explorer home This PC.
- Start menu pins at default, but **Folders on Start** custom: Documents hide; Downloads show; File Explorer hide; Music hide; Network hide; Personal folder show; Pictures show; Settings show; Videos hide.
- Visual effects: Windows default. Colors, wallpaper and lock-screen image: Windows default. Sticky Keys and Lock Keys default. Power settings default. Maintain Windows system sounds, including device plug-in sound.

### Debloat — individual editable tri-state

Implement grouped Advanced lists with **Keep / Remove / Leave untouched** semantics. `Keep` means don't remove, *not* install if absent; `Leave untouched` means no action. App removal should be tolerant of absent or retired apps and based on package identifiers/version applicability, not only friendly labels.

**Remove by owner default:** 3D Viewer, Clipchamp, Feedback Hub, Maps, Microsoft News, Microsoft Pay, Teams personal, Mixed Reality Portal, Movies & TV, OneNote for Windows 10, People, Quick Assist, Skype, Tips, Weather, OneDrive (with startup/setup prompts disabled where supported).

**Keep by owner default:** Alarms & Clock, Calculator, Camera, Dev Home, Get Help, Mail & Calendar, Media Player, Microsoft Photos, Microsoft Store, Microsoft To Do, Paint 3D, Power Automate, Snipping Tool, Solitaire Collection, Sound Recorder/Voice Recorder as named in versions, Sticky Notes, Windows Backup, Xbox app and gaming services, Xbox Game Bar, Xbox Identity Provider, Phone Link.

**Cortana:** Explicitly **leave untouched** (may not exist on target release).

Review the list for duplicates and obsolete Windows apps; preserve user-facing selection but map to actual installed package identities only where appropriate. Do not run removal without platform detection; avoid provisioning state corruption.

### VM hosts and guests

- Core Isolation enabled where supported. Preserve Virtual Machine Platform and Hyper-V availability; do not disable them. Differentiate VBS/Core Isolation, the Microsoft hypervisor, Hyper-V features, WSL2, Docker Desktop, Windows Sandbox, VMware Workstation, VirtualBox. Enabling every component is not inherently necessary on all targets; reflect **do not disable**, not an instruction to silently install everything on every family computer.
- VM Guest options all unchecked by default: VirtualBox Guest Additions, VMware Tools, VirtIO/QEMU Guest Agent, Parallels Tools. Retain all controls for special VM builds.

### Wi-Fi and first-boot intention

- Wi-Fi default: interactive selection during installation. Alternatives (skip, manually supply SSID/password, import profile) selectable but unselected by default. Never store network credentials in owner profile.
- User's intended flow: boot USB; manually select/format install partition; connect to Wi-Fi if offered; Windows 11 Pro installation; local account auto-created; auto-login; first-logon automation begins without user manually launching scripts. No Microsoft online account regardless of network availability. Current Windows OOBE behaviors require actual testing; never guarantee every media version behaves the same.
- M1 should prove XML's interactive disk path, local-account creation, and FirstLogon command mapping in a disposable VM. **Later milestone** must stage deployment files on the destination Windows volume or another reliable medium *before* first login. WinGet needs a valid installed/runtime context, network and user session. Queue/retry/log internet-dependent work later; no empty ZIP pretending to execute.

### Custom scripts and advanced XML

- Keep functionality for System scripts, DefaultUser scripts, FirstLogon scripts, UserOnce scripts. No preselected sample scripts; no Visual C++ Redistributable, 7-Zip offline installer, or sample gallery as M1 features. FirstLogon editor always visible, other three under Advanced. Each script type: create/edit/enable/disable/reorder/delete, show context/timing, ensure XML escaping and safe command staging. Distinguish script-entry support from future `setup.ps1` orchestrator.
- Advanced XML Markup for More Components: optional, blank. Parse XML, validate syntax, component/pass/architecture uniqueness, preserve namespaces, reject conflicting insertions; no unsafe blind string concatenation.
- AppLocker remains unconfigured default but advanced policy input available if mapped and validated.

### Download and profile behavior

- Default answer filename `autounattend.xml`. Alternative `notautounattend.xml` under Advanced only; note only standard filename automatically discovered on USB media. No ISO wrapping in M1. Preview XML, download XML, JSON profile import/export, Reset to Owner Defaults, final basic/advanced review.
- Later ZIP bundle, WinGet-native `winget export`/`winget import` JSON, empty list default, individual package selection, command dry run, external script templates, update-check notifications (notify only, no automatic changes). Keep storage/selection isolated from M1 engine.

## Explicit hazards to address rather than hide

1. Windows setup key selects edition only; no activation.
2. Empty-password admin + auto-login is risky. Make it the requested default while labeling it clearly; do not silently replace it with a safer but different account mode.
3. Initial auto-login and the separate Windows update auto sign-in feature are **not the same**.
4. Some earlier conversation descriptions casually called XML settings 'checkboxes' even where Schneegans offers radio selections; use the real upstream data model.
5. Certain settings are only reliably applied from setup scripts/registry/group policy and may need staging; enumerate the actual mechanism and support status; do not fake direct XML nodes for these.
6. Bloatware apps vary between Windows builds; use version gates and tolerant skip behavior.
7. Active Internet should not force a Microsoft account in the intended unattended workflow; verify with target Win11 image/build, not assumptions.
8. For local username and computer name, account name normalization must be deterministic; 15-char hostname limit is a compatibility target.
9. Windows Startup optimization, hibernation and power policies interact; preserve requested combination.
10. The upstream `unattend-generator` repository may not provide the same license for every asset on its website; audit provenance.
11. An XML document being syntactically well-formed does **not** establish that Windows Setup will accept or execute it. Use WSIM/ADK and a VM.

## Acceptance tests

- `npm install`, `npm run dev`, `npm run build`, `npm test` work from a fresh clone. Include lint/typecheck and browser smoke tests.
- The owner profile loads to the exact chosen controls. Basic/Advanced toggling does not reset values. Import/export round trip retains every supported field. Owner-default reset restores all decisions.
- Snapshot tests for default XML and variation cases; XML parser assertions, schema validation, architecture and pass assertions. No plain-text secret leakage by default.
- Automated validation rejects incompatible combinations and provides field-level messages. Test proper XML escaping of quotes, ampersands, script text, and names.
- Disk setup remains interactive under generated XML; automatic disk wipe is absent.
- Edits to account name correctly update hostname and local account references.
- Tests for the four script stages and empty lists; no phantom script execution from blank fields.
- Tests for optional advanced XML merge conflicts and malformed input.
- Validate resulting answer file against target Windows 11 Pro image using Windows ADK/WSIM. Carry out disposable VM setup smoke test with Internet and without Internet for local account flow, ensuring manual partition selection and FirstLogon timing.
- Document exact validated Windows ISO/build, repository revision, Windows ADK version, VM environment, limitations, deferred items and any unverifiable assumptions. If VM testing cannot be executed in Claude's environment, provide the precise local test procedure and report *unverified* rather than marking complete.

## Deliverables from Claude

1. Working repository code, tests, owner-default profile, and README.
2. `docs/architecture.md`, `docs/settings-mapping.md` (each setting → XML/script/policy pass and validation), `docs/testing.md`, `docs/roadmap.md`, and `docs/upstream-attribution.md`.
3. A short implementation report: built, tested, not tested, blockers, sample generated file and next milestone steps.
4. Git commits with descriptive messages; do not push/deploy unless the user explicitly authorizes remote actions. Do not create public repositories.

## Directions to Claude

Start by inspecting the upstream GitHub repository and live generator to understand exact option semantics. Establish the declarative configuration schema and XML stage pipeline before building UI. Prioritize correctness over cosmetic polish. Implement Milestone 1 end to end, validate what is possible and explain actual test limits. Avoid treating every planned future feature as completed functionality. If the upstream repository doesn't contain the live site's full source, say so and reference official Windows documentation for the remaining implementation. Do not broaden scope to the full deployment ZIP or WinGet execution yet.
