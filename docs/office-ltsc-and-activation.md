# Microsoft Office LTSC and activation

Branch `feature/office-ltsc`, from `main` `dc14fa8`. Nothing has been installed, activated, pushed
or deployed. Profile schema 9 (older profiles migrate with no Office and no activation).

## What the technician chooses

**Applications page (Basic and Advanced): Microsoft Office LTSC (volume licensed)**

| Choice | Product ID | Channel | Notes |
|---|---|---|---|
| Do not install Office (default) | none | none | Application profiles never install Office |
| Office LTSC Standard 2024 | `Standard2024Volume` | `PerpetualVL2024` | Current LTSC; supported until October 2029 |
| Office LTSC Professional Plus 2024 | `ProPlus2024Volume` | `PerpetualVL2024` | Current LTSC |
| Office LTSC Standard 2021 | `Standard2021Volume` | `PerpetualVL2021` | Legacy: support ended October 13, 2026 (warning shown) |
| Office LTSC Professional Plus 2021 | `ProPlus2021Volume` | `PerpetualVL2021` | Legacy (warning shown) |

Advanced only: *Remove Windows Installer (MSI) Office 2016 and earlier first* (off by default).

**Advanced only (the builder's expert view): Activation**, independent for Windows and Office:

| | Windows | Office (only when an edition is selected) |
|---|---|---|
| No activation action | default | default |
| Microsoft activation | digital license, product key (typed by the technician), or KMS (optional host) | KMS (optional host), Active Directory, or MAK (typed by the technician) |
| Technician activates manually | the deployment only checks and reports the licensing state | same |

Choosing an Office edition, switching to Advanced view or selecting any application profile never
enables activation. Office activation without an Office edition is a validation error, so no package
is generated. The review shows **Software: Microsoft Office** and **Activation** as separate tiles.

**Not included:** the Massgrave / "get.activated.win" workflow from the request. It activates Windows
and Office without a valid license, so the builder neither links to nor launches it, in any mode.
"Technician activates manually" covers activation through other legitimate channels (for example
the customer's own key, a phone activation or an organization's process). The deployment then only
confirms the result from the licensing service.

## Sources (pinned, never fetched from a branch at run time)

Repository: <https://github.com/jdepew88/download_office_ltsc> (the technician's own project, MIT).

| Version | Branch @ commit | Shipped files | Changes |
|---|---|---|---|
| 2024 | `2024` @ `3e2817194aaef0856c5ce8653763c77e24cb3e72` | `Install_Office.ps1`, `config_standard.xml`, `config_ProPlus.xml`, `Activate_Office.ps1` | none (byte-identical; SHA-256 recorded in `src/engine/office/index.ts` and checked by `office.test.ts`) |
| 2021 | `2021` @ `548c49142589a9c7c093a4724b9cee1045c0eb2b` | `config-2021-Standard.xml`, `config-2021-ProPlus.xml` (from `config_standard.xml` / `config_ProPlus.xml`) | adapted, see below |

Only the selected edition's configuration is packaged. A 2021 configuration is never used for 2024,
or the other way round.

### Why Office 2021 needed an adapter

The `2021` branch only has an interactive script: a menu, Y/N prompts and a cleanup question. It also
downloads its XML from the repository's **main** branch, which now holds the 2024 configuration, so
running it as-is would install the wrong version. WDB therefore:

- runs the 2021 configuration through the pinned **2024** `Install_Office.ps1`, in its documented
  unattended custom-configuration mode (`-Unattended -ConfigPath <xml>`). That gives the same ODT
  signature check, exit codes, logging and silent setup as for 2024. The installer prints a harmless
  warning that a custom configuration is not a 2024 product.
- adapts the 2021 XML:
  - removed `AUTOACTIVATE=1`, so installing never activates;
  - removed the unconditional `<RemoveMSI />` from the Standard file (it would silently uninstall
    older Office); it is added only when chosen;
  - removed `PIDKEY`. Microsoft documents that volume Office installs with its Generic Volume License
    Key by default ([GVLKs for Office](https://learn.microsoft.com/office/volume-license-activation/gvlks)),
    the same as the repository's 2024 files, so no key is in any shipped file.

The original Office repository was not changed.

## How it runs on the computer

1. **Office stage** (`OfficeEngine.ps1`, SYSTEM task `\WindowsDeploymentBuilder\Office`, at startup and
   every 15 minutes, order 4):
   - It waits for the Windows Update stage, then the WinGet applications (at most their own time
     budget), then any restart another engine scheduled.
   - **Existing Office:** the same product is verified and kept (never reinstalled). Any other
     Click-to-Run Office (Microsoft 365, 2019, the other LTSC) or MSI Office without the removal
     choice ends the stage with a follow-up. Nothing is uninstalled.
   - It checks 10 GB of free space, the connection to Microsoft's Office servers (waits up to 6 h,
     then `Offline`) and the SHA-256 of the pinned installer and XML; a changed file is never run.
   - It runs `Install_Office.ps1 -Unattended` under the shared installation lock. The installer
     downloads the current Office Deployment Tool from Microsoft and verifies its Microsoft signature.
   - **Progress:** the phase comes from the processes (ODT extraction, `setup.exe /download`,
     `setup.exe /configure`), not from console output, and is rewritten every 15 seconds. A quiet
     multi-gigabyte download is therefore never reported as stalled. No percentage or speed is
     shown, because ODT reports none.
   - An installer running longer than 240 minutes is stopped. Exit codes are mapped (1, 2, 3, 4, 10:
     permanent; others are retried once, two attempts in total). An attempt interrupted by a restart
     is recorded, and a still-running installer is followed, never started twice.
   - **Verification:** success only when the Click-to-Run registration lists the product ID. Exit
     code 0 alone is never success.
   - Result `Office\result.json`: `Succeeded`, `CompletedWithFollowUp`, `Failed` or `Offline`.
     `activated` is always false. An Office failure never stops other stages.
2. **Final checks and restart**: the existing orchestrator 1.3.0 behaviour (restart coordination,
   Windows Update re-check). `WaitingForApplications` is a restart-safe phase.
3. **Activation stage** (`Activation.ps1`, deployment monitor; each target is attempted once, and only a `Blocked` or `Deferred` target is looked at again, for example after `Resume-Deployment.ps1 -RestartStage office`):
   - It runs only after every stage is final and Windows needs no further restart. With a restart
     still outstanding, each target is `Deferred`.
   - Office activation runs only when the Office stage `Succeeded`; otherwise it is `Blocked`, never
     a failure of the installation. Windows is handled independently.
   - **Microsoft methods:**
     - Windows uses `SoftwareLicensingProduct.Activate()` (online / digital license) and the
       licensing service's KMS host settings.
     - Office uses the pinned `Activate_Office.ps1` (`-KmsHost` / `-Activate`, OSPP.VBS) for KMS and
       Active Directory activation.
     - A product key or MAK is only entered by the technician:
       `DeploymentRecovery.ps1 -Action Activate -Target Windows|Office` (also menu item A).
       `Read-Host -AsSecureString` passes it straight to `SoftwareLicensingService.InstallProductKey`
       in the same process: no command line, file or log ever contains it.
   - **Evidence only:** `Activated` requires `LicenseStatus = 1` from the licensing service.
     `DeploymentRecovery.ps1 -Action CheckActivation` re-reads the state (for example after a manual
     activation).
   - **Statuses:** `NotRequested`, `AwaitingTechnician`, `Activated`, `Failed`, `Deferred`,
     `Blocked`, `Unavailable` (licensing service unreadable). Anything but `Activated` or
     `NotRequested` makes the deployment `CompletedWithFollowUp`, never `CompletedWithFailures`.
   - The deployment never waits for the technician.
   - `Activation\result.json` and `Activation\activation.log` are separate from the installer logs.
4. **Report**: sections "Microsoft Office" (installation, pinned sources) and "Activation (separate
   from the installation results)". Activation changes made later by the technician are written into
   the report.

**Progress window** (refreshes every 7 seconds): the Office stage is listed like the other stages,
with its phase, plus an `Activation : Windows …; Office …` line.

**LAN monitor:** `office` (edition, phase, verified, `progress: unavailable`) and `activation`
(status and message per target) cards. The fields exist only for deployments that include them, so
the whitelist test for other deployments is unchanged. No key is served: not even the five
characters Windows reports ("key ending …" is removed from every status view).

## Tests

- **`tests/unit/office.test.ts`** (24):
  - the pinned bytes and the four products' IDs and channels;
  - the adapted 2021 XML (no key, `AUTOACTIVATE` or `RemoveMSI`);
  - no `Invoke-Expression`, `irm`, `iex`, download-and-run or third-party activation in any shipped
    script;
  - defaults and migration;
  - application profiles never select Office;
  - Basic and Advanced visibility, and impossible combinations refused;
  - per product: its own configuration only, `-Edition` or `-ConfigPath`, stage order and waits;
  - independent Windows and Office activation (neither, either, both);
  - the recovery tool is forced on when a technician is needed;
  - the KMS helper ships only when used;
  - no product-key pattern and no Massgrave reference in any package or answer file across 12
    combinations.
- **`tests/powershell/Office.Tests.ps1`** (26, in `npm run test:ps`), against the real generated 2024
  and 2021 packages on a simulated computer:
  - ordering; process-derived phases with a quiet download;
  - 2021 adapter arguments;
  - existing Office (same product, Click-to-Run conflict, MSI conflict);
  - exit code 0 without registration, retried download error, permanent errors and the disk check;
  - timeout, interrupted installation, and following a running installer;
  - network wait and Offline, the lock, a pending restart, a tampered installer;
  - applications that never finish;
  - activation:
    - Microsoft, both targets;
    - a blocked Office leaves Windows unaffected;
    - evidence-only results, Deferred and Unavailable;
    - the technician methods;
    - runs once, and a blocked Office activation is attempted after a successful Office re-run;
    - a MAK that never reaches a file, a log or the state;
    - CheckActivation;
  - the LAN monitor model without keys.
- **`Acl.Tests.ps1`** covers the new `Install-OfficeEngine.ps1` copy of `Protect-WdbDataRoot` with
  real icacls (29 tests, up from 25).
- **`tests/e2e/office.spec.ts`** (4 scenarios × 3 viewports):
  - Basic and Advanced visibility; the legacy notice;
  - independence; review tiles;
  - the blocked package;
  - the downloaded 2024 package (one XML, pinned commit, stage order, no key, no third-party tool).

## Known limitations

- Office downloads from Microsoft's CDN at run time (about 3-4 GB). There is no offline Office
  source in the package yet.
- English and the OS language (`en-us`, `MatchOS`) and 64-bit, as in the repository's
  configurations. There is no language or architecture choice in the builder.
- Click-to-Run Office conflicts are reported, never resolved automatically.
- Product keys and MAKs are entered interactively by the technician only: there is no unattended key
  injection by design. KMS for Windows requires a Windows volume edition with its KMS client key.
- `Activate_Office.ps1` looks for OSPP.VBS under `Office16` (correct for 2021 and 2024 64-bit).
- The Quick Deployment wizard does not show the Office choice; it is on the Applications page.
- The profile schema is 9 here and also 9 on `feature/disk-preparation`: whichever branch merges
  second needs its migration renumbered to 10.

## Must be proven on a real installation

1. **2024 ProPlus, then 2021 Standard, on a disposable VM:**
   - the stage waits for Windows Update and the applications;
   - phases appear in the progress window and the LAN monitor during the 2-4 GB download;
   - `Office\result.json` is `Succeeded` with `verified: true`;
   - Word opens.
2. **The 2021 run through the 2024 installer with `-ConfigPath`:** check the ODT log for channel
   `PerpetualVL2021`, then run `cscript OSPP.VBS /dstatus` to confirm the GVLK was installed without
   PIDKEY.
3. **Existing Office:**
   - a VM with Microsoft 365 Apps gives a follow-up, with nothing removed;
   - a VM with Office 2016 MSI and the removal choice ends with the old suite gone and LTSC
     installed.
4. **Interrupted installation:** restart during `setup.exe /configure`. Expect `Interrupted` to be
   recorded and a retry (or verification if Click-to-Run finished on its own).
5. **Activation:**
   - Windows with a digital license: Activated;
   - a KMS lab host (`kms.example:1688`) for Windows volume and Office: Activated;
   - MAK entered through the recovery tool: Activated, and the key appears in no file under
     `C:\ProgramData\WindowsDeploymentBuilder` (search for it);
   - with no network: Failed, then a later `-Action Activate` works.
6. The deployment with activation awaiting the technician finishes as `CompletedWithFollowUp`, and
   the report and the LAN monitor show the activation separately.
