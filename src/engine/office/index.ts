import engineSource from './scripts/OfficeEngine.ps1?raw';
import installerSource from './scripts/Install-OfficeEngine.ps1?raw';
import officeInstaller2024 from './vendor/2024/Install_Office.ps1?raw';
import config2024Standard from './vendor/2024/config_standard.xml?raw';
import config2024ProPlus from './vendor/2024/config_ProPlus.xml?raw';
import config2021Standard from './vendor/2021/config_standard.xml?raw';
import config2021ProPlus from './vendor/2021/config_ProPlus.xml?raw';
import type { OfficeProduct, Profile } from '../schema/profile';
import { DATA_ROOT, TASK_PATH, type DeploymentAsset } from '../windows-update';
import { applicationsActive } from '../applications';
import { sha256, utf8 } from '../deployment/sha256';

/**
 * Optional Microsoft Office LTSC (volume licensed) as its own deployment stage.
 *
 * The installer is the technician's own project, jdepew88/download_office_ltsc, pinned to reviewed
 * commits and shipped inside the package (never fetched from a branch URL at run time):
 *
 *   2024  branch 2024 @ 3e28171: Install_Office.ps1 (unattended mode, documented exit codes, ODT
 *         download with Microsoft signature check) and its own config_<edition>.xml, unchanged.
 *   2021  branch 2021 @ 548c491 only has an interactive script that downloads its XML from the
 *         repository's main branch (now the 2024 configuration). WDB therefore uses the 2021
 *         branch's configuration files (adapted: no AUTOACTIVATE, no unconditional RemoveMSI) and
 *         runs them through the pinned 2024 Install_Office.ps1 with -ConfigPath, its documented
 *         custom-configuration mode. The 2021 configuration is never a fallback for 2024 or back.
 *
 * OfficeEngine.ps1 (SYSTEM task) waits for Windows Update and the WinGet applications, respects an
 * existing Office installation, runs the installer under the machine-wide installation lock,
 * reports each phase and verifies the Click-to-Run registration before reporting success. It never
 * activates Office: activation is a separate, optional final stage (src/engine/activation).
 */

export const OFFICE_ENGINE_VERSION = '1.0.0';
export const OFFICE_TASK_NAME = 'Office';
export const OFFICE_ENGINE_FILE = 'OfficeEngine.ps1';
export const OFFICE_INSTALLER_FILE = 'Install-OfficeEngine.ps1';
export const OFFICE_CONFIG_FILE = 'office-config.json';
export const OFFICE_SETUP_SCRIPT = 'Install_Office.ps1';
export const OFFICE_STAGE = { id: 'office', root: 'Office', resultFile: 'Office\\result.json', statusFile: 'Office\\status.json', marker: 'state\\office.done' } as const;
export const OFFICE_FINAL_STATUSES = ['Succeeded', 'CompletedWithFollowUp', 'Failed', 'Offline'] as const;
/** Microsoft's documented minimum is about 4 GB for Office; the installer's own default is 10 GB. */
export const OFFICE_MIN_FREE_GB = 10;

export const OFFICE_REPOSITORY = 'https://github.com/jdepew88/download_office_ltsc';

export interface OfficeSourceFile {
  /** Path in the upstream repository. */
  path: string;
  /** SHA-256 of the file exactly as committed upstream (CRLF). */
  upstreamSha256: string;
  /** Shipped unchanged (true) or adapted by WDB (false; see the file's comment). */
  unchanged: boolean;
}

export interface OfficeSource {
  branch: string;
  commit: string;
  files: OfficeSourceFile[];
}

/** The reviewed upstream revisions. tests/unit/office.test.ts checks the shipped files against them. */
export const OFFICE_SOURCES = {
  2024: {
    branch: '2024',
    commit: '3e2817194aaef0856c5ce8653763c77e24cb3e72',
    files: [
      { path: 'Install_Office.ps1', upstreamSha256: '55648698d51a43f24fd814e88cfc7405f5404e18a3ac2f49520188a5c3269a9c', unchanged: true },
      { path: 'config_standard.xml', upstreamSha256: '3e6640923d6056d295b04482f5975a4a75aeb38958b28c5e439ccf630d5bfe63', unchanged: true },
      { path: 'config_ProPlus.xml', upstreamSha256: '890505e38a7fd0b93b1c3033c824e4fe5800919642ea9b2b08d6c67d4c1fbac4', unchanged: true },
      { path: 'Activate_Office.ps1', upstreamSha256: '7004afa7ba50c1b85beeafef98d3d8555909d5558912c59883a6b98847f5f44d', unchanged: true },
    ],
  },
  2021: {
    branch: '2021',
    commit: '548c49142589a9c7c093a4724b9cee1045c0eb2b',
    files: [
      { path: 'config_standard.xml', upstreamSha256: '06637697ba3fbc8b3844d7b33ef93c90cd3873bb159ef6654d31a9b54375cb98', unchanged: false },
      { path: 'config_ProPlus.xml', upstreamSha256: '68f853492216fb1a2e8628792067abe1532690f867ab65d4da6a56f95033a4f0', unchanged: false },
    ],
  },
} as const satisfies Record<2021 | 2024, OfficeSource>;

export interface OfficeProductInfo {
  id: Exclude<OfficeProduct, 'none'>;
  version: 2021 | 2024;
  edition: 'Standard' | 'ProPlus';
  displayName: string;
  productId: string;
  channel: string;
  /** Office LTSC 2021: still supported, but older; 2024 is the current LTSC release. */
  legacy: boolean;
}

export const OFFICE_CATALOG: Record<Exclude<OfficeProduct, 'none'>, OfficeProductInfo> = {
  ltsc2021Standard: { id: 'ltsc2021Standard', version: 2021, edition: 'Standard', displayName: 'Office LTSC Standard 2021', productId: 'Standard2021Volume', channel: 'PerpetualVL2021', legacy: true },
  ltsc2021ProPlus: { id: 'ltsc2021ProPlus', version: 2021, edition: 'ProPlus', displayName: 'Office LTSC Professional Plus 2021', productId: 'ProPlus2021Volume', channel: 'PerpetualVL2021', legacy: true },
  ltsc2024Standard: { id: 'ltsc2024Standard', version: 2024, edition: 'Standard', displayName: 'Office LTSC Standard 2024', productId: 'Standard2024Volume', channel: 'PerpetualVL2024', legacy: false },
  ltsc2024ProPlus: { id: 'ltsc2024ProPlus', version: 2024, edition: 'ProPlus', displayName: 'Office LTSC Professional Plus 2024', productId: 'ProPlus2024Volume', channel: 'PerpetualVL2024', legacy: false },
};

export const officeActive = (p: Profile): boolean => p.office.product !== 'none';
export const officeProduct = (p: Profile): OfficeProductInfo | null => (p.office.product === 'none' ? null : OFFICE_CATALOG[p.office.product]);

const crlf = (s: string): string => s.replace(/\r?\n/g, '\r\n');
/** Same normalization as the deployment's text hash: what survives extraction from the answer file. */
const textSha256 = (s: string): string => sha256(utf8(s.replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n').trim()));

/** The configuration file shipped for a product: the 2024 installer's own, or the adapted 2021 one. */
export function officeConfiguration(info: OfficeProductInfo): { name: string; content: string; upstreamPath: string; unchanged: boolean } {
  if (info.version === 2024) {
    // The installer's -Edition mode reads config_<edition>.xml next to itself (and checks the channel and product).
    const name = info.edition === 'ProPlus' ? 'config_ProPlus.xml' : 'config_standard.xml';
    return { name, content: info.edition === 'ProPlus' ? config2024ProPlus : config2024Standard, upstreamPath: name, unchanged: true };
  }
  return {
    name: `config-2021-${info.edition}.xml`,
    content: info.edition === 'ProPlus' ? config2021ProPlus : config2021Standard,
    upstreamPath: info.edition === 'ProPlus' ? 'config_ProPlus.xml' : 'config_standard.xml',
    unchanged: false,
  };
}

/** Installer arguments (fixed; paths are added by the engine). Never -AcceptEula: users accept the terms at first start. */
export function officeInstallerArguments(p: Profile): string[] {
  const info = officeProduct(p);
  if (!info) return [];
  const args = ['-Unattended', '-Cleanup', 'Yes', '-MinimumFreeSpaceGB', String(OFFICE_MIN_FREE_GB)];
  if (info.version === 2024) args.push('-Edition', info.edition);
  else args.push('-ConfigPath', '<configuration>');
  if (p.office.removeMsiOffice) args.push('-RemovePreviousVersions');
  return args;
}

/** Hours the Office stage waits for the WinGet application stage before it installs anyway. */
export function officeWaitForApplicationsHours(p: Profile): number {
  return applicationsActive(p) ? p.applications.waitForUpdatesHours + p.applications.maxRuntimeHours : 0;
}

export function officeConfig(p: Profile) {
  const info = officeProduct(p);
  if (!info) return null;
  const cfg = officeConfiguration(info);
  const src = OFFICE_SOURCES[info.version];
  return {
    schemaVersion: 1,
    engineVersion: OFFICE_ENGINE_VERSION,
    dataRoot: DATA_ROOT,
    taskPath: TASK_PATH,
    taskName: OFFICE_TASK_NAME,
    product: { id: info.id, displayName: info.displayName, version: info.version, edition: info.edition, productId: info.productId, channel: info.channel },
    installer: {
      file: OFFICE_SETUP_SCRIPT,
      textSha256: textSha256(officeInstaller2024),
      arguments: officeInstallerArguments(p),
      source: { repository: OFFICE_REPOSITORY, branch: OFFICE_SOURCES[2024].branch, commit: OFFICE_SOURCES[2024].commit, path: OFFICE_SETUP_SCRIPT },
      exitCodes: { 0: 'Success', 1: 'InvalidArguments', 2: 'ConfigError', 3: 'DiskSpace', 4: 'NotAdministrator', 5: 'OdtDownload', 6: 'OdtExtraction', 7: 'OfficeDownload', 8: 'OfficeInstall', 10: 'Cancelled', 99: 'Unexpected' },
    },
    configuration: { file: cfg.name, textSha256: textSha256(cfg.content), source: { repository: OFFICE_REPOSITORY, branch: src.branch, commit: src.commit, path: cfg.upstreamPath }, adaptedByWdb: !cfg.unchanged },
    removeMsiOffice: p.office.removeMsiOffice,
    minimumFreeSpaceGB: OFFICE_MIN_FREE_GB,
    // ODT downloads about 2-4 GB and may be quiet for a long time; the engine checks the processes, not the output.
    installTimeoutMinutes: 240,
    maxAttempts: 2,
    networkWaitHours: 6,
    waitFor: {
      windowsUpdate: { enabled: p.windowsUpdate.enabled, marker: 'state\\windows-update.done' },
      applications: { enabled: applicationsActive(p), marker: 'state\\applications.done', maxWaitHours: officeWaitForApplicationsHours(p) },
    },
    networkTest: ['https://officecdn.microsoft.com/', 'https://go.microsoft.com/'],
    activates: false,
  };
}

const README = (p: Profile): string => {
  const info = officeProduct(p)!;
  return `Microsoft Office LTSC - deployment stage
==========================================

Product:   ${info.displayName} (${info.productId}, channel ${info.channel})
Installer: Install_Office.ps1 from ${OFFICE_REPOSITORY}
           branch ${OFFICE_SOURCES[2024].branch}, commit ${OFFICE_SOURCES[2024].commit} (unchanged)
Config:    ${officeConfiguration(info).name} from branch ${OFFICE_SOURCES[info.version].branch}, commit ${OFFICE_SOURCES[info.version].commit}${officeConfiguration(info).unchanged ? ' (unchanged)' : ' (adapted: no automatic activation, no unconditional RemoveMSI)'}

OfficeEngine.ps1 runs as SYSTEM from the scheduled task ${TASK_PATH}${OFFICE_TASK_NAME}:
  1. waits until Windows Update${applicationsActive(p) ? ' and the WinGet applications' : ''} have finished and no restart is pending;
  2. checks for an existing Office installation. The same product counts as installed; any other
     Click-to-Run Office, or Windows Installer (MSI) Office${p.office.removeMsiOffice ? ' (removal of MSI Office was chosen)' : ''}, stops the stage with a
     follow-up instead of installing next to it. Nothing is uninstalled unless chosen explicitly;
  3. checks ${OFFICE_MIN_FREE_GB} GB of free space and the connection to Microsoft's Office servers;
  4. runs Install_Office.ps1 unattended (it downloads the Office Deployment Tool from Microsoft and
     verifies its Microsoft signature) and reports Preparing / Downloading / Installing;
  5. verifies the Click-to-Run registration (${info.productId}) before it reports success.

Office is NOT activated by this stage. Logs: ${DATA_ROOT}\\Office\\logs
`;
};

export function officeAssets(p: Profile): DeploymentAsset[] {
  const info = officeProduct(p);
  if (!info) return [];
  const cfg = officeConfiguration(info);
  return [
    { name: OFFICE_ENGINE_FILE, content: crlf(engineSource), mime: 'text/plain', description: 'Office stage engine (runs as SYSTEM from its scheduled task)', group: 'office' },
    { name: OFFICE_INSTALLER_FILE, content: crlf(installerSource), mime: 'text/plain', description: 'Installs the Office stage engine and registers its task', group: 'office' },
    { name: OFFICE_CONFIG_FILE, content: crlf(JSON.stringify(officeConfig(p), null, 2) + '\n'), mime: 'application/json', description: `${info.displayName}: product, pinned installer and configuration`, group: 'office' },
    { name: OFFICE_SETUP_SCRIPT, content: crlf(officeInstaller2024), mime: 'text/plain', description: `Office LTSC installer (${OFFICE_REPOSITORY}, commit ${OFFICE_SOURCES[2024].commit.slice(0, 7)})`, group: 'office' },
    { name: cfg.name, content: crlf(cfg.content), mime: 'application/xml', description: `Office Deployment Tool configuration for ${info.displayName}`, group: 'office' },
    { name: 'README-office.txt', content: crlf(README(p)), mime: 'text/plain', description: 'How the Office stage works', group: 'office' },
  ];
}

/** Every Office file except the README runs on the computer, so all of them go into the answer file. */
export const embeddedOfficeFile = (name: string): boolean => name !== 'README-office.txt';
