import engineSource from './scripts/ApplicationEngine.ps1?raw';
import bootstrapSource from './scripts/WinGetBootstrap.ps1?raw';
import installerSource from './scripts/Install-ApplicationEngine.ps1?raw';
import migrationSource from '../migration/scripts/WdbMigration.ps1?raw';
import type { Profile } from '../schema/profile';
import type { AdditionalItem } from '../schema/applications';
import { DATA_ROOT, RESULT_FILE as WU_RESULT_FILE, TASK_NAME as WU_TASK_NAME, TASK_PATH, type DeploymentAsset } from '../windows-update';
import { allProfiles, installable, manualItems, resolveSelection, type PlannedPackage, type SelectionResult } from './selection';
import { exportWinGetJson } from './winget-json';
import { exportAppProfiles } from './profiles';
import { verifySpec, type VerifySpec } from './catalog';
import { RESULTS_JSON_SCHEMA } from './results';
import { migrationConfig, restorePlanText, settingsRestoreActive, settingsRestoreConfig, migrationActive } from '../migration/plan';
import { DRIVER_STAGE } from '../drivers/contract';

/**
 * Phase 3 application provisioning: engine configuration, the exact WinGet commands, the plan
 * preview and the downloadable deployment assets. The PowerShell sources are static files (tested
 * directly by tests/powershell); everything a profile can change goes into the config and the
 * native WinGet package list, which the engine reads at run time.
 */

export const APP_ENGINE_VERSION = '1.6.0';
export const APP_STAGING_DIR = 'C:\\Windows\\Setup\\Scripts\\Applications';
export const APP_ROOT = `${DATA_ROOT}\\Applications`;
export const APP_TASK_NAME = 'Applications';
export const APP_RESULT_FILE = `${APP_ROOT}\\result.json`;
export const APP_MARKER = `${DATA_ROOT}\\state\\applications.done`;

export const APP_ENGINE_FILE = 'ApplicationEngine.ps1';
export const APP_BOOTSTRAP_FILE = 'WinGetBootstrap.ps1';
export const APP_INSTALLER_FILE = 'Install-ApplicationEngine.ps1';
export const APP_CONFIG_FILE = 'applications-config.json';
export const APP_PACKAGES_FILE = 'winget-packages.json';
export const APP_PROFILE_FILE = 'application-profile.json';
export const APP_PLAN_FILE = 'applications-plan.txt';
export const APP_RESULTS_SCHEMA_FILE = 'applications-results.schema.json';
export const ORCHESTRATION_FILE = 'orchestration.json';
export const APP_README_FILE = 'README-Applications.txt';
/** Phase 6: the settings restore library (also the stand-alone inventory and backup tool) and the plan. */
export const MIGRATION_SCRIPT_FILE = 'WdbMigration.ps1';
export const RESTORE_PLAN_FILE = 'restore-plan.txt';
export const RESTORATION_FILE = `${APP_ROOT}\\restoration.json`;

/**
 * Phase 5 retry timing (engine 1.2.0). Fixed, reviewed values rather than settings: the first retry
 * waits a minute, each further one twice as long (plus or minus 20 %), never more than 15 minutes; a
 * package whose source is unreachable is deferred at most six times. The engine clamps every value.
 */
export const RETRY_TIMING = { baseDelaySeconds: 60, maxDelaySeconds: 900, jitterRatio: 0.2, maxNetworkDeferrals: 6 } as const;

/** Numeric limits, shared by validation and the UI. */
export const APP_LIMITS = {
  maxReboots: [0, 10],
  maxAttemptsPerPackage: [1, 5],
  packageTimeoutMinutes: [5, 180],
  networkWaitMinutes: [1, 60],
  maxRuntimeHours: [1, 24],
  waitForUpdatesHours: [1, 48],
  rebootWarningSeconds: [0, 600],
} as const satisfies Record<string, readonly [number, number]>;

/** Arguments exactly as ApplicationEngine.ps1 (Get-WdaArguments) builds them. */
export function wingetArguments(verb: 'install' | 'list' | 'show', p: { packageIdentifier: string; source: string; version?: string; scope?: string }): string[] {
  const a = [verb, '--id', p.packageIdentifier, '--exact', '--source', p.source];
  if (verb === 'install') {
    if (p.version) a.push('--version', p.version);
    if (p.scope) a.push('--scope', p.scope);
    a.push('--silent', '--no-upgrade', '--accept-package-agreements');
  }
  a.push('--accept-source-agreements', '--disable-interactivity');
  return a;
}

/**
 * Splits an installer argument string into tokens (double quotes group, and are removed). Returns
 * the tokens and any characters that are refused (shell and PowerShell metacharacters).
 */
export function splitArgs(text: string): { tokens: string[]; refused: string[] } {
  const refused = [...new Set([...text].filter((c) => /[;|&<>`$'\r\n\0]/.test(c)))];
  // Whitespace separates tokens except inside double quotes; the quotes themselves are removed
  // (so /D="C:\Program Files\X" becomes one token /D=C:\Program Files\X).
  const tokens: string[] = [];
  let cur = '';
  let quoted = false;
  let started = false;
  for (const c of text) {
    if (c === '"') {
      quoted = !quoted;
      started = true;
    } else if (/\s/.test(c) && !quoted) {
      if (started) tokens.push(cur);
      cur = '';
      started = false;
    } else {
      cur += c;
      started = true;
    }
  }
  if (started) tokens.push(cur);
  return { tokens: tokens.filter((t) => t !== ''), refused: refused.map((c) => (c === '\r' || c === '\n' ? 'line break' : c === '\0' ? 'NUL' : c)) };
}

/**
 * Installers reviewed for automatic execution (official URL, publisher signature, documented
 * silent switches). Empty in this release: every Additional Software entry is a manual follow-up
 * until an entry is reviewed and added here. Matching is by name, SHA-256 and arguments.
 */
export const REVIEWED_INSTALLERS: readonly { name: string; sha256: string; installerType: AdditionalItem['installerType']; silentArgs: string }[] = [];

export function isReviewed(item: AdditionalItem, reviewed = REVIEWED_INSTALLERS): boolean {
  return reviewed.some((r) => r.name === item.name && r.sha256.toUpperCase() === item.sha256.toUpperCase() && r.installerType === item.installerType && r.silentArgs === item.silentArgs);
}

/** True when the application stage has anything to do (otherwise nothing is generated for it). */
export function applicationsActive(p: Profile): boolean {
  if (!p.applications.enabled) return false;
  return resolveSelection(p.applications.selection).packages.length > 0 || p.additionalSoftware.items.length > 0 || settingsRestoreActive(p);
}

export interface ApplicationsConfig {
  schemaVersion: 1;
  engineVersion: string;
  dataRoot: string;
  taskPath: string;
  taskName: string;
  packagesFile: string;
  coordination: {
    policy: Profile['applications']['coordination'];
    windowsUpdate: { enabled: boolean; stateFile: string; resultFile: string; taskPath: string; taskName: string };
    /** Phase 8: present only when the deployment has the driver stage; applications start after it. */
    drivers?: { enabled: boolean; stateFile: string; resultFile: string; taskPath: string; taskName: string };
  };
  restartPolicy: Profile['applications']['restartPolicy'];
  registerAppInstaller: boolean;
  onlineRepair: boolean;
  minimumWinGetVersion: string;
  maxReboots: number;
  maxAttemptsPerPackage: number;
  packageTimeoutMinutes: number;
  networkWaitMinutes: number;
  maxRuntimeHours: number;
  waitForUpdatesHours: number;
  lockWaitMinutes: number;
  rebootWarningSeconds: number;
  /** Engine 1.2.0 (Phase 5); configurations without it get the same values from the engine. */
  retry: { automatic: boolean; continueAfterFailure: boolean; baseDelaySeconds: number; maxDelaySeconds: number; jitterRatio: number; maxNetworkDeferrals: number };
  packages: {
    key: string;
    packageIdentifier: string;
    source: string;
    displayName: string;
    version: string;
    scope: string;
    interaction: string;
    after: string[];
    /** Engine 1.1.0: winget | msstore | portable (portable = winget package + Start menu shortcut). */
    method: 'winget' | 'msstore' | 'portable';
    portable?: { executable: string; shortcut: string };
    /** Engine 1.6.0: installation evidence from the catalog (verifySpec); empty = WinGet's own record only. */
    verify: VerifySpec;
  }[];
  /** removed: an app removed from the automated catalog (reported as Skipped, not a failure). */
  unresolved: { key: string; packageIdentifier: string; source: string; displayName: string; reason: string; removed?: true }[];
  /** Engine 1.1.0: catalog entries without an unattended installation, reported as manual follow-ups. */
  manual: { key: string; displayName: string; instructions: string; url: string }[];
  /** Engine 1.1.0: apps a profile selects but the customer deselected, reported as SkippedByUser. */
  deselected: { key: string; packageIdentifier: string; source: string; displayName: string }[];
  /** Engine 1.3.0 (Phase 6): settings restored after their applications, from one pinned backup. */
  settingsRestore?: ReturnType<typeof settingsRestoreConfig>;
  /** Engine 1.3.0 (Phase 6): the migration review, reported per application in restoration.json. */
  migration?: ReturnType<typeof migrationConfig>;
  additionalSoftware: {
    id: string;
    name: string;
    publisher: string;
    downloadUrl: string;
    installerType: string;
    fileName: string;
    sha256: string;
    silentArgs: string[];
    interaction: string;
    execution: 'manual' | 'automatic';
    prerequisites: string;
    license: string;
  }[];
}

export function applicationsConfig(p: Profile, sel: SelectionResult = resolveSelection(p.applications.selection)): ApplicationsConfig {
  const a = p.applications;
  return {
    schemaVersion: 1,
    engineVersion: APP_ENGINE_VERSION,
    dataRoot: DATA_ROOT,
    taskPath: TASK_PATH,
    taskName: APP_TASK_NAME,
    packagesFile: APP_PACKAGES_FILE,
    coordination: {
      policy: a.coordination,
      windowsUpdate: { enabled: p.windowsUpdate.enabled, stateFile: `${DATA_ROOT}\\Updates\\state.json`, resultFile: WU_RESULT_FILE, taskPath: TASK_PATH, taskName: WU_TASK_NAME },
      ...(p.drivers.enabled ? { drivers: { enabled: true, stateFile: DRIVER_STAGE.stateFile, resultFile: DRIVER_STAGE.resultFile, taskPath: TASK_PATH, taskName: 'Drivers' } } : {}),
    },
    restartPolicy: a.restartPolicy,
    registerAppInstaller: a.registerAppInstaller,
    onlineRepair: a.onlineRepair,
    minimumWinGetVersion: '1.6.0',
    maxReboots: a.maxReboots,
    maxAttemptsPerPackage: a.maxAttemptsPerPackage,
    packageTimeoutMinutes: a.packageTimeoutMinutes,
    networkWaitMinutes: a.networkWaitMinutes,
    maxRuntimeHours: a.maxRuntimeHours,
    waitForUpdatesHours: a.waitForUpdatesHours,
    lockWaitMinutes: 60,
    rebootWarningSeconds: a.rebootWarningSeconds,
    retry: { automatic: a.recovery.automaticRetry, continueAfterFailure: a.recovery.continueAfterFailure, ...RETRY_TIMING },
    packages: installable(sel).map((x) => ({
      key: x.key,
      packageIdentifier: x.ref.packageIdentifier,
      source: x.ref.source.toLowerCase(),
      displayName: x.displayName,
      version: x.ref.version,
      scope: x.ref.scope,
      interaction: x.interaction,
      after: x.after,
      method: x.method === 'portable' ? ('portable' as const) : x.ref.source.toLowerCase() === 'msstore' ? ('msstore' as const) : ('winget' as const),
      ...(x.method === 'portable' && x.catalog?.portable ? { portable: { ...x.catalog.portable } } : {}),
      verify: verifySpec(x.catalog),
    })),
    unresolved: sel.packages
      .filter((x) => x.resolution === 'unresolved')
      .map((x) => ({ key: x.key, packageIdentifier: x.ref.packageIdentifier, source: x.ref.source, displayName: x.displayName, reason: x.reason ?? '', ...(x.excludedFromCatalog?.removed ? { removed: true as const } : {}) })),
    manual: manualItems(sel).map((x) => ({ key: x.key, displayName: x.displayName, instructions: x.catalog?.manual?.instructions ?? 'Install it manually.', url: x.catalog?.manual?.url ?? '' })),
    deselected: sel.removed
      .filter((x) => x.resolution !== 'unresolved')
      .map((x) => ({ key: x.key, packageIdentifier: x.ref.packageIdentifier, source: x.ref.source.toLowerCase(), displayName: x.displayName })),
    additionalSoftware: p.additionalSoftware.items.map((i) => ({
      id: i.id,
      name: i.name || i.fileName || 'Unnamed installer',
      publisher: i.publisher,
      downloadUrl: i.downloadUrl,
      installerType: i.installerType,
      fileName: i.fileName,
      sha256: i.sha256.toUpperCase(),
      silentArgs: splitArgs(i.silentArgs).tokens,
      interaction: i.interaction,
      execution: i.execution === 'automatic' && isReviewed(i) ? 'automatic' : 'manual',
      prerequisites: i.prerequisites,
      license: i.license,
    })),
    // Phase 6 blocks only when the deployment migrates, so other configurations are unchanged.
    ...(settingsRestoreActive(p) ? { settingsRestore: settingsRestoreConfig(p) } : {}),
    ...(migrationActive(p) && migrationConfig(p) ? { migration: migrationConfig(p) } : {}),
  };
}

const crlf = (s: string): string => s.replace(/\r?\n/g, '\r\n');

function note(x: PlannedPackage): string {
  const n: string[] = [];
  if (x.resolution === 'unverified') n.push('identifier not verified in the catalog; availability is checked on the device');
  if (x.interaction === 'required') n.push('needs interaction: recorded as RequiresInteraction, not attempted');
  if (x.interaction === 'mayPrompt') n.push('installer may prompt');
  if (x.accountSignIn) n.push('needs an account sign-in after installation');
  if (x.reboot === 'mayRequire') n.push('may need a restart');
  if (x.after.length) n.push(`after ${x.after.join(', ')}`);
  if (x.method === 'portable' && x.catalog?.portable) n.push(`portable: machine-wide, Start menu shortcut "${x.catalog.portable.shortcut}" (${x.catalog.portable.executable})`);
  if (x.ref.source.toLowerCase() === 'msstore') n.push('Microsoft Store package');
  if (x.origins.includes('required')) n.push('added as a dependency');
  return n.join('; ');
}

/** Human-readable dry run of what the engine will do, with the exact commands. */
export function planPreview(p: Profile, sel: SelectionResult = resolveSelection(p.applications.selection)): string {
  const a = p.applications;
  const lines: string[] = [
    'Windows Deployment Builder - application installation plan (preview)',
    '=====================================================================',
    'Nothing has been installed. This is what ApplicationEngine.ps1 will do, in this order.',
    '',
    `Runs as:       the signed-in user, elevated (scheduled task ${TASK_PATH}${APP_TASK_NAME})`,
    `Coordination:  ${a.coordination === 'updatesFirst' ? 'updates first' : a.coordination}${p.windowsUpdate.enabled ? ' - waits for the Windows Update stage to finish' : ' - Windows Update automation is off, so it does not wait'}`,
    `WinGet:        checked first; ${a.registerAppInstaller ? 'App Installer registration is attempted if needed' : 'no registration'}${a.onlineRepair ? ', then online repair (Microsoft.WinGet.Client)' : ''}`,
    `Restarts:      ${a.restartPolicy === 'whenRequired' ? `when a package requires one (at most ${a.maxReboots})` : 'never (packages that need one are reported RequiresRestart)'}`,
    `Attempts:      ${a.recovery.automaticRetry ? `up to ${a.maxAttemptsPerPackage} per package for temporary failures (waits ${RETRY_TIMING.baseDelaySeconds} s, then doubling, at most ${RETRY_TIMING.maxDelaySeconds / 60} min)` : '1 per package (automatic retry off; use the recovery tool)'}, ${a.packageTimeoutMinutes} min timeout each, ${a.maxRuntimeHours} h in total`,
    `Failures:      permanent ones (hash, policy, not found, cancelled) are never retried automatically; ${a.recovery.continueAfterFailure ? 'other applications continue after a failure' : 'the queue stops after the first failure'}`,
    '',
    'For every package: "winget list" first (already installed = left unchanged), then:',
    '',
  ];
  const queue = installable(sel);
  if (queue.length === 0) lines.push('  (no WinGet packages selected)');
  queue.forEach((x, i) => {
    lines.push(`${String(i + 1).padStart(3)}. ${x.displayName}  [${x.ref.source}: ${x.ref.packageIdentifier}]`);
    const n = note(x);
    if (n) lines.push(`     ${n}`);
    if (x.interaction !== 'required') lines.push(`     winget ${wingetArguments('install', x.ref).join(' ')}`);
  });
  const unresolved = sel.packages.filter((x) => x.resolution === 'unresolved' && !x.excludedFromCatalog?.removed);
  if (unresolved.length) {
    lines.push('', 'Not installed (unresolved; reported as Unavailable):');
    for (const x of unresolved) lines.push(`  - ${x.displayName} [${x.ref.source}: ${x.ref.packageIdentifier}]: ${x.reason}`);
  }
  const removed = sel.packages.filter((x) => x.resolution === 'unresolved' && x.excludedFromCatalog?.removed);
  if (removed.length) {
    lines.push('', 'Not installed (removed from the automated catalog; reported as Skipped):');
    for (const x of removed) lines.push(`  - ${x.displayName} [${x.ref.source}: ${x.ref.packageIdentifier}]: ${x.reason}`);
  }
  const manual = manualItems(sel);
  if (manual.length) {
    lines.push('', 'Manual follow-up (no unattended installation; reported as RequiresInteraction):');
    for (const x of manual) lines.push(`  - ${x.displayName}: ${x.catalog?.manual?.instructions ?? ''}${x.catalog?.manual?.url ? ` ${x.catalog.manual.url}` : ''}`);
  }
  if (sel.removed.length) {
    lines.push('', 'Deselected (not installed; reported as SkippedByUser):');
    for (const x of sel.removed) lines.push(`  - ${x.displayName} [${x.ref.source}: ${x.ref.packageIdentifier}]`);
  }
  const items = applicationsConfig(p, sel).additionalSoftware;
  lines.push('', 'Additional Software (after WinGet):');
  if (items.length === 0) lines.push('  (none)');
  for (const i of items) {
    lines.push(`  - ${i.name}: ${i.execution === 'automatic' ? `reviewed installer ${i.fileName}, SHA-256 and signature checked, then run with: ${i.silentArgs.join(' ')}` : `manual follow-up${i.downloadUrl ? ` (${i.downloadUrl})` : ''}`}`);
  }
  lines.push('', `Results: ${APP_RESULT_FILE}`, `Marker:  ${APP_MARKER} (Succeeded, CompletedWithFollowUp, CompletedWithFailures)`);
  return lines.join('\n') + '\n';
}

function readme(): string {
  return `Windows Deployment Builder - application engine ${APP_ENGINE_VERSION}
=========================================================

Generated by Windows Deployment Builder. When application provisioning is enabled and
applications are selected, the engine files are embedded in autounattend.xml and installed
automatically at the end of FirstLogon. Download them separately to inspect them, or to run the
engine by hand on a machine that is already installed.

Files
  ${APP_ENGINE_FILE}           The engine. Runs as the signed-in user, elevated.
  ${APP_BOOTSTRAP_FILE}            Checks WinGet and repairs it with documented Microsoft steps.
  ${APP_INSTALLER_FILE}  Secures ${DATA_ROOT}, copies the files, registers the
                                 task ${TASK_PATH}${APP_TASK_NAME} for the current user and starts it.
  ${APP_CONFIG_FILE}       Order, metadata, policy and limits.
  ${APP_PACKAGES_FILE}           The package list in Microsoft's format. It also works on its own:
                                   winget import -i ${APP_PACKAGES_FILE} --accept-package-agreements --accept-source-agreements
  ${APP_PROFILE_FILE}       The selection in this builder's profile format (re-importable).
  ${APP_PLAN_FILE}           Preview: the exact commands, in order.
  ${APP_RESULTS_SCHEMA_FILE}  JSON Schema of result.json.
  ${ORCHESTRATION_FILE}              Stages, order, locks and result files (for the orchestrator).

Manual use (elevated Windows PowerShell 5.1, signed in as the target user, all files in one folder)
  powershell.exe -ExecutionPolicy Bypass -File .\\${APP_BOOTSTRAP_FILE} -Mode Check
  powershell.exe -ExecutionPolicy Bypass -File .\\${APP_ENGINE_FILE} -Mode Plan
      (read-only: WinGet state, installed/available per package and the exact command)
  powershell.exe -ExecutionPolicy Bypass -File ${APP_ROOT}\\${APP_ENGINE_FILE} -Mode Verify
      (engine 1.6.0: re-verifies every package from installation evidence, installs nothing;
       exit 0 verified, 10 pending, 20 failed or not installed, 1 engine running)
  powershell.exe -ExecutionPolicy Bypass -File .\\${APP_INSTALLER_FILE}
  powershell.exe -ExecutionPolicy Bypass -File .\\${APP_INSTALLER_FILE} -Uninstall

Offline WinGet
  If App Installer cannot be registered, the bootstrap installs a Microsoft-signed
  *DesktopAppInstaller*.msixbundle (and its .appx/.msix dependencies) from an "offline" folder next
  to these files. Files without a valid Microsoft signature are ignored.

What happens
  WinGet is checked (never reinstalled when it works). While Windows Update is still running the
  engine only prepares (network, WinGet check, package availability). Installation starts after
  the Windows Update stage is final. Each package is checked with "winget list" first and
  installed with an explicit --id, --exact and --source, silently, while holding the shared
  install lock, so Windows Update cannot restart the computer in the middle. Temporary failures
  are retried up to the attempt limit with a growing wait (engine 1.2.0); permanent ones (hash
  mismatch, policy, not found, cancelled) are not. If the network or a package source is lost, the
  package waits for it instead of failing. Packages that need a restart get one (policy) and are
  verified after it. Packages marked as needing interaction are not attempted. Every attempt is
  recorded in logs\\attempts.jsonl; failed ones can be retried later with the deployment recovery
  tool without repeating anything that succeeded.
  Portable tools (for example Rufus, Ventoy) are WinGet portable packages: WinGet downloads them
  from the publisher URL in the manifest, checks the SHA-256 and installs them machine-wide under
  %ProgramFiles%\\WinGet\\Packages; the engine then adds a Start menu shortcut under "Windows
  Deployment Tools". Nothing ever runs them. Apps without an unattended installation are listed
  as manual follow-ups with official download instructions; deselected apps are recorded as
  SkippedByUser.

Results
  Log:      ${APP_ROOT}\\logs\\engine.log  (WinGet output: logs\\packages\\*.log)
  Status:   ${APP_ROOT}\\status.json
  Result:   ${APP_RESULT_FILE}
            status = Succeeded | CompletedWithFollowUp | CompletedWithFailures | Failed | Offline
  Follow-up: ${APP_ROOT}\\follow-up.txt
  Marker:   ${APP_MARKER}
  Events:   Application log, source "WindowsDeploymentBuilder", IDs 2000 started, 2001 restart,
            2100 Succeeded, 2101 CompletedWithFailures, 2102 Failed, 2103 Offline,
            2104 CompletedWithFollowUp

Status: not yet validated on a Windows installation in a VM. Test before relying on it.
`;
}

/** Downloadable deployment assets; empty when the application stage has nothing to do. */
export function applicationAssets(p: Profile): DeploymentAsset[] {
  if (!applicationsActive(p)) return [];
  const sel = resolveSelection(p.applications.selection);
  const refs = sel.packages.map((x) => x.ref);
  const effective = {
    id: 'deployment-selection',
    name: p.profileName ? `${p.profileName}: application selection` : 'Application selection',
    category: 'custom' as const,
    description: `Effective, flattened selection of this deployment (${sel.activeProfiles.map((id) => allProfiles(p.applications.selection).find((x) => x.id === id)?.name ?? id).join(', ') || 'no profiles'} + individual changes): exactly the applications in the installation plan.`.slice(0, 500),
    builtin: false,
    inherits: [],
    packages: refs,
  };
  const json = (v: unknown) => crlf(JSON.stringify(v, null, 2) + '\n');
  // Non-ASCII escaped (\uXXXX): Windows PowerShell 5.1 reads the config in the ANSI code page, which
  // matches the answer-file extraction but not the UTF-8 copy in the ZIP; escaped JSON reads the same
  // either way. ASCII-only content is unchanged.
  const asciiJson = (v: unknown) => json(v).replace(/[\u007f-￿]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`);
  return [
    { name: APP_ENGINE_FILE, content: crlf(engineSource), mime: 'text/plain', description: 'Application engine (runs as the signed-in user, elevated)', group: 'applications' },
    { name: APP_BOOTSTRAP_FILE, content: crlf(bootstrapSource), mime: 'text/plain', description: 'WinGet check and documented repair (-Mode Check is read-only)', group: 'applications' },
    { name: APP_INSTALLER_FILE, content: crlf(installerSource), mime: 'text/plain', description: 'Installs the engine, registers the per-user task and confirms it starts', group: 'applications' },
    { name: APP_CONFIG_FILE, content: asciiJson(applicationsConfig(p, sel)), mime: 'application/json', description: 'Order, metadata, policy and limits', group: 'applications' },
    { name: APP_PACKAGES_FILE, content: crlf(exportWinGetJson(refs, null)), mime: 'application/json', description: 'Native WinGet package list (works with winget import)', group: 'applications' },
    { name: APP_PROFILE_FILE, content: crlf(exportAppProfiles([effective], null)), mime: 'application/json', description: "The selection in this builder's profile format", group: 'applications' },
    { name: APP_PLAN_FILE, content: crlf(planPreview(p, sel)), mime: 'text/plain', description: 'Installation plan preview with the exact commands', group: 'applications' },
    { name: APP_RESULTS_SCHEMA_FILE, content: json(RESULTS_JSON_SCHEMA), mime: 'application/json', description: 'JSON Schema of result.json', group: 'applications' },
    { name: APP_README_FILE, content: crlf(readme()), mime: 'text/plain', description: 'How to use the files and read the results', group: 'applications' },
    ...(settingsRestoreActive(p)
      ? [{ name: MIGRATION_SCRIPT_FILE, content: crlf(migrationSource), mime: 'text/plain', description: 'Settings restore library (validates the pinned backup, restores supported settings)', group: 'applications' as const }]
      : []),
    ...(migrationActive(p) ? [{ name: RESTORE_PLAN_FILE, content: crlf(restorePlanText(p)), mime: 'text/plain', description: 'Application restoration plan: what is reinstalled, restored, manual or excluded', group: 'applications' as const }] : []),
  ];
}

/** Files embedded in the answer file (extracted to APP_STAGING_DIR during specialize). */
export const EMBEDDED_APP_FILES = [APP_ENGINE_FILE, APP_BOOTSTRAP_FILE, APP_INSTALLER_FILE, APP_CONFIG_FILE, APP_PACKAGES_FILE] as const;

/** Embedded files of this profile: Phase 6 adds the restore library when settings are restored. */
export function embeddedAppFiles(p: Profile): string[] {
  return [...EMBEDDED_APP_FILES, ...(settingsRestoreActive(p) ? [MIGRATION_SCRIPT_FILE] : [])];
}

/** The stand-alone collector for the source computer (Review & download, Application Backup & Restore). */
export function collectorAsset(): DeploymentAsset {
  return { name: MIGRATION_SCRIPT_FILE, content: crlf(migrationSource), mime: 'text/plain', description: 'Inventory, settings backup and restore tool for the existing computer (read-only inventory)', group: 'applications' };
}
