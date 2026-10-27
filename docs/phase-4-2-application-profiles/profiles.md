# Profiles, devices, overrides and saved profiles (Phase 4.2)

## Built-in profiles

Defined in `src/data/apps/profiles.json` (catalog ids only), validated at load by
`src/engine/applications/builtin.ts`. They are templates: never stored in a deployment, never
edited, renamed or deleted. "Duplicate" makes an editable custom copy.

| Profile | Ticked by default | Recommended (shown unticked) |
|---|---|---|
| **Core Essentials** (selected in every new deployment) | Google Chrome, VLC, 7-Zip, TeraCopy, RustDesk (manual follow-up), Bitwarden, Visual C++ 2015-2026 x64 and x86 | — |
| Everyday Essentials | Adobe Acrobat Reader | Firefox, Edge, Thunderbird, Zoom, WhatsApp, Google Drive, OneDrive, XnView MP, Everything, QuickLook, Spotify, PowerToys |
| Gaming | Steam, Epic Games Launcher | Battle.net, EA app, Ubisoft Connect, GOG GALAXY, Playnite, Discord, RetroArch, LaunchBox (manual) |
| General Developer | Git, Visual Studio Code, Python 3.14, Node.js LTS | GitHub Desktop, Cursor, Claude Code, Claude Desktop, ChatGPT, Sublime Text, Docker Desktop, Wireshark, WinSCP, PuTTY, FileZilla (manual), Tailscale, WireGuard, WinMerge, WizTree, Notepad++, Windows Terminal, PowerShell 7, WSL, Python 3.13 |
| Network Engineer / Developer / Technician (includes General Developer) | Cursor, Claude Code, Claude Desktop, ChatGPT, GitHub Desktop, Sublime Text, Docker Desktop (+ WSL as its dependency), Wireshark, WinSCP, PuTTY, FileZilla (manual), Tailscale, WireGuard, WinMerge, WizTree, HWiNFO, CrystalDiskInfo, CrystalDiskMark, Bulk Rename Utility, Rufus, Ventoy, qBittorrent, SABnzbd, Syncthing | QuickLook, FreeFileSync (manual), Everything, PowerToys, Sysinternals, Nmap, Notepad++, Windows Terminal, PowerShell 7, VirtualBox, Revo Uninstaller |
| Music Enthusiast | MusicBee | Tauon Music Box, Dopamine 3, Museeks, mpv.net, Audacity, HandBrake, Spotify, iTunes, Apple Music, OBS Studio |
| iPhone / iPad (device profile) | Apple Devices | Apple Music, iTunes, iCloud for Windows |
| Android (device profile) | — | Quick Share from Google, Samsung Smart Switch |
| Laptop | BatteryInfoView | Dell Command \| Update, Lenovo System Update, Lenovo Vantage |
| Touchscreen / 2-in-1 | Xournal++ | Microsoft Whiteboard, Joplin |

Owner decisions that are not obvious from the table: Music Enthusiast ticks only one library
manager (MusicBee) so that customers pick their own player; Everyday Essentials ticks only a PDF
reader. The old empty built-in "Custom" profile is gone: saved profiles replace it.

## Mobile devices & ecosystem

Questions: *What type of smartphone does the customer use?* (iPhone / Android / Other or none) and
independent checkboxes for iPad, additional iPhone and Android tablet. Only the kind of device is
recorded: no names, serial numbers, phone numbers or accounts.

* iPhone (primary or additional) or iPad activates **iPhone / iPad**: Apple Devices is ticked, and
  Apple Music, iTunes and iCloud are recommended. An Android phone plus an iPad activates both
  device profiles.
* Android phone or tablet activates **Android**, which ticks nothing: ordinary USB file transfer
  needs no software. Manufacturer tools are optional and there is room for more (Pixel, others).
* Apple Devices stays removable like every other app. iCloud for Windows is installed only, with a
  warning about the data volume of iCloud Photos/Drive; no Apple Account is signed in.

## Selection rules (deterministic)

`src/engine/applications/selection.ts` resolves the selection in this order:

1. **Active profiles**: the ticked profiles, every profile they include (`inherits`), and the
   device profiles the answers activate (the deployment's answers combined with those saved in a
   ticked custom profile).
2. **Selected** = the defaults of all active profiles ∪ individual additions ∪ dependencies of those
   (catalog `requires`).
3. **Removed** = individual removals ∪ exclusions saved in an active custom profile (an individual
   addition beats a saved exclusion).
4. **Recommended** = optional apps of the active profiles that are neither selected nor removed.
5. De-duplication by source + identifier (case-insensitive), never by display name.
6. Order: dependencies before dependants, unattended packages first, then packages needing
   interaction, manual follow-ups, unresolved ones.

Behaviour that follows from the rules:

| Action | Effect |
|---|---|
| Tick a profile | Its defaults are selected unless you removed them earlier; your earlier changes stay. |
| Untick a profile | Its defaults leave the plan, and so do its recommendations you ticked (unless another active profile also recommends them). Apps you added yourself stay; your removals stay recorded but have no effect while nothing selects the app. |
| Untick an app that a profile selects | Recorded as a removal (`removed`). The profile itself never changes. Shown as "Unticked by you (default in …)". |
| Tick an app | Undoes a removal, or adds the app individually (`added`). A recommendation of an active profile is linked to the profiles that recommend it (`addedWith`) and leaves the plan with them; any other app is your own addition and survives profile changes. |
| Change a device answer | Its device profile's defaults and the recommendations of it you ticked follow the answer. |
| Untick a dependency | It stays out, and the dependent app gets a warning. |
| Restore defaults (on a profile card) | Ticks that profile's defaults again and unticks its recommendations you had ticked. |
| Undo my changes | Clears all individual additions and removals; ticked profiles and devices stay. |
| Reset applications (Advanced) | Core Essentials only, no devices, no changes. Saved profiles are kept. |
| Reset to owner defaults (header) | The whole configuration; saved profiles are restored from browser storage. |
| Import a deployment profile (header) | Replaces the whole configuration with the file; saved profiles in the browser are added back. |
| Import application profile JSON | Adds new custom profiles and ticks them; nothing existing is changed. |

The application profiles a deployment uses are saved with it in the deployment profile JSON
(`applications.selection`: custom profiles, ticked ids, devices, additions, removals).

## Saved (custom) profiles

* **Save as new profile…** turns the current selection into a profile: the ticked profiles become
  its parents, the individual additions its packages, the removals its exclusions, and the device
  answers are saved with it. The deployment then ticks just that profile, which resolves to the same
  apps (checked in code; a mismatch is an error).
* **Update from selection** folds later changes into a ticked custom profile (or replaces an
  unticked one with the current selection).
* Rename, Description (Advanced), Duplicate, Export and Delete (with confirmation) work on custom
  profiles. Built-in profiles offer only Duplicate, Export and Restore defaults.
* Names are untrusted text: the UI only ever sets them as text, and in generated files they are
  JSON/XML-escaped data. They never become part of a command.

## Browser persistence

`src/ui/library.ts` keeps custom application profiles in `localStorage` (`wdb.appProfiles`, the same
JSON as an export).

* Survives page reloads and browser restarts while the site data is kept. Restored after a reset or
  an import. A profile leaves storage only through Delete.
* Only application profiles are stored: never the deployment profile, names, passwords, Wi-Fi keys
  or licence keys (the strict schema has no fields for them).
* It is local to this browser and not a backup; the UI says so and offers Export.
* Corrupt or incompatible data is ignored with a readable message; an id that clashes with a
  built-in profile is renamed; if storage is blocked (private mode) the page still works and says
  that saved profiles last only for the session.
* The current, unsaved selection is not stored automatically (as before: the configuration can hold
  passwords). Save it as a profile, or export the deployment profile.

## JSON formats

* **Application profile file** (`windows-deployment-builder/app-profiles`), format version **2**:
  version 1 plus optional `optional`, `excluded`, `devices`, `createdUtc`, `updatedUtc` per profile.
  Version 1 files still import. Unknown members (a password, a URL, a command) are rejected; invalid
  identifiers and exclusions are dropped with a warning; imported profiles are never built-in.
* **Deployment profile**, schema version **4**: `applications.selection` stores only custom profiles
  and gains `devices`. Migration from version 3: empty v3 built-in profiles are dropped and unticked;
  a v3 built-in profile someone had filled becomes a custom profile "… (from an older profile)" with
  the same packages, ticked if it was; Core Essentials is *not* added, so an older profile installs
  the same applications as before.
* **Native WinGet list** (`winget-packages.json`, Microsoft's schema 2.0) stays the portable package
  list: it contains the WinGet and Store packages of the plan (portable ones with `Scope: machine`).
  Manual follow-ups cannot be expressed in it and are not exported there.
* `profiles/applications.json` in the ZIP is the effective, flattened selection in the builder's
  format; `applications-config.json` is the executable plan the engine reads.
