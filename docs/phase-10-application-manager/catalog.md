# Phase 10A: catalog, categories and profiles

Generated from `src/data/apps/catalog.json` (catalog 2, updated 2026-10-25) and `src/data/apps/profiles.json`.

## Sources and verification

- The owner inventory `docs/application-inventory/WDB_Application_Identity_Catalog_WinGet_Only.csv` (130 rows). Its exact WinGet identifiers were used; no name matching, no substitution.
- Every identifier (the 130 from the CSV and every existing catalog identifier, 184 in all) was checked read-only against the `microsoft/winget-pkgs` repository at commit `fbe878e92602fbfadfd72c6604f93209bb6f101b` (2026-10-25) with `scripts/verify-winget-ids.ts`. Evidence: `winget-verification-2026-10-25.json`. All 184 exist with exactly that spelling; every installer in the latest manifests has a SHA-256.
- WinGet was **not** run on the development PC (no source update, no agreement prompts, nothing installed). The Application Manager validates each identifier again with `winget show --id <id> --exact` on the target computer before installing.
- `scripts/catalog-source.mjs` refuses to generate the catalog if an identifier is unverified or its case differs from the repository.

## Totals

- 190 entries (75 added in Phase 10: 74 WinGet, 1 manual), 28 exclusions with reasons.
- Kinds: application 141, runtime 17, launcher 10, manufacturer 9, service 5, system 4, driver 3, sdk 1
- Removal safety: normal 136, caution 36, blocked 18
- Upgrade method: winget 180, manual 7, explicit 3 (`explicit` = the manifest sets RequireExplicitUpgrade: Parsec, Discord, Slack; never part of "Update all eligible").

## Categories (what an application does)

Categories are independent of profiles. An application has one category and can belong to any number of profiles.

| Category | Entries |
|---|---|
| Web Browsers (`browsers`) | 6 |
| Communication (`communication`) | 8 |
| Documents, PDF & Notes (`documents`) | 6 |
| Books & E-readers (`books`) | 2 |
| Photos & Imaging (`media`) | 4 |
| Music & Streaming (`music`) | 10 |
| Media Players & Video (`video`) | 5 |
| Audio & Video Production (`creative`) | 7 |
| Gaming Platforms & Tools (`gaming`) | 14 |
| Developer Tools (`development`) | 20 |
| AI Assistants & Local Models (`ai`) | 6 |
| Virtualization (`virtualization`) | 6 |
| Network Tools & Diagnostics (`networking`) | 8 |
| Remote Access & Streaming (`remote`) | 9 |
| Downloads & Transfers (`downloads`) | 4 |
| File Management (`files`) | 8 |
| Disk & Storage Utilities (`storage`) | 11 |
| USB & Imaging Tools (`usb`) | 5 |
| System Utilities & Diagnostics (`utilities`) | 8 |
| Cloud & Device Integration (`cloud`) | 6 |
| Security, Passwords & VPN (`security`) | 8 |
| Peripherals, RGB & Device Control (`peripherals`) | 5 |
| Runtimes (`runtimes`) | 17 |
| Battery & Manufacturer Utilities (`hardware`) | 4 |
| Pen, Touch & Handwriting (`touch`) | 3 |

## Profiles (who gets it)

Profiles stack. An application selected by several profiles is installed once and shows every profile that selected it. An application the user removes stays removed when profiles change. Profiles never uninstall anything.

### Core Essentials (`core`)

The small universal baseline: browser, media player, archives, verified copying, a password manager and the Visual C++ runtimes. Remote support (RustDesk) and power-user tools stay optional. Every app stays individually removable.

- Selected: Google Chrome, VLC media player, 7-Zip, TeraCopy, Bitwarden, Visual C++ Redistributable 2015-2026 (x64), Visual C++ Redistributable 2015-2026 (x86)
- Recommended (not ticked): RustDesk, Notepad++, Everything, PowerToys

### Everyday / Home (`everyday`)

Home use: a PDF reader by default, with email, video calls, messaging, cloud storage and photo viewing to choose from.

- Selected: Adobe Acrobat Reader (64-bit)
- Recommended (not ticked): Mozilla Firefox, Microsoft Edge, Mozilla Thunderbird, Zoom Workplace, WhatsApp, Google Drive, Microsoft OneDrive, XnView MP, Everything, QuickLook, Spotify, PowerToys, LibreOffice, Mozilla Thunderbird ESR, Microsoft Teams, Amazon Kindle, calibre, ImageGlass

### Gaming (`gaming`)

Steam and the Epic Games Launcher, with the other launchers, Playnite and Discord to choose from. No accounts, logins or game libraries are configured.

- Selected: Steam, Epic Games Launcher
- Recommended (not ticked): Battle.net, EA app, Ubisoft Connect, GOG GALAXY, Playnite, Discord, RetroArch, LaunchBox, RivaTuner Statistics Server, Rockstar Games Launcher, ScummVM, HidHide, OBS Studio

### General Developer (`developer`)

A lean developer baseline: Git, Visual Studio Code, Python and Node.js LTS. Editors, AI tools, containers and network tools are optional.

- Selected: Git, Visual Studio Code, Python 3.14, Node.js (LTS)
- Recommended (not ticked): GitHub Desktop, Cursor, Claude Code (CLI), Claude Desktop, ChatGPT Desktop, Sublime Text 4, Docker Desktop, Wireshark, WinSCP, PuTTY, FileZilla Client, Tailscale, WireGuard, WinMerge, WizTree, Notepad++, Windows Terminal, PowerShell 7, Windows Subsystem for Linux, Python 3.13, CMake, GitHub CLI, draw.io, LM Studio, Ollama

### Network Engineer / Technician (`network-engineer`)

A complete personal power-user workstation: the General Developer baseline plus AI and development tools, networking and remote administration, diagnostics, USB tools, downloads and synchronisation. VPNs, sync and download tools are installed only, never configured.

- Selected: Cursor, Claude Code (CLI), Claude Desktop, ChatGPT Desktop, GitHub Desktop, Sublime Text 4, Docker Desktop, Wireshark, WinSCP, PuTTY, FileZilla Client, Tailscale, WireGuard, WinMerge, WizTree, HWiNFO, CrystalDiskInfo, CrystalDiskMark, Bulk Rename Utility, Rufus, Ventoy, qBittorrent, SABnzbd, Syncthing
- Recommended (not ticked): QuickLook, FreeFileSync, Everything, PowerToys, Sysinternals Suite, Nmap, Notepad++, Windows Terminal, PowerShell 7, Oracle VirtualBox, Revo Uninstaller, QEMU, BIND 9, NoMachine, Tabby, Termius, UniFi OS Server, balenaEtcher, Raspberry Pi Imager, OSFMount, SD Card Formatter

### Music Lover (`music`)

Local music libraries and playback: MusicBee as the library manager by default, with other players, editors, converters and streaming apps to choose from (VLC is already in Core Essentials).

- Selected: MusicBee
- Recommended (not ticked): Tauon Music Box, Dopamine 3, Museeks, mpv.net, Audacity, HandBrake, Spotify, iTunes, Apple Music, OBS Studio, foobar2000, MediaMonkey 4, Mp3tag, FFmpeg, K-Lite Codec Pack Full

### Content Creator (`creator`)

Recording, audio editing and video editing: OBS Studio, Audacity and OpenShot by default, with converters, image editors and the Adobe and Autodesk app managers to choose from. No accounts are signed in.

- Selected: OBS Studio, Audacity, OpenShot Video Editor
- Recommended (not ticked): HandBrake, FFmpeg, GIMP, ImageGlass, PhotoDemon, Adobe Creative Cloud, Autodesk Access

### Personal Workstation (`workstation`)

The owner's personal additions: VPN, game streaming, media centre, downloads, PlayStation Remote Play and OpenRGB. Peripheral software (Corsair, Logitech, NZXT) and VMware Workstation Pro are optional: install them only for the hardware and needs of the computer. Nothing is signed in or configured.

- Selected: Private Internet Access, Parsec, Stremio, JDownloader 2, qBittorrent, PS Remote Play, OpenRGB
- Recommended (not ticked): SABnzbd, VMware Workstation Pro, Corsair iCUE 5, Logitech G HUB, NZXT CAM

### iPhone / iPad (`apple-devices`)

Activated by an iPhone or iPad under Mobile devices & ecosystem: Apple Devices is recommended and ticked; Apple Music, iTunes and iCloud stay optional.

- Selected: Apple Devices
- Recommended (not ticked): Apple Music, iTunes, iCloud for Windows

### Android (`android-devices`)

Activated by an Android phone or tablet. Basic USB file transfer needs no extra software, so nothing is ticked; manufacturer tools are optional.

- Selected: none
- Recommended (not ticked): Quick Share from Google, Samsung Smart Switch

### Laptop (`laptop`)

Portable computers: BatteryInfoView to check battery wear, with manufacturer update tools for Dell and Lenovo to choose from.

- Selected: BatteryInfoView
- Recommended (not ticked): Dell Command | Update, Lenovo System Update, Lenovo Vantage, Microsoft OneDrive

### Touchscreen / 2-in-1 (`touch`)

Pen and touch: Xournal++ for handwritten notes and PDF annotation, with Whiteboard and Joplin to choose from.

- Selected: Xournal++
- Recommended (not ticked): Microsoft Whiteboard, Joplin

### Changes to built-in profiles (owner decisions in the Phase 10 specification)

- Core Essentials: RustDesk is no longer selected for everyone; it is a recommendation with Notepad++, Everything and PowerToys.
- New: Content Creator, Personal Workstation. Renamed: Everyday / Home, Network Engineer / Technician, Music Lover (ids unchanged, so saved selections keep working).
- Recommendations added from the inventory to Everyday, Gaming, General Developer, Network Engineer, Music Lover and Laptop (listed above). Nothing new is ticked in an existing profile.
- Peripheral software (Corsair iCUE, Logitech G HUB, NZXT CAM) is only a recommendation, in Personal Workstation; OpenRGB is selected there because the owner asked for it.

## Added in Phase 10

| Application | Identifier | Category | Kind | Removal | Upgrade |
|---|---|---|---|---|---|
| LM Studio | `ElementLabs.LMStudio` | ai | application | normal | winget |
| Microsoft 365 Copilot | `Microsoft.365Copilot` | ai | application | normal | winget |
| Ollama | `Ollama.Ollama` | ai | service | caution | winget |
| Amazon Kindle | `Amazon.Kindle` | books | application | normal | winget |
| calibre | `calibre.calibre` | books | application | normal | winget |
| DuckDuckGo Browser | `DuckDuckGo.DesktopBrowser` | browsers | application | normal | winget |
| Google Chrome Canary | `Google.Chrome.Canary` | browsers | application | normal | winget |
| Opera | `Opera.Opera` | browsers | application | normal | winget |
| Mozilla Thunderbird ESR | `Mozilla.Thunderbird.ESR` | communication | application | normal | winget |
| Telegram Desktop | `Telegram.TelegramDesktop` | communication | application | normal | winget |
| Adobe Creative Cloud | `Adobe.CreativeCloud` | creative | launcher | normal | winget |
| Autodesk Access | `Autodesk.AutodeskAccess` | creative | launcher | normal | winget |
| FFmpeg | `Gyan.FFmpeg` | creative | application | normal | winget |
| OpenShot Video Editor | `OpenShot.OpenShot` | creative | application | normal | winget |
| Builder.io | `BuilderIO.BuilderIO` | development | application | normal | winget |
| CMake | `Kitware.CMake` | development | sdk | normal | winget |
| GitHub CLI | `GitHub.cli` | development | application | normal | winget |
| gsudo | `gerardog.gsudo` | development | application | normal | winget |
| neofetch (Windows) | `nepnep.neofetch-win` | development | application | normal | winget |
| PostgreSQL 18 | `PostgreSQL.PostgreSQL.18` | development | service | caution | winget |
| Python 3.12 | `Python.Python.3.12` | development | application | normal | winget |
| ripgrep | `BurntSushi.ripgrep.MSVC` | development | application | normal | winget |
| Stripe CLI | `Stripe.StripeCli` | development | application | normal | winget |
| Anytype | `AnyAssociation.Anytype` | documents | application | normal | winget |
| draw.io | `JGraph.Draw` | documents | application | normal | winget |
| LibreOffice | `TheDocumentFoundation.LibreOffice` | documents | application | normal | winget |
| Notion | `Notion.Notion` | documents | application | normal | winget |
| croc | `schollz.croc` | downloads | application | normal | winget |
| JDownloader 2 | `AppWork.JDownloader` | downloads | application | normal | winget |
| HidHide | `Nefarius.HidHide` | gaming | driver | caution | winget |
| PlayStation Plus | `PlayStation.PSPlus` | gaming | launcher | normal | winget |
| RivaTuner Statistics Server | `Guru3D.RTSS` | gaming | application | normal | winget |
| Rockstar Games Launcher | `RockstarGames.Launcher` | gaming | launcher | normal | winget |
| ScummVM | `ScummVM.ScummVM` | gaming | application | normal | winget |
| ImageGlass | `DuongDieuPhap.ImageGlass` | media | application | normal | winget |
| PhotoDemon | `tannerhelland.PhotoDemon` | media | application | normal | winget |
| foobar2000 | `PeterPawlowski.foobar2000` | music | application | normal | winget |
| MediaMonkey 4 | `VentisMedia.MediaMonkey.4` | music | application | normal | winget |
| Mp3tag | `FlorianHeidenreich.Mp3tag` | music | application | normal | winget |
| BIND 9 | `ISC.Bind` | networking | application | normal | winget |
| UniFi OS Server | `Ubiquiti.UniFiOSServer` | networking | service | caution | winget |
| Corsair iCUE 5 | `Corsair.iCUE.5` | peripherals | manufacturer | caution | winget |
| Logitech G HUB | `Logitech.GHUB` | peripherals | manufacturer | caution | winget |
| Logitech MyHarmony | `Logitech.MyHarmony` | peripherals | manufacturer | caution | winget |
| NZXT CAM | `NZXT.CAM` | peripherals | manufacturer | caution | winget |
| OpenRGB | `OpenRGB.OpenRGB` | peripherals | manufacturer | caution | winget |
| NoMachine | `NoMachine.NoMachine` | remote | service | caution | winget |
| Parsec | `Parsec.Parsec` | remote | application | normal | explicit |
| PS Remote Play | `PlayStation.PSRemotePlay` | remote | application | normal | winget |
| RealVNC Server | `RealVNC.VNCServer` | remote | service | caution | winget |
| Tabby | `Eugeny.Tabby` | remote | application | normal | winget |
| TeamViewer | `TeamViewer.TeamViewer` | remote | application | caution | winget |
| Termius | `Termius.Termius` | remote | application | normal | winget |
| Private Internet Access | `PrivateInternetAccess.PrivateInternetAccess` | security | application | caution | winget |
| Disk Drill | `CleverFiles.DiskDrill` | storage | application | normal | winget |
| EaseUS Partition Master | `EaseUS.PartitionMaster` | storage | application | normal | winget |
| FAT32 Format (guiformat) | `Ridgecrop.guiformat` | storage | application | normal | winget |
| ImgBurn | `LIGHTNINGUK.ImgBurn` | storage | application | normal | winget |
| OSFMount | `PassMark.OSFMount` | storage | driver | caution | winget |
| PowerISO | `PowerSoftware.PowerISO` | storage | application | normal | winget |
| SD Card Formatter | `SDAssociation.SDMemoryCardFormatter` | storage | application | normal | winget |
| VirtualCloneDrive | `ElaborateBytes.VirtualCloneDrive` | storage | driver | caution | winget |
| balenaEtcher | `Balena.Etcher` | usb | application | normal | winget |
| Raspberry Pi Imager | `RaspberryPiFoundation.RaspberryPiImager` | usb | application | normal | winget |
| Win32 Disk Imager | `Win32diskimager.win32diskimager` | usb | application | normal | winget |
| Glary Utilities | `Glarysoft.GlaryUtilities` | utilities | application | normal | winget |
| HWMonitor | `CPUID.HWMonitor` | utilities | application | normal | winget |
| UniGetUI | `Devolutions.UniGetUI` | utilities | application | normal | winget |
| Winhance | `memstechtips.Winhance` | utilities | application | normal | winget |
| K-Lite Codec Pack Full | `CodecGuide.K-LiteCodecPack.Full` | video | application | normal | winget |
| Kodi | `XBMCFoundation.Kodi` | video | application | normal | winget |
| Stremio | `Stremio.Stremio` | video | application | normal | winget |
| QEMU | `SoftwareFreedomConservancy.QEMU` | virtualization | application | caution | winget |
| Ubuntu 24.04 LTS (WSL) | `Canonical.Ubuntu.2404` | virtualization | application | caution | winget |
| VMware Workstation Pro | manual | virtualization | application | caution | manual |

`Zoom.Zoom.EXE` from the inventory is recorded as an alternate identifier of the existing Zoom entry (`Zoom.Zoom`), so either is recognised as installed.

## Inventory rows not offered (exclusions)

| Name | Identifier | Reason |
|---|---|---|
| Brave | `Brave.Brave` | Owner decision: Chrome is the universal browser; Firefox and Edge stay optional. |
| Vivaldi |  | Owner decision: not offered. |
| Pidgin |  | Owner decision: not offered. |
| Dropbox |  | Owner decision: Google Drive and OneDrive are offered instead. |
| SugarSync |  | Owner decision: not offered. |
| Foxit Reader |  | Owner decision: Adobe Acrobat Reader is offered. |
| PDF24 Creator |  | Owner decision: not offered. |
| CutePDF |  | Owner decision: not offered. |
| Ghostscript |  | Owner decision: not offered. |
| SumatraPDF | `SumatraPDF.SumatraPDF` | Owner decision: not offered. |
| Paint.NET |  | Owner decision: not offered. |
| Krita | `KDE.Krita` | Owner decision: not offered. |
| IrfanView | `IrfanSkiljan.IrfanView` | Owner decision: XnView MP is offered. |
| Greenshot | `Greenshot.Greenshot` | Owner decision: not offered. |
| ShareX |  | Owner decision: not offered. |
| WinDirStat |  | WizTree is preferred. |
| Apple TV |  | Owner decision: not offered. |
| Python Launcher | `Python.Launcher` | Installed together with every Python package; not selected on its own. |
| DirectX End-User Runtime | `Microsoft.DirectX` | Windows component; games install the legacy DirectX files they need themselves. |
| Futuremark SystemInfo | `Futuremark.FuturemarkSystemInfo` | Component installed by 3DMark and PCMark, not an application on its own. |
| Windows 11 Installation Assistant | `Microsoft.WindowsInstallationAssistant` | Upgrades Windows itself; not an application to manage here. |
| Windows App Runtime 1.3 | `Microsoft.WindowsAppRuntime.1.3` | Runtime installed automatically as a dependency of the apps that need it. |
| Windows App Runtime 1.5 | `Microsoft.WindowsAppRuntime.1.5` | Runtime installed automatically as a dependency of the apps that need it. |
| Windows App Runtime 1.6 | `Microsoft.WindowsAppRuntime.1.6` | Runtime installed automatically as a dependency of the apps that need it. |
| Windows App Runtime 1.7 | `Microsoft.WindowsAppRuntime.1.7` | Runtime installed automatically as a dependency of the apps that need it. |
| Windows App Runtime 1.8 | `Microsoft.WindowsAppRuntime.1.8` | Runtime installed automatically as a dependency of the apps that need it. |
| Windows App Runtime 2 | `Microsoft.WindowsAppRuntime.2` | Runtime installed automatically as a dependency of the apps that need it. |
| Chocolatey GUI | `Chocolatey.ChocolateyGUI` | Front-end for the Chocolatey package manager. WinGet stays the only package manager here: two package managers could install the same application twice. |

Opera and LibreOffice were excluded in Phase 4.2; the owner inventory lists them, so they are now offered (unticked).

## Requested but not in the inventory (manual, not added)

These were named in the Phase 10 specification but have no row in the owner inventory, so no identifier was invented:

- **VMware Workstation Pro**: no WinGet package exists (only `VMware.SpringToolSuite`). Added as a manual entry: Broadcom distributes it only through its support portal (free account), free for all use since 17.5.2 ([KB 368667](https://knowledge.broadcom.com/external/article/368667/download-and-license-vmware-desktop-hype.html)). It can run alongside Hyper-V and WSL 2; nothing is disabled.
- **PS5Upload**, **Reolink**, **Samsung Flow**, **Samsung Magician**: not in the inventory; not added. Add them to the inventory with a confirmed identifier (or as manual installers) to include them.
