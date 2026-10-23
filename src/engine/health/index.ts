import engineSource from './scripts/DeploymentHealth.ps1?raw';
import templateSource from './scripts/HealthReport.html?raw';
import type { Profile } from '../schema/profile';
import { lookup } from '../../data';
import { resolveIdentity } from '../naming';
import { DATA_ROOT, resolveDrivers, ongoingPolicyDeferred } from '../windows-update';
import { applicationsActive, applicationsConfig } from '../applications';
import { resolveSelection } from '../applications/selection';
import { settingsRestoreActive } from '../migration/plan';
import { adapterById } from '../migration/adapters';
import { driversActive } from '../drivers';
import { HEALTH_CATEGORIES, HEALTH_REPORT_JSON_SCHEMA } from './contract';

export * from './contract';

/**
 * Phase 9: the deployment verification plan. The website cannot see the target computer, so it
 * only writes down what the deployment is expected to achieve (health-config.json); the health
 * engine (DeploymentHealth.ps1) checks each expectation against the installed Windows itself and
 * reads the engines' own results as evidence, never as proof.
 */

export const HEALTH_ENGINE_VERSION = '1.0.0';
export const HEALTH_DIR = 'scripts/health';
export const HEALTH_ENGINE_FILE = 'DeploymentHealth.ps1';
export const HEALTH_CONFIG_FILE = 'health-config.json';
export const HEALTH_TEMPLATE_FILE = 'HealthReport.html';
export const HEALTH_SCHEMA_FILE = 'deployment-health.schema.json';
export const HEALTH_README_FILE = 'README-Health.txt';
export const HEALTH_REPORT_DIR = `${DATA_ROOT}\\reports\\health`;
export const HEALTH_REPORT_FILE = `${HEALTH_REPORT_DIR}\\deployment-health.json`;
export const HEALTH_TECHNICIAN_HTML = `${HEALTH_REPORT_DIR}\\technician-report.html`;
export const HEALTH_CUSTOMER_HTML = `${HEALTH_REPORT_DIR}\\customer-handoff.html`;
export const HEALTH_TOOL = `${DATA_ROOT}\\Package\\scripts\\health\\${HEALTH_ENGINE_FILE}`;
/** The desktop entry point (an em dash, as Windows shows it). */
export const HEALTH_SHORTCUT = 'Windows Deployment \u2014 Health Report';
/** Files embedded in the answer file, so verification never needs the USB drive. */
export const EMBEDDED_HEALTH_FILES: readonly string[] = [HEALTH_ENGINE_FILE, HEALTH_CONFIG_FILE, HEALTH_TEMPLATE_FILE];
/** Exit codes of DeploymentHealth.ps1 -Mode Verify (one per overall state). */
export const HEALTH_EXIT_CODES = { Ready: 0, ReadyWithWarnings: 10, NeedsAttention: 20, Incomplete: 30, Unverifiable: 50, Failed: 60 } as const;

/** True when the package carries the health engine and verifies itself at the end (something must run after installation). */
export const healthActive = (p: Profile): boolean => p.health.enabled && (p.windowsUpdate.enabled || applicationsActive(p) || driversActive(p));

/** Setup's edition id → the EditionID Windows records (HKLM\…\CurrentVersion\EditionID). */
export const EDITION_IDS: Record<string, string> = {
  home: 'Core',
  home_n: 'CoreN',
  home_single: 'CoreSingleLanguage',
  education: 'Education',
  education_n: 'EducationN',
  pro: 'Professional',
  pro_n: 'ProfessionalN',
  pro_education: 'ProfessionalEducation',
  pro_education_n: 'ProfessionalEducationN',
  pro_workstations: 'ProfessionalWorkstation',
  pro_workstations_n: 'ProfessionalWorkstationN',
  enterprise: 'Enterprise',
  enterprise_n: 'EnterpriseN',
};

/** UAC values each level of the Security section writes (null: Windows' own default, not checked). */
const UAC_EXPECTED: Record<Profile['security']['uacLevel'], { enableLua: number; consentPromptBehaviorAdmin: number | null; promptOnSecureDesktop: number | null }> = {
  alwaysNotify: { enableLua: 1, consentPromptBehaviorAdmin: 2, promptOnSecureDesktop: 1 },
  windowsDefault: { enableLua: 1, consentPromptBehaviorAdmin: null, promptOnSecureDesktop: null },
  noDim: { enableLua: 1, consentPromptBehaviorAdmin: 5, promptOnSecureDesktop: 0 },
  neverNotify: { enableLua: 1, consentPromptBehaviorAdmin: 0, promptOnSecureDesktop: 0 },
  disabled: { enableLua: 0, consentPromptBehaviorAdmin: null, promptOnSecureDesktop: null },
};

/**
 * Verification adapters for settings earlier phases already apply (Phase 8.5 customizations will
 * register theirs the same way). Only settings this repository implements are listed, each with
 * the exact value its feature module writes.
 */
export interface CustomizationAdapter {
  id: string;
  label: string;
  scope: 'machine' | 'user';
  windows: string;
  method: 'registry';
  registry: { path: string; name: string; expected: number };
  /** When the value takes effect: it is checked as written, which may precede the effect. */
  effect: 'immediate' | 'signIn' | 'restart';
  reversible: string;
}

const ADV = 'Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced';

export function customizationAdapters(p: Profile): CustomizationAdapter[] {
  const out: CustomizationAdapter[] = [];
  if (p.explorer.showFileExtensions) out.push({ id: 'explorer.showFileExtensions', label: 'File name extensions are shown', scope: 'user', windows: 'Windows 10/11', method: 'registry', registry: { path: ADV, name: 'HideFileExt', expected: 0 }, effect: 'signIn', reversible: 'File Explorer › View › Show › File name extensions' });
  if (p.explorer.launchToThisPC) out.push({ id: 'explorer.launchToThisPC', label: 'File Explorer opens to This PC', scope: 'user', windows: 'Windows 10/11', method: 'registry', registry: { path: ADV, name: 'LaunchTo', expected: 1 }, effect: 'immediate', reversible: 'File Explorer › Options › Open File Explorer to' });
  if (p.taskbar.leftAlign) out.push({ id: 'taskbar.leftAlign', label: 'Taskbar aligned to the left', scope: 'user', windows: 'Windows 11', method: 'registry', registry: { path: ADV, name: 'TaskbarAl', expected: 0 }, effect: 'signIn', reversible: 'Settings › Personalization › Taskbar › Taskbar behaviors' });
  if (p.system.enableLongPaths) out.push({ id: 'system.enableLongPaths', label: 'Long paths enabled', scope: 'machine', windows: 'Windows 10 1607+ / 11', method: 'registry', registry: { path: 'SYSTEM\\CurrentControlSet\\Control\\FileSystem', name: 'LongPathsEnabled', expected: 1 }, effect: 'restart', reversible: 'Set LongPathsEnabled to 0' });
  if (p.system.disableFastStartup) out.push({ id: 'system.disableFastStartup', label: 'Fast Startup off', scope: 'machine', windows: 'Windows 10/11', method: 'registry', registry: { path: 'SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Power', name: 'HiberbootEnabled', expected: 0 }, effect: 'restart', reversible: 'Control Panel › Power Options › Choose what the power buttons do' });
  return out;
}

/** The health engine's configuration: what this deployment must have achieved. */
export function healthConfig(p: Profile) {
  const sel = resolveSelection(p.applications.selection);
  const apps = applicationsActive(p);
  const cfg = apps ? applicationsConfig(p, sel) : null;
  const id = resolveIdentity(p.accounts);
  const optional = new Set(p.health.optionalApps);
  const scopeOf = new Map(sel.packages.map((x) => [x.key, x.catalog?.scope ?? (x.ref.scope || 'unknown')]));
  const catalogName = new Map(sel.packages.map((x) => [x.key, x.catalog?.displayName ?? '']));
  const signIn = new Set(sel.packages.filter((x) => x.accountSignIn).map((x) => x.key));
  const items = cfg
    ? [
        ...cfg.packages.map((x) => ({
          key: x.key,
          operationId: `app:${x.key}`,
          name: x.displayName,
          names: [...new Set([x.displayName, catalogName.get(x.key) ?? ''].filter(Boolean))],
          source: x.source,
          packageIdentifier: x.packageIdentifier,
          method: x.method,
          kind: 'automatic' as const,
          required: !optional.has(x.key),
          scope: scopeOf.get(x.key) ?? 'unknown',
          version: x.version,
          shortcut: x.portable?.shortcut ?? '',
          signIn: signIn.has(x.key),
          instructions: '',
          url: '',
        })),
        ...cfg.manual.map((x) => ({ key: x.key, operationId: `app:${x.key}`, name: x.displayName, names: [x.displayName], source: 'catalog', packageIdentifier: '', method: 'manual', kind: 'manual' as const, required: false, scope: 'unknown', version: '', shortcut: '', signIn: signIn.has(x.key), instructions: x.instructions, url: x.url })),
        ...cfg.additionalSoftware.map((x) => ({
          key: `additional:${x.id.toLowerCase()}`,
          operationId: `additional:${x.id}`,
          name: x.name,
          names: [x.name],
          source: 'additional',
          packageIdentifier: '',
          method: x.execution === 'automatic' ? 'installer' : 'manual',
          kind: x.execution === 'automatic' ? ('additional' as const) : ('manual' as const),
          required: x.execution === 'automatic' && !optional.has(`additional:${x.id.toLowerCase()}`),
          scope: 'unknown',
          version: '',
          shortcut: '',
          signIn: false,
          instructions: x.execution === 'automatic' ? '' : `Install ${x.name} by hand${x.downloadUrl ? ` from ${x.downloadUrl}` : ''}.`,
          url: x.downloadUrl,
        })),
      ]
    : [];
  const restore = settingsRestoreActive(p) ? p.migration : null;
  const account = p.accounts;
  return {
    schemaVersion: 1 as const,
    engineVersion: HEALTH_ENGINE_VERSION,
    dataRoot: DATA_ROOT,
    reportDir: 'reports\\health',
    options: {
      technicianReport: p.health.technicianReport,
      customerReport: p.health.customerReport,
      keepHistory: p.health.keepHistory,
      historyLimit: p.health.keepHistory ? 50 : 2,
      storageObservations: p.health.storageObservations,
      openReportAfterDeployment: p.health.openReportAfterDeployment,
      /** Startup re-checks after a pending restart (the task removes itself). */
      startupRechecks: 3,
    },
    categories: HEALTH_CATEGORIES.map((c) => ({ id: c.id, name: c.name })),
    windows: {
      editionMode: p.setup.editionMode,
      editionName: p.setup.editionMode === 'genericKey' ? `Windows 11 ${lookup.edition(p.setup.editionId)?.DisplayName ?? p.setup.editionId}` : '',
      expectedEditionIds: p.setup.editionMode === 'genericKey' && EDITION_IDS[p.setup.editionId] ? [EDITION_IDS[p.setup.editionId]!] : [],
      architectures: p.setup.processorArchitectures,
      minimumBuild: 22000,
    },
    identity: { computerNameMode: account.computerNameMode, computerName: id.computerName ?? null },
    account: {
      mode: account.accountMode,
      username: account.accountMode === 'unattendedLocal' ? id.username : '',
      expectedGroup: account.accountGroup,
      autoLogon: account.accountMode === 'unattendedLocal' ? account.autoLogon : 'none',
    },
    windowsUpdate: {
      enabled: p.windowsUpdate.enabled,
      drivers: resolveDrivers(p),
      featureUpdates: p.windowsUpdate.featureUpdates,
      optionalUpdates: p.windowsUpdate.optionalUpdates,
      ongoingPolicy: ongoingPolicyDeferred(p) ? p.updates.mode : null,
    },
    applications: { enabled: apps, items, deselected: cfg ? cfg.deselected.map((x) => x.key) : [] },
    restoration: restore
      ? {
          required: true,
          backupId: restore.backup!.backupId,
          folderName: restore.backup!.folderName,
          adapters: restore.settings.filter((s) => s.enabled && adapterById(s.adapterId)).map((s) => ({ id: s.adapterId, name: adapterById(s.adapterId)!.name })),
        }
      : { required: false, backupId: '', folderName: '', adapters: [] },
    drivers: { enabled: driversActive(p), useWindowsUpdate: p.drivers.useWindowsUpdate, reportUnresolved: p.drivers.reportUnresolved },
    security: {
      uac: { level: p.security.uacLevel, ...UAC_EXPECTED[p.security.uacLevel] },
      smartScreenExpected: !p.security.disableSmartScreen,
      deviceEncryptionPrevented: p.security.preventDeviceEncryption,
    },
    network: { requirement: p.health.networkRequirement, wifiConfigured: p.wifi.mode === 'parameters' || p.wifi.mode === 'profileXml' },
    customizations: customizationAdapters(p),
    customerNotes: p.health.customerNotes,
  };
}

export type HealthConfig = ReturnType<typeof healthConfig>;

const crlf = (s: string): string => s.replace(/\r?\n/g, '\r\n');
/** JSON with every non-ASCII character escaped, so the code page used on extraction cannot matter. */
const asciiJson = (v: unknown) => crlf(JSON.stringify(v, null, 2).replace(/[\u007f-\uffff]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`) + '\n');

function readme(): string {
  return `Windows Deployment Builder - deployment verification and health ${HEALTH_ENGINE_VERSION}
=====================================================================

DeploymentHealth.ps1 checks what this deployment was meant to achieve against the installed
Windows itself. It reads the engines' results as evidence, then looks at Windows: the edition,
the account and its groups, the computer name, Windows Update, the installed applications (only
those this deployment selected), restored settings, devices and their drivers, Defender and the
firewall, encryption, the network and the system drive. A script that exited with 0 is never taken
as proof that a computer is configured.

Verification is read-only. It installs, removes, restarts, deletes and changes nothing; repairs
are separate actions of the "Deployment recovery" tool, and each asks first.

Use (Windows PowerShell 5.1, as administrator)
  powershell.exe -ExecutionPolicy Bypass -File "${HEALTH_TOOL}"
      verifies again and writes the reports (exit code: 0 Ready, 10 ReadyWithWarnings,
      20 NeedsAttention, 30 Incomplete, 50 Unverifiable, 60 Failed)
  ... -Mode Dashboard      verifies, then opens the technician report
  ... -ScanUpdates         also asks Windows Update which updates are still available (read-only)
  ... -Mode CleanupBackups lists the retained settings backup; -ConfirmCleanup <backup id> removes
                           it, only when no restoration is outstanding (never the USB copy)
  ... -Mode ExportDiagnostics  a ZIP with the reports and sanitized logs (no backups, no passwords)

Reports (${HEALTH_REPORT_DIR})
  deployment-health.json  every finding, with expected and observed state, evidence and next action
  technician-report.html  the dashboard (print it or save it as PDF from the browser)
  customer-handoff.html   a plain summary for the person receiving the computer
  history\\                earlier reports, so the record of a failed deployment is never lost

Status: tested with simulated computers only. Validate on a spare computer before relying on it.
`;
}

/** Package assets of the health engine; empty when verification is off. */
export function healthAssets(p: Profile): { name: string; content: string; description: string }[] {
  if (!healthActive(p)) return [];
  return [
    { name: HEALTH_ENGINE_FILE, content: crlf(engineSource), description: 'Deployment verification: checks Windows itself and writes the health reports (read-only)' },
    { name: HEALTH_CONFIG_FILE, content: asciiJson(healthConfig(p)), description: 'What this deployment must have achieved (the verification plan)' },
    { name: HEALTH_TEMPLATE_FILE, content: crlf(templateSource), description: 'Report template (technician dashboard and customer handoff; works offline)' },
    { name: HEALTH_SCHEMA_FILE, content: crlf(JSON.stringify(HEALTH_REPORT_JSON_SCHEMA, null, 2) + '\n'), description: 'JSON Schema of deployment-health.json' },
    { name: HEALTH_README_FILE, content: crlf(readme()), description: 'How to run the verification and read its reports' },
  ];
}

/**
 * The report template with data inserted (the website's sample preview uses the same template).
 * The page's Content-Security-Policy allows exactly this template's script by its SHA-256 (see
 * index.html; a unit test keeps the two in step), so line endings are normalised first.
 */
export function renderHealthTemplate(data: unknown, template: string = templateSource): string {
  const json = JSON.stringify(data).replace(/</g, '\\u003c').replace(/>/g, '\\u003e').replace(/&/g, '\\u0026').replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');
  return template.replace(/\r\n/g, '\n').replace('__WDB_HEALTH_DATA__', () => json);
}

export { templateSource as HEALTH_TEMPLATE };
