import type { GenContext } from '../../engine/context';
import type { SettingDef } from '../../engine/settings/types';
import type { Profile } from '../../engine/schema/profile';
import type { Issue } from '../../engine/validation/issues';
import { TASK_PATH } from '../../engine/windows-update';
import {
  DRIVER_CONFIG_FILE,
  DRIVER_ENGINE_FILE,
  DRIVER_INSTALLER_FILE,
  DRIVER_LIMITS,
  DRIVER_REPORT_FILE,
  DRIVER_RESULT_FILE,
  DRIVER_STAGING_DIR,
  DRIVER_TASK_NAME,
  EMBEDDED_DRIVER_FILES,
  driverAssets,
  driversActive,
  verifiedPackageProblems,
} from '../../engine/drivers';

/**
 * Phase 8: Hardware & Drivers. The website cannot see the target computer: hardware is detected by
 * the driver engine on the installed Windows. Here the technician sets the policy and may attach a
 * pinned offline driver bundle, technician-verified packages and approvals, and review an inventory
 * taken earlier on the same computer.
 */

const on = (p: Profile) => p.drivers.enabled;
const APPLIES = 'Windows 10/11 (Windows PowerShell 5.1, Plug and Play, pnputil.exe)';

const flag = (path: string, label: string, description: string, mapping: string, advanced = false, risk?: string): SettingDef => ({
  path,
  section: 'drivers',
  label,
  control: 'checkbox',
  description,
  applicability: APPLIES,
  stages: ['firstLogon'],
  mapping,
  advanced,
  visibleWhen: on,
  verification: 'unverified',
  ...(risk ? { risk } : {}),
});

export const settings: SettingDef[] = [
  {
    path: 'drivers.enabled',
    section: 'drivers',
    label: 'Detect hardware automatically and provision drivers',
    control: 'checkbox',
    description:
      'On the installed computer, a SYSTEM task identifies every device by its hardware IDs, keeps every working driver, lets Windows Update go first and installs a verified driver only where one is missing or not working. Everything else is reported with what to do.',
    applicability: APPLIES,
    risk: 'Driver installation can restart the computer (with a warning). Tested with simulated hardware only.',
    stages: ['specialize', 'firstLogon'],
    mapping: `Embeds ${DRIVER_ENGINE_FILE}, ${DRIVER_INSTALLER_FILE} and ${DRIVER_CONFIG_FILE} in ${DRIVER_STAGING_DIR}. The deployment orchestrator runs ${DRIVER_INSTALLER_FILE} once, which registers ${TASK_PATH}${DRIVER_TASK_NAME} (SYSTEM, at startup + every 30 minutes). Result: ${DRIVER_RESULT_FILE}; report: ${DRIVER_REPORT_FILE}.`,
    advanced: false,
    verification: 'unverified',
  },
  flag(
    'drivers.useWindowsUpdate',
    'Let Windows Update resolve drivers first',
    'Driver decisions wait until the Windows Update stage has finished and restarted, then the devices are inspected again. Only what is still missing afterwards is handled here.',
    `${DRIVER_CONFIG_FILE} › policy.useWindowsUpdate (reads Updates\\state.json / result.json; never starts or changes Windows Update)`,
  ),
  flag(
    'drivers.resolveMissing',
    'Resolve missing drivers from verified sources',
    'For a device without a working driver: the Windows driver store, then the offline bundle below, then the verified packages below. A package is used only if its INF declares the device, it is Microsoft-signed (WHQL or attestation), fits this Windows and architecture and respects OEM customizations. Otherwise the device is reported with the official support page.',
    `${DRIVER_CONFIG_FILE} › policy.resolveMissing; pnputil /add-driver <inf> /install (Windows' ranking decides), pnputil /scan-devices for driver-store candidates`,
  ),
  flag(
    'drivers.includeOfflinePackages',
    'Include approved offline driver packages',
    'Use the pinned offline bundle (it goes on the USB drive, not into the package). Needed for installations without a network and for storage drivers Windows Setup must load.',
    `${DRIVER_CONFIG_FILE} › bundle (folder name and manifest SHA-256); media › drivers in the package manifest`,
  ),
  {
    path: 'drivers.optionalReplacements',
    section: 'drivers',
    label: 'Replacing a working driver',
    control: 'radio',
    choices: [
      { value: 'never', label: 'Never: report newer drivers only (owner default)', description: 'A working driver is kept even when a newer package exists.' },
      { value: 'approvedOnly', label: 'Only the replacements a technician approved below', description: 'For a working device, only an approved package for that hardware ID, and only if it is newer.' },
    ],
    description: 'A newer version number alone never replaces a working driver, and a working driver is never downgraded.',
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: `${DRIVER_CONFIG_FILE} › policy.optionalReplacements, approvals`,
    advanced: false,
    visibleWhen: on,
    verification: 'unverified',
  },
  flag(
    'drivers.reportUnresolved',
    'Report unresolved hardware',
    'Devices that still need a driver, a technician or a restart are listed in the deployment report and the recovery tool, with the hardware ID and the official support page.',
    `${DRIVER_REPORT_FILE} › manualActions; deployment report › remaining tasks`,
  ),
  flag(
    'drivers.networkBootstrap',
    'Try offline network drivers when there is no network',
    'If the computer is offline because its network adapter has no driver, compatible packages from the offline bundle are tried before anything else waits for the network. Without one, the deployment pauses and reports that a network driver must be supplied.',
    `${DRIVER_CONFIG_FILE} › policy.networkBootstrap; state\\network-driver-missing.json`,
    true,
  ),
  {
    path: 'drivers.maxReboots',
    section: 'drivers',
    label: `Maximum restarts for drivers (${DRIVER_LIMITS.maxReboots[0]}-${DRIVER_LIMITS.maxReboots[1]})`,
    control: 'number',
    description: 'Restarts the driver stage may request (after Windows Update, and to start newly installed drivers). Further restarts are reported instead.',
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: `${DRIVER_CONFIG_FILE} › maxReboots`,
    advanced: true,
    visibleWhen: on,
    verification: 'unverified',
  },
  {
    path: 'drivers.hardware',
    section: 'drivers',
    label: 'Hardware of the target computer (optional, before installation)',
    control: 'custom',
    description:
      'The website cannot see a computer. If Windows already runs on the target computer, run the read-only inventory there and import it to review its devices and plan drivers. The deployment inspects the hardware again on the installed computer and decides from that.',
    applicability: 'Inventory: Windows 10/11 on the computer itself (no administrator rights needed)',
    stages: ['none'],
    mapping: `Website only: the inventory stays in this browser tab; its summary is recorded (drivers.hardware) and the model is compared with the installed computer's.`,
    advanced: false,
    visibleWhen: on,
    verification: 'unverified',
  },
  {
    path: 'drivers.bundle',
    section: 'drivers',
    label: 'Offline driver bundle',
    control: 'custom',
    description:
      'A verified bundle of INF driver packages, exported from a compatible Windows installation or built from drivers you downloaded from the manufacturer. Only its manifest is read here; the deployment accepts exactly that bundle (manifest SHA-256).',
    applicability: 'Bundle tool: Windows 10/11; export needs administrator rights',
    stages: ['firstLogon'],
    mapping: `${DRIVER_CONFIG_FILE} › bundle; on the USB drive WindowsDeployment\\drivers\\<folder>, Setup-critical packages in $WinPEDriver$\\<folder>`,
    advanced: false,
    visibleWhen: on,
    verification: 'unverified',
  },
  {
    path: 'drivers.verifiedPackages',
    section: 'drivers',
    label: 'Verified driver packages (download)',
    control: 'custom',
    description:
      'An INF driver package (.cab or .zip) you checked yourself: the exact HTTPS URL on the manufacturer\'s or Microsoft\'s download host, its SHA-256 and the hardware IDs it is for. Downloaded only if a device still needs it; a different file is deleted and never used.',
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: `${DRIVER_CONFIG_FILE} › verifiedPackages`,
    advanced: true,
    visibleWhen: on,
    verification: 'unverified',
  },
  {
    path: 'drivers.approvals',
    section: 'drivers',
    label: 'Approved replacements of working drivers',
    control: 'custom',
    description: 'Package and hardware ID pairs a technician approved. Used only with "Only the replacements a technician approved".',
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: `${DRIVER_CONFIG_FILE} › approvals`,
    advanced: true,
    visibleWhen: on,
    verification: 'unverified',
  },
];

export function validate(p: Profile, issues: Issue[]): void {
  const d = p.drivers;
  if (!d.enabled) return;
  const err = (path: string, message: string) => issues.push({ severity: 'error', path, message });
  const warn = (path: string, message: string) => issues.push({ severity: 'warning', path, message });
  const [min, max] = DRIVER_LIMITS.maxReboots;
  if (d.maxReboots < min || d.maxReboots > max) err('drivers.maxReboots', `Must be between ${min} and ${max}.`);
  // The Windows Update driver policy is explained on the card and in the report, not warned about:
  // the owner default (drivers withheld from Windows Update) is a deliberate, valid combination.
  const ids = new Set<string>();
  for (const v of d.verifiedPackages) {
    if (ids.has(v.id)) err('drivers.verifiedPackages', `Two verified packages have the id "${v.id}".`);
    ids.add(v.id);
    for (const m of verifiedPackageProblems(v)) err('drivers.verifiedPackages', m);
    if (!p.setup.processorArchitectures.includes(v.architecture)) warn('drivers.verifiedPackages', `${v.name}: built for ${v.architecture}, which this answer file does not target.`);
  }
  if (d.verifiedPackages.length && !d.resolveMissing) warn('drivers.verifiedPackages', 'Verified packages are listed but "Resolve missing drivers from verified sources" is off, so they are never used.');
  const known = new Set([...(d.bundle?.packages.map((x) => x.id) ?? []), ...d.verifiedPackages.map((v) => v.id)]);
  for (const a of d.approvals) if (!known.has(a.packageId)) err('drivers.approvals', `Approval for unknown package "${a.packageId}": attach its bundle or add it as a verified package.`);
  if (d.approvals.length && d.optionalReplacements !== 'approvedOnly') warn('drivers.approvals', 'Approvals are ignored while "Replacing a working driver" is set to Never.');
  if (d.bundle) {
    if (!d.includeOfflinePackages) warn('drivers.bundle', 'An offline bundle is attached but "Include approved offline driver packages" is off, so it is not used.');
    const archs = new Set(d.bundle.packages.flatMap((x) => x.architectures));
    if (!p.setup.processorArchitectures.some((a) => archs.has(a))) warn('drivers.bundle', `The bundle has drivers for ${[...archs].join(', ') || 'no architecture'}, not for ${p.setup.processorArchitectures.join(', ')}.`);
    if (d.hardware && d.bundle.source.model && d.hardware.model && d.bundle.source.model !== d.hardware.model) {
      warn('drivers.bundle', `The bundle was exported from a ${d.bundle.source.manufacturer} ${d.bundle.source.model}, the inventory is of a ${d.hardware.manufacturer} ${d.hardware.model}: packages are used only where they match a device, but check that they are the right ones.`);
    }
  }
  if (d.hardware && d.hardware.setupCritical > 0 && !d.bundle?.packages.some((x) => x.setupCritical)) {
    warn('drivers.hardware', `The inventory shows ${d.hardware.setupCritical} storage controller(s) with a non-inbox driver: Windows Setup may not see the disk without it. Attach a bundle that contains that driver (it is placed in $WinPEDriver$ on the USB drive).`);
  }
}

/** Embeds the engine files; the orchestrator runs the installer from its verified package copy. */
export function modify(ctx: GenContext): void {
  if (!driversActive(ctx.profile)) return;
  for (const asset of driverAssets(ctx.profile)) {
    if (EMBEDDED_DRIVER_FILES.includes(asset.name)) ctx.embedFile(`${DRIVER_STAGING_DIR}\\${asset.name}`, asset.content);
  }
}
