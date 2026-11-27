# Unified application catalog and profile rebuild (2026-11-26)

The Deployment Builder and the Application Manager read **one** catalog: `src/data/apps/catalog.json`, loaded and validated only by `src/engine/applications/catalog.ts`, which both tools import (a unit test fails if any other file reads the data file). The Application Manager's removal/upgrade policy (`catalog-policy.json`) is generated from the same module.

## Why applications were easier to find in the Application Manager

- The manager opens on **Browse** with the *whole* catalog, grouped by category. The builder's Applications list opened on the **Suggested** filter (selected, unticked and recommended apps of the ticked profiles only); the full catalog was the sixth of eight small chips ("All apps"). In Quick Deployment the Applications step also opened on Suggested, and step 2 showed only the combined selection.
- The manager searched name, **publisher**, identifier and description and had a publisher filter; the builder's search did not look at the publisher.
- The manager's filters showed counts; the builder's did not, so a technician could not see that 190 apps were one click away.

## What changed in the builder

- Two tab-like scopes above the list, in Advanced Configuration and Quick Deployment alike: **Apps for the ticked profiles** (the default, short and useful) and **All applications (289)**. Status filters with counts: Selected, Recommended, Available (installable automatically and not selected), Manual installation, Unticked by you, Profile defaults, Not offered.
- Search covers name, publisher, category and description; the category filter narrows it.
- Quick Deployment step 2 (profiles) has a **Browse all 289 applications** button, and the Applications step a **Browse all applications** link; both open the whole catalog directly. Step 2 still shows the combined list with the profile(s) that selected each app, and ticking or unticking a profile updates it immediately.
- Manual entries are labelled *Manual follow-up* everywhere and are never counted as "to install"; they appear in the plan as follow-ups with the official download.
- Overlapping tools (two remote-support tools, two PDF readers, two office suites) may be selected deliberately; the plan says so (an information notice). Real-time antivirus stays a hard conflict.

## Catalog: 190 → 289 entries

99 WinGet entries were added. Every identifier was read from the WinGet community repository (`microsoft/winget-pkgs` at `aca69c384d300bfdddf79bd1bb219d70cfcd1cb1`, 2026-11-26) by `scripts/verify-winget-ids.ts` (read-only, nothing installed), exactly as spelled there, with a SHA-256 for every installer; the generator (`scripts/catalog-source.mjs`) refuses any identifier that is not in `winget-verification-2026-11-26.json` or not fully hashed. Packages whose only installers are portable archives were left out. SumatraPDF, Krita, ShareX, Greenshot and Paint.NET were "not offered" owner decisions; the owner lifted those five exclusions for this change. Existing catalog ids and identifiers are unchanged.

| Category | Application | WinGet identifier | Verified version · publisher |
| --- | --- | --- | --- |
| Documents, PDF & Notes | SumatraPDF | `SumatraPDF.SumatraPDF` | 3.6.1 · Krzysztof Kowalczyk |
| Documents, PDF & Notes | ONLYOFFICE Desktop Editors | `ONLYOFFICE.DesktopEditors` | 10.0.0 · Ascensio System SIA |
| Documents, PDF & Notes | PDFsam Basic | `PDFsam.PDFsam` | 6.0.11.0 · Sober Lemur S.r.l. |
| Documents, PDF & Notes | NAPS2 | `Cyanfish.NAPS2` | 8.6.1 · NAPS2 Software |
| Documents, PDF & Notes | Zotero | `DigitalScholar.Zotero` | 10.0.8 · Corporation for Digital Scholarship |
| Documents, PDF & Notes | Anki | `Anki.Anki` | 26.09.4 · Anki |
| Documents, PDF & Notes | Evernote | `Evernote.Evernote` | 11.44.6 · Evernote Corporation |
| Communication | Signal | `OpenWhisperSystems.Signal` | 8.36.0 · Signal Messenger, LLC |
| Communication | Viber | `Rakuten.Viber` | 29.7.0.0 · Rakuten |
| Communication | Webex | `Cisco.Webex` | 46.11.0.36194 · Cisco Systems, Inc |
| Security, Passwords & VPN | KeePassXC | `KeePassXCTeam.KeePassXC` | 2.8.0 · KeePassXC Team |
| Security, Passwords & VPN | 1Password | `AgileBits.1Password` | 8.12.46.29 · AgileBits Inc. |
| Security, Passwords & VPN | Proton Pass | `Proton.ProtonPass` | 1.44.1 · Proton AG |
| Security, Passwords & VPN | Proton VPN | `Proton.ProtonVPN` | 5.1.10 · Proton AG |
| Security, Passwords & VPN | Mullvad VPN | `MullvadVPN.MullvadVPN` | 2026.5 · Mullvad VPN |
| Security, Passwords & VPN | Cryptomator | `Cryptomator.Cryptomator` | 1.19.7 · Skymatic GmbH |
| Security, Passwords & VPN | VeraCrypt | `IDRIX.VeraCrypt` | 1.26.31 · IDRIX |
| Security, Passwords & VPN | Yubico Authenticator | `Yubico.Authenticator` | 7.5.1 · Yubico AB |
| Remote Access & Streaming | AnyDesk | `AnyDesk.AnyDesk` | 9.8.4 · AnyDesk Software GmbH |
| Remote Access & Streaming | Chrome Remote Desktop Host | `Google.ChromeRemoteDesktopHost` | 157.0.8103.41 · Google LLC |
| Remote Access & Streaming | Moonlight | `MoonlightGameStreamingProject.Moonlight` | 6.2.0.0 · Moonlight Game Streaming Project |
| Remote Access & Streaming | Sunshine | `LizardByte.Sunshine` | 2026.914.233613 · LizardByte |
| Remote Access & Streaming | mRemoteNG | `mRemoteNG.mRemoteNG` | 1.76.20.24615 · Next Generation Software |
| Remote Access & Streaming | MobaXterm Home | `Mobatek.MobaXterm` | 26.6.0.5560 · Mobatek |
| Music & Streaming | AIMP | `AIMP.AIMP` | 5.10.2418 · Artem Izmaylov |
| Music & Streaming | MusicBrainz Picard | `MusicBrainz.Picard` | 3.0.5 · MusicBrainz |
| Music & Streaming | TIDAL | `TIDALMusicAS.TIDAL` | 2.48.0 · TIDAL Music AS |
| Music & Streaming | Amazon Music | `Amazon.Music` | 9.4.0.2386 · Amazon.com Services LLC |
| Music & Streaming | Deezer | `Deezer.Deezer` | 8.0.10 · Deezer |
| Music & Streaming | Exact Audio Copy | `AndreWiethoff.ExactAudioCopy` | 1.8 · Andre Wiethoff |
| Audio & Video Production | Voicemeeter | `VB-Audio.Voicemeeter` | 1.1.2.2 · VB-Audio Software |
| Audio & Video Production | REAPER | `Cockos.REAPER` | 7.86 · Cockos Incorporated |
| Audio & Video Production | MuseScore Studio | `Musescore.Musescore` | 4.7.7.261109195 · MuseScore BVBA and Others |
| Audio & Video Production | Shotcut | `Meltytech.Shotcut` | 26.11.15 · Meltytech |
| Audio & Video Production | Kdenlive | `KDE.Kdenlive` | 26.08.3 · KDE e.V. |
| Audio & Video Production | Blender | `BlenderFoundation.Blender` | 5.3.0 · Blender Foundation |
| Audio & Video Production | FreeCAD | `FreeCAD.FreeCAD` | 1.1.4 · FreeCAD Team |
| Photos & Imaging | Krita | `KDE.Krita` | 5.3.5.0 · Krita Foundation |
| Photos & Imaging | Inkscape | `Inkscape.Inkscape` | 1.4.4 · Inkscape |
| Photos & Imaging | Paint.NET | `dotPDN.PaintDotNet` | 5.2 · dotPDN LLC |
| Photos & Imaging | darktable | `darktable.darktable` | 5.6.2 · darktable team |
| Photos & Imaging | digiKam | `KDE.digiKam` | 9.1.0 · The digiKam team |
| Photos & Imaging | Figma | `Figma.Figma` | 126.12.8 · Figma, Inc. |
| Photos & Imaging | ShareX | `ShareX.ShareX` | 22.4.0 · ShareX Team |
| Photos & Imaging | Greenshot | `Greenshot.Greenshot` | 1.3.328 · Greenshot |
| Photos & Imaging | ScreenToGif | `NickeManarin.ScreenToGif` | 2.43.2 · Nicke Manarin |
| Media Players & Video | MPC-HC | `clsid2.mpc-hc` | 2.8.5 · MPC-HC Team |
| Media Players & Video | PotPlayer | `Daum.PotPlayer` | 26.10.21.0 · Kakao Corp. |
| Media Players & Video | Plex | `Plex.Plex` | 1.115.0 · Plex, Inc. |
| Media Players & Video | Jellyfin Media Player | `Jellyfin.JellyfinMediaPlayer` | 1.12.0 · Jellyfin |
| Media Players & Video | MKVToolNix | `MoritzBunkus.MKVToolNix` | 103.0.0 · Moritz Bunkus |
| Media Players & Video | MediaInfo | `MediaArea.MediaInfo.GUI` | 26.10 · MediaArea.net |
| Gaming Platforms & Tools | Heroic Games Launcher | `HeroicGamesLauncher.HeroicGamesLauncher` | 2.22.4 · Heroic Games Launcher |
| Gaming Platforms & Tools | Amazon Games | `Amazon.Games` | 3.0.9700.3 · Amazon.com Services, Inc. |
| Gaming Platforms & Tools | itch | `ItchIo.Itch` | 26.22.0 · itch corp. |
| Gaming Platforms & Tools | MSI Afterburner | `Guru3D.Afterburner` | 4.6.6 · MSI Co., LTD |
| Gaming Platforms & Tools | Prism Launcher | `PrismLauncher.PrismLauncher` | 11.1.1 · Prism Launcher Contributors |
| Gaming Platforms & Tools | Minecraft Launcher | `Mojang.MinecraftLauncher` | 2.0.0.0 · Mojang |
| Gaming Platforms & Tools | GeForce NOW | `Nvidia.GeForceNow` | 2.0.90.138 · NVIDIA Corporation |
| Files, Archives & Backup | PeaZip | `Giorgiotani.Peazip` | 11.4.0 · Giorgio Tani |
| Files, Archives & Backup | WinRAR | `RARLab.WinRAR` | 7.23.0 · win.rar GmbH |
| Files, Archives & Backup | Total Commander | `Ghisler.TotalCommander` | 11.58.1 · Ghisler Software GmbH |
| Files, Archives & Backup | Files | `FilesCommunity.Files` | 4.3.0.0 · Files Community |
| Files, Archives & Backup | Duplicati | `Duplicati.Duplicati` | 2.4.1.1 · Duplicati Team |
| Files, Archives & Backup | KopiaUI | `Kopia.KopiaUI` | 0.23.1 · Kopia Authors |
| Files, Archives & Backup | AOMEI Backupper Standard | `AOMEI.Backupper.Standard` | 8.5.1 · AOMEI International Network Limited. |
| Disk & Storage Utilities | TreeSize Free | `JAMSoftware.TreeSize.Free` | 4.8.1.610 · JAM Software |
| System Utilities & Diagnostics | CPU-Z | `CPUID.CPU-Z` | 3.02 · CPUID, Inc. |
| System Utilities & Diagnostics | GPU-Z | `TechPowerUp.GPU-Z` | 2.72.0 · TechPowerUp |
| System Utilities & Diagnostics | BleachBit | `BleachBit.BleachBit` | 6.0.6.633 · BleachBit |
| System Utilities & Diagnostics | Speccy | `Piriform.Speccy` | 1.34.84 · Piriform |
| System Utilities & Diagnostics | BlueScreenView | `NirSoft.BlueScreenView` | 1.55 · NirSoft |
| System Utilities & Diagnostics | Display Driver Uninstaller | `Wagnardsoft.DisplayDriverUninstaller` | 18.1.5.3 · Wagnardsoft |
| System Utilities & Diagnostics | Bulk Crap Uninstaller | `Klocman.BulkCrapUninstaller` | 6.3.0.0 · Marcin Szeniak |
| Network Tools & Diagnostics | Advanced IP Scanner | `Famatech.AdvancedIPScanner` | 2.5.4594.1 · Famatech |
| Network Tools & Diagnostics | Angry IP Scanner | `angryziber.AngryIPScanner` | 3.12.2 · Angry IP Scanner |
| Network Tools & Diagnostics | OpenVPN Connect | `OpenVPNTechnologies.OpenVPNConnect` | 3.9.0 · OpenVPN Inc. |
| Network Tools & Diagnostics | Speedtest by Ookla | `Ookla.Speedtest.Desktop` | 1.15.200.001 · Ookla |
| Developer Tools | Visual Studio Community | `Microsoft.VisualStudio.Community` | 18.12.1 · Microsoft Corporation |
| Developer Tools | Go | `GoLang.Go` | 1.27.4 · https://go.dev |
| Developer Tools | Rustup (Rust) | `Rustlang.Rustup` | 1.29.3 · The Rust Programming Language |
| Developer Tools | JetBrains Toolbox | `JetBrains.Toolbox` | 3.9.2.0 · JetBrains |
| Developer Tools | DBeaver Community | `DBeaver.DBeaver.Community` | 26.2.5 · DBeaver Corp |
| Developer Tools | Windsurf | `Codeium.Windsurf` | 2.3.15 · Codeium |
| Developer Tools | Zed | `ZedIndustries.Zed` | 1.30.2 · Zed Industries |
| Developer Tools | NVM for Windows | `CoreyButler.NVMforWindows` | 1.2.2 · Ecor Ventures LLC |
| Developer Tools | Neovim | `Neovim.Neovim` | 0.12.6 · neovim.io |
| Developer Tools | Postman | `Postman.Postman` | 12.38.5 · Postman |
| Developer Tools | Miniconda | `Anaconda.Miniconda3` | py314_26.9.4-1 · Anaconda, Inc. |
| Developer Tools | Android Studio | `Google.AndroidStudio` | 2026.2.2.10 · Google LLC |
| Virtualization | Podman Desktop | `RedHat.Podman-Desktop` | 1.31.0 · RedHat |
| AI Assistants & Local Models | GPT4All | `nomic.gpt4all` | 3.10.0 · Nomic |
| Cloud & Device Integration | Proton Drive | `Proton.ProtonDrive` | 3.1.0 · Proton AG |
| Cloud & Device Integration | MEGA Desktop App | `Mega.MEGASync` | 6.7.1.0 · Mega Limited |
| Cloud & Device Integration | Nextcloud Desktop | `Nextcloud.NextcloudDesktop` | 35.0.3 · Nextcloud GmbH |
| Cloud & Device Integration | pCloud Drive | `pCloudAG.pCloudDrive` | 5.2.4.0 · pCloud AG |
| Cloud & Device Integration | Box Drive | `Box.Box` | 2.55.145 · Box, Inc. |
| Cloud & Device Integration | KDE Connect | `KDE.KDEConnect` | 26.08.1 · KDE e.V. |
| Cloud & Device Integration | LocalSend | `LocalSend.LocalSend` | 1.19.0 · Tien Do Nam |

Identifiers checked and **not** found (nothing was added for them): `RustDesk.RustDesk`, `TimKosse.FileZilla.Client`, `FreeFileSync.FreeFileSync`, `LaunchBox.LaunchBox`, `SaferNetworking.SpybotSearchandDestroy`, `Cisco.WebexMeetings`, `AnyDeskSoftwareGmbH.AnyDesk`, `StrawberryMusicPlayer.Strawberry`, `EqualizerAPO.EqualizerAPO`, `BlackmagicDesign.DaVinciResolve`, `Ryochan7.DS4Windows`, `Jounin.TFTPD64`, `GNS3.GNS3`, `dbeaver.dbeaver`, `Box.Drive`. AnyDesk, DBeaver and Box were found under `AnyDesk.AnyDesk`, `DBeaver.DBeaver.Community` and `Box.Box`.

## Manual installations

| Application | Why | Official source |
| --- | --- | --- |
| RustDesk | No RustDesk package in WinGet or the Microsoft Store. Rechecked 2026-11-26: no manifests/r/RustDesk folder in winget-pkgs (aca69c38); "winget search RustDesk" finds nothing in the winget and msstore sources. | https://github.com/rustdesk/rustdesk/releases/latest |
| FileZilla Client | FileZilla is not in the WinGet community repository (no manifests/t/TimKosse folder, rechecked 2026-11-26) or the Microsoft Store. | https://filezilla-project.org/download.php?show_all=1 |
| FreeFileSync | FreeFileSync is not in the WinGet community repository (no manifests/f/FreeFileSync folder, rechecked 2026-11-26) or the Microsoft Store. | https://freefilesync.org/download.php |
| Spybot - Search & Destroy | Only Spybot Anti-Beacon is in WinGet; Search & Destroy is not in WinGet (rechecked 2026-11-26) or the Microsoft Store. | https://www.safer-networking.org/ |
| LaunchBox | No verified LaunchBox package in WinGet (no manifests/l/LaunchBox folder, rechecked 2026-11-26) or the Microsoft Store. | https://www.launchbox-app.com/download |
| VMware Workstation Pro | No VMware Workstation Pro package in the WinGet community repository (manifests/v/VMware has only SpringToolSuite, checked 2026-10-25). Broadcom distributes the installer only to signed-in accounts of its support portal. | https://knowledge.broadcom.com/external/article/368667/download-and-license-vmware-desktop-hype.html |
| .NET Framework 3.5 | .NET Framework 3.5 is a Windows optional feature, not a WinGet package; enabling it downloads files from Windows Update. | https://learn.microsoft.com/dotnet/framework/install/dotnet-35-windows |

RustDesk was rechecked: there is no `manifests/r/RustDesk` folder in winget-pkgs, and `winget search RustDesk` finds nothing in the winget or msstore sources. It stays discoverable as a manual follow-up with RustDesk's official GitHub releases. TeamViewer is installed through WinGet (`TeamViewer.TeamViewer`). Installing either never turns on unattended access or sets a password.

## Profiles (revision 2)

Profiles are additive: ticking several combines their defaults, each package is installed once and shows every profile that selected it; explicit additions and removals survive profile changes. None of them inherits another any more, and competing tools (PDF readers, remote support, antivirus) are never defaults of two profiles that can be combined.

| Profile | Defaults | Default applications | Recommended (optional) |
| --- | ---: | --- | ---: |
| Core Essentials (`core`) | 9 | Google Chrome, 7-Zip, VLC media player, Notepad++, Bitwarden, SumatraPDF, ImageGlass, Visual C++ Redistributable 2015-2026 (x64), Visual C++ Redistributable 2015-2026 (x86) | 9 |
| Everyday / Home (`everyday`) | 5 | Zoom Workplace, Microsoft Teams, LibreOffice, Everything, Revo Uninstaller | 25 |
| Gamer (`gaming`) | 7 | Steam, Epic Games Launcher, Battle.net, GOG GALAXY, Ubisoft Connect, Rockstar Games Launcher, Discord | 19 |
| Music Lover (`music`) | 5 | Spotify, MusicBee, Audacity, mpv.net, Mp3tag | 17 |
| Student / Office (`student-office`) | 6 | LibreOffice, Mozilla Thunderbird, Microsoft Teams, PDFsam Basic, Zotero, Anki | 18 |
| Content Creator (`creator`) | 6 | OBS Studio, GIMP, Inkscape, Audacity, HandBrake, ShareX | 20 |
| Developer (`developer`) | 5 | Git, Visual Studio Code, Python 3.14, Node.js (LTS), GitHub CLI | 33 |
| IT Technician / Network Engineer (`network-engineer`) | 8 | HWiNFO, CrystalDiskInfo, Sysinternals Suite, WinSCP, PuTTY, Wireshark, Rufus, Revo Uninstaller | 39 |
| Remote Support (`remote-support`) | 1 | TeamViewer | 3 |
| Personal Workstation (`workstation`) | 7 | Private Internet Access, Parsec, Stremio, JDownloader 2, qBittorrent, PS Remote Play, OpenRGB | 5 |
| iPhone / iPad (`apple-devices`) | 1 | Apple Devices | 4 |
| Android (`android-devices`) | 0 | (none: device answers / recommendations only) | 4 |
| Laptop (`laptop`) | 1 | BatteryInfoView | 4 |
| Touchscreen / 2-in-1 (`touch`) | 1 | Xournal++ | 2 |

Microsoft Office LTSC stays a separate, optional choice (its own card on the Applications page).

## Compatibility: nothing saved changes by itself

- Revision 1 of the built-in profiles (the Phase 10 definitions) is frozen in `src/data/apps/profiles-v1.json`; revision 2 is `profiles.json`.
- A deployment records the revision it uses (`applications.selection.profileRevision`, profile schema 11). The v10→v11 migration sets revision 1 for every older profile, with a note, so it selects exactly the applications it did before. **Use the new profile defaults** (Applications page, Quick Deployment step 2, and the Application Manager's Profiles tab) adopts revision 2 explicitly; ticked profiles, devices, additions and removals are kept.
- A saved custom profile records the revision its parent profiles refer to (`builtinRevision`). One saved before the rebuild keeps resolving its parents in revision 1 even inside a new deployment (they appear as "… (earlier defaults)"); its card offers **Use the new defaults**.
- Saved profiles whose id became a built-in id (`student-office`, `remote-support`) are renamed by the migration and in the browser library, and every reference follows.
- Schema 10 is main's preview-update setting (Windows Update 2.1.0); this branch's profile revision became schema 11 when main was merged in. The unmerged `feature/disk-preparation` branch also numbers its migration 10 and must renumber when it merges.

Revision 1, for reference:

| Profile | Defaults |
| --- | --- |
| Core Essentials | Google Chrome, VLC media player, 7-Zip, TeraCopy, Bitwarden, Visual C++ Redistributable 2015-2026 (x64), Visual C++ Redistributable 2015-2026 (x86) |
| Everyday / Home | Adobe Acrobat Reader (64-bit) |
| Gaming | Steam, Epic Games Launcher |
| General Developer | Git, Visual Studio Code, Python 3.14, Node.js (LTS) |
| Network Engineer / Technician | Cursor, Claude Code (CLI), Claude Desktop, ChatGPT Desktop, GitHub Desktop, Sublime Text 4, Docker Desktop, Wireshark, WinSCP, PuTTY, FileZilla Client, Tailscale, WireGuard, WinMerge, WizTree, HWiNFO, CrystalDiskInfo, CrystalDiskMark, Bulk Rename Utility, Rufus, Ventoy, qBittorrent, SABnzbd, Syncthing (+ developer) |
| Music Lover | MusicBee |
| Content Creator | OBS Studio, Audacity, OpenShot Video Editor |
| Personal Workstation | Private Internet Access, Parsec, Stremio, JDownloader 2, qBittorrent, PS Remote Play, OpenRGB |
| iPhone / iPad | Apple Devices |
| Android | (none) |
| Laptop | BatteryInfoView |
| Touchscreen / 2-in-1 | Xournal++ |

## Tests

- `tests/unit/unified-catalog.test.ts`: one catalog for both tools; every entry discoverable by search and category; publisher and category search; revision 2 defaults and counts; additive selection, one installation per package; overrides survive profile changes; manual entries never installable; the ZIP holds exactly the plan; schema 9 deployments, pre-rebuild saved profiles and id collisions migrate safely; adoption is explicit.
- `tests/unit/app-profiles.test.ts`, `catalog-phase10.test.ts` and the inheritance tests pin revision 1, proving older configurations resolve as before.
- `tests/e2e/unified-catalog.spec.ts`: additive profiles with origins in Quick Deployment, the whole catalog one click away (search by publisher, category and status filters), manual follow-ups and the exact ZIP, and an older saved deployment adopting the new defaults.
