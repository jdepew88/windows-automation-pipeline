import engineSource from './scripts/WindowsUpdateEngine.ps1?raw';
import installerSource from './scripts/Install-UpdateEngine.ps1?raw';
import retrySource from './scripts/Invoke-WindowsUpdateRetry.ps1?raw';
import type { Profile } from '../schema/profile';

/**
 * Phase 2 Windows Update engine: configuration and deployment assets.
 *
 * The PowerShell sources are static files (tested directly by tests/powershell); everything a
 * profile can change goes into config.json, which both scripts read at run time.
 */

export const ENGINE_VERSION = '2.0.0';
export const DATA_ROOT = 'C:\\ProgramData\\WindowsDeploymentBuilder';
/** Where the answer file extracts the assets during specialize (Administrators-only by default). */
export const STAGING_DIR = 'C:\\Windows\\Setup\\Scripts\\WindowsUpdate';
export const TASK_PATH = '\\WindowsDeploymentBuilder\\';
export const TASK_NAME = 'WindowsUpdate';
export const RESULT_FILE = `${DATA_ROOT}\\Updates\\result.json`;
export const COMPLETION_MARKER = `${DATA_ROOT}\\state\\windows-update.done`;

export const ENGINE_FILE = 'WindowsUpdateEngine.ps1';
export const INSTALLER_FILE = 'Install-UpdateEngine.ps1';
export const CONFIG_FILE = 'config.json';
export const README_FILE = 'README-WindowsUpdate.txt';
/** Engine 2.0.0: Retry Windows Update, the standalone recovery tool (package and retry kit only). */
export const RETRY_FILE = 'Invoke-WindowsUpdateRetry.ps1';
export const RETRY_SOURCE = retrySource;
export const ENGINE_SOURCE = engineSource;
/** The standalone Windows Update recovery download (recovery-kit.ts, scripts/build-update-recovery-kit.ts). */
export const RECOVERY_KIT_FILE = 'windows-update-recovery.zip';
export const RECOVERY_KIT_DIR = 'WDB-WindowsUpdate';
/** Files embedded in the answer file (extracted to STAGING_DIR during specialize). Engine 2.0.0 adds Retry Windows Update, so it is on every computer the engine ran on. */
export const EMBEDDED_UPDATE_FILES: readonly string[] = [ENGINE_FILE, INSTALLER_FILE, CONFIG_FILE, 'Invoke-WindowsUpdateRetry.ps1'];

/**
 * Phase 4.3: the ongoing ("Configure Automatic Updates") policy is a different concept from the
 * initial update provisioning above. When this engine runs, a notify-mode policy is applied only
 * after its stage is final (Set-UpdatePolicy.ps1, from the deployment monitor) instead of during
 * specialize. Without the engine the answer file writes it during specialize as before.
 */
export const POLICY_RESULT_FILE = 'Updates\\policy-result.json';
export function ongoingPolicyDeferred(p: Profile): boolean {
  return p.windowsUpdate.enabled && (p.updates.mode === 'notifyInstall' || p.updates.mode === 'notifyDownload');
}

/** Numeric limits, shared by validation and the UI. */
export const LIMITS = {
  maxReboots: [1, 30],
  maxAttemptsPerUpdate: [1, 5],
  maxRuntimeHours: [1, 24],
  networkWaitMinutes: [1, 60],
  confirmationScans: [0, 5],
  rebootWarningSeconds: [0, 600],
} as const satisfies Record<string, readonly [number, number]>;

export interface EngineConfig {
  schemaVersion: 1;
  engineVersion: string;
  dataRoot: string;
  taskPath: string;
  taskName: string;
  drivers: 'include' | 'exclude';
  featureUpdates: 'skip' | 'install';
  optionalUpdates: 'skip' | 'install';
  microsoftUpdate: boolean;
  maxReboots: number;
  maxAttemptsPerUpdate: number;
  maxRuntimeHours: number;
  networkWaitMinutes: number;
  confirmationScans: number;
  resetComponentsOnce: boolean;
  rebootWarningSeconds: number;
  /** Phase 3 coordination: how long to wait for the shared install lock before trying later. */
  lockWaitMinutes: number;
  /** Engine 1.2.0: delay before a failed download or installation is retried (multiplied by the attempt). */
  retryDelaySeconds: number;
  excludedKbs: string[];
}

export interface DeploymentAsset {
  name: string;
  content: string;
  mime: string;
  description: string;
  /** Folder/group in the downloads panel and the future deployment ZIP. */
  group: 'windows-update' | 'drivers' | 'applications' | 'orchestration' | 'office';
}

/** Splits a free-text KB list. Accepts "KB5034441", "5034441", commas, spaces or new lines. */
export function parseKbList(text: string): { kbs: string[]; invalid: string[] } {
  const kbs: string[] = [];
  const invalid: string[] = [];
  for (const token of text.split(/[\s,;]+/).filter(Boolean)) {
    const m = /^(?:KB)?(\d{6,8})$/i.exec(token);
    if (!m) invalid.push(token);
    else if (!kbs.includes(`KB${m[1]}`)) kbs.push(`KB${m[1]}`);
  }
  return { kbs, invalid };
}

/** "followPolicy" resolves against the M1 policy that withholds drivers from Windows Update. */
export function resolveDrivers(p: Profile): 'include' | 'exclude' {
  const d = p.windowsUpdate.drivers;
  if (d === 'followPolicy') return p.updates.excludeDrivers ? 'exclude' : 'include';
  return d;
}

export function engineConfig(p: Profile): EngineConfig {
  const w = p.windowsUpdate;
  return {
    schemaVersion: 1,
    engineVersion: ENGINE_VERSION,
    dataRoot: DATA_ROOT,
    taskPath: TASK_PATH,
    taskName: TASK_NAME,
    drivers: resolveDrivers(p),
    featureUpdates: w.featureUpdates,
    optionalUpdates: w.optionalUpdates,
    microsoftUpdate: w.microsoftUpdate,
    maxReboots: w.maxReboots,
    maxAttemptsPerUpdate: w.maxAttemptsPerUpdate,
    maxRuntimeHours: w.maxRuntimeHours,
    networkWaitMinutes: w.networkWaitMinutes,
    confirmationScans: w.confirmationScans,
    resetComponentsOnce: w.resetComponentsOnce,
    rebootWarningSeconds: w.rebootWarningSeconds,
    lockWaitMinutes: 60,
    retryDelaySeconds: 120,
    excludedKbs: parseKbList(w.excludedKbs).kbs,
  };
}

const crlf = (s: string): string => s.replace(/\r?\n/g, '\r\n');

function readme(): string {
  return `Windows Deployment Builder - Windows Update engine ${ENGINE_VERSION}
====================================================================

These files are generated by Windows Deployment Builder. When Windows Update automation is
enabled, the same files are embedded in autounattend.xml and installed automatically at the
end of FirstLogon; you only need them separately to inspect them or to run the engine on a
machine that is already installed.

Files
  ${ENGINE_FILE}   The engine. Runs as SYSTEM from a scheduled task.
  ${INSTALLER_FILE}  Secures ${DATA_ROOT}, copies the engine there,
                              registers the task ${TASK_PATH}${TASK_NAME} and starts it.
  ${CONFIG_FILE}               Policy and limits chosen in the web app.

Manual use (elevated Windows PowerShell 5.1, all files in one folder)
  powershell.exe -ExecutionPolicy Bypass -File .\\${INSTALLER_FILE}
  powershell.exe -ExecutionPolicy Bypass -File .\\${ENGINE_FILE} -Mode Scan
      (read-only: lists what would be installed or skipped; installs nothing)
  powershell.exe -ExecutionPolicy Bypass -File .\\${INSTALLER_FILE} -Uninstall

  powershell.exe -ExecutionPolicy Bypass -File .\\${RETRY_FILE} -Mode Status
      Retry Windows Update on an installed computer (see "Retry Windows Update" below)

What happens
  The engine waits for the network, installs applicable updates through the Windows Update
  Agent API, restarts when required (with a warning to signed-in users) and resumes after each
  restart, until nothing applicable remains. It stops at the configured limits instead of
  looping: maximum restarts, attempts per update, total runtime and unexpected errors. Updates
  that keep failing are given up and reported.

  Engine 2.0.0 first checks that Windows Update is ready (services, a restart already pending,
  a first successful search; never an arbitrary wait), then installs in passes: A servicing
  prerequisites (servicing stack, Defender platform) on their own, B normal updates, C optional
  updates and drivers (each driver on its own, recorded with the device it is for), D a final
  search that verifies nothing installed is still offered and lists devices with problems.
  Every failure has a category (engine exception, Windows Update API, not applicable, network,
  download, installer, restart required, busy, not ready, technician). An exception in the
  engine's own code is recorded once with its line and stack trace, never as one failure per
  update; the same one twice stops the stage. Components are reset only for download-cache or
  data-store errors.

  Engines 1.0.0-1.3.0 failed every download and installation with 0x80131508
  (IndexOutOfRangeException) because the update collection was unrolled by PowerShell before it
  reached Windows Update; 2.0.0 fixes this.

  Selection: recommended updates always; optional updates (cumulative previews, optional driver
  updates) when "optional updates" is Install; drivers when drivers are included. Windows decides
  what is applicable; feature updates and Insider builds are not installed. An update that can
  ask for input is installed on its own, quietly; only if Windows answers that it needs a person
  is it reported for follow-up. Each update is downloaded on its own; a transient failure is
  retried after a delay, up to the attempts per update (download and installation count
  together); a permanent one (for example "not applicable") is not retried. Installing updates and scheduling a restart both
  take the install lock (${DATA_ROOT}\\state\\install.lock) shared with the
  application engine, so a restart never interrupts an application installation.

Results
  Log:     ${DATA_ROOT}\\Updates\\logs\\engine.log
  Status:  ${DATA_ROOT}\\Updates\\status.json   (live phase)
  Result:  ${RESULT_FILE}
           status = Succeeded | CompletedWithFollowUp | CompletedWithFailures | Failed | Offline
  Marker:  ${COMPLETION_MARKER}
           written for Succeeded, CompletedWithFollowUp and CompletedWithFailures
  Events:  Application log, source "WindowsDeploymentBuilder", IDs 1000 started, 1001 restart,
           1100 Succeeded, 1101 CompletedWithFailures, 1102 Failed, 1103 Offline,
           1104 CompletedWithFollowUp

Retry Windows Update (${RETRY_FILE})
  Runs the corrected engine again on an installed computer, as a separate run that never changes
  the original Windows Update results or the deployment report; it adds its own lines to the
  deployment's activity log and the Application event log (${DATA_ROOT}\\UpdateRetry\\<run>). Elevated Windows PowerShell:
    -Mode Status             read-only readiness and what the original run shows
    -Mode Scan               read-only search: what would be installed, by pass
    -Mode RetryUpdates       normal updates (no drivers, no optional updates)
    -Mode RetryDrivers       drivers offered by Windows Update
    -Mode RetryAll           everything the deployment's policy allows
    -Mode ExportDiagnostics  ZIP with logs, results, history and a before/after comparison
  Add -Wait to follow progress. The Deployment Recovery tool offers the same (menu U).

Status: engine 2.0.0's Windows Update calls were checked read-only against the real Windows
Update Agent (search, collections, assignment). On a physical computer deployed with engine
1.3.0 (every update failed with 0x80131508), Retry Windows Update with engine 2.0.0 installed 1
normal update and 9 drivers with no failure, and no device was left with a problem. A full
deployment with engine 2.0.0 from the start has not been tested on hardware yet.
`;
}

/** Downloadable deployment assets; empty when the engine is disabled. */
export function updateEngineAssets(p: Profile): DeploymentAsset[] {
  if (!p.windowsUpdate.enabled) return [];
  return [
    { name: ENGINE_FILE, content: crlf(engineSource), mime: 'text/plain', description: 'Update engine (runs as SYSTEM from the scheduled task)', group: 'windows-update' },
    { name: INSTALLER_FILE, content: crlf(installerSource), mime: 'text/plain', description: 'Installs the engine, registers the task and confirms it starts', group: 'windows-update' },
    { name: CONFIG_FILE, content: crlf(JSON.stringify(engineConfig(p), null, 2) + '\n'), mime: 'application/json', description: 'Policy and limits from this profile', group: 'windows-update' },
    { name: RETRY_FILE, content: crlf(retrySource), mime: 'text/plain', description: 'Retry Windows Update: status, scan, retry and diagnostics on an installed computer', group: 'windows-update' },
    { name: README_FILE, content: crlf(readme()), mime: 'text/plain', description: 'How to use the files and read the results', group: 'windows-update' },
  ];
}
