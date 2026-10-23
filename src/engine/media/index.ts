import { z } from 'zod';
import assistantSource from './scripts/WdbMediaAssistant.ps1?raw';
import migrationSource from '../migration/scripts/WdbMigration.ps1?raw';
import driverEngineSource from '../drivers/scripts/DriverEngine.ps1?raw';
import releasesJson from '../../data/windows-releases.json';
import { lookup } from '../../data';
import type { Profile } from '../schema/profile';
import { settingsRestoreActive } from '../migration/plan';
import { sha256, utf8 } from '../deployment/sha256';
import { createZip } from '../deployment/zip';
import { DRIVER_ENGINE_FILE, DRIVER_SOURCES_FILE, DRIVER_SOURCE_DATA, MEDIA_DRIVERS_DIR, MEDIA_WINPE_DRIVERS_DIR, driverMediaBlock } from '../drivers';

/**
 * Phase 7: the USB Preparation Assistant. The website decides what is installed and produces the
 * deployment package; the local assistant (scripts/WdbMediaAssistant.ps1, Windows PowerShell 5.1)
 * prepares and verifies installation media from it. They meet only through the package's
 * manifest: the `media` block below tells the assistant what the media must provide and where
 * every file goes. The website never touches a disk.
 */

export const MEDIA_CONTRACT_VERSION = 1;
export const ASSISTANT_VERSION = '1.0.0';
export const ASSISTANT_SCRIPT = 'WdbMediaAssistant.ps1';
export const ASSISTANT_BUNDLE = 'usb-preparation-assistant.zip';
export const MICROSOFT_DOWNLOAD = 'https://www.microsoft.com/software-download/windows11';

/** Generic edition ids of the builder -> the EditionId inside install.wim/esd (DISM). */
export const DISM_EDITIONS: Readonly<Record<string, string>> = {
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

/** The installation media layout the Phase 4-6 engines rely on (relative to the drive root). */
export const MEDIA_LAYOUT = {
  answerFile: 'autounattend.xml',
  packageDir: 'WindowsDeployment',
  backupsDir: 'WindowsDeployment/backups',
  /** Phase 8: the pinned offline driver bundle and the Setup-critical drivers Windows Setup loads. */
  driversDir: MEDIA_DRIVERS_DIR,
  setupDriversDir: MEDIA_WINPE_DRIVERS_DIR,
} as const;

const ReleaseSchema = z
  .object({
    version: z.string().regex(/^\d{2}H\d$/),
    build: z.number().int(),
    availability: z.string().nullable(),
    endHomePro: z.string().nullable(),
    endEnterpriseEducation: z.string().nullable(),
    latestRevision: z.number().int().nullable(),
    latestRevisionDate: z.string().nullable(),
    note: z.string(),
  })
  .strict();
export const ReleasesSchema = z
  .object({ $comment: z.string().optional(), source: z.string().url().startsWith('https://learn.microsoft.com/'), sourceUpdated: z.string(), verifiedUtc: z.string(), minimumBuild: z.number().int(), releases: z.array(ReleaseSchema).min(1) })
  .strict();
export const WINDOWS_RELEASES = ReleasesSchema.parse(releasesJson);

/** What the installation media must provide for this deployment. */
export function mediaRequirements(p: Profile) {
  const s = p.setup;
  const generic = s.editionMode === 'genericKey';
  return {
    editionMode: s.editionMode,
    editionId: generic ? s.editionId : '',
    dismEditionId: generic ? (DISM_EDITIONS[s.editionId] ?? '') : '',
    editionName: generic ? `Windows 11 ${lookup.edition(s.editionId)?.DisplayName ?? s.editionId}` : s.editionMode,
    architectures: [...s.processorArchitectures],
    minimumBuild: WINDOWS_RELEASES.minimumBuild,
  };
}

/**
 * The manifest's `media` block (package scope only: the copy embedded in the answer file is
 * unchanged, so the answer file is the same as before Phase 7). The answer file's SHA-256 lets the
 * assistant verify it; it cannot be inside the answer file itself.
 */
export function mediaBlock(p: Profile, answerFileName: string, answerFileBytes: Uint8Array) {
  const m = p.migration;
  return {
    contractVersion: MEDIA_CONTRACT_VERSION,
    layout: { ...MEDIA_LAYOUT },
    answerFile: { fileName: answerFileName, size: answerFileBytes.length, sha256: sha256(answerFileBytes) },
    requirements: mediaRequirements(p),
    backup: settingsRestoreActive(p) ? { backupId: m.backup!.backupId, manifestSha256: m.backup!.manifestSha256, folderName: m.backup!.folderName, location: `${MEDIA_LAYOUT.backupsDir}/${m.backup!.folderName}` } : null,
    ...(driverMediaBlock(p) ? { drivers: driverMediaBlock(p) } : {}),
    usbRequiredAfterSetup: false,
  };
}

const crlf = (s: string) => s.replace(/\r?\n/g, '\r\n');

const LAUNCHER = `@echo off
rem Windows Deployment Builder - USB Preparation Assistant.
rem Starts the guided steps. Inspecting and updating a USB drive needs no administrator rights;
rem creating a drive from an ISO asks for them (Windows shows a prompt) only for that step.
"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0${ASSISTANT_SCRIPT}" %*
pause
`;

export function assistantReadme(): string {
  return `Windows Deployment Builder - USB Preparation Assistant ${ASSISTANT_VERSION}
=====================================================

Prepares a Windows 11 installation USB drive from the deployment package you downloaded
(windows-deployment-package.zip), on this computer. Nothing is uploaded. Needs Windows 10/11 with
Windows PowerShell 5.1 (included).

Start: double-click Prepare-InstallationUSB.cmd and follow the steps. Or run the steps yourself:

  .\\${ASSISTANT_SCRIPT} -Mode Discover                    list drives and whether each can be used
  .\\${ASSISTANT_SCRIPT} -Mode Inspect -Target E:          read-only look at a drive (or -Iso <file>)
  .\\${ASSISTANT_SCRIPT} -Mode Plan -Workflow Update -Package <zip> -Target E: [-Backup <folder>] [-Drivers <folder>]
  .\\${ASSISTANT_SCRIPT} -Mode Plan -Workflow Create -Package <zip> -Iso <file> -Disk <number> [-IsoSha256 <hash>]
  .\\${ASSISTANT_SCRIPT} -Mode Apply -PlanPath <plan.json> [-ConfirmErase <code from the plan>]
  .\\${ASSISTANT_SCRIPT} -Mode Verify -Target E: -Package <zip>

Workflows
  Update   Adds the deployment to an existing Windows USB (Media Creation Tool, or made earlier with
           this assistant). Nothing is erased; Windows' own files are not changed; an older
           deployment on the drive is moved to WDB-previous\\<time>, never deleted.
  Create   ERASES the USB flash drive you choose and makes a new one from a Windows 11 ISO
           (official download: ${MICROSOFT_DOWNLOAD}). Only removable USB flash drives
           can be erased; the drive of the running Windows, internal and external hard disks and
           Ventoy drives never are. You must type the confirmation code shown for that exact drive.
  Inspect  Read-only report of a drive or ISO.

Driver bundle (only when the deployment pins one): -Drivers <WDB-Drivers-... folder>. It is copied to
WindowsDeployment\\drivers\\<folder>; storage drivers Windows Setup needs go to $WinPEDriver$\\<folder>,
where Setup loads them. The Windows image itself is never modified.

Files: ${ASSISTANT_SCRIPT} (the assistant), WdbMigration.ps1 (verifies Phase 6 settings backups),
${DRIVER_ENGINE_FILE} and ${DRIVER_SOURCES_FILE} (verify Phase 8 driver bundles),
windows-releases.json (Microsoft release information cached ${WINDOWS_RELEASES.verifiedUtc}, used to say how current
the Windows image is), Prepare-InstallationUSB.cmd (starts the wizard).

Reports: %LOCALAPPDATA%\\WindowsDeploymentBuilder\\media\\reports and wdb-media-report.txt on the drive.
"Ready for installation" means the files, the Windows image, the boot files and every hash were
checked. It does not mean the drive was booted: no computer is started by this assistant.

Status: tested with simulated disks and synthetic images only. Not yet run against a real USB drive.
`;
}

/** The files of the assistant bundle (all text; the ZIP adds nothing else). */
export function assistantFiles(): { path: string; content: string }[] {
  return [
    { path: ASSISTANT_SCRIPT, content: crlf(assistantSource) },
    { path: 'WdbMigration.ps1', content: crlf(migrationSource) },
    { path: DRIVER_ENGINE_FILE, content: crlf(driverEngineSource) },
    { path: DRIVER_SOURCES_FILE, content: crlf(JSON.stringify(DRIVER_SOURCE_DATA, null, 2) + '\n') },
    { path: 'Prepare-InstallationUSB.cmd', content: crlf(LAUNCHER) },
    { path: 'windows-releases.json', content: crlf(JSON.stringify(WINDOWS_RELEASES, null, 2) + '\n') },
    { path: 'README-USB-Assistant.txt', content: crlf(assistantReadme()) },
  ];
}

/** usb-preparation-assistant.zip; .ps1 files carry a BOM so Windows PowerShell 5.1 reads them as UTF-8. */
export function assistantBundle(): Uint8Array {
  return createZip(
    assistantFiles().map((f) => {
      const body = utf8(f.content);
      if (!f.path.endsWith('.ps1')) return { path: `usb-preparation-assistant/${f.path}`, data: body };
      const out = new Uint8Array(body.length + 3);
      out.set([0xef, 0xbb, 0xbf]);
      out.set(body, 3);
      return { path: `usb-preparation-assistant/${f.path}`, data: out };
    }),
  );
}
