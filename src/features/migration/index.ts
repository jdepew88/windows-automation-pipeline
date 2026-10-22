import type { SettingDef } from '../../engine/settings/types';
import type { Profile } from '../../engine/schema/profile';
import type { Issue } from '../../engine/validation/issues';
import { APP_ROOT, MIGRATION_SCRIPT_FILE, RESTORATION_FILE, RESTORE_PLAN_FILE } from '../../engine/applications';
import { installable, resolveSelection } from '../../engine/applications/selection';
import { adapterById } from '../../engine/migration/adapters';
import { settingsRestoreActive } from '../../engine/migration/plan';

/**
 * Phase 6: Application Backup & Restore. The local collector (WdbMigration.ps1) inventories an
 * existing computer and backs up supported settings; the website imports the inventory, reviews
 * every application against the catalog, creates a named profile, and pins the settings backup
 * the deployment restores after installation. No backup content passes through the website.
 */

const APPLIES = 'Inventory and backup: Windows 10/11 with Windows PowerShell 5.1 on the existing computer. Restore: the application stage of the deployment (signed-in user).';

export const settings: SettingDef[] = [
  {
    path: 'migration.source',
    section: 'migration',
    label: 'Inventory of the existing computer',
    control: 'custom',
    description: `Run ${MIGRATION_SCRIPT_FILE} -Mode Inventory on the computer you want to reconstruct, then import its inventory file here. The inventory is read-only: it never changes installed software and contains no passwords, tokens or user names.`,
    applicability: APPLIES,
    stages: ['none'],
    mapping: 'Website only: the inventory is kept in this browser tab; its summary is recorded in the profile (migration.source).',
    advanced: false,
    verification: 'unverified',
  },
  {
    path: 'migration.decisions',
    section: 'migration',
    label: 'Review: what to reinstall',
    control: 'custom',
    description:
      'Every application found, matched against the catalog. Only identifiers that WinGet itself reported are exact matches; a name match is shown as strong or possible and is never installed without your decision. Choose for each: restore automatically, manual installation, optional, or exclude.',
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: `Creates a custom application profile (inherits the base profile) and Additional Software manual entries; the decisions go to applications-config.json › migration and are reported per application in ${RESTORATION_FILE}.`,
    advanced: false,
    verification: 'unverified',
  },
  {
    path: 'migration.backup',
    section: 'migration',
    label: 'Settings backup',
    control: 'custom',
    description: `Create the backup on the existing computer (${MIGRATION_SCRIPT_FILE} -Mode PreviewBackup, then -Mode Backup -Destination <drive>) and attach its backup-manifest.json. Only the manifest is read here: the deployment accepts exactly that backup, identified by the manifest's SHA-256.`,
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: 'applications-config.json › settingsRestore (backupId, manifestSha256, folderName); the backup folder itself goes to the USB drive as WindowsDeployment\\backups\\<folder>.',
    advanced: false,
    verification: 'unverified',
  },
  {
    path: 'migration.settings',
    section: 'migration',
    label: 'Settings to restore',
    control: 'custom',
    description: 'Settings of the backed-up applications are restored after the applications are installed, with the conflict policy you choose. Unsupported applications are listed with the reason.',
    applicability: APPLIES,
    risk: 'Restored settings are personal data: keep the backup on a drive you control. Version-specific settings may not apply to a much newer application version.',
    stages: ['firstLogon'],
    mapping: `ApplicationEngine.ps1 (engine 1.3.0) operations settings:<adapter>, using ${MIGRATION_SCRIPT_FILE}; staged copy under C:\\ProgramData\\WindowsDeploymentBuilder\\Backup; results in ${APP_ROOT}\\result.json and ${RESTORATION_FILE}.`,
    advanced: false,
    verification: 'unverified',
  },
  {
    path: 'migration.followUps',
    section: 'migration',
    label: 'Manual follow-ups for the development environment',
    control: 'custom',
    description: 'Version managers, PowerShell modules, extensions and repositories found by the inventory. They are listed, never installed or cloned automatically.',
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: `applications-config.json › migration.followUps; follow-up.txt and ${RESTORATION_FILE}.`,
    advanced: false,
    verification: 'unverified',
  },
  {
    path: 'migration.enabled',
    section: 'migration',
    label: 'Include the restoration plan in the deployment',
    control: 'checkbox',
    description: `Adds ${RESTORE_PLAN_FILE}, the settings restore and the per-application restoration report to the deployment. The applications themselves are installed by the selected profiles either way.`,
    applicability: APPLIES,
    stages: ['firstLogon'],
    mapping: `applications-config.json › migration / settingsRestore; ${MIGRATION_SCRIPT_FILE} embedded with the application engine when settings are restored.`,
    advanced: false,
    verification: 'unverified',
  },
];

export function validate(p: Profile, issues: Issue[]): void {
  const m = p.migration;
  const enabled = m.settings.filter((s) => s.enabled);
  const err = (path: string, message: string) => issues.push({ severity: 'error', path, message });
  const warn = (path: string, message: string) => issues.push({ severity: 'warning', path, message });
  for (const s of m.settings) if (!adapterById(s.adapterId)) err('migration.settings', `Unknown settings adapter "${s.adapterId}".`);
  if (!m.enabled) return;
  if (enabled.length && !m.backup) err('migration.settings', 'Settings are selected for restore, but no backup manifest is attached.');
  if (m.backup && !enabled.length) warn('migration.settings', 'A backup is attached but no settings are selected for restore.');
  if (enabled.length && !p.applications.enabled) err('migration.settings', 'Settings are restored by the application stage: turn on application provisioning.');
  if (settingsRestoreActive(p)) {
    const selected = new Set(installable(resolveSelection(p.applications.selection)).map((x) => x.key));
    for (const s of enabled) {
      const a = adapterById(s.adapterId);
      if (a && a.requiresApp && a.appKeys.length && !a.appKeys.some((k) => selected.has(k)) && a.id !== 'windows-terminal') {
        warn('migration.settings', `${a.name} is not selected for installation: its settings are restored only if it is already installed on the new computer.`);
      }
      if (s.conflict === 'restoreBackup') warn('migration.settings', `${a?.name ?? s.adapterId}: existing settings on the new computer are replaced (the original is kept as .wdb-before-restore).`);
    }
  }
  const selectedKeys = new Set(resolveSelection(p.applications.selection).packages.map((x) => x.key));
  const missing = m.decisions.filter((d) => d.decision === 'restore' && d.key && !d.key.startsWith('additional:') && !selectedKeys.has(d.key));
  if (missing.length) warn('migration.decisions', `${missing.length} application(s) approved for restoration are no longer in the selection (for example ${missing[0]!.displayName}); tick the migration profile again or create it from the review.`);
}
