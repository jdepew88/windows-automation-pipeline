import type { SettingDef } from '../../engine/settings/types';
import type { Profile } from '../../engine/schema/profile';
import type { Issue } from '../../engine/validation/issues';
import { resolveSelection } from '../../engine/applications/selection';
import { HEALTH_CONFIG_FILE, HEALTH_ENGINE_FILE, HEALTH_REPORT_DIR, HEALTH_SHORTCUT } from '../../engine/health';

/**
 * Phase 9: Deployment Verification & Health. The installed computer checks itself at the end of
 * the deployment: read-only, against Windows itself, never trusting an exit code alone. The
 * integrity of the results and the security checks cannot be switched off here.
 */

const on = (p: Profile) => p.health.enabled;
const APPLIES = 'Windows 11 (Windows PowerShell 5.1); runs as SYSTEM at the end of the deployment and on demand as administrator';

const flag = (path: string, label: string, description: string, mapping: string, advanced = false): SettingDef => ({
  path,
  section: 'health',
  label,
  control: 'checkbox',
  description,
  applicability: APPLIES,
  stages: ['firstLogon'],
  mapping,
  advanced,
  visibleWhen: on,
  verification: 'unverified',
});

export const settings: SettingDef[] = [
  {
    path: 'health.enabled',
    section: 'health',
    label: 'Verify the deployment automatically when it finishes',
    control: 'checkbox',
    description:
      'Checks the edition, account, computer name, Windows Update, the selected applications, restored settings, devices, Defender and the firewall, encryption, the network and the system drive against Windows itself, and writes a technician report and a customer handoff. Read-only: it never installs, removes, restarts or changes anything.',
    applicability: APPLIES,
    risk: 'Tested with simulated computers only; validate on a spare computer before relying on it.',
    stages: ['firstLogon'],
    mapping: `Embeds ${HEALTH_ENGINE_FILE}, ${HEALTH_CONFIG_FILE} and the report template. Complete-Deployment.ps1 runs it once the deployment is complete (again after a pending restart); reports in ${HEALTH_REPORT_DIR}; desktop shortcut "${HEALTH_SHORTCUT}".`,
    advanced: false,
    verification: 'unverified',
  },
  flag('health.technicianReport', 'Generate the technician report', 'An offline HTML dashboard with every check, its evidence and the next action; print it or save it as PDF from the browser.', `${HEALTH_REPORT_DIR}\\technician-report.html`),
  flag('health.customerReport', 'Generate the customer handoff report', 'A plain summary for the person receiving the computer: what is installed, protection, updates and what they still need to do. No passwords, keys or private paths.', `${HEALTH_REPORT_DIR}\\customer-handoff.html`),
  flag('health.openReportAfterDeployment', 'Open the technician report when the deployment finishes', 'Once, from the progress window. It never opens at later sign-ins.', 'Show-DeploymentStatus.ps1 -Watch opens technician-report.html once'),
  flag('health.keepHistory', 'Keep the history of earlier reports', 'Every re-check keeps the previous report, so a fixed problem shows as resolved. Off: only the first and the previous report are kept. The record of the first verification is never removed.', `${HEALTH_REPORT_DIR}\\history (up to 50 reports, or the first and the previous one)`, true),
  flag('health.storageObservations', 'Include drive health observations', 'Read-only health, wear and temperature counters where the drive reports them. Not a full diagnosis; no disk test or surface scan is run.', 'Get-PhysicalDisk, Get-StorageReliabilityCounter', true),
  {
    path: 'health.networkRequirement',
    section: 'health',
    label: 'Internet during verification',
    control: 'radio',
    choices: [
      { value: 'auto', label: 'Required only while outstanding work needs it (owner default)', description: 'A finished, deliberately offline computer is not reported as broken.' },
      { value: 'required', label: 'Always required', description: 'No Internet blocks "Ready".' },
      { value: 'notRequired', label: 'Never required', description: 'Connectivity is reported for information only.' },
    ],
    description: 'Connectivity is judged from a connected adapter, a gateway, DNS and the Windows connectivity test, never from a single ping.',
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: `${HEALTH_CONFIG_FILE} › network.requirement`,
    advanced: true,
    visibleWhen: on,
    verification: 'unverified',
  },
  {
    path: 'health.optionalApps',
    section: 'health',
    label: 'Applications that may be missing without blocking delivery',
    control: 'custom',
    description: 'A selected application that fails to install normally means "Needs attention". Applications ticked here give "Ready with warnings" instead, with a manual action. Manual follow-ups are always optional.',
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: `${HEALTH_CONFIG_FILE} › applications.items[].required`,
    advanced: false,
    visibleWhen: on,
    verification: 'unverified',
  },
  {
    path: 'health.customerNotes',
    section: 'health',
    label: 'Technician notes for the customer report',
    control: 'custom',
    description: 'Printed in the customer handoff report. Do not write passwords, keys or Wi-Fi details here.',
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: `${HEALTH_CONFIG_FILE} › customerNotes`,
    advanced: false,
    visibleWhen: on,
    verification: 'unverified',
  },
];

/** Text that looks like a password, a key or a product key (the notes are printed for the customer). */
export const SECRET_LIKE = /(\b(password|passwd|pwd|passphrase|pin|wifi key|wi-fi key|network key|recovery key|product key)\b\s*[:=])|(\b[A-Z0-9]{5}(-[A-Z0-9]{5}){4}\b)|(\b\d{6}(-\d{6}){7}\b)/i;

export function validate(p: Profile, issues: Issue[]): void {
  const h = p.health;
  if (SECRET_LIKE.test(h.customerNotes)) {
    issues.push({ severity: 'error', path: 'health.customerNotes', message: 'The notes look like they contain a password, a product key or a recovery key. The customer report is printed and shared: remove it.' });
  }
  if (h.optionalApps.length) {
    const keys = new Set([...resolveSelection(p.applications.selection).packages.map((x) => x.key), ...p.additionalSoftware.items.map((i) => `additional:${i.id.toLowerCase()}`)]);
    const stale = h.optionalApps.filter((k) => !keys.has(k));
    if (stale.length) issues.push({ severity: 'warning', path: 'health.optionalApps', message: `${stale.length} application(s) marked optional are no longer selected and are ignored.` });
  }
}
