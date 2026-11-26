import type { Profile } from '../../engine/schema/profile';
import type { SettingDef } from '../../engine/settings/types';
import type { Issue } from '../../engine/validation/issues';
import { OFFICE_CATALOG, OFFICE_REPOSITORY, OFFICE_SOURCES, OFFICE_TASK_NAME } from '../../engine/office';
import { TASK_PATH } from '../../engine/windows-update';

/**
 * Schema 9: optional Microsoft Office LTSC (Applications page, Basic and Advanced) and the
 * activation preferences (Advanced only: the builder's expert view). Neither is ever switched on by
 * an application profile, by Advanced view or by choosing an Office edition.
 */

const officeOn = (p: Profile) => p.office.product !== 'none';
const MS_DOCS = 'Microsoft Learn: Deploy Office LTSC 2021 / 2024; Activate volume licensed versions of Office';

export const settings: SettingDef[] = [
  {
    path: 'office.product',
    section: 'applications',
    label: 'Microsoft Office LTSC (volume licensed)',
    control: 'radio',
    choices: [
      { value: 'none', label: 'Do not install Office', description: 'Default. Application profiles never install Office.' },
      { value: 'ltsc2024Standard', label: `${OFFICE_CATALOG.ltsc2024Standard.displayName} (current LTSC)`, description: 'Word, Excel, PowerPoint, Outlook, OneNote. Supported until October 2029.' },
      { value: 'ltsc2024ProPlus', label: `${OFFICE_CATALOG.ltsc2024ProPlus.displayName} (current LTSC)`, description: 'Standard plus Access.' },
      { value: 'ltsc2021Standard', label: OFFICE_CATALOG.ltsc2021Standard.displayName, description: 'Legacy: Microsoft support ended on October 13, 2026 (no more security updates). Prefer 2024.' },
      { value: 'ltsc2021ProPlus', label: OFFICE_CATALOG.ltsc2021ProPlus.displayName, description: 'Legacy: Microsoft support ended on October 13, 2026 (no more security updates). Prefer 2024.' },
    ],
    description:
      'Volume-licensed Office LTSC, not Microsoft 365 or a retail edition. Installed with the Office Deployment Tool after Windows Update and the WinGet applications, then verified. Installing does not activate it: see Activation.',
    applicability: 'Windows 10/11; needs a volume license (KMS, Active Directory or MAK) to activate',
    stages: ['firstLogon'],
    mapping: `${TASK_PATH}${OFFICE_TASK_NAME} (SYSTEM) runs Install_Office.ps1 from ${OFFICE_REPOSITORY} (commit ${OFFICE_SOURCES[2024].commit.slice(0, 7)}) with the edition's pinned configuration (Product ID Standard/ProPlus 2021/2024 Volume, channel PerpetualVL2021/PerpetualVL2024).`,
    advanced: false,
    verification: 'unverified',
  },
  {
    path: 'office.removeMsiOffice',
    section: 'applications',
    label: 'Remove Windows Installer (MSI) Office 2016 and earlier first',
    control: 'checkbox',
    description:
      'Adds <RemoveMSI /> to the Office configuration. Off: an existing Office is never removed; the Office stage stops with a follow-up instead. Click-to-Run Office (Microsoft 365, 2019, 2021) is never removed automatically.',
    applicability: 'Office LTSC 2021 / 2024 deployment',
    risk: 'Uninstalls the existing MSI Office suite on the computer.',
    stages: ['firstLogon'],
    mapping: 'Install_Office.ps1 -RemovePreviousVersions (<RemoveMSI />)',
    advanced: true,
    visibleWhen: officeOn,
    verification: 'documented',
  },
  {
    path: 'activation.windows',
    section: 'applications',
    label: 'Windows activation',
    control: 'radio',
    choices: [
      { value: 'none', label: 'No activation action', description: 'Default. Windows activates as it normally would.' },
      { value: 'microsoft', label: 'Microsoft activation', description: 'Digital license, product key or your KMS host, at the end of the deployment.' },
      { value: 'manual', label: 'Technician activates manually', description: 'The deployment only checks and reports the licensing state; the technician confirms in the recovery tool.' },
    ],
    description: 'Runs once at the very end, after every stage and restart, and is reported apart from the installation results. Activated is reported only when Windows itself says it is licensed.',
    applicability: 'Windows 10/11',
    stages: ['firstLogon'],
    mapping: 'Activation.ps1 (deployment monitor, SYSTEM) → SoftwareLicensingProduct.Activate(); result Activation\\result.json',
    advanced: true,
    verification: 'unverified',
  },
  {
    path: 'activation.windowsMethod',
    section: 'applications',
    label: 'Windows: Microsoft activation method',
    control: 'radio',
    choices: [
      { value: 'digitalLicense', label: 'Digital license', description: 'Online activation of the license this hardware or account already has (or the firmware key).' },
      { value: 'productKey', label: 'Product key', description: 'The technician types the key into the recovery tool when asked. It is never stored in the package, the answer file or a log.' },
      { value: 'kms', label: 'KMS (organization)', description: 'Activates against your KMS host. Windows needs a KMS client setup key (volume edition).' },
    ],
    description: 'Only Microsoft licensing mechanisms are automated.',
    applicability: 'Windows 10/11',
    stages: ['firstLogon'],
    mapping: 'SoftwareLicensingService.InstallProductKey / SetKeyManagementServiceMachine; SoftwareLicensingProduct.Activate',
    advanced: true,
    visibleWhen: (p) => p.activation.windows === 'microsoft',
    verification: 'documented',
  },
  {
    path: 'activation.windowsKmsHost',
    section: 'applications',
    label: 'Windows: KMS host (optional)',
    control: 'text',
    placeholder: 'kms.example.org or kms.example.org:1688',
    description: 'Empty: DNS auto-discovery of your organization\'s KMS host.',
    applicability: 'Windows volume editions',
    stages: ['firstLogon'],
    mapping: 'SoftwareLicensingService.SetKeyManagementServiceMachine / Port',
    advanced: true,
    visibleWhen: (p) => p.activation.windows === 'microsoft' && p.activation.windowsMethod === 'kms',
    verification: 'documented',
  },
  {
    path: 'activation.office',
    section: 'applications',
    label: 'Office activation',
    control: 'radio',
    choices: [
      { value: 'none', label: 'No activation action', description: 'Default.' },
      { value: 'microsoft', label: 'Microsoft activation', description: 'KMS, Active Directory or MAK, after Office was installed and verified.' },
      { value: 'manual', label: 'Technician activates manually', description: 'The deployment only checks and reports the licensing state.' },
    ],
    description: 'Independent of Windows activation. Runs only when the Office stage installed and verified Office; otherwise it is reported as blocked, never as an installation failure.',
    applicability: 'Office LTSC 2021 / 2024 volume licensed',
    stages: ['firstLogon'],
    mapping: 'Activation.ps1 → Activate_Office.ps1 (OSPP.VBS) or SoftwareLicensingProduct; result Activation\\result.json',
    advanced: true,
    visibleWhen: officeOn,
    verification: 'unverified',
  },
  {
    path: 'activation.officeMethod',
    section: 'applications',
    label: 'Office: Microsoft activation method',
    control: 'radio',
    choices: [
      { value: 'kms', label: 'KMS (organization)', description: 'Office LTSC installs as a KMS client; activates against your KMS host.' },
      { value: 'activeDirectory', label: 'Active Directory-based activation', description: 'For domain-joined computers in a forest with Active Directory-based activation.' },
      { value: 'mak', label: 'MAK', description: 'The technician types the Multiple Activation Key into the recovery tool when asked. Never stored or logged.' },
    ],
    description: MS_DOCS,
    applicability: 'Office LTSC 2021 / 2024 volume licensed',
    stages: ['firstLogon'],
    mapping: 'Activate_Office.ps1 -KmsHost / -Activate (OSPP.VBS); MAK: SoftwareLicensingService.InstallProductKey',
    advanced: true,
    visibleWhen: (p) => officeOn(p) && p.activation.office === 'microsoft',
    verification: 'documented',
  },
  {
    path: 'activation.officeKmsHost',
    section: 'applications',
    label: 'Office: KMS host (optional)',
    control: 'text',
    placeholder: 'kms.example.org or kms.example.org:1688',
    description: 'Empty: DNS auto-discovery of your organization\'s KMS host.',
    applicability: 'Office LTSC volume licensed',
    stages: ['firstLogon'],
    mapping: 'Activate_Office.ps1 -KmsHost (OSPP.VBS /sethst, /setprt)',
    advanced: true,
    visibleWhen: (p) => officeOn(p) && p.activation.office === 'microsoft' && p.activation.officeMethod === 'kms',
    verification: 'documented',
  },
];

export function validate(p: Profile, issues: Issue[]): void {
  const a = p.activation;
  if (a.office !== 'none' && !officeOn(p)) {
    issues.push({ severity: 'error', path: 'activation.office', message: 'Office activation is selected, but no Office edition is installed by this deployment. Choose an Office edition or set Office activation to "No activation action".' });
  }
  if (p.office.removeMsiOffice && !officeOn(p)) {
    issues.push({ severity: 'warning', path: 'office.removeMsiOffice', message: 'Removing MSI Office is ignored: no Office edition is selected.' });
  }
  if (a.windows === 'microsoft' && a.windowsMethod === 'kms') {
    issues.push({ severity: 'warning', path: 'activation.windowsMethod', message: 'KMS activation works only for a Windows volume edition installed with a KMS client setup key (GVLK) and a reachable KMS host.' });
  }
  if (officeOn(p) && OFFICE_CATALOG[p.office.product as Exclude<Profile['office']['product'], 'none'>].legacy) {
    issues.push({ severity: 'warning', path: 'office.product', message: 'Office LTSC 2021 is a legacy release: Microsoft support ended on October 13, 2026, so it no longer receives security updates. Office LTSC 2024 is the current LTSC release (supported until October 2029).' });
  }
}
