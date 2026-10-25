# Installers that need manual integration (Phase 10)

These applications were requested but cannot be installed automatically from a verified WinGet
package. No identifier was guessed for them.

| Application | Requested in | State | What is needed |
|---|---|---|---|
| VMware Workstation Pro | Personal Workstation (optional) | In the catalog as a **manual** entry | No WinGet manifest exists (`manifests/v/VMware` has only SpringToolSuite at winget-pkgs `fbe878e9`, 2026-10-25). Broadcom distributes the installer only to signed-in support-portal accounts (free since 17.5.2, [KB 368667](https://knowledge.broadcom.com/external/article/368667/download-and-license-vmware-desktop-hype.html)). A verified unattended method for a locally supplied installer could be added later; until then the manager shows the steps. It runs alongside Hyper-V and WSL 2, and nothing is disabled. |
| PS5Upload | Personal Workstation | Not added | Not in the owner inventory CSV; no confirmed identifier. Add it to the inventory with a WinGet ID, or as a manual installer with its official source. |
| Reolink (client) | Peripheral software | Not added | Not in the owner inventory CSV. |
| Samsung Flow | Peripheral software | Not added | Not in the owner inventory CSV. |
| Samsung Magician | Peripheral software | Not added | Not in the owner inventory CSV. (Samsung Smart Switch, a different product, is already in the catalog.) |
| RustDesk | Core Essentials (now optional) | Manual entry since Phase 4.2 | No RustDesk package in the WinGet community repository or the Microsoft Store (Phase 4.2 check); it is installed from the publisher. |

Manual entries carried over from Phase 4.2 for the same reason (no verified package): FileZilla,
FreeFileSync, Spybot Search & Destroy, LaunchBox, and .NET Framework 3.5 (a Windows optional
feature, not a package). The manager lists them with their instructions and never runs them.

Also left out of the catalog on purpose, with reasons, in [catalog.md](catalog.md#inventory-rows-not-offered-exclusions):
runtimes and frameworks (Windows App Runtime 1.3–2, DirectX), Python Launcher, Futuremark
SystemInfo, the Windows 11 Installation Assistant, and Chocolatey GUI (no third-party package
managers).
