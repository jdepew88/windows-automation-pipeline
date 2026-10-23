import { z } from 'zod';

/**
 * Phase 9: the contract of deployment-health.json (written by DeploymentHealth.ps1) and of the
 * customer handoff data. The PowerShell engine writes these files; the tests validate its output
 * against the Zod schemas below, and the JSON Schema ships in the package.
 */

/** Overall and category states, best to worst (the order is part of the contract). */
export const HEALTH_STATES = ['Ready', 'ReadyWithWarnings', 'NeedsAttention', 'Incomplete', 'Unverifiable', 'Failed'] as const;
export type HealthState = (typeof HEALTH_STATES)[number];
export const CATEGORY_STATES = ['Verified', 'Warning', 'NeedsAttention', 'Incomplete', 'Unverifiable', 'Failed', 'NotApplicable'] as const;
export const SEVERITIES = ['Informational', 'Warning', 'Error', 'Critical'] as const;
/** What one check found. Pass/Info never colour a category green unless something was checked. */
export const FINDING_STATUSES = ['Pass', 'Info', 'Warning', 'Fail', 'Pending', 'Unverifiable', 'Deferred', 'NotApplicable'] as const;
export const SOURCE_STATES = ['ok', 'missing', 'corrupt', 'stale', 'inconsistent', 'notApplicable'] as const;
export const CHECKLIST_STATES = ['done', 'notDone', 'pending', 'confirm', 'notApplicable'] as const;

export const HEALTH_CATEGORIES = [
  { id: 'windows', name: 'Windows' },
  { id: 'accounts', name: 'Accounts and identity' },
  { id: 'updates', name: 'Windows Update' },
  { id: 'drivers', name: 'Hardware and drivers' },
  { id: 'applications', name: 'Applications' },
  { id: 'restoration', name: 'Restored settings' },
  { id: 'security', name: 'Security' },
  { id: 'network', name: 'Network' },
  { id: 'storage', name: 'Storage' },
  { id: 'customizations', name: 'Windows settings' },
  { id: 'recovery', name: 'Recovery and outstanding work' },
] as const;
export type HealthCategoryId = (typeof HEALTH_CATEGORIES)[number]['id'];
const CATEGORY_IDS = HEALTH_CATEGORIES.map((c) => c.id) as [HealthCategoryId, ...HealthCategoryId[]];

/** Phase 5 outcome → what the health engine concludes from it (documented in health-states.md). */
export const PHASE5_OUTCOME_MAP: Record<string, { finding: (typeof FINDING_STATUSES)[number]; severity: (typeof SEVERITIES)[number] }> = {
  Succeeded: { finding: 'Pass', severity: 'Informational' },
  CompletedWithWarnings: { finding: 'Info', severity: 'Informational' },
  CompletedWithFailures: { finding: 'Info', severity: 'Informational' },
  Incomplete: { finding: 'Fail', severity: 'Error' },
  PausedAwaitingNetwork: { finding: 'Pending', severity: 'Warning' },
  PausedAwaitingReboot: { finding: 'Pending', severity: 'Warning' },
  PausedAwaitingUser: { finding: 'Pending', severity: 'Warning' },
  InProgress: { finding: 'Pending', severity: 'Informational' },
  FailedToInitialize: { finding: 'Fail', severity: 'Critical' },
  Failed: { finding: 'Fail', severity: 'Critical' },
};

const str = z.string();
const FINDING_ID = /^[a-z][a-z0-9]*(\.[A-Za-z0-9_:+-]+)+$/;

export const HealthFindingSchema = z
  .object({
    id: z.string().regex(FINDING_ID),
    category: z.enum(CATEGORY_IDS),
    title: str,
    severity: z.enum(SEVERITIES),
    status: z.enum(FINDING_STATUSES),
    required: z.boolean(),
    expected: str,
    observed: str,
    method: str,
    evidence: str,
    timestampUtc: str,
    nextAction: str,
    automaticRecovery: z.boolean(),
    technicianRequired: z.boolean(),
    recoveryAction: str,
  })
  .strict();
export type HealthFinding = z.infer<typeof HealthFindingSchema>;

export const HealthReportSchema = z
  .object({
    format: z.literal('windows-deployment-builder/deployment-health'),
    schemaVersion: z.literal(1),
    engineVersion: str,
    verificationId: z.string().regex(/^[0-9a-f]{16}$/),
    deploymentId: str,
    generatedUtc: str,
    trigger: z.enum(['Technician', 'DeploymentComplete', 'Startup', 'Recovery', 'Test']),
    readOnly: z.literal(true),
    context: z.object({ runAs: str, deploymentUser: str, sameUser: z.boolean().nullable(), userContext: z.enum(['Available', 'Deferred', 'NotNeeded']) }).strict(),
    os: z.object({ computerName: str, caption: str, editionId: str, displayVersion: str, build: str, architecture: str, productType: z.number().int() }).strict(),
    overall: z.object({ status: z.enum(HEALTH_STATES), title: str, summary: str, readyForDelivery: z.boolean(), exitCode: z.number().int() }).strict(),
    categories: z.array(z.object({ id: z.enum(CATEGORY_IDS), name: str, status: z.enum(CATEGORY_STATES), summary: str, findings: z.number().int().min(0) }).strict()),
    findings: z.array(HealthFindingSchema),
    applications: z.array(
      z
        .object({
          key: str,
          name: str,
          source: str,
          packageIdentifier: str,
          method: str,
          kind: z.enum(['automatic', 'manual', 'additional']),
          required: z.boolean(),
          scope: str,
          engineStatus: str,
          lifecycle: str,
          attempts: z.number().int().min(0),
          detection: str,
          independent: z.enum(['Found', 'NotFound', 'Deferred', 'NotChecked']),
          foundIn: str,
          version: str,
          result: str,
          findingId: str,
        })
        .strict(),
    ),
    outstanding: z.array(z.object({ operationId: str, name: str, lifecycle: str, action: str, retryable: z.boolean() }).strict()),
    manualActions: z.array(z.object({ id: str, text: str, url: str }).strict()),
    checklist: z.array(z.object({ id: str, label: str, state: z.enum(CHECKLIST_STATES), note: str, findingIds: z.array(str) }).strict()),
    recovery: z.object({ toolAvailable: z.boolean(), actions: z.array(z.object({ id: str, label: str, command: str, sideEffects: z.boolean() }).strict()) }).strict(),
    backups: z.object({ retained: z.number().int().min(0), bytes: z.number().min(0), location: str, requiredForOutstanding: z.boolean(), cleanup: str }).strict(),
    customizations: z.array(z.object({ id: str, label: str, scope: z.enum(['machine', 'user']), expected: str, observed: str, result: z.enum(FINDING_STATUSES), effect: str, reversible: str }).strict()),
    sources: z.array(z.object({ id: str, file: str, format: str, version: str, generatedUtc: str, state: z.enum(SOURCE_STATES) }).strict()),
    limitations: z.array(str),
    comparison: z
      .object({ previousStatus: str, previousUtc: str, previousVerificationId: str, resolved: z.array(str), new: z.array(str), remaining: z.array(str) })
      .strict()
      .nullable(),
    history: z.array(z.object({ file: str, generatedUtc: str, status: str }).strict()),
  })
  .strict();
export type HealthReport = z.infer<typeof HealthReportSchema>;

/** The customer handoff: plain language, nothing private (no paths, usernames of others, keys or serials). */
export const CustomerHandoffSchema = z
  .object({
    format: z.literal('windows-deployment-builder/customer-handoff'),
    schemaVersion: z.literal(1),
    generatedUtc: str,
    computerName: str,
    windows: str,
    status: z.enum(HEALTH_STATES),
    headline: str,
    statusText: str,
    account: str,
    applications: z.object({ installed: z.array(str), toDoYourself: z.array(z.object({ name: str, how: str }).strict()), notYet: z.array(str) }).strict(),
    security: z.array(z.object({ label: str, state: str }).strict()),
    updates: str,
    actions: z.array(str),
    notes: str,
  })
  .strict();
export type CustomerHandoff = z.infer<typeof CustomerHandoffSchema>;

const s = { type: 'string' } as const;
/** JSON Schema (draft 2020-12) of deployment-health.json, published as deployment-health.schema.json. */
export const HEALTH_REPORT_JSON_SCHEMA = {
  $schema: 'https://json-schema.org/draft/2020-12/schema',
  $id: 'https://windows-deployment-builder.local/schemas/deployment-health.v1.json',
  title: 'Windows Deployment Builder deployment health report',
  description:
    'Written by DeploymentHealth.ps1 to C:\\ProgramData\\WindowsDeploymentBuilder\\reports\\health\\deployment-health.json. Every finding has a stable id, the expected and the observed state, how it was verified and the evidence. Verification is read-only. A finding with status Pass was checked against Windows itself or against evidence that the engine reconciled with Windows; "Deferred" and "Unverifiable" are never shown as success.',
  type: 'object',
  required: ['format', 'schemaVersion', 'engineVersion', 'verificationId', 'deploymentId', 'generatedUtc', 'trigger', 'readOnly', 'context', 'os', 'overall', 'categories', 'findings', 'applications', 'outstanding', 'manualActions', 'checklist', 'recovery', 'backups', 'customizations', 'sources', 'limitations', 'comparison', 'history'],
  properties: {
    format: { const: 'windows-deployment-builder/deployment-health' },
    schemaVersion: { const: 1 },
    overall: {
      type: 'object',
      required: ['status', 'title', 'summary', 'readyForDelivery', 'exitCode'],
      properties: { status: { enum: [...HEALTH_STATES] }, title: s, summary: s, readyForDelivery: { type: 'boolean' }, exitCode: { type: 'integer' } },
    },
    categories: { type: 'array', items: { type: 'object', required: ['id', 'name', 'status', 'summary', 'findings'], properties: { id: { enum: CATEGORY_IDS }, status: { enum: [...CATEGORY_STATES] } } } },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['id', 'category', 'title', 'severity', 'status', 'required', 'expected', 'observed', 'method', 'evidence', 'timestampUtc', 'nextAction', 'automaticRecovery', 'technicianRequired', 'recoveryAction'],
        properties: { id: { type: 'string', pattern: FINDING_ID.source }, category: { enum: CATEGORY_IDS }, severity: { enum: [...SEVERITIES] }, status: { enum: [...FINDING_STATUSES] } },
      },
    },
    sources: { type: 'array', items: { type: 'object', properties: { state: { enum: [...SOURCE_STATES] } } } },
    checklist: { type: 'array', items: { type: 'object', properties: { state: { enum: [...CHECKLIST_STATES] } } } },
  },
} as const;

/**
 * Sample report for the website's preview. Clearly labelled as sample data everywhere it is shown:
 * the website never knows the target computer's real state.
 */
export function sampleHealthReport(mode: 'technician' | 'customer', notes = ''): Record<string, unknown> {
  const t = '2026-10-23T15:42:00.0000000Z';
  const f = (id: string, category: HealthCategoryId, title: string, status: (typeof FINDING_STATUSES)[number], severity: (typeof SEVERITIES)[number], expected: string, observed: string, method: string, nextAction = '', extra: Partial<HealthFinding> = {}): HealthFinding => ({
    id, category, title, severity, status, required: true, expected, observed, method, evidence: 'sample', timestampUtc: t, nextAction, automaticRecovery: false, technicianRequired: status === 'Fail' || status === 'Warning', recoveryAction: '', ...extra,
  });
  const findings: HealthFinding[] = [
    f('windows.edition', 'windows', 'Windows edition', 'Pass', 'Critical', 'Professional (Windows 11 Pro)', 'Professional', 'Registry EditionID'),
    f('windows.activation', 'windows', 'Activation', 'Warning', 'Warning', 'Activated', 'Not activated yet (licence status: notification)', 'SoftwareLicensingProduct', 'Activate Windows with the computer\u2019s digital licence or a valid product key.', { required: false }),
    f('account.exists', 'accounts', 'Local account owner', 'Pass', 'Error', 'owner exists and is enabled', 'owner exists, enabled', 'Local accounts'),
    f('identity.computerName', 'accounts', 'Computer name', 'Pass', 'Error', 'owner-Computer', 'owner-Computer (active)', 'ActiveComputerName'),
    f('updates.stage', 'updates', 'Initial Windows Update', 'Pass', 'Error', 'Every applicable update installed', 'Succeeded: 14 installed, 2 restarts', 'Updates\\result.json + Windows Update Agent'),
    f('drivers.device.display', 'drivers', 'NVIDIA GeForce RTX 3060', 'Pass', 'Error', 'Working driver', 'Working (NVIDIA 32.0.15.8100)', 'Plug and Play'),
    f('app.winget:git.git', 'applications', 'Git', 'Pass', 'Error', 'Installed', 'Installed 2.51.0 (machine)', 'Uninstall registry + engine result'),
    f('app.catalog:rustdesk', 'applications', 'RustDesk', 'Warning', 'Warning', 'Manual follow-up', 'Not installed automatically (no unattended installer)', 'Plan', 'Install it from https://rustdesk.com/download.', { required: false }),
    f('security.antivirus', 'security', 'Antivirus', 'Pass', 'Critical', 'Real-time protection on', 'Microsoft Defender Antivirus, real-time protection on', 'Get-MpComputerStatus + Security Center'),
    f('security.firewall', 'security', 'Firewall', 'Pass', 'Critical', 'On for every profile', 'On: Domain, Private, Public', 'Get-NetFirewallProfile'),
    f('security.recoveryKey', 'security', 'Recovery key backup', 'Warning', 'Warning', 'Recovery key stored by the customer', 'Device encryption on; the recovery key backup cannot be verified from this computer', 'BitLocker key protector types', 'Confirm with the customer where the recovery key is kept (for example the Microsoft account).', { required: false }),
    f('network.internet', 'network', 'Internet', 'Pass', 'Informational', 'Reachable when needed', 'Reachable (Windows connectivity test)', 'msftconnecttest.com'),
    f('storage.freeSpace', 'storage', 'Free space on C:', 'Pass', 'Warning', 'At least 10 GB and 10 %', '402 GB free of 475 GB', 'Get-Volume'),
  ];
  const cats = HEALTH_CATEGORIES.map((c) => {
    const fs = findings.filter((x) => x.category === c.id);
    // A category without checks is never green (as in the real report).
    const st: (typeof CATEGORY_STATES)[number] = fs.some((x) => x.status === 'Warning') ? 'Warning' : fs.length ? 'Verified' : 'NotApplicable';
    return { id: c.id, name: c.name, status: st, summary: fs.length ? `${fs.length} check${fs.length === 1 ? '' : 's'}` : c.id === 'restoration' ? 'Not part of this deployment' : 'Not shown in this sample', findings: fs.length };
  });
  if (mode === 'customer') {
    return {
      sample: true,
      mode: 'customer',
      handoff: {
        format: 'windows-deployment-builder/customer-handoff',
        schemaVersion: 1,
        generatedUtc: t,
        computerName: 'owner-Computer',
        windows: 'Windows 11 Pro',
        status: 'ReadyWithWarnings',
        headline: 'Your computer is ready to use. A few items need your attention.',
        statusText: 'Windows, updates, drivers, applications and security protection were checked on this computer.',
        account: 'owner',
        applications: { installed: ['Google Chrome', 'VLC media player', '7-Zip', 'TeraCopy', 'Bitwarden', 'Git'], toDoYourself: [{ name: 'RustDesk', how: 'Install it from https://rustdesk.com/download.' }], notYet: [] },
        security: [
          { label: 'Virus protection', state: 'On' },
          { label: 'Firewall', state: 'On' },
          { label: 'Device encryption', state: 'On \u2014 keep your recovery key safe' },
        ],
        updates: 'Windows is up to date as of the last check.',
        actions: ['Activate Windows (Settings \u203a System \u203a Activation).', 'Sign in to Bitwarden with your account.', 'Install RustDesk from https://rustdesk.com/download.'],
        notes,
      } satisfies CustomerHandoff,
    };
  }
  return {
    sample: true,
    mode: 'technician',
    report: {
      format: 'windows-deployment-builder/deployment-health',
      schemaVersion: 1,
      engineVersion: 'sample',
      verificationId: '0000000000000000',
      deploymentId: 'SAMPLE0000000000',
      generatedUtc: t,
      trigger: 'DeploymentComplete',
      readOnly: true,
      context: { runAs: 'SYSTEM', deploymentUser: 'owner', sameUser: null, userContext: 'Available' },
      os: { computerName: 'owner-Computer', caption: 'Microsoft Windows 11 Pro', editionId: 'Professional', displayVersion: '25H2', build: '26200.6899', architecture: 'amd64', productType: 1 },
      overall: { status: 'ReadyWithWarnings', title: 'Ready with warnings', summary: 'Every required objective was verified. 3 items need a technician or the customer.', readyForDelivery: true, exitCode: 10 },
      categories: cats,
      findings,
      applications: [
        { key: 'winget:git.git', name: 'Git', source: 'winget', packageIdentifier: 'Git.Git', method: 'winget', kind: 'automatic', required: true, scope: 'machine', engineStatus: 'Succeeded', lifecycle: 'Succeeded', attempts: 1, detection: 'Installed', independent: 'Found', foundIn: 'machine', version: '2.51.0', result: 'InstalledVerified', findingId: 'app.winget:git.git' },
        { key: 'catalog:rustdesk', name: 'RustDesk', source: 'catalog', packageIdentifier: '', method: 'manual', kind: 'manual', required: false, scope: 'unknown', engineStatus: 'RequiresInteraction', lifecycle: 'ManualActionRequired', attempts: 0, detection: '', independent: 'NotFound', foundIn: '', version: '', result: 'ManualInstallationRequired', findingId: 'app.catalog:rustdesk' },
      ],
      outstanding: [],
      manualActions: [{ id: 'app.catalog:rustdesk', text: 'RustDesk: install it from https://rustdesk.com/download.', url: 'https://rustdesk.com/download' }],
      checklist: [
        { id: 'windows', label: 'Windows installed (Windows 11 Pro)', state: 'done', note: '', findingIds: ['windows.edition'] },
        { id: 'activation', label: 'Windows activated, or activation pending clearly identified', state: 'pending', note: 'Not activated yet', findingIds: ['windows.activation'] },
        { id: 'apps', label: 'Selected applications verified', state: 'done', note: '1 manual follow-up', findingIds: ['app.winget:git.git'] },
        { id: 'recoveryKey', label: 'Recovery key arrangement confirmed with the customer', state: 'confirm', note: 'Cannot be measured on this computer', findingIds: ['security.recoveryKey'] },
      ],
      recovery: { toolAvailable: true, actions: [{ id: 'recheck', label: 'Verify again', command: 'DeploymentHealth.ps1', sideEffects: false }] },
      backups: { retained: 0, bytes: 0, location: '', requiredForOutstanding: false, cleanup: '' },
      customizations: [],
      sources: [{ id: 'applications', file: 'Applications\\result.json', format: 'applications-result', version: '2', generatedUtc: t, state: 'ok' }],
      limitations: ['Sample data: the website does not know the target computer.'],
      comparison: null,
      history: [],
    } satisfies HealthReport,
  };
}
