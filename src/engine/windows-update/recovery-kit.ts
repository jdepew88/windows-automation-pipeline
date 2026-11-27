import { createZip, type ZipEntry } from '../deployment/zip';
import { encodeFile } from '../deployment';
import { sha256 } from '../deployment/sha256';
import { DATA_ROOT, ENGINE_FILE, ENGINE_SOURCE, ENGINE_VERSION, RECOVERY_KIT_DIR, RETRY_FILE, RETRY_SOURCE } from '.';
import healthSource from '../health/scripts/DeploymentHealth.ps1?raw';
import healthTemplate from '../health/scripts/HealthReport.html?raw';
import commonSource from '../deployment/scripts/DeploymentCommon.ps1?raw';

/**
 * The standalone Windows Update recovery download (dist/downloads/windows-update-recovery.zip,
 * written by scripts/build-update-recovery-kit.ts):
 *
 *   WDB-WindowsUpdate/WindowsUpdateEngine.ps1        engine 2.0.0 or later
 *   WDB-WindowsUpdate/Invoke-WindowsUpdateRetry.ps1  Retry Windows Update (finds the engine next to it)
 *   WDB-WindowsUpdate/health/DeploymentHealth.ps1    the read-only health audit (-Mode HealthAudit)
 *   WDB-WindowsUpdate/health/HealthReport.html       its report template
 *   WDB-WindowsUpdate/common/DeploymentCommon.ps1    shared functions the audit loads (..\common)
 *   WDB-WindowsUpdate/README.txt
 *   WDB-WindowsUpdate/files.json                     SHA-256 of every file
 *
 * For a computer deployed with an engine before 2.0.0 (every update failed with 0x80131508): its
 * deployment package does not contain the retry tool. A package built with 2.0.0 or later already
 * has it (Deployment Recovery, menu U). Nothing in the kit runs by itself.
 */

const crlf = (s: string): string => s.replace(/\r?\n/g, '\r\n');

export function recoveryKitReadme(): string {
  const rw = `powershell.exe -ExecutionPolicy Bypass -File .\\${RETRY_FILE}`;
  return crlf(`Windows Deployment Builder - Windows Update recovery (engine ${ENGINE_VERSION})
==========================================================================

For a computer that is already installed, typically one deployed with Windows Update engine
1.0.0-1.3.0, whose updates and drivers all failed with 0x80131508. Windows is not reinstalled and
nothing is erased. The original deployment's Windows Update results and report are only read (a
retry adds its own lines to the deployment's activity log, shown in the progress window and LAN
monitor, and to the Application event log). Every retry is a separate run
in ${DATA_ROOT}\\UpdateRetry\\<run>, under the scheduled task
\\WindowsDeploymentBuilder\\WindowsUpdateRetry (SYSTEM).

Extract this folder (for example to C:\\${RECOVERY_KIT_DIR}), open Windows PowerShell as
administrator in it and run, in order:

  1. ${rw} -Mode ExportDiagnostics
       ZIP of the original evidence on the desktop (read-only). Keep it.
  2. ${rw} -Mode Status
       Readiness, pending restart, devices with problems, what the original run shows (read-only).
  3. ${rw} -Mode Scan
       What Windows Update offers now, by pass (read-only; nothing is downloaded).
  4. ${rw} -Mode RetryUpdates -Wait
       Servicing prerequisites, then normal updates. Restarts when an update needs it (60-second
       warning) and continues after the restart; sign in and run -Mode Status, or the same
       command again to follow the same run.
  5. ${rw} -Mode RetryDrivers -Wait
       Drivers offered by Windows Update, one at a time, each recorded with its device.
       Start it once step 4's run has finished (-Mode Status lists it as Succeeded,
       CompletedWithFollowUp or CompletedWithFailures); until then it is refused and nothing changes.
  6. ${rw} -Mode Status
       Advice follows what happened: once the retries succeeded it recommends the health audit,
       never another retry.
  7. ${rw} -Mode HealthAudit
       Read-only health audit of the computer now (Windows Update, devices, applications, Office,
       manufacturer software recommendations, recovery history). Writes only its report under
       ${DATA_ROOT}\\reports\\health. The original deployment report is never rewritten.
  8. ${rw} -Mode ExportDiagnostics
       Includes comparison.txt: the original run against each retry.

RetryUpdates installs every Windows update the deployment's policy allows (security,
cumulative, .NET, Defender, MSRT, and the Windows and .NET preview updates when the policy
includes previews); RetryDrivers installs drivers. -Mode RetryAll does both in one run. Firmware,
feature updates and Insider builds are never installed. Add -Json for machine-readable output.

A good result: no 0x80131508 anywhere; anything still failing carries a Windows Update code and
category (for example InstallerFailure 0x800F0922 or NotApplicable), never EngineException.

Files
  ${ENGINE_FILE}         Windows Update engine ${ENGINE_VERSION}
  ${RETRY_FILE}  Retry Windows Update (needs the engine in the same folder)
  health\\DeploymentHealth.ps1    read-only health audit (needs common\\ beside it)
  files.json                      SHA-256 of every file
`);
}

export interface RecoveryKitFile {
  path: string;
  content: string;
}

export function recoveryKitFiles(): RecoveryKitFile[] {
  return [
    { path: ENGINE_FILE, content: crlf(ENGINE_SOURCE) },
    { path: RETRY_FILE, content: crlf(RETRY_SOURCE) },
    { path: 'health/DeploymentHealth.ps1', content: crlf(healthSource) },
    { path: 'health/HealthReport.html', content: crlf(healthTemplate) },
    { path: 'common/DeploymentCommon.ps1', content: crlf(commonSource) },
    { path: 'README.txt', content: recoveryKitReadme() },
  ];
}

/** The ZIP: every file under RECOVERY_KIT_DIR/, PowerShell files with a UTF-8 BOM, plus files.json. */
export function buildRecoveryKit(): Uint8Array {
  const entries: ZipEntry[] = recoveryKitFiles().map((f) => ({ path: `${RECOVERY_KIT_DIR}/${f.path}`, data: encodeFile(f.path, f.content) }));
  const manifest = {
    format: 'windows-deployment-builder/windows-update-recovery',
    windowsUpdateEngine: ENGINE_VERSION,
    files: entries.map((e) => ({ path: e.path.slice(RECOVERY_KIT_DIR.length + 1), sha256: sha256(e.data), bytes: e.data.length })),
  };
  entries.push({ path: `${RECOVERY_KIT_DIR}/files.json`, data: encodeFile('files.json', JSON.stringify(manifest, null, 2) + '\n') });
  return createZip(entries);
}
