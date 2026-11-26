import activationSource from './scripts/Activation.ps1?raw';
import activateOfficeSource from '../office/vendor/2024/Activate_Office.ps1?raw';
import type { Profile } from '../schema/profile';
import { OFFICE_REPOSITORY, OFFICE_SOURCES, officeActive } from '../office';

/**
 * Optional activation, a separate final stage (Activation.ps1, run by the deployment monitor once
 * every stage is final and Windows needs no further restart). Windows and Office are independent.
 *
 * Only Microsoft licensing mechanisms are automated: online activation of a digital license, KMS,
 * Active Directory-based activation, and a product key or MAK that the technician types into the
 * recovery tool when asked (never stored, logged or put in a file). "manual" leaves activation to
 * the technician's own process and only checks the licensing state afterwards. No third-party
 * activation tool is bundled, downloaded or started.
 */

export const ACTIVATION_SCRIPT = 'scripts/finalization/Activation.ps1';
export const ACTIVATE_OFFICE_SCRIPT = 'scripts/activation/Activate_Office.ps1';
export const ACTIVATION_RESULT_FILE = 'Activation\\result.json';
export const ACTIVATION_STATUSES = ['NotRequested', 'AwaitingTechnician', 'Activated', 'Failed', 'Deferred', 'Blocked', 'Unavailable'] as const;

const crlf = (s: string): string => s.replace(/\r?\n/g, '\r\n');

/** The Office preference counts only when Office is installed by this deployment. */
export const officeActivationAction = (p: Profile) => (officeActive(p) ? p.activation.office : 'none');

export const activationActive = (p: Profile): boolean => p.activation.windows !== 'none' || officeActivationAction(p) !== 'none';

/** True when a person has to act: a key to type, or activation by the technician's own process. */
export function activationNeedsTechnician(p: Profile): boolean {
  const w = p.activation.windows;
  const o = officeActivationAction(p);
  return w === 'manual' || (w === 'microsoft' && p.activation.windowsMethod === 'productKey') || o === 'manual' || (o === 'microsoft' && p.activation.officeMethod === 'mak');
}

const usesOfficeHelper = (p: Profile) => officeActivationAction(p) === 'microsoft' && p.activation.officeMethod !== 'mak';

export function activationPlan(p: Profile) {
  if (!activationActive(p)) return null;
  const w = p.activation.windows;
  const o = officeActivationAction(p);
  return {
    runsAt: 'end of the deployment: after every stage has a final result and Windows needs no further restart (deployment monitor, SYSTEM)',
    windows: { action: w, method: w === 'microsoft' ? p.activation.windowsMethod : null, kmsHost: w === 'microsoft' && p.activation.windowsMethod === 'kms' ? p.activation.windowsKmsHost : '' },
    office: { action: o, method: o === 'microsoft' ? p.activation.officeMethod : null, kmsHost: o === 'microsoft' && p.activation.officeMethod === 'kms' ? p.activation.officeKmsHost : '', requires: 'office' },
    independent: true,
    technicianRequired: activationNeedsTechnician(p),
    containsSecrets: false,
    script: ACTIVATION_SCRIPT,
    officeHelper: usesOfficeHelper(p) ? { script: ACTIVATE_OFFICE_SCRIPT, repository: OFFICE_REPOSITORY, commit: OFFICE_SOURCES[2024].commit } : null,
    result: ACTIVATION_RESULT_FILE,
    verifiedBy: 'SoftwareLicensingProduct.LicenseStatus = 1 (Licensed)',
    technicianCommands: ['DeploymentRecovery.ps1 -Action Activate -Target Windows|Office', 'DeploymentRecovery.ps1 -Action CheckActivation'],
    statuses: [...ACTIVATION_STATUSES],
  };
}

export interface ActivationFile {
  path: string;
  content: string;
  description: string;
}

export function activationFiles(p: Profile): ActivationFile[] {
  if (!activationActive(p)) return [];
  const files: ActivationFile[] = [{ path: ACTIVATION_SCRIPT, content: crlf(activationSource), description: 'Activation stage: Microsoft licensing only, run once at the end; verifies the licensing state' }];
  if (usesOfficeHelper(p)) {
    files.push({ path: ACTIVATE_OFFICE_SCRIPT, content: crlf(activateOfficeSource), description: `Office activation helper (OSPP.VBS: KMS host, Active Directory), ${OFFICE_REPOSITORY} commit ${OFFICE_SOURCES[2024].commit.slice(0, 7)}` });
  }
  return files;
}

const WINDOWS_TEXT = { digitalLicense: 'Microsoft activation (digital license)', productKey: 'Microsoft activation (product key, entered by the technician)', kms: 'Microsoft activation (KMS)' } as const;
const OFFICE_TEXT = { kms: 'Microsoft activation (KMS)', mak: 'Microsoft activation (MAK, entered by the technician)', activeDirectory: 'Microsoft activation (Active Directory)' } as const;

/** One line per target for the review and the package summary. */
export function activationSummary(p: Profile): { windows: string; office: string } {
  const w = p.activation.windows;
  const o = officeActivationAction(p);
  const host = (h: string) => (h ? `, host ${h}` : '');
  return {
    windows: w === 'none' ? 'No activation action' : w === 'manual' ? 'Technician activates manually (checked afterwards)' : `${WINDOWS_TEXT[p.activation.windowsMethod]}${p.activation.windowsMethod === 'kms' ? host(p.activation.windowsKmsHost) : ''}`,
    office: !officeActive(p) ? 'No Office selected' : o === 'none' ? 'No activation action' : o === 'manual' ? 'Technician activates manually (checked afterwards)' : `${OFFICE_TEXT[p.activation.officeMethod]}${p.activation.officeMethod === 'kms' ? host(p.activation.officeKmsHost) : ''}`,
  };
}
