import commonSource from './scripts/DeploymentCommon.ps1?raw';
import stageSource from './scripts/Stage-Deployment.ps1?raw';
import initializeSource from './scripts/Initialize-Deployment.ps1?raw';
import orchestratorSource from './scripts/DeploymentOrchestrator.ps1?raw';
import showSource from './scripts/Show-DeploymentStatus.ps1?raw';
import resumeSource from './scripts/Resume-Deployment.ps1?raw';
import completeSource from './scripts/Complete-Deployment.ps1?raw';
import setupSource from './scripts/setup.ps1?raw';
import policySource from './scripts/Set-UpdatePolicy.ps1?raw';
import type { GenContext } from '../context';
import type { GenerateResult } from '../pipeline';
import type { Profile } from '../schema/profile';
import { lookup } from '../../data';
import { resolveIdentity } from '../naming';
import { exportProfile, hasSecrets } from '../profiles';
import { orchestrationAsset } from '../orchestration';
import { DATA_ROOT, EMBEDDED_UPDATE_FILES, ENGINE_VERSION, POLICY_RESULT_FILE, TASK_NAME, TASK_PATH, ongoingPolicyDeferred, resolveDrivers, updateEngineAssets } from '../windows-update';
import { APP_ENGINE_VERSION, APP_PROFILE_FILE, APP_TASK_NAME, EMBEDDED_APP_FILES, applicationAssets, applicationsActive } from '../applications';
import { allProfiles, effectiveDevices, resolveSelection } from '../applications/selection';
import { DRIVER_STAGE } from '../drivers/contract';
import { isEffective, PHASES } from '../../features/scripts';
import { sha256, utf8 } from './sha256';
import { createZip } from './zip';

/**
 * Phase 4: the USB deployment package and the first-boot orchestrator.
 *
 * The answer file stays the carrier: everything the installed computer needs (both engines, the
 * orchestrator scripts and the manifest) is embedded in autounattend.xml and extracted during
 * specialize from Setup's own copy, so nothing depends on the USB drive's letter or on the drive
 * still being attached. The ZIP adds the same files as a WindowsDeployment folder for
 * verification, manual runs on other installations (setup.cmd) and recovery.
 */

export const DEPLOYMENT_VERSION = '1.0.0';
export const PACKAGE_DIR = 'WindowsDeployment';
export const PACKAGE_FILE_NAME = 'windows-deployment-package.zip';
export const MANIFEST_FILE = 'deployment-manifest.json';
export const MANIFEST_FORMAT = 'windows-deployment-builder/deployment-manifest';
/** Embedded files are extracted under this folder (Administrators-only by default). */
export const SETUP_SCRIPTS_DIR = 'C:\\Windows\\Setup\\Scripts';
export const DEPLOY_STAGING_DIR = `${SETUP_SCRIPTS_DIR}\\Deployment`;
export const MONITOR_TASK = { path: TASK_PATH, name: 'Deployment' } as const;
export const PACKAGE_ROOT = `${DATA_ROOT}\\Package`;
export const DEPLOYMENT_STATE = `${DATA_ROOT}\\state\\deployment.json`;
export const DEPLOYMENT_STATUS = `${DATA_ROOT}\\Deployment\\status.json`;
export const DEPLOYMENT_MARKER = `${DATA_ROOT}\\state\\deployment.done`;
export const DEPLOYMENT_REPORT = `${DATA_ROOT}\\reports\\deployment-report.txt`;
export const INITIALIZE_SCRIPT = 'scripts/bootstrap/Initialize-Deployment.ps1';
export const RESUME_SCRIPT = 'scripts/orchestrator/Resume-Deployment.ps1';
export const STATUS_SCRIPT = 'scripts/orchestrator/Show-DeploymentStatus.ps1';

/** Orchestrator limits (in addition to each engine's own limits, which are unchanged). */
export const ORCHESTRATOR_LIMITS = { launchAttempts: 2, stalledAfterMinutes: 120, monitorIntervalMinutes: 15, graceHours: 24 } as const;

export type FileRole = 'entry' | 'orchestrator' | 'engine' | 'configuration' | 'profile' | 'documentation';

export interface PackageFile {
  /** Path inside WindowsDeployment/ (forward slashes). */
  path: string;
  content: string;
  role: FileRole;
  description: string;
  /** Path relative to C:\Windows\Setup\Scripts when the file is also embedded in the answer file. */
  embedded: string | null;
}

const crlf = (s: string): string => s.replace(/\r?\n/g, '\r\n');

/** True when the answer file starts the post-installation deployment. */
export function deploymentActive(p: Profile): boolean {
  return p.windowsUpdate.enabled || applicationsActive(p);
}

const ORCHESTRATOR_SCRIPTS: { path: string; source: string; description: string }[] = [
  { path: 'scripts/common/DeploymentCommon.ps1', source: commonSource, description: 'Shared functions: manifest, integrity checks, state and stage snapshots' },
  { path: 'scripts/bootstrap/Stage-Deployment.ps1', source: stageSource, description: 'Verifies the package and copies it to the protected package folder' },
  { path: INITIALIZE_SCRIPT, source: initializeSource, description: 'First-sign-in entry: stages the package, launches each stage once, registers the monitor' },
  { path: 'scripts/orchestrator/DeploymentOrchestrator.ps1', source: orchestratorSource, description: 'Monitor task (SYSTEM): follows the stages, writes status.json, finishes the deployment' },
  { path: STATUS_SCRIPT, source: showSource, description: 'Progress in a console window (read-only)' },
  { path: RESUME_SCRIPT, source: resumeSource, description: 'Manual recovery: re-check, re-register the monitor, restart a stage on request' },
  { path: 'scripts/finalization/Complete-Deployment.ps1', source: completeSource, description: 'Final report, completion marker and cleanup' },
];

export const POLICY_SCRIPT = 'scripts/finalization/Set-UpdatePolicy.ps1';

/** Phase 4.3: the ongoing Windows Update policy the monitor applies after the initial update stage. */
export function updatePolicyPlan(p: Profile) {
  if (!ongoingPolicyDeferred(p)) return null;
  return {
    mode: p.updates.mode,
    applyAfter: 'windowsUpdate',
    context: 'SYSTEM',
    script: POLICY_SCRIPT,
    key: 'HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU',
    values: { NoAutoUpdate: 0, AUOptions: p.updates.mode === 'notifyInstall' ? 3 : 2 },
    result: POLICY_RESULT_FILE,
    finalStatuses: ['Applied', 'AlreadyApplied', 'Unsupported', 'ManagedByOrganization', 'Conflict', 'Failed'],
  };
}

const embeddedDeploymentPath = (path: string) => `Deployment\\${path.replace(/\//g, '\\')}`;

/** Every file of the WindowsDeployment folder except the manifest itself. */
export function packageFiles(p: Profile): PackageFile[] {
  const files: PackageFile[] = [
    { path: 'README.txt', content: crlf(readme(p)), role: 'documentation', description: 'What the package is and how to use it', embedded: null },
    { path: 'setup.cmd', content: crlf(SETUP_CMD), role: 'entry', description: 'Manual entry point (run as administrator): starts setup.ps1', embedded: null },
    { path: 'setup.ps1', content: crlf(setupSource), role: 'entry', description: 'Verifies the package and starts the deployment on an installed Windows', embedded: null },
    ...ORCHESTRATOR_SCRIPTS.map((s) => ({ path: s.path, content: crlf(s.source), role: 'orchestrator' as const, description: s.description, embedded: embeddedDeploymentPath(s.path) })),
  ];
  if (updatePolicyPlan(p)) {
    files.push({ path: POLICY_SCRIPT, content: crlf(policySource), role: 'orchestrator', description: 'Applies the ongoing Windows Update policy once the initial update stage is final', embedded: embeddedDeploymentPath(POLICY_SCRIPT) });
  }
  for (const a of updateEngineAssets(p)) {
    files.push({
      path: `scripts/windows-update/${a.name}`,
      content: a.content,
      role: a.name.endsWith('.json') ? 'configuration' : a.name.endsWith('.txt') ? 'documentation' : 'engine',
      description: a.description,
      embedded: EMBEDDED_UPDATE_FILES.includes(a.name) ? `WindowsUpdate\\${a.name}` : null,
    });
  }
  for (const a of applicationAssets(p)) {
    if (a.name === APP_PROFILE_FILE) continue;
    files.push({
      path: `scripts/applications/${a.name}`,
      content: a.content,
      role: a.name.endsWith('.json') ? 'configuration' : a.name.endsWith('.ps1') ? 'engine' : 'documentation',
      description: a.description,
      embedded: (EMBEDDED_APP_FILES as readonly string[]).includes(a.name) ? `Applications\\${a.name}` : null,
    });
  }
  const orch = orchestrationAsset(p);
  files.push({ path: 'config/orchestration.json', content: orch.content, role: 'configuration', description: orch.description, embedded: embeddedDeploymentPath('config/orchestration.json') });
  files.push({ path: 'profiles/windows-settings.json', content: crlf(exportProfile(p)), role: 'profile', description: 'This configuration as a builder profile (passwords removed); re-import it in the website', embedded: null });
  const appProfile = applicationAssets(p).find((a) => a.name === APP_PROFILE_FILE);
  if (appProfile) files.push({ path: 'profiles/applications.json', content: appProfile.content, role: 'profile', description: "The effective application selection in the builder's profile format", embedded: null });
  files.push({ path: 'docs/INSTALLATION.txt', content: crlf(installation(p)), role: 'documentation', description: 'Preparing the USB drive and installing', embedded: null });
  return files;
}

/** Bytes as written to the ZIP: UTF-8; .ps1 with a BOM so Windows PowerShell 5.1 reads them as UTF-8. */
export function encodeFile(path: string, content: string): Uint8Array {
  const body = utf8(content);
  if (!path.endsWith('.ps1')) return body;
  const out = new Uint8Array(body.length + 3);
  out.set([0xef, 0xbb, 0xbf]);
  out.set(body, 3);
  return out;
}

/** Text hash: what the answer-file extraction writes (LF, trimmed) as UTF-8. See Get-WddTextHash. */
export function textHash(content: string): string {
  return sha256(utf8(content.replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n').trim()));
}

/** .ps1/.xml are extracted as UTF-8; other files in the system code page, exact only for ASCII. */
function textHashFor(path: string, content: string): string | null {
  // eslint-disable-next-line no-control-regex
  return /\.(ps1|xml)$/i.test(path) || /^[\x00-\x7f]*$/.test(content) ? textHash(content) : null;
}

/** JSON with every non-ASCII character escaped, so the code page used on extraction cannot matter. */
const asciiJson = (v: unknown) => crlf(JSON.stringify(v, null, 2).replace(/[\u007f-\uffff]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`) + '\n');

export function deadlineHours(p: Profile): number {
  const wu = p.windowsUpdate.enabled ? p.windowsUpdate.maxRuntimeHours : 0;
  const apps = applicationsActive(p) ? p.applications.waitForUpdatesHours + p.applications.maxRuntimeHours : 0;
  return wu + apps + ORCHESTRATOR_LIMITS.graceHours;
}

export function buildManifest(p: Profile) {
  const files = packageFiles(p);
  const entries = files.map((f) => {
    const bytes = encodeFile(f.path, f.content);
    return { path: f.path, role: f.role, size: bytes.length, sha256: sha256(bytes), textSha256: textHashFor(f.path, f.content), embedded: f.embedded };
  });
  // Identity of the deployment = what runs on the computer (the embedded files), so documentation
  // and profile exports in the ZIP cannot change the answer file.
  const packageId = sha256(utf8(entries.filter((e) => e.embedded).map((e) => `${e.path}:${e.textSha256 ?? e.sha256}`).sort().join('\n'))).slice(0, 16);
  const id = resolveIdentity(p.accounts);
  const sel = resolveSelection(p.applications.selection);
  const apps = applicationsActive(p);
  const wu = p.windowsUpdate;
  const a = p.applications;
  const manifest = {
    format: MANIFEST_FORMAT,
    manifestVersion: 1,
    packageVersion: DEPLOYMENT_VERSION,
    packageId,
    /** package: the ZIP's manifest (every file); answerFile: the copy embedded in the answer file (embedded files only). */
    scope: 'package' as 'package' | 'answerFile',
    generator: { name: 'Windows Deployment Builder', orchestrator: DEPLOYMENT_VERSION, windowsUpdateEngine: ENGINE_VERSION, applicationEngine: APP_ENGINE_VERSION },
    dataRoot: DATA_ROOT,
    packageFolder: PACKAGE_DIR,
    answerFile: {
      fileName: p.output.answerFileName,
      location: 'Root of the Windows installation USB drive',
      foundAutomatically: p.output.answerFileName === 'autounattend.xml',
      containsSecrets: hasSecrets(p),
      startsDeployment: deploymentActive(p),
    },
    windows: {
      edition: p.setup.editionMode === 'genericKey' ? `Windows 11 ${lookup.edition(p.setup.editionId)?.DisplayName ?? p.setup.editionId}` : p.setup.editionMode,
      editionMode: p.setup.editionMode,
      computerName: id.computerName ?? null,
      architectures: p.setup.processorArchitectures,
      diskSelection: 'interactive',
    },
    stages: [
      {
        id: 'staging',
        order: 0,
        name: 'Verify and stage the package',
        enabled: deploymentActive(p),
        implemented: true,
        context: 'user',
        when: 'Last FirstLogon command (or setup.cmd)',
        launcher: INITIALIZE_SCRIPT,
        requiresInternet: false,
      },
      {
        id: 'windowsUpdate',
        order: 1,
        name: 'Windows Update',
        enabled: wu.enabled,
        implemented: true,
        context: 'SYSTEM',
        launcher: 'scripts/windows-update/Install-UpdateEngine.ps1',
        task: { path: TASK_PATH, name: TASK_NAME },
        result: 'Updates\\result.json',
        status: 'Updates\\status.json',
        marker: 'state\\windows-update.done',
        finalStatuses: ['Succeeded', 'CompletedWithFailures', 'Failed', 'Offline'],
        waitsFor: [],
        requiresInternet: true,
      },
      {
        id: 'applications',
        order: 2,
        name: 'Applications (WinGet)',
        enabled: apps,
        implemented: true,
        context: 'user',
        launcher: 'scripts/applications/Install-ApplicationEngine.ps1',
        task: { path: TASK_PATH, name: APP_TASK_NAME },
        result: 'Applications\\result.json',
        status: 'Applications\\status.json',
        marker: 'state\\applications.done',
        finalStatuses: ['Succeeded', 'CompletedWithFollowUp', 'CompletedWithFailures', 'Failed', 'Offline'],
        waitsFor: wu.enabled ? ['windowsUpdate'] : [],
        coordination: a.coordination,
        requiresInternet: true,
      },
      {
        id: DRIVER_STAGE.id,
        order: 3,
        name: 'Manufacturer drivers',
        enabled: false,
        implemented: false,
        status: 'NotImplemented',
        context: 'SYSTEM',
        waitsFor: ['windowsUpdate'],
        note: 'Not implemented in this version. Nothing installs or changes drivers. Interface: src/engine/drivers/contract.ts.',
        requiresInternet: true,
      },
      {
        id: 'finalization',
        order: 4,
        name: 'Report and cleanup',
        enabled: deploymentActive(p),
        implemented: true,
        context: 'SYSTEM',
        launcher: 'scripts/finalization/Complete-Deployment.ps1',
        requiresInternet: false,
      },
    ],
    applications: {
      enabled: apps,
      selectedProfiles: a.selection.selectedProfiles.map((pid) => allProfiles(a.selection).find((x) => x.id === pid)?.name ?? pid),
      // Phase 4.2 fields only when the stage runs, so a deployment without applications keeps the Phase 4 manifest (and answer file).
      ...(apps ? { deviceProfiles: sel.deviceProfiles.map((pid) => allProfiles(a.selection).find((x) => x.id === pid)?.name ?? pid), devices: effectiveDevices(a.selection) } : {}),
      packages: sel.packages.map((x) => ({
        displayName: x.displayName,
        packageIdentifier: x.ref.packageIdentifier,
        source: x.ref.source,
        method: x.method,
        version: x.ref.version,
        scope: x.ref.scope,
        resolution: x.resolution,
        origins: x.origins,
        requiresAttention: x.resolution === 'unresolved' || x.resolution === 'manual' || x.interaction === 'required',
      })),
      removedFromProfiles: sel.removed.map((x) => x.key),
      additionalSoftware: p.additionalSoftware.items.map((i) => ({ name: i.name, execution: i.execution })),
    },
    // Phase 4.3: only when the policy is deferred, so other manifests keep their Phase 4 shape.
    ...(updatePolicyPlan(p) ? { updatePolicy: updatePolicyPlan(p) } : {}),
    restartPolicy: {
      windowsUpdate: { maxReboots: wu.maxReboots, rebootWarningSeconds: wu.rebootWarningSeconds },
      applications: { restartPolicy: a.restartPolicy, maxReboots: a.maxReboots, rebootWarningSeconds: a.rebootWarningSeconds },
    },
    failureHandling: {
      windowsUpdate: { maxAttemptsPerUpdate: wu.maxAttemptsPerUpdate, maxRuntimeHours: wu.maxRuntimeHours, networkWaitMinutes: wu.networkWaitMinutes, drivers: resolveDrivers(p) },
      applications: {
        maxAttemptsPerPackage: a.maxAttemptsPerPackage,
        packageTimeoutMinutes: a.packageTimeoutMinutes,
        maxRuntimeHours: a.maxRuntimeHours,
        waitForUpdatesHours: a.waitForUpdatesHours,
        networkWaitMinutes: a.networkWaitMinutes,
      },
      orchestrator: { ...ORCHESTRATOR_LIMITS, deadlineHours: deadlineHours(p) },
    },
    drivers: { implemented: false, preferences: { mode: 'notConfigured' }, note: 'Reserved for a later phase (vendor packages matched by hardware ID).' },
    customScripts: { managedBy: 'answer file', ...Object.fromEntries(PHASES.map((ph) => [ph.phase, p.scripts[ph.phase].filter(isEffective).length])) },
    paths: { package: PACKAGE_ROOT, state: DEPLOYMENT_STATE, status: DEPLOYMENT_STATUS, marker: DEPLOYMENT_MARKER, report: DEPLOYMENT_REPORT, monitorTask: `${MONITOR_TASK.path}${MONITOR_TASK.name}` },
    files: entries,
  };
  const runtime = { ...manifest, scope: 'answerFile' as const, files: entries.filter((e) => e.embedded) };
  return { manifest, json: asciiJson(manifest), runtimeJson: asciiJson(runtime), files };
}

export type DeploymentManifest = ReturnType<typeof buildManifest>['manifest'];

/**
 * Embeds the orchestrator and the manifest, and makes Initialize-Deployment.ps1 the last
 * FirstLogon command (it replaces the two engine installer commands of Phases 2 and 3).
 * Runs after the engine modifiers, which embed their own files.
 */
export function modify(ctx: GenContext): void {
  if (!deploymentActive(ctx.profile)) return;
  const { runtimeJson, files } = buildManifest(ctx.profile);
  let initialize = '';
  for (const f of files) {
    if (!f.embedded?.startsWith('Deployment\\')) continue;
    const path = ctx.embedFile(`${SETUP_SCRIPTS_DIR}\\${f.embedded}`, f.content);
    if (f.path === INITIALIZE_SCRIPT) initialize = path;
  }
  ctx.embedFile(`${DEPLOY_STAGING_DIR}\\${MANIFEST_FILE}`, runtimeJson);
  ctx.appendCommand('firstLogon', ctx.cmd.powerShellFile(initialize));
}

export interface DeploymentPackage {
  fileName: string;
  zip: Uint8Array;
  manifest: DeploymentManifest;
  entries: { path: string; size: number; role: FileRole | 'answer-file' | 'manifest'; description: string }[];
  warnings: string[];
}

/** The complete deployment ZIP: the answer file at the root plus the WindowsDeployment folder. */
export function buildDeploymentPackage(p: Profile, result: GenerateResult): DeploymentPackage {
  if (!result.ok || !result.xml) throw new Error('The deployment package needs a valid answer file.');
  const { manifest, json, files } = buildManifest(p);
  const zipEntries = [
    { path: result.fileName, data: utf8(result.xml), role: 'answer-file' as const, description: 'Windows Setup answer file (copy to the USB root); carries the whole deployment' },
    { path: `${PACKAGE_DIR}/${MANIFEST_FILE}`, data: utf8(json), role: 'manifest' as const, description: 'Stages, selections, limits and the SHA-256 of every file' },
    ...files.map((f) => ({ path: `${PACKAGE_DIR}/${f.path}`, data: encodeFile(f.path, f.content), role: f.role, description: f.description })),
  ];
  const warnings: string[] = [];
  if (hasSecrets(p)) warnings.push(`${result.fileName} contains the account or Wi-Fi password. Keep the ZIP and the USB drive private, and delete the file from the drive after installing. profiles/windows-settings.json does not contain passwords.`);
  if (p.output.answerFileName !== 'autounattend.xml') warnings.push(`The answer file is named ${p.output.answerFileName}, so Windows Setup will not find it automatically. Choose "autounattend.xml" under Output for a USB installation.`);
  if (!deploymentActive(p)) warnings.push('Windows Update automation is off and no applications are selected, so nothing runs after installation; the package contains the answer file and the tools only.');
  if (manifest.applications.packages.some((x) => x.requiresAttention)) warnings.push('Some selected applications are unresolved or need interaction; they are reported for follow-up and not installed automatically.');
  return {
    fileName: PACKAGE_FILE_NAME,
    zip: createZip(zipEntries.map((e) => ({ path: e.path, data: e.data }))),
    manifest,
    entries: zipEntries.map((e) => ({ path: e.path, size: e.data.length, role: e.role, description: e.description })),
    warnings,
  };
}

// ------------------------------------------------------------------------------------------------
// Static texts
// ------------------------------------------------------------------------------------------------

const SETUP_CMD = `@echo off
rem Windows Deployment Builder - manual entry point of this deployment package.
rem A USB installation does not need this file: autounattend.xml starts the deployment by itself.
rem Run as administrator. Options are passed to setup.ps1: -Verify, -Status, -Force.
setlocal
net session >nul 2>&1
if errorlevel 1 (
  echo Administrator rights are required. Right-click setup.cmd and choose "Run as administrator".
  pause
  exit /b 4
)
"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
set RC=%errorlevel%
pause
exit /b %RC%
`;

function stageLines(p: Profile): string {
  return [
    `  1. Windows Update        ${p.windowsUpdate.enabled ? 'on   (SYSTEM task; restarts and resumes by itself)' : 'off'}`,
    `  2. Applications (WinGet) ${applicationsActive(p) ? `on   (${resolveSelection(p.applications.selection).packages.length} package(s); as the signed-in user, after Windows Update)` : 'off'}`,
    ...(updatePolicyPlan(p)
      ? [`     Ongoing update policy, set once Windows Update has finished: ${p.updates.mode === 'notifyInstall' ? 'download automatically, notify before installing' : 'notify before downloading and installing'}`]
      : []),
    '  3. Manufacturer drivers  not implemented in this version (nothing is installed)',
    '  4. Report               C:\\ProgramData\\WindowsDeploymentBuilder\\reports\\deployment-report.txt',
  ].join('\n');
}

function readme(p: Profile): string {
  return `Windows Deployment Builder - deployment package ${DEPLOYMENT_VERSION}
==================================================

This ZIP turns an ordinary Windows 11 installation USB drive (made from official Microsoft media)
into an automated deployment. It does not contain Windows itself.

  ${p.output.answerFileName.padEnd(26)} Windows Setup answer file. It also carries every script below
                             (embedded), so the installed computer does not need the USB
                             drive after Windows Setup has finished.
  ${PACKAGE_DIR}\\           The same files, for verification, manual runs and recovery.
    setup.cmd                Manual entry point (run as administrator). Not needed for a USB
                             installation.
    deployment-manifest.json Stages, selections, limits and the SHA-256 of every file.
    scripts\\                 Orchestrator, Windows Update engine, application engine.
    profiles\\                This configuration (no passwords) and the application selection.
    config\\orchestration.json
    docs\\INSTALLATION.txt    Step-by-step USB preparation and installation.

Stages after installation:
${stageLines(p)}

Windows Setup still stops at the disk selection page. Nothing in this package partitions,
formats or selects a disk; you choose where Windows is installed.

Progress on the installed computer: "Deployment progress" on the desktop, or
  C:\\ProgramData\\WindowsDeploymentBuilder\\Deployment\\status.json

Status: generated and tested with simulations only. Validate in a virtual machine or on a spare
computer before relying on it.
`;
}

function installation(p: Profile): string {
  return `Installing Windows with this deployment package
================================================

You need: a USB drive (8 GB or more; it will be erased when you create the Windows media), the
official Windows 11 media, and this ZIP.

1. Create a normal Windows 11 installation USB drive
   - Media Creation Tool (Microsoft): choose "USB flash drive". Recommended.
   - Rufus with an official ISO: when Rufus offers "Customize Windows installation" options,
     turn ALL of them off. Rufus otherwise adds its own answer file, which conflicts with this one.
   - Copying an ISO's files to a USB drive by hand: the drive must be FAT32 for UEFI boot, and
     sources\\install.wim is often larger than 4 GB, so this usually needs the wim to be split
     (dism /Split-Image). Use one of the tools above instead.

2. Copy the package onto the USB drive
   Extract the ZIP to the ROOT of the USB drive (the drive itself, not a subfolder), so that you see:

     USB drive\\
       boot\\  efi\\  sources\\  setup.exe        (from Microsoft)
       ${p.output.answerFileName}                (from this ZIP)
       ${PACKAGE_DIR}\\                  (from this ZIP)

   In Windows' "Extract all" dialog, remove the folder name the dialog suggests and pick the
   drive letter of the USB drive. If ${p.output.answerFileName} ends up in a subfolder, Windows
   Setup will not find it.

3. Boot the target computer from the USB drive and let Setup start.
   Setup applies the answer file. It stops at "Where do you want to install Windows?":
   SELECT THE DISK YOURSELF. Check the size and name carefully; nothing chooses it for you, and
   other drives are never touched by this package.

4. Windows installs, restarts and signs in. At the first sign-in the deployment starts by itself:
${stageLines(p)}
   A "Deployment progress" window opens. You can close it; the deployment continues. The computer
   restarts by itself when updates or applications need it.

5. When it is finished, "Deployment report" appears on the desktop.

Internet: Windows Update and the applications need an Internet connection. Without one those
stages wait and retry within their limits, then end as Offline; installation itself works offline.

Recovery: see the report, or run (elevated)
  powershell.exe -ExecutionPolicy Bypass -File "C:\\ProgramData\\WindowsDeploymentBuilder\\Package\\scripts\\orchestrator\\Resume-Deployment.ps1"
  ... -Status                 shows progress
  ... -RestartStage <stage>   starts windowsUpdate or applications again

Remove the USB drive, or at least ${p.output.answerFileName}, after installing: another computer
booted from it would be installed with the same settings, and the file may contain passwords.
`;
}
