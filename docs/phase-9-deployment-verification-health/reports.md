# Reports, dashboard, customer handoff and recovery integration

All files are written to `C:\ProgramData\WindowsDeploymentBuilder\reports\health` (SYSTEM and
Administrators full control, Users read, inherited from the data root).

| File | Content |
|---|---|
| `deployment-health.json` | the machine-readable report, format `windows-deployment-builder/deployment-health` v1 (JSON Schema shipped as `scripts\health\deployment-health.schema.json`; Zod `HealthReportSchema`) |
| `technician-report.html` | the technician dashboard (written when "Generate the technician report" is on) |
| `customer-handoff.html`, `customer-handoff.json` | the customer report (when "Generate the customer handoff report" is on) |
| `history\deployment-health-<UTC time>-<status>.json` | every earlier report. The first one is always kept; up to 50, or the first and the previous one when history is off |
| `recheck.json` | the number of startup re-checks after a pending restart |

`deployment-health.json` contains:

- schema version, engine version, verification id;
- deployment id (the package id), time and trigger;
- `readOnly: true`;
- who ran it and whose profile was read;
- the OS identity (computer name, edition, build; no serials or keys);
- the overall state with its exit code;
- the category states, every finding, the selected applications;
- outstanding operations, manual actions, the delivery checklist;
- recovery actions, retained backups, the Windows settings adapters;
- the evidence sources with their state, the limitations, the comparison with the previous report,
  and the history.

The deployment report (`deployment-report.json`, report version 2) gets an additive `health` block:
status, summary, readyForDelivery, verificationId and paths. Its text version gets a "Deployment
verification" section.

## Technician dashboard

One offline HTML file: no network, no external script, font or style. The data is embedded as JSON
(with `<`, `>` and `&` escaped) and every value is inserted as text. It contains:

- the overall state and whether the computer can be handed over;
- the comparison with the previous check (resolved, new, remaining);
- the categories, each with its state. A category without checks shows "Not part of this
  deployment", never green;
- "What needs attention", sorted by state and severity, each with the next action;
- the delivery checklist:
  - ticks come only from the verification;
  - items that cannot be measured (recovery-key arrangement, customer sign-in tasks) are
    "Confirm by hand", with check boxes and a notes field for printing;
- the applications: only the deployment's selection, with search and filters (needs attention,
  automatic, manual follow-up). It shows the result, whether Windows lists the application and where,
  the version, the engine's status and attempts;
- details per category, expandable: expected, observed, how it was verified, evidence;
- recovery: outstanding operations, manual actions, and the commands of the recovery tool. Each is
  marked read-only or "changes the computer" and has a Copy button;
- retained backups, and the evidence sources and limitations (collapsed).

Print or save as PDF with Ctrl+P: the stylesheet has a print layout and the details are expanded. A
generated PDF was not added: it would need an extra dependency on the computer, and Edge's "Save as
PDF" produces the same document.

## Customer handoff

A separate data set, so no technical detail is even present in the file.

**It contains:**

- computer name, Windows edition and the account to sign in with;
- a plain headline;
- installed applications; applications the technician still has to finish;
- applications to install themselves, with instructions;
- protection (virus protection, firewall, device encryption);
- update status;
- what they still need to do (activation, a restart, sign-in to applications that need their
  account, keeping the recovery key);
- the technician's notes.

**It never contains:**

- passwords, Wi-Fi keys, product keys or recovery keys;
- tokens;
- paths, SIDs or serial numbers;
- other accounts;
- findings, evidence or verification ids.

The tests check this on the embedded data. The technician notes are refused by the website if they
look like a password or a key.

**Headlines:**

| State | Headline |
|---|---|
| Ready | "Your computer is set up and ready to use." |
| ReadyWithWarnings | "Your computer is ready to use. A few items need your attention." |
| Any other | "Setup is not finished yet. Your technician needs to complete the items below before this computer is ready." It never claims everything is working. |

## Entry points

| Entry point | What it does |
|---|---|
| End of the deployment | `Complete-Deployment.ps1` (monitor, SYSTEM) verifies once the state says Completed, adds the result to the deployment report, and creates the public-desktop shortcut **Windows Deployment — Health Report** (`DeploymentHealth.ps1 -Mode Dashboard -Elevate`: verifies again, then opens the dashboard through Explorer, not elevated) |
| Pending restart | a self-removing SYSTEM startup task re-checks after the restart (at most 3 runs) |
| Progress window | when "Open the technician report when the deployment finishes" is on, the "Deployment progress" window opens the dashboard once when it appears. Nothing opens at later sign-ins |
| Recovery tool | menu 9 or `-Action Verify` (trigger Recovery) |
| By hand | `DeploymentHealth.ps1` (exit code = state), `-ScanUpdates`, `-Json` |

## Recovery integration and re-verification

Verification never repairs anything. The dashboard lists the existing actions:

- Retry failed operations;
- Resume provisioning;
- Retry settings restoration (RestoreSettings);
- Provide a verified driver package (AddDrivers);
- Recheck Windows Update (`-ScanUpdates`);
- Export diagnostics.

Each finding names its `recoveryAction`. After a recovery, the monitor completes the deployment
again and the verification runs again automatically. The new report keeps the previous one in the
history and lists:

- the previous and current state;
- resolved findings (by stable id);
- new findings;
- remaining findings.

The record of the failed deployment is never overwritten (scenario K). If a restart interrupts a
verification after the old report was archived, the next one compares with the newest archived
report.

## Diagnostic export

`DeploymentHealth.ps1 -Mode ExportDiagnostics` (or the recovery tool's ExportDiagnostics) builds one
ZIP:

- **What it collects:** only a whitelist of files below the data root:
  - logs, states, results and reports;
  - `drivers.json` and `restoration.json`;
  - the health reports and their history;
  - the package's configuration.
- **Redaction:** passwords, keys and tokens are removed by the Phase 5 redaction (`Protect-WdrText`).
  Pattern-based redaction is not infallible, which is why the collection is a whitelist in the first
  place.
- **Never collected:**
  - answer files and Wi-Fi profiles;
  - the `Backup` folder (settings backups);
  - executables.
- **Archive check:** every entry is checked once the archive is built
  (`Test-WdrDiagnosticArchive`): relative, no `..`, no backup folder, no XML or binary type. An
  archive with anything else is deleted and reported.
- **Nothing is sent anywhere.** Without the recovery tool, the export contains only the health
  reports.
