/**
 * Source of src/data/apps/catalog.json (Phase 4.2, extended in Phase 10). Run:
 *   node scripts/catalog-source.mjs docs/phase-4-2-application-profiles/verification-2026-10-21.json docs/phase-10-application-manager/winget-verification-2026-10-25.json > src/data/apps/catalog.json
 * <verified.json> is the parsed output of the read-only verification pass (winget show for every
 * winget/msstore entry, plus --architecture x64/arm64/x86 probes); see
 * docs/phase-4-2-application-profiles/catalog.md. Installer type, architectures and licence are
 * taken from that output; everything else is written here by hand. A winget/msstore entry whose
 * identifier was not found is a hard error: identifiers are never guessed.
 */
import { readFileSync } from 'node:fs';

const CHECKED = '2026-10-21';
const verified = new Map(JSON.parse(readFileSync(process.argv[2], 'utf8')).map((v) => [`${v.source}:${v.id}`.toLowerCase(), v]));

// [id, displayName, category, source, packageIdentifier, description, extra]
const W = 'winget';
const S = 'msstore';
const entries = [
  // Browsers
  ['chrome', 'Google Chrome', 'browsers', W, 'Google.Chrome', 'Web browser by Google.', { website: 'https://www.google.com/chrome/' }],
  ['firefox', 'Mozilla Firefox', 'browsers', W, 'Mozilla.Firefox', 'Open-source web browser by Mozilla.', { website: 'https://www.mozilla.org/firefox/' }],
  ['edge', 'Microsoft Edge', 'browsers', W, 'Microsoft.Edge', 'Microsoft Edge is already part of Windows 11; selecting it only makes sure the current version is installed. Nothing ever removes Edge.', { website: 'https://www.microsoft.com/edge', kind: 'system', removal: 'blocked' }],
  // Media players, archives, passwords (formerly the "Everyday Essentials" category, which was a profile name)
  ['vlc', 'VLC media player', 'video', W, 'VideoLAN.VLC', 'Plays almost any video or audio file.', { website: 'https://www.videolan.org/vlc/' }],
  ['7zip', '7-Zip', 'files', W, '7zip.7zip', 'Opens and creates ZIP, 7z, RAR and other archives.', { website: 'https://www.7-zip.org/' }],
  ['teracopy', 'TeraCopy', 'files', W, 'CodeSector.TeraCopy', 'Faster, verified file copying with a queue and error recovery.', { website: 'https://www.codesector.com/teracopy', notes: 'Free for home use; TeraCopy Pro is a paid upgrade (nothing is activated).' }],
  ['bitwarden', 'Bitwarden', 'security', W, 'Bitwarden.Bitwarden', 'Password manager client. Installed only: no account, vault or master password is created.', { website: 'https://bitwarden.com/', accountSignIn: true }],
  ['acrobat-reader', 'Adobe Acrobat Reader (64-bit)', 'documents', W, 'Adobe.Acrobat.Reader.64-bit', 'Free PDF viewer: read, print, fill in and sign PDF forms.', { website: 'https://www.adobe.com/acrobat/pdf-reader.html' }],
  ['obsidian', 'Obsidian', 'documents', W, 'Obsidian.Obsidian', 'Markdown note-taking and knowledge base (local files).', { website: 'https://obsidian.md/' }],
  ['everything', 'Everything', 'files', W, 'voidtools.Everything', 'Instant file name search for NTFS drives.', { website: 'https://www.voidtools.com/' }],
  ['powertoys', 'PowerToys', 'utilities', W, 'Microsoft.PowerToys', 'Microsoft power-user utilities (FancyZones, PowerRename, Run, …).', { website: 'https://learn.microsoft.com/windows/powertoys/' }],
  ['revo-uninstaller', 'Revo Uninstaller', 'utilities', W, 'RevoUninstaller.RevoUninstaller', 'Uninstaller that also removes leftover files and registry entries (free edition).', { website: 'https://www.revouninstaller.com/' }],
  ['quicklook', 'QuickLook', 'files', W, 'QL-Win.QuickLook', 'Preview files in Explorer by pressing the space bar.', { website: 'https://github.com/QL-Win/QuickLook' }],
  // Communication
  ['discord', 'Discord', 'communication', W, 'Discord.Discord', 'Voice, video and text chat.', { accountSignIn: true, scope: 'user' }],
  ['zoom', 'Zoom Workplace', 'communication', W, 'Zoom.Zoom', 'Video meetings.', { accountSignIn: true, alternateIds: ['Zoom.Zoom.EXE'], notes: 'Zoom.Zoom is the machine-wide installer; a per-user installation (Zoom.Zoom.EXE) is recognised as the same application.' }],
  ['teams', 'Microsoft Teams', 'communication', W, 'Microsoft.Teams', 'Microsoft Teams (work or school, and personal).', { accountSignIn: true }],
  ['slack', 'Slack', 'communication', W, 'SlackTechnologies.Slack', 'Team messaging.', { accountSignIn: true }],
  ['whatsapp', 'WhatsApp', 'communication', S, '9NKSQGP7F2NH', 'WhatsApp desktop app from the Microsoft Store (publisher WhatsApp Inc.). Linking it to a phone is left to the customer.', { accountSignIn: true }],
  ['thunderbird', 'Mozilla Thunderbird', 'communication', W, 'Mozilla.Thunderbird', 'Email, calendar and contacts. No account is configured.', { website: 'https://www.thunderbird.net/' }],
  // Cloud & devices
  ['google-drive', 'Google Drive', 'cloud', W, 'Google.GoogleDrive', 'Google Drive for desktop. No account is signed in and nothing is synchronised.', { accountSignIn: true }],
  ['onedrive', 'Microsoft OneDrive', 'cloud', W, 'Microsoft.OneDrive', 'OneDrive is part of Windows; this makes sure the current client is installed. No account is signed in.', { accountSignIn: true, kind: 'system', removal: 'caution' }],
  ['apple-devices', 'Apple Devices', 'cloud', S, '9NP83LWLPZ9K', 'Apple\'s app to back up, update and sync iPhone and iPad (Microsoft Store, publisher Apple Inc.). Recommended for iPhone and iPad owners.', { website: 'https://support.apple.com/guide/devices-windows/' }],
  ['apple-music', 'Apple Music', 'music', S, '9PFHDD62MXS1', 'Apple Music app (Microsoft Store, publisher Apple Inc.). Needs an Apple Account for the streaming service.', { accountSignIn: true }],
  ['itunes', 'iTunes', 'music', W, 'Apple.iTunes', 'iTunes for Windows (publisher Apple Inc.). Apple now recommends Apple Devices and Apple Music instead; installing iTunes alongside them is not needed.', {}],
  ['icloud', 'iCloud for Windows', 'cloud', S, '9PKTQ5699M62', 'iCloud for Windows (Microsoft Store, publisher Apple Inc.). Installed only: no Apple Account is signed in and iCloud Photos, Drive and Passwords stay off.', {
    accountSignIn: true,
    selectionWarning: 'Turning on iCloud Photos or iCloud Drive later can download and upload very large amounts of data, fill the disk and keep the PC busy indexing and verifying for hours or days. Nothing is signed in or synchronised by this deployment.',
    notes: 'The WinGet package Apple.iCloud is the 2020 "iCloud (Legacy)" desktop build, so the current Store version is used.',
  }],
  ['samsung-smart-switch', 'Samsung Smart Switch', 'cloud', W, 'Samsung.SmartSwitch', 'Samsung\'s backup and transfer tool for Galaxy phones and tablets. Only useful for Samsung devices; ordinary USB file transfer needs no extra software.', { kind: 'manufacturer', hardware: { requirement: 'A Samsung Galaxy phone or tablet', vendors: ['Samsung'] } }],
  ['google-quick-share', 'Quick Share from Google', 'cloud', W, 'Google.QuickShare', 'Send files between Android devices and this PC nearby (Google LLC). Optional.', { accountSignIn: true }],
  // Photos & imaging
  ['xnview', 'XnView MP', 'media', W, 'XnSoft.XnViewMP', 'Image viewer, organiser and batch converter (free for private use).', { website: 'https://www.xnview.com/' }],
  ['gimp', 'GIMP', 'media', W, 'GIMP.GIMP.3', 'Image editor (GIMP 3).', { website: 'https://www.gimp.org/', notes: 'GIMP.GIMP and GIMP.GIMP.3 point to the same installer; the major-version package is used so a future GIMP 4 is a deliberate choice.' }],
  // Music & Media
  ['tauon', 'Tauon Music Box', 'music', W, 'Taiko2k.TauonMusicBox', 'Music player for large local libraries, with folder and album views.', { website: 'https://tauonmusicbox.rocks/' }],
  ['dopamine', 'Dopamine 3', 'music', W, 'Digimezzo.Dopamine.3', 'Elegant local music library player (Dopamine 3 by Digimezzo).', { website: 'https://digimezzo.github.io/site/' }],
  ['museeks', 'Museeks', 'music', W, 'Pierre.Museeks', 'Simple, clean local music player.', { website: 'https://museeks.io/' }],
  ['mpv-net', 'mpv.net', 'video', W, 'mpv.net', 'Media player based on mpv, by mpv.net\'s author (Frank Skare). The plain "mpv" WinGet entries are third-party repackaged builds and are not in the catalog.', { website: 'https://github.com/mpvnet-player/mpv.net' }],
  ['musicbee', 'MusicBee', 'music', S, '9P4CLT2RJ1RS', 'Music library manager and player (Microsoft Store, publisher Steven Mayall, the author). Not in the WinGet community repository.', { website: 'https://getmusicbee.com/' }],
  ['audacity', 'Audacity', 'creative', W, 'Audacity.Audacity', 'Audio recording and editing.', { website: 'https://www.audacityteam.org/' }],
  ['handbrake', 'HandBrake', 'creative', W, 'HandBrake.HandBrake', 'Video converter.', { website: 'https://handbrake.fr/', requires: ['winget:microsoft.dotnet.desktopruntime.8'], notes: 'Needs the .NET Desktop Runtime 8, which is added to the plan with it.' }],
  ['spotify', 'Spotify', 'music', W, 'Spotify.Spotify', 'Music streaming client.', { accountSignIn: true, scope: 'user' }],
  ['obs-studio', 'OBS Studio', 'creative', W, 'OBSProject.OBSStudio', 'Screen recording and live streaming.', { website: 'https://obsproject.com/' }],
  // Gaming
  ['steam', 'Steam', 'gaming', W, 'Valve.Steam', 'Valve\'s game store and launcher. No account is signed in and no games are installed.', { accountSignIn: true }],
  ['epic', 'Epic Games Launcher', 'gaming', W, 'EpicGames.EpicGamesLauncher', 'Epic Games store and launcher. No account is signed in.', { accountSignIn: true }],
  ['battlenet', 'Battle.net', 'gaming', W, 'Blizzard.BattleNet', 'Blizzard\'s launcher (the package installs "Battle.net Setup", which downloads the launcher).', { accountSignIn: true, interaction: 'mayPrompt' }],
  ['ea-app', 'EA app', 'gaming', W, 'ElectronicArts.EADesktop', 'Electronic Arts launcher.', { accountSignIn: true }],
  ['ubisoft-connect', 'Ubisoft Connect', 'gaming', W, 'Ubisoft.Connect', 'Ubisoft launcher.', { accountSignIn: true }],
  ['gog-galaxy', 'GOG GALAXY', 'gaming', W, 'GOG.Galaxy', 'GOG launcher and library.', { accountSignIn: true }],
  ['playnite', 'Playnite', 'gaming', W, 'Playnite.Playnite', 'Open-source library manager for games from every launcher.', {}],
  ['retroarch', 'RetroArch', 'gaming', W, 'Libretro.RetroArch', 'Emulator frontend (no games or BIOS files included).', {}],
  // Developer Tools
  ['git', 'Git', 'development', W, 'Git.Git', 'Git for Windows (includes Git Bash).', { website: 'https://git-scm.com/' }],
  ['vscode', 'Visual Studio Code', 'development', W, 'Microsoft.VisualStudioCode', 'Code editor by Microsoft.', { website: 'https://code.visualstudio.com/' }],
  ['python-314', 'Python 3.14', 'development', W, 'Python.Python.3.14', 'Python 3.14, the current release line (3.15 is not in WinGet yet).', { website: 'https://www.python.org/' }],
  ['python-313', 'Python 3.13', 'development', W, 'Python.Python.3.13', 'Python 3.13 (still supported), for projects that need it.', { website: 'https://www.python.org/' }],
  ['nodejs-lts', 'Node.js (LTS)', 'development', W, 'OpenJS.NodeJS.LTS', 'Node.js, current long-term-support line (the package follows the LTS release).', { website: 'https://nodejs.org/' }],
  ['github-desktop', 'GitHub Desktop', 'development', W, 'GitHub.GitHubDesktop', 'Git client by GitHub. No account is signed in.', { accountSignIn: true, scope: 'user' }],
  ['cursor', 'Cursor', 'development', W, 'Anysphere.Cursor', 'AI code editor by Anysphere.', { website: 'https://cursor.com/', accountSignIn: true }],
  ['claude-code', 'Claude Code (CLI)', 'ai', W, 'Anthropic.ClaudeCode', 'Anthropic\'s command-line coding agent ("claude" in any terminal). A different product from Claude Desktop.', {
    website: 'https://code.claude.com/docs/en/setup',
    accountSignIn: true,
    notes: 'Install method documented by Anthropic ("winget install Anthropic.ClaudeCode"). WinGet installs do not auto-update (winget upgrade Anthropic.ClaudeCode). Git for Windows is recommended (Bash tool) but optional. Needs a Pro, Max, Team, Enterprise or Console account; nothing is signed in.',
  }],
  ['claude-desktop', 'Claude Desktop', 'ai', W, 'Anthropic.Claude', 'Anthropic\'s Claude desktop app. A different product from the Claude Code CLI.', { website: 'https://claude.com/download', accountSignIn: true }],
  ['chatgpt', 'ChatGPT Desktop', 'ai', S, '9PLM9XGG6VKS', 'OpenAI\'s ChatGPT app (Microsoft Store, publisher OpenAI). The WinGet "ChatGPT" packages are unofficial third-party wrappers and are not used.', { accountSignIn: true }],
  ['sublime-text', 'Sublime Text 4', 'development', W, 'SublimeHQ.SublimeText.4', 'Text and code editor (evaluation; a licence is needed for continued use, nothing is entered).', { website: 'https://www.sublimetext.com/' }],
  ['notepadpp', 'Notepad++', 'development', W, 'Notepad++.Notepad++', 'Lightweight text and code editor.', {}],
  ['windows-terminal', 'Windows Terminal', 'development', W, 'Microsoft.WindowsTerminal', 'Usually already part of Windows 11; makes sure it is installed.', { kind: 'system', removal: 'caution' }],
  ['powershell', 'PowerShell 7', 'development', W, 'Microsoft.PowerShell', 'Cross-platform PowerShell (installed next to Windows PowerShell 5.1).', {}],
  ['sysinternals', 'Sysinternals Suite', 'utilities', W, 'Microsoft.Sysinternals.Suite', 'Microsoft\'s troubleshooting tools (Process Explorer, Autoruns, …). WinGet adds them to PATH.', {}],
  // Virtualization
  ['wsl', 'Windows Subsystem for Linux', 'virtualization', W, 'Microsoft.WSL', 'WSL 2 runtime. No Linux distribution is installed.', { reboot: 'mayRequire', kind: 'system', removal: 'caution' }],
  ['docker-desktop', 'Docker Desktop', 'virtualization', W, 'Docker.DockerDesktop', 'Containers on Windows (WSL 2 back end). Free for personal and small-business use; larger organisations need a subscription.', { requires: ['winget:microsoft.wsl'], reboot: 'mayRequire', accountSignIn: true }],
  ['virtualbox', 'Oracle VirtualBox', 'virtualization', W, 'Oracle.VirtualBox', 'Virtual machines.', { reboot: 'mayRequire' }],
  // Networking
  ['wireshark', 'Wireshark', 'networking', W, 'WiresharkFoundation.Wireshark', 'Network protocol analyser.', { notes: 'The silent installation does not install the Npcap capture driver (its free edition cannot install silently); install Npcap from https://npcap.com/ before capturing live traffic.' }],
  ['nmap', 'Nmap', 'networking', W, 'Insecure.Nmap', 'Network scanner (the package is version 7.80).', { interaction: 'mayPrompt', notes: 'The bundled Npcap installer may need interaction.' }],
  ['winscp', 'WinSCP', 'networking', W, 'WinSCP.WinSCP', 'SFTP, SCP and FTP client. No sites or credentials are configured.', {}],
  ['tailscale', 'Tailscale', 'networking', W, 'Tailscale.Tailscale', 'Mesh VPN client. Installed only: it does not sign in, join a tailnet or connect.', { accountSignIn: true, reboot: 'none' }],
  ['wireguard', 'WireGuard', 'networking', W, 'WireGuard.WireGuard', 'VPN client. Installed only: no tunnel or key is imported and nothing connects.', {}],
  ['qbittorrent', 'qBittorrent', 'downloads', W, 'qBittorrent.qBittorrent', 'BitTorrent client. No trackers, Web UI or port forwarding are configured.', {}],
  ['sabnzbd', 'SABnzbd', 'downloads', W, 'SABnzbdTeam.SABnzbd', 'Usenet downloader. No servers or credentials are configured; its web interface listens only on this PC until changed.', {}],
  // Remote Access
  ['putty', 'PuTTY', 'remote', W, 'PuTTY.PuTTY', 'SSH and serial terminal.', {}],
  // File management / sync
  ['winmerge', 'WinMerge', 'files', W, 'WinMerge.WinMerge', 'Compare and merge files and folders.', {}],
  ['wiztree', 'WizTree', 'storage', W, 'AntibodySoftware.WizTree', 'Very fast disk-space analyser (preferred over WinDirStat). Free for personal use.', { website: 'https://diskanalyzer.com/' }],
  ['bulk-rename-utility', 'Bulk Rename Utility', 'files', W, 'TGRMNSoftware.BulkRenameUtility', 'Rename many files at once (free for personal use).', {}],
  ['syncthing', 'Syncthing', 'files', W, 'Syncthing.Syncthing', 'Peer-to-peer folder synchronisation. Installed only: no folders or devices are shared, and its web interface listens only on this PC.', {
    method: 'portable',
    portable: { executable: 'syncthing.exe', shortcut: 'Syncthing' },
    notes: 'The shortcut starts Syncthing in a console window and opens its web interface on this PC; it does not start automatically with Windows.',
  }],
  // USB & Deployment
  ['rufus', 'Rufus', 'usb', W, 'Rufus.Rufus', 'Creates bootable USB drives. Never run by the deployment: formatting happens only when someone uses it.', { method: 'portable', portable: { executable: 'rufus*.exe', shortcut: 'Rufus' }, website: 'https://rufus.ie/' }],
  ['ventoy', 'Ventoy', 'usb', W, 'Ventoy.Ventoy', 'Multi-ISO bootable USB tool. Never run by the deployment: installing Ventoy to a drive erases it, so that is always a manual step.', { method: 'portable', portable: { executable: 'Ventoy2Disk.exe', shortcut: 'Ventoy2Disk' }, website: 'https://www.ventoy.net/' }],
  // System utilities & diagnostics
  ['hwinfo', 'HWiNFO', 'utilities', W, 'REALiX.HWiNFO', 'Hardware information and sensor monitoring (free for non-commercial use).', { website: 'https://www.hwinfo.com/' }],
  ['crystaldiskinfo', 'CrystalDiskInfo', 'storage', W, 'CrystalDewWorld.CrystalDiskInfo', 'Disk health (S.M.A.R.T.) monitor.', {}],
  ['crystaldiskmark', 'CrystalDiskMark', 'storage', W, 'CrystalDewWorld.CrystalDiskMark', 'Disk speed benchmark (read-only test files; never formats).', {}],
  // Security
  ['malwarebytes', 'Malwarebytes', 'security', W, 'Malwarebytes.Malwarebytes', 'Anti-malware scanner. The free edition scans on demand next to Microsoft Defender or another antivirus.', {
    selectionWarning: 'The installer cannot guarantee on-demand-only operation: a Premium trial or licence turns on real-time protection, which registers with Windows Security and overlaps with other real-time antivirus. Check its Real-Time Protection settings after installation. No licence is entered.',
    interaction: 'mayPrompt',
  }],
  ['avast', 'Avast One Free Antivirus', 'security', S, 'XPDNZJFNCR1B07', 'Real-time antivirus (Microsoft Store listing of the Avast installer, publisher AVAST Software).', {
    conflictGroup: 'realtime-antivirus',
    interaction: 'mayPrompt',
    selectionWarning: 'A third-party real-time antivirus makes Microsoft Defender Antivirus switch itself to passive mode; this deployment does not change Defender or Windows Firewall settings. The installer may offer additional Avast products.',
  }],
  ['avg', 'AVG AntiVirus Free', 'security', S, 'XP8BX2DWV7TF50', 'Real-time antivirus (Microsoft Store listing of the AVG installer, publisher AVG Technologies).', {
    conflictGroup: 'realtime-antivirus',
    interaction: 'mayPrompt',
    selectionWarning: 'A third-party real-time antivirus makes Microsoft Defender Antivirus switch itself to passive mode; this deployment does not change Defender or Windows Firewall settings. The installer may offer additional AVG products.',
  }],
  ['avira', 'Avira Security', 'security', S, 'XPFD23M0L795KD', 'Real-time antivirus (Microsoft Store listing of the Avira bootstrapper, publisher Avira).', {
    conflictGroup: 'realtime-antivirus',
    interaction: 'mayPrompt',
    selectionWarning: 'A third-party real-time antivirus makes Microsoft Defender Antivirus switch itself to passive mode; this deployment does not change Defender or Windows Firewall settings. The Avira bootstrapper downloads the product during installation.',
  }],
  ['superantispyware', 'SUPERAntiSpyware', 'security', W, 'SUPERAntiSpyware.SUPERAntiSpyware', 'On-demand anti-spyware scanner (free edition; real-time protection is a paid feature).', { interaction: 'mayPrompt' }],
  // Runtimes
  ['vcredist-x64', 'Visual C++ Redistributable 2015-2026 (x64)', 'runtimes', W, 'Microsoft.VCRedist.2015+.x64', 'Runtime many 64-bit programs need; skipped when a compatible version is already installed (winget list).', { reboot: 'mayRequire' }],
  ['vcredist-x86', 'Visual C++ Redistributable 2015-2026 (x86)', 'runtimes', W, 'Microsoft.VCRedist.2015+.x86', 'Runtime many 32-bit programs need; skipped when already installed.', { reboot: 'mayRequire' }],
  ['vcredist-2013-x64', 'Visual C++ 2013 Redistributable (x64)', 'runtimes', W, 'Microsoft.VCRedist.2013.x64', 'Legacy runtime, only for programs that ask for it.', {}],
  ['vcredist-2013-x86', 'Visual C++ 2013 Redistributable (x86)', 'runtimes', W, 'Microsoft.VCRedist.2013.x86', 'Legacy runtime, only for programs that ask for it.', {}],
  ['vcredist-2012-x64', 'Visual C++ 2012 Redistributable (x64)', 'runtimes', W, 'Microsoft.VCRedist.2012.x64', 'Legacy runtime, only for programs that ask for it.', {}],
  ['vcredist-2012-x86', 'Visual C++ 2012 Redistributable (x86)', 'runtimes', W, 'Microsoft.VCRedist.2012.x86', 'Legacy runtime, only for programs that ask for it.', {}],
  ['vcredist-2010-x64', 'Visual C++ 2010 Redistributable (x64)', 'runtimes', W, 'Microsoft.VCRedist.2010.x64', 'Legacy runtime, only for programs that ask for it.', {}],
  ['vcredist-2010-x86', 'Visual C++ 2010 Redistributable (x86)', 'runtimes', W, 'Microsoft.VCRedist.2010.x86', 'Legacy runtime, only for programs that ask for it.', {}],
  ['dotnet-desktop-8', '.NET Desktop Runtime 8', 'runtimes', W, 'Microsoft.DotNet.DesktopRuntime.8', '.NET 8 (long-term support) for Windows desktop apps.', {}],
  ['dotnet-desktop-10', '.NET Desktop Runtime 10', 'runtimes', W, 'Microsoft.DotNet.DesktopRuntime.10', '.NET 10 (long-term support) for Windows desktop apps.', {}],
  ['aspnetcore-8', 'ASP.NET Core Runtime 8', 'runtimes', W, 'Microsoft.DotNet.AspNetCore.8', 'ASP.NET Core 8 runtime (web apps and local services that need it).', {}],
  ['aspnetcore-10', 'ASP.NET Core Runtime 10', 'runtimes', W, 'Microsoft.DotNet.AspNetCore.10', 'ASP.NET Core 10 runtime.', {}],
  ['temurin-25-jre', 'Java Runtime (Eclipse Temurin 25 JRE)', 'runtimes', W, 'EclipseAdoptium.Temurin.25.JRE', 'OpenJDK 25 (long-term support) runtime for Java programs.', { website: 'https://adoptium.net/' }],
  ['temurin-21-jre', 'Java Runtime (Eclipse Temurin 21 JRE)', 'runtimes', W, 'EclipseAdoptium.Temurin.21.JRE', 'OpenJDK 21 (long-term support) runtime, for programs that need Java 21.', { website: 'https://adoptium.net/' }],
  ['temurin-25-jdk', 'Java Development Kit (Eclipse Temurin 25 JDK)', 'runtimes', W, 'EclipseAdoptium.Temurin.25.JDK', 'OpenJDK 25 development kit.', { website: 'https://adoptium.net/' }],
  ['vstor', 'Visual Studio Tools for Office Runtime', 'runtimes', W, 'Microsoft.VSTOR', 'Runtime for Office add-ins built with VSTO.', {}],
  // Hardware / touch
  ['batteryinfoview', 'BatteryInfoView', 'hardware', W, 'NirSoft.BatteryInfoView', 'Shows battery capacity, wear and charge history (NirSoft).', { kind: 'application', method: 'portable', portable: { executable: 'BatteryInfoView.exe', shortcut: 'BatteryInfoView' } }],
  ['dell-command-update', 'Dell Command | Update', 'hardware', W, 'Dell.CommandUpdate', 'Dell\'s driver and BIOS updater. Only for Dell computers; it never runs automatically from this deployment.', { kind: 'manufacturer', hardware: { requirement: 'Dell computers', vendors: ['Dell'] } }],
  ['lenovo-system-update', 'Lenovo System Update', 'hardware', W, 'Lenovo.SystemUpdate', 'Lenovo\'s driver and BIOS updater for ThinkPad/ThinkCentre. Only for Lenovo computers.', { kind: 'manufacturer', hardware: { requirement: 'Lenovo computers', vendors: ['Lenovo'] } }],
  ['lenovo-vantage', 'Lenovo Vantage', 'hardware', S, '9WZDNCRFJ4MV', 'Lenovo device settings and updates (Microsoft Store). Only for Lenovo computers.', { kind: 'manufacturer', hardware: { requirement: 'Lenovo computers', vendors: ['Lenovo'] } }],
  ['xournalpp', 'Xournal++', 'touch', W, 'Xournal++.Xournal++', 'Handwritten notes and PDF annotation with a pen.', {}],
  ['whiteboard', 'Microsoft Whiteboard', 'touch', S, '9MSPC6MP8FM4', 'Freeform digital whiteboard (Microsoft Store).', { accountSignIn: true }],
  ['joplin', 'Joplin', 'touch', W, 'Joplin.Joplin', 'Open-source notes and to-do app.', {}],
];

/*
 * Phase 10: applications from the owner's inventory
 * (docs/application-inventory/WDB_Application_Identity_Catalog_WinGet_Only.csv), each with the
 * exact WinGet identifier the CSV gives, verified read-only against the WinGet community repository
 * (docs/phase-10-application-manager/winget-verification-2026-10-25.json, scripts/verify-winget-ids.ts).
 * Installer facts come from that record; categories, kinds and descriptions are written here.
 * [id, displayName, category, packageIdentifier, description, extra]
 */
const phase10 = [
  // Books
  ['kindle', 'Amazon Kindle', 'books', 'Amazon.Kindle', 'Read Kindle e-books on the PC. Needs an Amazon account.', { accountSignIn: true }],
  ['calibre', 'calibre', 'books', 'calibre.calibre', 'E-book library manager, converter and reader.', {}],
  // Music
  ['foobar2000', 'foobar2000', 'music', 'PeterPawlowski.foobar2000', 'Lightweight, highly customisable audio player.', {}],
  ['mediamonkey', 'MediaMonkey 4', 'music', 'VentisMedia.MediaMonkey.4', 'Music library manager and player for large collections.', {}],
  ['mp3tag', 'Mp3tag', 'music', 'FlorianHeidenreich.Mp3tag', 'Edits the tags and cover art of audio files.', {}],
  // Video & players
  ['kodi', 'Kodi', 'video', 'XBMCFoundation.Kodi', 'Media centre for local video, music and photos.', {}],
  ['stremio', 'Stremio', 'video', 'Stremio.Stremio', 'Media centre for streaming add-ons.', { accountSignIn: true }],
  ['k-lite-codec-pack', 'K-Lite Codec Pack Full', 'video', 'CodecGuide.K-LiteCodecPack.Full', 'Audio and video codecs and filters for players that use DirectShow.', {
    selectionWarning: 'Installs system-wide codecs that change how other players decode media. VLC and mpv.net do not need it; install it only if an application asks for codecs.',
    interaction: 'mayPrompt',
  }],
  // Audio & video production
  ['ffmpeg', 'FFmpeg', 'creative', 'Gyan.FFmpeg', 'Command-line audio and video converter (Gyan Doshi\'s Windows builds).', {}],
  ['openshot', 'OpenShot Video Editor', 'creative', 'OpenShot.OpenShot', 'Simple open-source video editor.', {}],
  ['adobe-creative-cloud', 'Adobe Creative Cloud', 'creative', 'Adobe.CreativeCloud', 'Adobe\'s app manager for Photoshop, Premiere and the other Creative Cloud apps. Needs an Adobe account and subscription.', { accountSignIn: true, kind: 'launcher' }],
  ['autodesk-access', 'Autodesk Access', 'creative', 'Autodesk.AutodeskAccess', 'Autodesk\'s app manager for installing and updating Autodesk products. Needs an Autodesk account.', { accountSignIn: true, kind: 'launcher' }],
  // Photos & imaging
  ['imageglass', 'ImageGlass', 'media', 'DuongDieuPhap.ImageGlass', 'Fast, lightweight image viewer.', {}],
  ['photodemon', 'PhotoDemon', 'media', 'tannerhelland.PhotoDemon', 'Portable photo editor.', {}],
  // AI
  ['lm-studio', 'LM Studio', 'ai', 'ElementLabs.LMStudio', 'Runs large language models locally. Needs a capable GPU or plenty of RAM; models are downloaded separately.', { hardware: { requirement: 'A recent GPU or at least 16 GB of RAM for useful local models', vendors: [] } }],
  ['ollama', 'Ollama', 'ai', 'Ollama.Ollama', 'Runs large language models locally from the command line and a local API. Models are downloaded separately.', { kind: 'service', hardware: { requirement: 'A recent GPU or at least 16 GB of RAM for useful local models', vendors: [] } }],
  ['m365-copilot', 'Microsoft 365 Copilot', 'ai', 'Microsoft.365Copilot', 'Microsoft 365 Copilot app (formerly Office). Needs a Microsoft account.', { accountSignIn: true }],
  // Development
  ['cmake', 'CMake', 'development', 'Kitware.CMake', 'Cross-platform build system generator.', { kind: 'sdk' }],
  ['github-cli', 'GitHub CLI', 'development', 'GitHub.cli', 'GitHub on the command line ("gh"). Nothing is signed in.', { accountSignIn: true }],
  ['builder-io', 'Builder.io', 'development', 'BuilderIO.BuilderIO', 'Builder.io desktop app for visual development.', { accountSignIn: true }],
  ['postgresql-18', 'PostgreSQL 18', 'development', 'PostgreSQL.PostgreSQL.18', 'PostgreSQL database server 18.', { kind: 'service', interaction: 'mayPrompt', notes: 'Installs a database service; set the superuser password interactively. Nothing is configured by the application manager.' }],
  ['python-312', 'Python 3.12', 'development', 'Python.Python.3.12', 'Python 3.12, for projects that need it.', {}],
  ['stripe-cli', 'Stripe CLI', 'development', 'Stripe.StripeCli', 'Stripe\'s command-line tool for developers. Nothing is signed in.', { accountSignIn: true }],
  ['gsudo', 'gsudo', 'development', 'gerardog.gsudo', 'Runs a command elevated from the current console ("sudo for Windows").', {}],
  ['neofetch-win', 'neofetch (Windows)', 'development', 'nepnep.neofetch-win', 'Prints system information in the terminal.', {}],
  ['ripgrep', 'ripgrep', 'development', 'BurntSushi.ripgrep.MSVC', 'Very fast recursive text search ("rg").', {}],
  // Virtualization
  ['qemu', 'QEMU', 'virtualization', 'SoftwareFreedomConservancy.QEMU', 'Machine emulator and virtualizer (command line).', {}],
  ['ubuntu-2404', 'Ubuntu 24.04 LTS (WSL)', 'virtualization', 'Canonical.Ubuntu.2404', 'Ubuntu 24.04 for the Windows Subsystem for Linux. The Linux user is created at first start.', { requires: ['winget:microsoft.wsl'], interaction: 'mayPrompt' }],
  // Gaming
  ['psplus', 'PlayStation Plus', 'gaming', 'PlayStation.PSPlus', 'PlayStation Plus PC app for streaming games. Needs a PlayStation Network account.', { accountSignIn: true, kind: 'launcher' }],
  ['rockstar-launcher', 'Rockstar Games Launcher', 'gaming', 'RockstarGames.Launcher', 'Rockstar\'s game launcher. No account is signed in.', { accountSignIn: true, kind: 'launcher' }],
  ['scummvm', 'ScummVM', 'gaming', 'ScummVM.ScummVM', 'Runs classic point-and-click adventure games (game files not included).', {}],
  ['rtss', 'RivaTuner Statistics Server', 'gaming', 'Guru3D.RTSS', 'Frame-rate limiter and on-screen display for games.', {}],
  ['hidhide', 'HidHide', 'gaming', 'Nefarius.HidHide', 'Hides physical game controllers from games (used with controller remappers).', {
    kind: 'driver',
    removal: 'caution',
    reboot: 'mayRequire',
    selectionWarning: 'Installs a kernel filter driver for input devices. Only useful together with controller-remapping software.',
  }],
  // Remote access & streaming
  ['parsec', 'Parsec', 'remote', 'Parsec.Parsec', 'Low-latency remote desktop and game streaming. Nothing is signed in.', { accountSignIn: true }],
  ['ps-remote-play', 'PS Remote Play', 'remote', 'PlayStation.PSRemotePlay', 'Streams a PlayStation 4 or 5 console to the PC. Needs a PlayStation Network account.', { accountSignIn: true, hardware: { requirement: 'A PlayStation 4 or PlayStation 5 console', vendors: ['Sony'] } }],
  ['nomachine', 'NoMachine', 'remote', 'NoMachine.NoMachine', 'Remote desktop client and server.', { kind: 'service', removal: 'caution', notes: 'Installs a remote-access service. Check who may connect before leaving it running.' }],
  ['realvnc-server', 'RealVNC Server', 'remote', 'RealVNC.VNCServer', 'VNC remote-access server.', { kind: 'service', removal: 'caution', accountSignIn: true, notes: 'Installs a remote-access service; nothing is licensed or configured.' }],
  ['teamviewer', 'TeamViewer', 'remote', 'TeamViewer.TeamViewer', 'Remote support and remote access.', { removal: 'caution', notes: 'Free for personal use only; commercial use needs a licence.' }],
  ['tabby', 'Tabby', 'remote', 'Eugeny.Tabby', 'Terminal with SSH, serial and Telnet sessions.', {}],
  ['termius', 'Termius', 'remote', 'Termius.Termius', 'SSH client with a synchronised host list. Nothing is signed in.', { accountSignIn: true }],
  // Networking
  ['bind9', 'BIND 9', 'networking', 'ISC.Bind', 'ISC BIND DNS tools (dig, nslookup) and server.', {}],
  ['unifi-os-server', 'UniFi OS Server', 'networking', 'Ubiquiti.UniFiOSServer', 'Self-hosted controller for Ubiquiti UniFi network devices.', { kind: 'service', hardware: { requirement: 'Ubiquiti UniFi network devices', vendors: ['Ubiquiti'] } }],
  // Downloads & transfers
  ['jdownloader', 'JDownloader 2', 'downloads', 'AppWork.JDownloader', 'Download manager for direct-download links.', { interaction: 'mayPrompt', notes: 'The official installer may offer additional software; check each step if it asks.' }],
  ['croc', 'croc', 'downloads', 'schollz.croc', 'Sends files between two computers over an encrypted relay (command line).', {}],
  // Security & VPN
  ['pia', 'Private Internet Access', 'security', 'PrivateInternetAccess.PrivateInternetAccess', 'VPN client. Installed only: no account is signed in and nothing connects.', { accountSignIn: true, removal: 'caution', reboot: 'mayRequire' }],
  // Browsers
  ['chrome-canary', 'Google Chrome Canary', 'browsers', 'Google.Chrome.Canary', 'Nightly developer build of Chrome (installed next to Chrome).', {}],
  ['duckduckgo', 'DuckDuckGo Browser', 'browsers', 'DuckDuckGo.DesktopBrowser', 'Privacy-focused web browser.', {}],
  ['opera', 'Opera', 'browsers', 'Opera.Opera', 'Opera web browser.', {}],
  // Communication
  ['thunderbird-esr', 'Mozilla Thunderbird ESR', 'communication', 'Mozilla.Thunderbird.ESR', 'Thunderbird extended-support release (fewer feature changes). No account is configured.', {}],
  ['telegram', 'Telegram Desktop', 'communication', 'Telegram.TelegramDesktop', 'Messaging app. Linking it to a phone is left to the user.', { accountSignIn: true }],
  // Documents & notes
  ['libreoffice', 'LibreOffice', 'documents', 'TheDocumentFoundation.LibreOffice', 'Free office suite: documents, spreadsheets, presentations.', {}],
  ['drawio', 'draw.io', 'documents', 'JGraph.Draw', 'Diagram editor (flowcharts, network diagrams).', {}],
  ['notion', 'Notion', 'documents', 'Notion.Notion', 'Notes and workspaces. Needs a Notion account.', { accountSignIn: true }],
  ['anytype', 'Anytype', 'documents', 'AnyAssociation.Anytype', 'Local-first notes and knowledge base.', { accountSignIn: true }],
  // Storage
  ['disk-drill', 'Disk Drill', 'storage', 'CleverFiles.DiskDrill', 'Data recovery for deleted files (free edition recovers a limited amount).', {}],
  ['easeus-partition-master', 'EaseUS Partition Master', 'storage', 'EaseUS.PartitionMaster', 'Partition manager (free edition).', {
    interaction: 'mayPrompt',
    selectionWarning: 'A partition tool can erase data when used wrongly. Nothing is run by the application manager.',
  }],
  ['guiformat', 'FAT32 Format (guiformat)', 'storage', 'Ridgecrop.guiformat', 'Formats large drives as FAT32. Never run automatically: formatting erases the drive.', {}],
  ['imgburn', 'ImgBurn', 'storage', 'LIGHTNINGUK.ImgBurn', 'Burns and creates CD, DVD and Blu-ray images.', { interaction: 'mayPrompt' }],
  ['osfmount', 'OSFMount', 'storage', 'PassMark.OSFMount', 'Mounts disk images as drives (read-only by default).', { kind: 'driver', removal: 'caution' }],
  ['poweriso', 'PowerISO', 'storage', 'PowerSoftware.PowerISO', 'Creates, edits and mounts disc images (trial; a licence is needed for full use).', {}],
  ['sd-card-formatter', 'SD Card Formatter', 'storage', 'SDAssociation.SDMemoryCardFormatter', 'The SD Association\'s formatter for SD cards. Never run automatically.', {}],
  ['virtualclonedrive', 'VirtualCloneDrive', 'storage', 'ElaborateBytes.VirtualCloneDrive', 'Virtual drive for disc images.', { kind: 'driver', removal: 'caution' }],
  // USB & imaging
  ['balena-etcher', 'balenaEtcher', 'usb', 'Balena.Etcher', 'Writes OS images to USB drives and SD cards. Never run automatically: writing erases the drive.', {}],
  ['raspberry-pi-imager', 'Raspberry Pi Imager', 'usb', 'RaspberryPiFoundation.RaspberryPiImager', 'Writes Raspberry Pi OS images to SD cards. Never run automatically.', {}],
  ['win32diskimager', 'Win32 Disk Imager', 'usb', 'Win32diskimager.win32diskimager', 'Reads and writes raw disk images to USB drives and SD cards. Never run automatically.', {}],
  // System utilities
  ['hwmonitor', 'HWMonitor', 'utilities', 'CPUID.HWMonitor', 'Temperatures, voltages and fan speeds.', {}],
  ['glary-utilities', 'Glary Utilities', 'utilities', 'Glarysoft.GlaryUtilities', 'System cleaning and maintenance suite.', {
    interaction: 'mayPrompt',
    selectionWarning: 'Registry "cleaning" rarely helps and can break programs. The installer may offer additional software.',
  }],
  ['winhance', 'Winhance', 'utilities', 'memstechtips.Winhance', 'Windows optimisation and debloating tool.', {
    selectionWarning: 'Changes many Windows settings when used. Nothing is run by the application manager; review each change before applying it.',
  }],
  ['unigetui', 'UniGetUI', 'utilities', 'Devolutions.UniGetUI', 'Another graphical front-end for WinGet and other package managers.', {
    notes: 'Can manage the same applications as this manager. If it is set up to use Scoop or Chocolatey too, the same application can end up installed twice by different package managers.',
  }],
  // Peripherals & device control (only for the matching hardware)
  ['openrgb', 'OpenRGB', 'peripherals', 'OpenRGB.OpenRGB', 'Controls RGB lighting of many brands from one app.', { kind: 'manufacturer', removal: 'caution', hardware: { requirement: 'RGB-lit components or peripherals supported by OpenRGB', vendors: [] } }],
  ['corsair-icue', 'Corsair iCUE 5', 'peripherals', 'Corsair.iCUE.5', 'Lighting, fan and device control for Corsair hardware.', { kind: 'manufacturer', removal: 'caution', reboot: 'mayRequire', hardware: { requirement: 'Corsair peripherals or components', vendors: ['Corsair'] } }],
  ['logitech-ghub', 'Logitech G HUB', 'peripherals', 'Logitech.GHUB', 'Settings for Logitech G mice, keyboards, headsets and wheels.', { kind: 'manufacturer', removal: 'caution', hardware: { requirement: 'Logitech G peripherals', vendors: ['Logitech'] } }],
  ['nzxt-cam', 'NZXT CAM', 'peripherals', 'NZXT.CAM', 'Monitoring and control for NZXT coolers, fans and cases.', { kind: 'manufacturer', removal: 'caution', hardware: { requirement: 'NZXT coolers, fan controllers or cases', vendors: ['NZXT'] } }],
  ['logitech-myharmony', 'Logitech MyHarmony', 'peripherals', 'Logitech.MyHarmony', 'Configures Logitech Harmony remote controls.', { kind: 'manufacturer', hardware: { requirement: 'A Logitech Harmony remote', vendors: ['Logitech'] }, notes: 'Logitech has discontinued Harmony remotes; the service may stop working.' }],
];

// Manual follow-ups: verified official sources, no WinGet or Store package (checked CHECKED).
const manual = [
  ['rustdesk', 'RustDesk', 'remote', 'Open-source remote support; installed manually because no package exists in WinGet or the Microsoft Store.', {
    reason: 'No RustDesk package in the WinGet community repository (winget search, winget show RustDesk.RustDesk and the winget-pkgs manifests folder) or the Microsoft Store.',
    instructions: 'Download the signed Windows installer from RustDesk\'s official GitHub releases and install it. Leave unattended access off: do not set a permanent password; the customer approves each session.',
    url: 'https://github.com/rustdesk/rustdesk/releases/latest',
  }],
  ['filezilla', 'FileZilla Client', 'networking', 'FTP/SFTP client.', {
    reason: 'FileZilla is not in the WinGet community repository (TimKosse.FileZilla.Client: not found; no manifests folder) or the Microsoft Store.',
    instructions: 'Download the plain installer from the "show all" download page (the default download can bundle offers) and install it.',
    url: 'https://filezilla-project.org/download.php?show_all=1',
  }],
  ['freefilesync', 'FreeFileSync', 'files', 'Folder comparison and mirroring, for example backups to an external drive.', {
    reason: 'FreeFileSync is not in the WinGet community repository (FreeFileSync.FreeFileSync: not found) or the Microsoft Store.',
    instructions: 'Download the installer from the official website and install it.',
    url: 'https://freefilesync.org/download.php',
  }],
  ['spybot', 'Spybot - Search & Destroy', 'security', 'On-demand anti-spyware scanner (free edition).', {
    reason: 'Only Spybot Anti-Beacon is in WinGet; Search & Destroy is not in WinGet or the Microsoft Store.',
    instructions: 'Download Spybot - Search & Destroy (free edition) from the official website and install it.',
    url: 'https://www.safer-networking.org/',
  }],
  ['launchbox', 'LaunchBox', 'gaming', 'Game library frontend.', {
    reason: 'No verified LaunchBox package in WinGet or the Microsoft Store.',
    instructions: 'Download LaunchBox from the official website (the download form asks for an e-mail address) and install it.',
    url: 'https://www.launchbox-app.com/download',
  }],
  ['vmware-workstation', 'VMware Workstation Pro', 'virtualization', 'Virtual machines (free for personal, commercial and educational use since version 17.5.2).', {
    reason: 'No VMware Workstation Pro package in the WinGet community repository (manifests/v/VMware has only SpringToolSuite, checked 2026-10-25). Broadcom distributes the installer only to signed-in accounts of its support portal.',
    instructions: 'Sign in at support.broadcom.com (free account; complete the trade-compliance form), download VMware Workstation Pro 17.5.2 or later and run the installer; choose the personal-use option when it asks for a licence. It can run next to Hyper-V and WSL 2 (it uses the Windows Hypervisor Platform); nothing is disabled or changed automatically.',
    url: 'https://knowledge.broadcom.com/external/article/368667/download-and-license-vmware-desktop-hype.html',
  }],
  ['dotnet-framework-35', '.NET Framework 3.5', 'runtimes', 'Windows feature needed by some older programs (includes .NET 2.0 and 3.0).', {
    reason: '.NET Framework 3.5 is a Windows optional feature, not a WinGet package; enabling it downloads files from Windows Update.',
    instructions: 'Only if a program asks for it: Settings > System > Optional features > More Windows features > .NET Framework 3.5, or "DISM /Online /Enable-Feature /FeatureName:NetFx3 /All" as administrator.',
    url: 'https://learn.microsoft.com/dotnet/framework/install/dotnet-35-windows',
  }],
];

const excluded = [
  ['Brave', 'Brave.Brave', 'Owner decision: Chrome is the universal browser; Firefox and Edge stay optional.'],
  ['Vivaldi', undefined, 'Owner decision: not offered.'],
  ['Pidgin', undefined, 'Owner decision: not offered.'],
  ['Dropbox', undefined, 'Owner decision: Google Drive and OneDrive are offered instead.'],
  ['SugarSync', undefined, 'Owner decision: not offered.'],
  ['Foxit Reader', undefined, 'Owner decision: Adobe Acrobat Reader is offered.'],
  ['PDF24 Creator', undefined, 'Owner decision: not offered.'],
  ['CutePDF', undefined, 'Owner decision: not offered.'],
  ['Ghostscript', undefined, 'Owner decision: not offered.'],
  ['SumatraPDF', 'SumatraPDF.SumatraPDF', 'Owner decision: not offered.'],
  ['Paint.NET', undefined, 'Owner decision: not offered.'],
  ['Krita', 'KDE.Krita', 'Owner decision: not offered.'],
  ['IrfanView', 'IrfanSkiljan.IrfanView', 'Owner decision: XnView MP is offered.'],
  ['Greenshot', 'Greenshot.Greenshot', 'Owner decision: not offered.'],
  ['ShareX', undefined, 'Owner decision: not offered.'],
  ['WinDirStat', undefined, 'WizTree is preferred.'],
  ['Apple TV', undefined, 'Owner decision: not offered.'],
  // Phase 10: in the owner's inventory (verified WinGet identifiers) but not applications to offer.
  ['Python Launcher', 'Python.Launcher', 'Installed together with every Python package; not selected on its own.'],
  ['DirectX End-User Runtime', 'Microsoft.DirectX', 'Windows component; games install the legacy DirectX files they need themselves.'],
  ['Futuremark SystemInfo', 'Futuremark.FuturemarkSystemInfo', 'Component installed by 3DMark and PCMark, not an application on its own.'],
  ['Windows 11 Installation Assistant', 'Microsoft.WindowsInstallationAssistant', 'Upgrades Windows itself; not an application to manage here.'],
  ['Windows App Runtime 1.3', 'Microsoft.WindowsAppRuntime.1.3', 'Runtime installed automatically as a dependency of the apps that need it.'],
  ['Windows App Runtime 1.5', 'Microsoft.WindowsAppRuntime.1.5', 'Runtime installed automatically as a dependency of the apps that need it.'],
  ['Windows App Runtime 1.6', 'Microsoft.WindowsAppRuntime.1.6', 'Runtime installed automatically as a dependency of the apps that need it.'],
  ['Windows App Runtime 1.7', 'Microsoft.WindowsAppRuntime.1.7', 'Runtime installed automatically as a dependency of the apps that need it.'],
  ['Windows App Runtime 1.8', 'Microsoft.WindowsAppRuntime.1.8', 'Runtime installed automatically as a dependency of the apps that need it.'],
  ['Windows App Runtime 2', 'Microsoft.WindowsAppRuntime.2', 'Runtime installed automatically as a dependency of the apps that need it.'],
  ['Chocolatey GUI', 'Chocolatey.ChocolateyGUI', 'Front-end for the Chocolatey package manager. WinGet stays the only package manager here: two package managers could install the same application twice.'],
];

// Phase 10: the read-only check of every WinGet identifier against the WinGet community repository.
const P10_CHECKED = '2026-10-25';
const repo = JSON.parse(readFileSync(process.argv[3], 'utf8'));
const inRepo = new Map(repo.results.filter((r) => r.found).map((r) => [r.id.toLowerCase(), r]));
const repoMethod = (r) => `winget-pkgs ${repo.commit.slice(0, 8)} (${repo.commitDate.slice(0, 10)}): ${r.path} ${r.latestVersion}, publisher ${r.publisher || 'not stated'}`.slice(0, 400);

const KIND_BY_CATEGORY = { runtimes: 'runtime', peripherals: 'manufacturer', hardware: 'manufacturer' };
const LAUNCHERS = new Set(['steam', 'epic', 'battlenet', 'ea-app', 'ubisoft-connect', 'gog-galaxy']);
/**
 * Removal safety (application manager): "blocked" is never offered for removal (Windows
 * components and shared runtimes), "caution" needs an extra confirmation (security, drivers,
 * virtualization, VPN and remote-access services, device control software).
 */
function removalOf(id, category, kind, x) {
  if (x.removal) return x.removal;
  if (kind === 'runtime') return 'blocked';
  if (kind === 'driver' || kind === 'manufacturer' || kind === 'service') return 'caution';
  if (category === 'security' || category === 'virtualization') return 'caution';
  if (['tailscale', 'wireguard'].includes(id)) return 'caution';
  return 'normal';
}

/** Fields shared by every entry (Phase 10 metadata); the repository record gives publisher, detection names and upgrade behaviour. */
function common(id, category, source, packageIdentifier, x, fallbackPublisher = '') {
  const r = packageIdentifier ? inRepo.get(packageIdentifier.toLowerCase()) : undefined;
  const kind = x.kind ?? (LAUNCHERS.has(id) ? 'launcher' : KIND_BY_CATEGORY[category] ?? 'application');
  for (const a of x.alternateIds ?? []) if (!inRepo.has(a.toLowerCase())) throw new Error(`${id}: alternate identifier ${a} was not verified`);
  const names = (r?.appsAndFeaturesNames ?? []).map((n) => n.slice(0, 100)).slice(0, 10);
  return {
    publisher: (r?.publisher || fallbackPublisher || '').slice(0, 120) || undefined,
    kind,
    removal: removalOf(id, category, kind, x),
    upgrade: source === 'none' ? 'manual' : r?.requireExplicitUpgrade ? 'explicit' : 'winget',
    ...(x.hardware ? { hardware: x.hardware } : {}),
    ...(x.alternateIds ? { alternateIds: x.alternateIds } : {}),
    ...(names.length ? { detectNames: names } : {}),
  };
}

const ARCH = { x64: 'x64', x86: 'x86', arm64: 'arm64' };
const out = [];
for (const [id, displayName, category, source, packageIdentifier, description, x] of entries) {
  const v = verified.get(`${source}:${packageIdentifier}`.toLowerCase());
  if (!v || !v.ok) throw new Error(`${id}: ${source}:${packageIdentifier} was not verified`);
  if (source === 'winget' && !inRepo.has(packageIdentifier.toLowerCase())) throw new Error(`${id}: ${packageIdentifier} is not in the 2026-10-25 repository check`);
  const e = {
    id,
    displayName,
    packageIdentifier,
    source,
    ...(x.method ? { method: x.method } : {}),
    category,
    description,
    ...(x.website ? { website: x.website } : {}),
    architectures: v.arch,
    scope: x.scope ?? (x.method === 'portable' ? 'machine' : 'unknown'),
    installerType: source === 'msstore' ? (v.installerType === 'msstore' ? 'msstore' : `msstore (${v.installerType})`) : v.installerType,
    license: (source === 'msstore' ? `${v.pricing || 'Store'} (Microsoft Store)` : v.license || 'Not stated').slice(0, 120),
    requires: x.requires ?? [],
    interaction: x.interaction ?? 'unknown',
    accountSignIn: !!x.accountSignIn,
    reboot: x.reboot ?? 'unknown',
    ...(x.notes ? { notes: x.notes } : {}),
    ...(x.selectionWarning ? { selectionWarning: x.selectionWarning } : {}),
    ...(x.conflictGroup ? { conflictGroup: x.conflictGroup } : {}),
    ...(x.portable ? { portable: x.portable } : {}),
    ...common(id, category, source, packageIdentifier, x, v.publisher),
    validation: {
      status: 'verified',
      checkedAt: CHECKED,
      method: `winget show --id ${packageIdentifier} --exact --source ${source}: ${v.name} ${v.version !== 'Unknown' ? v.version : ''}, publisher ${v.publisher}`.replace(/\s+/g, ' ').slice(0, 400),
    },
  };
  out.push(e);
}
for (const [id, displayName, category, packageIdentifier, description, x] of phase10) {
  const r = inRepo.get(packageIdentifier.toLowerCase());
  if (!r) throw new Error(`${id}: ${packageIdentifier} was not verified in the WinGet repository`);
  if (r.canonicalId !== packageIdentifier) throw new Error(`${id}: ${packageIdentifier} differs from the repository's ${r.canonicalId}`);
  const scopes = r.scopes ?? [];
  out.push({
    id,
    displayName,
    packageIdentifier,
    source: 'winget',
    category,
    description,
    ...(r.packageUrl?.startsWith('https://') ? { website: r.packageUrl } : {}),
    architectures: (r.architectures ?? []).map((a) => ARCH[a]).filter(Boolean),
    scope: scopes.length === 1 ? scopes[0] : scopes.length > 1 ? 'either' : 'unknown',
    installerType: (r.installerTypes ?? [])[0] ?? 'unknown',
    license: (r.license || 'Not stated').slice(0, 120),
    requires: x.requires ?? [],
    interaction: x.interaction ?? 'unknown',
    accountSignIn: !!x.accountSignIn,
    reboot: x.reboot ?? 'unknown',
    ...(x.notes ? { notes: x.notes } : {}),
    ...(x.selectionWarning ? { selectionWarning: x.selectionWarning } : {}),
    ...common(id, category, 'winget', packageIdentifier, x),
    validation: { status: 'verified', checkedAt: P10_CHECKED, method: repoMethod(r) },
  });
}
for (const [id, displayName, category, description, m] of manual) {
  out.push({
    id,
    displayName,
    packageIdentifier: null,
    source: 'none',
    method: 'manual',
    category,
    description,
    architectures: [],
    scope: 'unknown',
    installerType: 'manual',
    license: 'See publisher',
    requires: [],
    interaction: 'required',
    accountSignIn: false,
    reboot: 'unknown',
    manual: { reason: m.reason, instructions: m.instructions, url: m.url },
    ...common(id, category, 'none', null, m),
    validation: { status: 'manual', checkedAt: id === 'vmware-workstation' ? P10_CHECKED : CHECKED, method: m.reason },
  });
}
process.stdout.write(
  JSON.stringify(
    {
      $comment: `Generated by scripts/catalog-source.mjs from the read-only verifications of ${CHECKED} (docs/phase-4-2-application-profiles/catalog.md) and ${P10_CHECKED} (docs/phase-10-application-manager/catalog.md). Listing an app here neither selects nor installs it.`,
      catalogVersion: 2,
      updated: P10_CHECKED,
      entries: out,
      excluded: excluded.map(([name, packageIdentifier, reason]) => ({ name, ...(packageIdentifier ? { packageIdentifier } : {}), reason })),
    },
    null,
    2,
  ) + '\n',
);
