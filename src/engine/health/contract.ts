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
  { id: 'hardwareSoftware', name: 'Manufacturer software' },
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
const int = z.number().int();

/**
 * How an application's installation was verified (never from an exit code alone). Health engine 1.1.0
 * states, extended compatibly by 1.2.0 (package-aware evidence from the catalog's verify block):
 *   InstalledAndVerified                   evidence found NOW (uninstall record, Store package, file, registry value)
 *   InstallerSucceededVerificationPending  the installer succeeded; no evidence yet, and it can only appear later
 *                                          (after sign-in or a restart, or in the deployment user's profile, which
 *                                          cannot be read now: signed out, no profile yet, or another account)
 *   InstallerSucceededVerificationFailed   the installer succeeded, the evidence could be checked, and none was found
 *   InstallerSucceededUnverified           health engine 1.1.0 only (older reports); 1.2.0 reports the two above
 *   PackageUnavailable / UnattendedUnsupported  the package was not offered, or cannot be installed without a person
 */
export const APP_VERIFICATION_STATES = [
  'InstalledAndVerified',
  'InstallerSucceededVerificationPending',
  'InstallerSucceededVerificationFailed',
  'InstallerSucceededUnverified',
  'Missing',
  'Failed',
  'PackageUnavailable',
  'UnattendedUnsupported',
  'ManualActionRequired',
  'NotSelected',
  'Pending',
  'Deferred',
] as const;
/** Kinds of installation evidence (the application engine 1.6.0 uses the same names in result.json). */
export const APP_EVIDENCE_KINDS = ['winget', 'uninstall', 'appx', 'file', 'registry'] as const;
/** One piece of evidence: where is "machine", "user:<account>" or "provisioned" (a Store package staged for every user). */
export const AppEvidenceSchema = z.object({ kind: z.enum(APP_EVIDENCE_KINDS), detail: z.string(), where: z.string(), version: z.string() }).strict();
/** Visual C++ runtime families the inventory distinguishes (2015+ is the shared v14 runtime: 2015-2022 and later). */
export const RUNTIME_FAMILIES = ['2015+', '2013', '2012', '2010', '2008', '2005'] as const;
const RUNTIME_ARCHS = ['x64', 'x86', 'arm64'] as const;
export const RuntimeInventorySchema = z
  .object({
    checkedUtc: z.string(),
    osArchitecture: z.string(),
    available: z.boolean(),
    source: z.string(),
    items: z.array(z.object({ family: z.enum(RUNTIME_FAMILIES), architecture: z.enum(RUNTIME_ARCHS), version: z.string(), displayName: z.string(), where: z.string() }).strict()),
    selected: z.array(z.object({ key: z.string(), name: z.string(), family: z.enum(RUNTIME_FAMILIES), architecture: z.enum(RUNTIME_ARCHS), present: z.boolean(), version: z.string() }).strict()),
    notes: z.array(z.string()),
    findingId: z.string(),
  })
  .strict();
/** Health engine 1.2.0, -CheckAppUpdates: a read-only "winget upgrade" listing (never as SYSTEM, never an installation). */
export const APP_UPDATE_CHECK_STATES = ['ok', 'notAsSystem', 'wingetUnavailable', 'failed'] as const;
export const AppUpdatesSchema = z
  .object({
    checkedUtc: z.string(),
    status: z.enum(APP_UPDATE_CHECK_STATES),
    runAs: z.string(),
    asDeploymentUser: z.boolean().nullable(),
    exitCode: z.string(),
    items: z.array(z.object({ key: z.string(), name: z.string(), id: z.string(), installed: z.string(), available: z.string(), source: z.string() }).strict()),
    otherAvailable: z.number().int().min(0),
    problems: z.array(z.string()),
    note: z.string(),
    findingId: z.string(),
  })
  .strict();
/** The update engine's (2.1.0) final state, and the finding the health engine makes of it. Never "Pass" because installation finished. */
export const UPDATE_STATES = ['UpToDate', 'UpToDateUnderPolicy', 'PreviewUpdatesExcluded', 'RestartRequired', 'UpdatesRemaining', 'InstallationIncomplete', 'CompletedWithFailures', 'VerificationUnavailable'] as const;
export const UPDATE_STATE_FINDING: Record<(typeof UPDATE_STATES)[number], 'Pass' | 'Warning' | 'Fail' | 'Unverifiable'> = {
  UpToDate: 'Pass',
  UpToDateUnderPolicy: 'Pass',
  PreviewUpdatesExcluded: 'Pass',
  RestartRequired: 'Warning',
  UpdatesRemaining: 'Warning',
  InstallationIncomplete: 'Fail',
  CompletedWithFailures: 'Fail',
  VerificationUnavailable: 'Unverifiable',
};
export const RETRY_RUN_STATES = ['Finished', 'RunningOrAwaitingRestart', 'StoppedBeforeFinishing'] as const;
export const DEVICE_COMPARISON_STATES = ['NowHealthy', 'StillHasProblem', 'NotPresent'] as const;
export const MANUFACTURER_UTILITIES = ['nvidiaApp', 'amdAdrenalin', 'amdRyzenMaster'] as const;

/** One engine result.json (the deployment's or a retry run's); fields of engine 2.1.0 are '' or null when absent. */
const UpdateResultViewSchema = z
  .object({
    source: str,
    label: str,
    engineVersion: str,
    status: str,
    updateState: str,
    updateStateText: str,
    startedUtc: str,
    finishedUtc: str,
    installed: int.min(0),
    failed: int.min(0),
    summary: z.record(z.string(), int).nullable(),
    verification: z.object({ remainingOffered: int.nullable(), noLongerOffered: int.min(0), devicesWithProblems: int.min(0), rebootPending: z.boolean().nullable() }).strict().nullable(),
  })
  .strict();

export const WindowsUpdateHealthSchema = z
  .object({
    partOfDeployment: z.boolean(),
    checkedUtc: str,
    original: UpdateResultViewSchema.nullable(),
    current: UpdateResultViewSchema.nullable(),
    policy: z
      .object({ source: str, featureUpdates: str, optionalUpdates: str, drivers: str, previewUpdates: z.boolean().nullable(), previewSource: z.enum(['policy', 'configuration', 'optionalUpdates', 'unknown']), maxAttemptsPerUpdate: int.nullable() })
      .strict()
      .nullable(),
    settingsRefresh: z
      .object({ from: str, available: z.boolean(), requested: z.boolean(), completed: z.boolean(), attempt: str, requestedUtc: str, completedUtc: str, lastSuccessfulScanBefore: str, lastSuccessfulScanAfter: str, settingsDisplayVerified: z.literal(false), message: str })
      .strict()
      .nullable(),
    orchestrator: z.object({ available: z.boolean(), lastSuccessfulScanUtc: str, isScanning: z.boolean().nullable(), isWorking: z.boolean().nullable() }).strict().nullable(),
    retries: z.array(z.object({ runId: str, selection: str, final: str, state: z.enum(RETRY_RUN_STATES), taskPresent: z.boolean(), engineVersion: str, status: str, updateState: str, installed: int.min(0), failed: int.min(0), finishedUtc: str, findingId: str }).strict()),
    originalFailures: z.array(z.object({ title: str, kbs: z.array(str), category: str, class: str, lastHResult: str, laterInstalled: z.boolean(), installedUtc: str, installedBy: str, findingId: str }).strict()),
    drivers: z.array(z.object({ title: str, model: str, hardwareId: str, result: str, installedBy: str }).strict()),
    liveScan: z.object({ performed: z.boolean(), required: int.min(0), optional: int.min(0), drivers: int.min(0), feature: int.min(0) }).strict().nullable(),
  })
  .strict();

export const DeviceComparisonSchema = z
  .object({ name: str, hardwareIds: z.array(str), deviceId: str, previousProblemCode: int, currentProblemCode: int.nullable(), state: z.enum(DEVICE_COMPARISON_STATES), source: str, findingId: str })
  .strict();

export const OfficeHealthSchema = z
  .object({
    selected: z.literal(true),
    product: str,
    displayName: str,
    expectedProductReleaseId: str,
    present: z.boolean().nullable(),
    productReleaseIds: z.array(str),
    version: str,
    platform: str,
    engineStatus: str,
    engineVerified: z.boolean(),
    result: z.enum(['InstalledAndVerified', 'DifferentProduct', 'Pending', 'InstallerSucceededUnverified', 'Missing', 'Unverifiable']),
    activation: z.object({ requested: str, status: str, verified: z.boolean(), message: str, source: str }).strict(),
    checkedUtc: str,
  })
  .strict();

/** A manufacturer utility recommendation: information only, never installed automatically. */
export const HardwareSoftwareSchema = z
  .object({
    id: z.enum(MANUFACTURER_UTILITIES),
    utility: str,
    vendor: str,
    recommended: z.literal(true),
    detectedHardware: str,
    compatibility: str,
    installed: z.boolean().nullable(),
    installedVersion: str,
    automaticInstall: z.literal(false),
    automaticInstallReason: str,
    manualAction: str,
    url: z.string().url(),
    signIn: str,
    notes: str,
    findingId: str,
    checkedUtc: str,
  })
  .strict();
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
          verification: z.enum(APP_VERIFICATION_STATES),
          findingId: str,
          /** Health engine 1.2.0 (absent from older reports): the evidence found now, and the engine's own record of it (history). */
          evidence: z.array(AppEvidenceSchema).optional(),
          engineEvidence: z.array(AppEvidenceSchema).optional(),
          /** Application engine 1.6.0 fields as recorded ('' for older engines). */
          outcome: str.optional(),
          engineVerification: str.optional(),
          failureClass: str.optional(),
          verificationNote: str.optional(),
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
    windowsUpdate: WindowsUpdateHealthSchema.nullable(),
    deviceComparison: z.array(DeviceComparisonSchema),
    office: OfficeHealthSchema.nullable(),
    hardwareSoftware: z.array(HardwareSoftwareSchema),
    /** Health engine 1.2.0 (absent from older reports). */
    runtimes: RuntimeInventorySchema.nullable().optional(),
    appUpdates: AppUpdatesSchema.nullable().optional(),
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
    applications: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          verification: { enum: [...APP_VERIFICATION_STATES] },
          evidence: { type: 'array', description: 'Health engine 1.2.0: evidence found now (kind, detail, where: machine | user:<account> | provisioned, version).', items: { type: 'object', properties: { kind: { enum: [...APP_EVIDENCE_KINDS] } } } },
          engineEvidence: { type: 'array', description: "The application engine's own verification evidence as recorded (history, not the current state)." },
          outcome: { type: 'string', description: 'Application engine 1.6.0 outcome as recorded, or empty.' },
        },
      },
    },
    runtimes: {
      type: ['object', 'null'],
      description: 'Health engine 1.2.0: Visual C++ runtimes in the uninstall records, by family and architecture (x86 and x64 are separate: 32-bit applications need the x86 runtime on 64-bit Windows).',
      properties: { items: { type: 'array', items: { type: 'object', properties: { family: { enum: [...RUNTIME_FAMILIES] }, architecture: { enum: [...RUNTIME_ARCHS] } } } } },
    },
    appUpdates: {
      type: ['object', 'null'],
      description: 'Health engine 1.2.0 with -CheckAppUpdates: a read-only "winget upgrade" listing for the selected applications. Not possible as SYSTEM (status notAsSystem). Nothing is installed.',
      properties: { status: { enum: [...APP_UPDATE_CHECK_STATES] } },
    },
    windowsUpdate: {
      type: ['object', 'null'],
      description:
        'Health engine 1.1.0: the update engine results (deployment and every Retry Windows Update run) as recorded; "current" is the most recent finished one. "original" stays the historical record; originalFailures says which were installed later (retry result or Windows Update history). settingsRefresh.settingsDisplayVerified is always false.',
      properties: {
        current: { type: ['object', 'null'], properties: { updateState: { type: 'string', description: `One of ${UPDATE_STATES.join(', ')}, or empty for update engines before 2.1.0` } } },
        retries: { type: 'array', items: { type: 'object', properties: { state: { enum: [...RETRY_RUN_STATES] } } } },
      },
    },
    deviceComparison: { type: 'array', description: 'Devices the deployment reported with problems, compared with Device Manager now.', items: { type: 'object', properties: { state: { enum: [...DEVICE_COMPARISON_STATES] } } } },
    office: { type: ['object', 'null'], description: 'Microsoft Office when this deployment selected it: Click-to-Run registry; activation as the activation stage recorded it (never a key or a KMS host).' },
    hardwareSoftware: {
      type: 'array',
      description: 'Optional manufacturer utilities recommended for the detected hardware. Information only: automaticInstall is always false.',
      items: { type: 'object', properties: { id: { enum: [...MANUFACTURER_UTILITIES] }, automaticInstall: { const: false } } },
    },
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
        { key: 'winget:git.git', name: 'Git', source: 'winget', packageIdentifier: 'Git.Git', method: 'winget', kind: 'automatic', required: true, scope: 'machine', engineStatus: 'Succeeded', lifecycle: 'Succeeded', attempts: 1, detection: 'Installed', independent: 'Found', foundIn: 'machine', version: '2.51.0', result: 'InstalledVerified', verification: 'InstalledAndVerified', findingId: 'app.winget:git.git', evidence: [{ kind: 'uninstall', detail: 'Uninstall record "Git"', where: 'machine', version: '2.51.0' }, { kind: 'file', detail: '%ProgramFiles%\\Git\\cmd\\git.exe', where: 'machine', version: '2.51.0.1' }], outcome: 'InstalledVerified' },
        { key: 'catalog:rustdesk', name: 'RustDesk', source: 'catalog', packageIdentifier: '', method: 'manual', kind: 'manual', required: false, scope: 'unknown', engineStatus: 'RequiresInteraction', lifecycle: 'ManualActionRequired', attempts: 0, detection: '', independent: 'NotFound', foundIn: '', version: '', result: 'ManualInstallationRequired', verification: 'ManualActionRequired', findingId: 'app.catalog:rustdesk' },
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
      windowsUpdate: null,
      deviceComparison: [],
      office: null,
      hardwareSoftware: [],
    } satisfies HealthReport,
  };
}
