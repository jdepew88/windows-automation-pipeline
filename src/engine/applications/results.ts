import { z } from 'zod';

/**
 * Result contract of the application engine (<dataRoot>\Applications\result.json). The engine
 * writes it; the future orchestrator and the deployment ZIP read it. The JSON Schema below is
 * published as an asset; the Zod schema validates engine output in the tests.
 */

export const PACKAGE_STATUSES = ['Pending', 'Installing', 'Succeeded', 'AlreadyInstalled', 'Skipped', 'SkippedByUser', 'RequiresInteraction', 'RequiresRestart', 'Failed', 'Unavailable'] as const;
export const TERMINAL_STATUSES = ['Succeeded', 'AlreadyInstalled', 'Skipped', 'SkippedByUser', 'RequiresInteraction', 'Failed', 'Unavailable'] as const;
export const FINAL_STATUSES = ['Succeeded', 'CompletedWithFollowUp', 'CompletedWithFailures', 'Failed', 'Offline'] as const;
/** Final statuses for which the completion marker is written. */
export const MARKER_STATUSES = ['Succeeded', 'CompletedWithFollowUp', 'CompletedWithFailures'] as const;
export const BOOTSTRAP_STATUSES = ['NotRun', 'Healthy', 'Repaired', 'NeedsRepair', 'Unsupported', 'Failed'] as const;
/** Phase 5: the operation lifecycle, derived from the status (Get-WdaLifecycle in ApplicationEngine.ps1). */
export const LIFECYCLE_STATES = ['Pending', 'Running', 'Succeeded', 'AlreadySatisfied', 'FailedRetryable', 'FailedPermanent', 'WaitingForNetwork', 'WaitingForReboot', 'ManualActionRequired', 'SkippedByUser', 'BlockedByDependency'] as const;
/**
 * Phase 5: failure classes. The first group is retried automatically, the second never. Engine 1.6.0
 * names them by cause: Download (DOWNLOAD_FAILED) and Source (SOURCE_OPEN_FAILED) next to Network,
 * Installer (the package's own installer failed), HashMismatch (was Integrity), Blocked (policy, was
 * Policy), Unavailable (not in the source / not for this system), RebootRequired (was Restart) and
 * Verification (the installer reported success, but no installation evidence was found).
 */
export const RETRIED_CLASSES = ['Network', 'Download', 'Source', 'Installer', 'Transient', 'Timeout', 'Resource', 'Unknown'] as const;
// Elevation (engine 1.5.0): the installer refuses administrator rights; run once without them, never retried.
// Integrity and Policy: the names engines before 1.6.0 used for HashMismatch and Blocked (resumed states).
export const PERMANENT_CLASSES = ['Permanent', 'Integrity', 'Policy', 'User', 'Manual', 'Elevation', 'HashMismatch', 'Blocked', 'Unavailable'] as const;
export const FAILURE_CLASSES = ['', 'Success', 'Restart', 'RebootRequired', ...RETRIED_CLASSES, ...PERMANENT_CLASSES, 'Dependency', 'Budget', 'Interrupted', 'Verification'] as const;
export const DETECTION_STATES = ['', 'Installed', 'InstalledRequiresRestart', 'NotInstalled', 'Unconfirmed', 'Unknown'] as const;

/**
 * Engine 1.6.0: package-aware verification (Test-WdaVerification in ApplicationEngine.ps1).
 * verification: Verified (installation evidence found), Pending (no evidence yet, but it is expected
 * after a sign-in or a restart, or the user's profile is not available yet; checked again at the
 * engine's next start and by -Mode Verify), Failed (the installer reported success, no evidence),
 * NotApplicable (nothing was installed by this run: failed, unavailable, manual, deselected ...).
 */
export const VERIFICATION_STATES = ['Verified', 'Pending', 'Failed', 'NotApplicable'] as const;
/** Engine 1.6.0: the outcome of every operation, derived from its status and verification. Only InstalledVerified is a success. */
export const OPERATION_OUTCOMES = [
  'InstalledVerified',
  'InstallerSucceededVerificationPending',
  'InstallerSucceededVerificationFailed',
  'InstallationFailed',
  'PackageUnavailable',
  'UnattendedUnsupported',
  'Skipped',
  'RestartOrSignInRequired',
  'ManualSetupRequired',
] as const;
/** Evidence kinds, in the order the engine looks for them. */
export const EVIDENCE_KINDS = ['winget', 'uninstall', 'appx', 'file', 'registry'] as const;
/** Where a piece of evidence was found: the machine, the deployment user's hive or profile, or a provisioned AppX package. */
export const EVIDENCE_WHERE = /^(machine|provisioned|user:.{0,256})$/;
/** -Mode Verify exit codes (ApplicationEngine.ps1 -Mode Verify). */
export const VERIFY_EXIT_CODES = { verified: 0, pending: 10, failed: 20, busyOrError: 1 } as const;

const Attempt = z
  .object({
    trigger: z.enum(['automatic', 'manual']),
    attempt: z.number().int().min(0),
    startUtc: z.string().nullable().optional(),
    endUtc: z.string().nullable().optional(),
    result: z.string(),
    exitCode: z.string().optional(),
    /** Engine 1.4.0: the package installer's own exit code, when WinGet reports one. */
    installerExitCode: z.string().optional(),
    class: z.string(),
    countsTowardLimit: z.boolean(),
    nextAction: z.string(),
    nextAttemptUtc: z.string().nullable().optional(),
    rebootRequired: z.boolean().optional(),
    message: z.string(),
    packageIdentifier: z.string().optional(),
    source: z.string().optional(),
  })
  .strict();

/** Result schema 2 (engine 1.2.0): every operation also carries its lifecycle and attempt history. */
const Resilience = {
  operationId: z.string().regex(/^(app|additional|settings):/),
  lifecycle: z.enum(LIFECYCLE_STATES),
  failureClass: z.enum(FAILURE_CLASSES),
  retryable: z.boolean(),
  detection: z.enum(DETECTION_STATES),
  nextAttemptUtc: z.string().nullable(),
  waitingFor: z.string(),
  totalAttempts: z.number().int().min(0),
  manualRetries: z.number().int().min(0),
  history: z.array(Attempt).max(20),
};

const Evidence = z.object({ kind: z.enum(EVIDENCE_KINDS), detail: z.string().max(600), where: z.string().regex(EVIDENCE_WHERE), version: z.string() }).strict();

/** Engine 1.6.0: verification fields of every package and Additional Software operation. */
const Verification = {
  verification: z.enum(VERIFICATION_STATES),
  verificationEvidence: z.array(Evidence).max(12),
  verificationNote: z.string(),
  outcome: z.enum(OPERATION_OUTCOMES),
};

/** Engine 1.6.0: a hash mismatch, with WinGet's exact message and what the engine did about it. */
const HashMismatch = z
  .object({
    packageIdentifier: z.string(),
    source: z.string(),
    version: z.string(),
    message: z.string().max(500),
    occurrences: z.number().int().min(1),
    sourceUpdated: z.boolean(),
    staleDownloadsRemoved: z.array(z.string()).max(4),
    retried: z.boolean(),
  })
  .strict();

const PackageResult = z
  .object({
    key: z.string(),
    name: z.string(),
    packageIdentifier: z.string(),
    source: z.string(),
    status: z.enum(PACKAGE_STATUSES),
    attempts: z.number().int().min(0),
    exitCode: z.string(),
    /** Engine 1.4.0: the package installer's own exit code, when WinGet reports one. */
    installerExitCode: z.string().optional(),
    message: z.string(),
    timestampUtc: z.string(),
    ...Resilience,
    ...Verification,
    /** Engine 1.6.0: the version the evidence reports (file version, uninstall record, AppX), when known. */
    installedVersion: z.string().optional(),
    hashMismatch: HashMismatch.optional(),
  })
  .strict();

const AdditionalResult = z
  .object({
    id: z.string(),
    name: z.string(),
    status: z.enum(PACKAGE_STATUSES),
    attempts: z.number().int().min(0),
    exitCode: z.string(),
    message: z.string(),
    timestampUtc: z.string(),
    ...Resilience,
    ...Verification,
  })
  .strict();

/** Engine 1.6.0: a Visual C++ runtime found on the computer (Get-WdaRuntimeInventory, read-only). */
export const RUNTIME_ARCHITECTURES = ['x86', 'x64', 'arm64', 'unknown'] as const;
const Runtime = z
  .object({ family: z.string().regex(/^(d{4}(-d{4})?|2015+)$/), architecture: z.enum(RUNTIME_ARCHITECTURES), version: z.string(), displayName: z.string(), source: z.enum(['uninstall', 'runtimeKey']) })
  .strict();

/** Phase 6 (engine 1.3.0): one settings restore operation per adapter, after its application. */
export const RESTORATION_OUTCOMES = [
  'InstalledSuccessfully',
  'AlreadyInstalled',
  'ConfigurationRestored',
  'ConfigurationPartiallyRestored',
  'KeptExisting',
  'ManualActionRequired',
  'WaitingForUser',
  'WaitingForBackup',
  'BlockedByDependency',
  'Unsupported',
  'Failed',
  'SkippedByUser',
  'Pending',
] as const;
export const BACKUP_STAGE_STATUSES = ['NotSearched', 'Staged', 'NotFound', 'Invalid', 'LibraryMissing'] as const;

const SettingsItem = z.object({ logical: z.string(), action: z.enum(['written', 'identical', 'kept', 'replace', 'write', 'partial', 'review', 'failed']), detail: z.string() }).strict();

const SettingsResult = z
  .object({
    id: z.string().regex(/^[a-z0-9][a-z0-9-]{0,31}$/),
    name: z.string(),
    status: z.enum(PACKAGE_STATUSES),
    restoreOutcome: z.enum(RESTORATION_OUTCOMES),
    attempts: z.number().int().min(0),
    message: z.string(),
    timestampUtc: z.string(),
    items: z.array(SettingsItem),
    followUps: z.array(z.string()),
    ...Resilience,
  })
  .strict();

const count = z.number().int().min(0);

export const ApplicationsResultSchema = z
  .object({
    schemaVersion: z.literal(2),
    stage: z.literal('applications'),
    status: z.enum(FINAL_STATUSES),
    reason: z.string(),
    engineVersion: z.string(),
    computer: z.string().nullable(),
    user: z.string().nullable(),
    startedUtc: z.string().nullable(),
    finishedUtc: z.string(),
    starts: count,
    reboots: count,
    bootstrap: z.object({ status: z.enum(BOOTSTRAP_STATUSES), method: z.string(), winGetVersion: z.string(), message: z.string() }).strict(),
    /** Engine 1.6.0: succeeded and alreadyInstalled count verified installations only; verificationPending/verificationFailed the rest. */
    counts: z
      .object({
        total: count,
        succeeded: count,
        alreadyInstalled: count,
        skipped: count,
        skippedByUser: count,
        requiresInteraction: count,
        requiresRestart: count,
        failed: count,
        unavailable: count,
        pending: count,
        verificationPending: count.optional(),
        verificationFailed: count.optional(),
      })
      .strict(),
    packages: z.array(PackageResult),
    additionalSoftware: z.array(AdditionalResult),
    followUp: z.array(z.string()),
    /** Phase 5: everything not done (or not done successfully), kept for the recovery tool. */
    outstanding: z.array(
      z.object({ operationId: z.string(), name: z.string(), status: z.enum(PACKAGE_STATUSES), lifecycle: z.enum(LIFECYCLE_STATES), failureClass: z.enum(FAILURE_CLASSES), retryable: z.boolean(), message: z.string() }).strict(),
    ),
    retryPolicy: z
      .object({ automatic: z.boolean(), maxAttempts: z.number().int().min(1).max(10), baseDelaySeconds: z.number().int().min(0).max(3600), maxDelaySeconds: z.number().int().min(0).max(3600), jitterRatio: z.number().min(0).max(0.5), continueAfterFailure: z.boolean(), maxNetworkDeferrals: z.number().int().min(0).max(24) })
      .strict(),
    recoveries: z.array(z.object({ atUtc: z.string(), by: z.string(), mode: z.enum(['retry', 'retryFailed', 'resume']), accepted: z.array(z.string()), refused: z.array(z.string()), includePermanent: z.boolean() }).strict()),
    stateRecoveredFrom: z.enum(['', 'backup', 'rebuilt']),
    /** Phase 6: present only when the deployment restores application settings. */
    settings: z.array(SettingsResult).optional(),
    settingsBackup: z.object({ status: z.enum(BACKUP_STAGE_STATUSES), message: z.string() }).strict().optional(),
    /** Engine 1.6.0: re-verification starts after the stage finished (pending verifications). */
    reverification: z.object({ starts: count, sinceUtc: z.string(), lastUtc: z.string() }).strict().optional(),
    /** Engine 1.6.0: the Visual C++ runtimes found on the computer (read-only inventory). */
    runtimes: z.array(Runtime).optional(),
  })
  .strict();
export type ApplicationsResult = z.infer<typeof ApplicationsResultSchema>;

const str = { type: 'string' } as const;
const int = { type: 'integer', minimum: 0 } as const;
const nullableStr = { type: ['string', 'null'] } as const;
const resilienceProps = {
  operationId: { type: 'string', pattern: '^(app|additional|settings):' },
  lifecycle: { enum: [...LIFECYCLE_STATES] },
  failureClass: { enum: [...FAILURE_CLASSES] },
  retryable: { type: 'boolean' },
  detection: { enum: [...DETECTION_STATES] },
  nextAttemptUtc: nullableStr,
  waitingFor: str,
  totalAttempts: int,
  manualRetries: int,
  history: { type: 'array', maxItems: 20, items: { type: 'object', required: ['trigger', 'attempt', 'result', 'class', 'countsTowardLimit', 'nextAction', 'message'] } },
};
const RESILIENCE_REQUIRED = Object.keys(resilienceProps);
const verificationProps = {
  verification: { enum: [...VERIFICATION_STATES], description: 'Engine 1.6.0: Verified (installation evidence found), Pending (expected after a sign-in or restart, or the user profile is not available yet; checked again), Failed (the installer reported success, no evidence), NotApplicable.' },
  verificationEvidence: {
    type: 'array',
    maxItems: 12,
    items: {
      type: 'object',
      additionalProperties: false,
      required: ['kind', 'detail', 'where', 'version'],
      properties: { kind: { enum: [...EVIDENCE_KINDS] }, detail: str, where: { type: 'string', pattern: EVIDENCE_WHERE.source }, version: str },
    },
  },
  verificationNote: str,
  outcome: { enum: [...OPERATION_OUTCOMES], description: 'Engine 1.6.0: only InstalledVerified is a success.' },
};
const VERIFICATION_REQUIRED = Object.keys(verificationProps);
const item = (extra: Record<string, unknown>, required: string[]) => ({
  type: 'object',
  additionalProperties: false,
  required: [...required, ...RESILIENCE_REQUIRED, ...VERIFICATION_REQUIRED],
  properties: { ...extra, status: { enum: [...PACKAGE_STATUSES] }, attempts: int, exitCode: str, message: str, timestampUtc: str, ...resilienceProps, ...verificationProps },
});

/** JSON Schema (draft 2020-12) of result.json, published as applications-results.schema.json. */
export const RESULTS_JSON_SCHEMA = {
  $schema: 'https://json-schema.org/draft/2020-12/schema',
  $id: 'https://windows-deployment-builder.local/schemas/applications-result.v2.json',
  title: 'Windows Deployment Builder application stage result',
  description:
    'Written by ApplicationEngine.ps1 to C:\\ProgramData\\WindowsDeploymentBuilder\\Applications\\result.json when the stage reaches a final status. Every selected package appears in "packages" with a terminal status, or "Pending" when it was not attempted. Schema 2 (engine 1.2.0) adds each operation\'s lifecycle, failure class and attempt history, and "outstanding": the work the deployment recovery tool can retry or resume. Engine 1.6.0 adds package-aware verification (verification, verificationEvidence, verificationNote, outcome; only InstalledVerified is a success), the hash-mismatch record, re-verification and the Visual C++ runtime inventory; result.json is rewritten when a pending verification is checked again (next start, or -Mode Verify).',
  type: 'object',
  additionalProperties: false,
  required: ['schemaVersion', 'stage', 'status', 'reason', 'engineVersion', 'finishedUtc', 'starts', 'reboots', 'bootstrap', 'counts', 'packages', 'additionalSoftware', 'followUp', 'outstanding', 'retryPolicy', 'recoveries', 'stateRecoveredFrom'],
  properties: {
    schemaVersion: { const: 2 },
    stage: { const: 'applications' },
    status: { enum: [...FINAL_STATUSES], description: 'The completion marker state\\applications.done is written for Succeeded, CompletedWithFollowUp and CompletedWithFailures.' },
    reason: str,
    engineVersion: str,
    computer: { type: ['string', 'null'] },
    user: { type: ['string', 'null'] },
    startedUtc: { type: ['string', 'null'] },
    finishedUtc: str,
    starts: int,
    reboots: int,
    bootstrap: {
      type: 'object',
      additionalProperties: false,
      required: ['status', 'method', 'winGetVersion', 'message'],
      properties: { status: { enum: [...BOOTSTRAP_STATUSES] }, method: str, winGetVersion: str, message: str },
    },
    counts: {
      type: 'object',
      additionalProperties: false,
      required: ['total', 'succeeded', 'alreadyInstalled', 'skipped', 'skippedByUser', 'requiresInteraction', 'requiresRestart', 'failed', 'unavailable', 'pending'],
      properties: { total: int, succeeded: int, alreadyInstalled: int, skipped: int, skippedByUser: int, requiresInteraction: int, requiresRestart: int, failed: int, unavailable: int, pending: int, verificationPending: int, verificationFailed: int },
    },
    packages: {
      type: 'array',
      items: item(
        {
          key: str,
          name: str,
          packageIdentifier: str,
          source: str,
          installerExitCode: str,
          installedVersion: str,
          hashMismatch: {
            type: 'object',
            additionalProperties: false,
            required: ['packageIdentifier', 'source', 'version', 'message', 'occurrences', 'sourceUpdated', 'staleDownloadsRemoved', 'retried'],
            properties: { packageIdentifier: str, source: str, version: str, message: str, occurrences: { type: 'integer', minimum: 1 }, sourceUpdated: { type: 'boolean' }, staleDownloadsRemoved: { type: 'array', maxItems: 4, items: str }, retried: { type: 'boolean' } },
          },
        },
        ['key', 'name', 'packageIdentifier', 'source', 'status', 'attempts', 'exitCode', 'message', 'timestampUtc'],
      ),
    },
    additionalSoftware: { type: 'array', items: item({ id: str, name: str }, ['id', 'name', 'status', 'attempts', 'exitCode', 'message', 'timestampUtc']) },
    followUp: { type: 'array', items: str },
    outstanding: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['operationId', 'name', 'status', 'lifecycle', 'failureClass', 'retryable', 'message'],
        properties: { operationId: str, name: str, status: { enum: [...PACKAGE_STATUSES] }, lifecycle: { enum: [...LIFECYCLE_STATES] }, failureClass: { enum: [...FAILURE_CLASSES] }, retryable: { type: 'boolean' }, message: str },
      },
    },
    retryPolicy: {
      type: 'object',
      additionalProperties: false,
      required: ['automatic', 'maxAttempts', 'baseDelaySeconds', 'maxDelaySeconds', 'jitterRatio', 'continueAfterFailure', 'maxNetworkDeferrals'],
      properties: {
        automatic: { type: 'boolean' },
        maxAttempts: { type: 'integer', minimum: 1, maximum: 10 },
        baseDelaySeconds: { type: 'integer', minimum: 0, maximum: 3600 },
        maxDelaySeconds: { type: 'integer', minimum: 0, maximum: 3600 },
        jitterRatio: { type: 'number', minimum: 0, maximum: 0.5 },
        continueAfterFailure: { type: 'boolean' },
        maxNetworkDeferrals: { type: 'integer', minimum: 0, maximum: 24 },
      },
    },
    recoveries: { type: 'array', items: { type: 'object' } },
    stateRecoveredFrom: { enum: ['', 'backup', 'rebuilt'] },
    settings: {
      type: 'array',
      description: 'Phase 6 (engine 1.3.0), only when settings are restored: one operation per settings adapter (operationId settings:<adapter>).',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['id', 'name', 'status', 'restoreOutcome', 'attempts', 'message', 'timestampUtc', 'items', 'followUps', ...RESILIENCE_REQUIRED],
        properties: {
          id: { type: 'string', pattern: '^[a-z0-9][a-z0-9-]{0,31}$' },
          name: str,
          status: { enum: [...PACKAGE_STATUSES] },
          restoreOutcome: { enum: [...RESTORATION_OUTCOMES] },
          attempts: int,
          message: str,
          timestampUtc: str,
          items: { type: 'array', items: { type: 'object', required: ['logical', 'action', 'detail'] } },
          followUps: { type: 'array', items: str },
          ...resilienceProps,
        },
      },
    },
    settingsBackup: { type: 'object', additionalProperties: false, required: ['status', 'message'], properties: { status: { enum: [...BACKUP_STAGE_STATUSES] }, message: str } },
    reverification: { type: 'object', additionalProperties: false, required: ['starts', 'sinceUtc', 'lastUtc'], properties: { starts: int, sinceUtc: str, lastUtc: str } },
    runtimes: {
      type: 'array',
      description: 'Engine 1.6.0: Visual C++ runtimes found on the computer (uninstall records and the 2015+ runtime keys), read-only.',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['family', 'architecture', 'version', 'displayName', 'source'],
        properties: { family: str, architecture: { enum: [...RUNTIME_ARCHITECTURES] }, version: str, displayName: str, source: { enum: ['uninstall', 'runtimeKey'] } },
      },
    },
  },
} as const;

/** Phase 6: restoration.json, the per-application restoration result (for the report and the later health check). */
export const RestorationResultSchema = z
  .object({
    format: z.literal('windows-deployment-builder/restoration-result'),
    formatVersion: z.literal(1),
    generatedUtc: z.string(),
    stageStatus: z.enum(FINAL_STATUSES),
    inventoryId: z.string(),
    backupId: z.string(),
    backup: z.object({ status: z.enum([...BACKUP_STAGE_STATUSES, 'None']), message: z.string() }).strict(),
    applications: z.array(z.object({ inventoryId: z.string(), displayName: z.string(), decision: z.enum(['restore', 'manual', 'optional', 'exclude']), key: z.string(), outcome: z.enum(RESTORATION_OUTCOMES), detail: z.string() }).strict()),
    settings: z.array(z.object({ adapterId: z.string(), name: z.string(), outcome: z.enum(RESTORATION_OUTCOMES), detail: z.string(), items: z.array(SettingsItem), followUps: z.array(z.string()), attempts: count }).strict()),
    followUps: z.array(z.string()),
    counts: z.record(z.enum(RESTORATION_OUTCOMES), count),
  })
  .strict();
export type RestorationResult = z.infer<typeof RestorationResultSchema>;

/** WinGet exit codes the engine maps explicitly (mirrors $script:ExitCodes in ApplicationEngine.ps1). */
export const WINGET_EXIT_CODES: Record<string, { status: (typeof PACKAGE_STATUSES)[number]; retry: boolean; restart: 'none' | 'later' | 'now' | 'initiated'; symbol: string; class: (typeof FAILURE_CLASSES)[number] }> = {
  '0x00000000': { status: 'Succeeded', retry: false, restart: 'none', symbol: 'S_OK' , class: 'Success' },
  '0x8A150061': { status: 'AlreadyInstalled', retry: false, restart: 'none', symbol: 'PACKAGE_ALREADY_INSTALLED' , class: 'Success' },
  '0x8A15010D': { status: 'AlreadyInstalled', retry: false, restart: 'none', symbol: 'INSTALL_ALREADY_INSTALLED' , class: 'Success' },
  '0x8A15002B': { status: 'AlreadyInstalled', retry: false, restart: 'none', symbol: 'UPDATE_NOT_APPLICABLE' , class: 'Success' },
  '0x8A15010E': { status: 'AlreadyInstalled', retry: false, restart: 'none', symbol: 'INSTALL_DOWNGRADE' , class: 'Success' },
  '0x8A150109': { status: 'RequiresRestart', retry: false, restart: 'later', symbol: 'INSTALL_REBOOT_REQUIRED_TO_FINISH' , class: 'RebootRequired' },
  '0x8A15010A': { status: 'RequiresRestart', retry: true, restart: 'now', symbol: 'INSTALL_REBOOT_REQUIRED_FOR_INSTALL' , class: 'RebootRequired' },
  '0x8A15010B': { status: 'RequiresRestart', retry: false, restart: 'initiated', symbol: 'INSTALL_REBOOT_INITIATED' , class: 'RebootRequired' },
  '0x00000BC2': { status: 'RequiresRestart', retry: false, restart: 'later', symbol: 'ERROR_SUCCESS_REBOOT_REQUIRED (3010)' , class: 'RebootRequired' },
  '0x00000669': { status: 'RequiresRestart', retry: false, restart: 'initiated', symbol: 'ERROR_SUCCESS_REBOOT_INITIATED (1641)' , class: 'RebootRequired' },
  '0x8A150014': { status: 'Unavailable', retry: false, restart: 'none', symbol: 'NO_APPLICATIONS_FOUND' , class: 'Unavailable' },
  '0x8A150113': { status: 'Unavailable', retry: false, restart: 'none', symbol: 'INSTALL_SYSTEM_NOT_SUPPORTED' , class: 'Unavailable' },
  '0x8A150016': { status: 'Failed', retry: false, restart: 'none', symbol: 'MULTIPLE_APPLICATIONS_FOUND' , class: 'Permanent' },
  '0x8A15010C': { status: 'RequiresInteraction', retry: false, restart: 'none', symbol: 'INSTALL_CANCELLED_BY_USER' , class: 'User' },
  '0x8A150011': { status: 'Failed', retry: false, restart: 'none', symbol: 'INSTALLER_HASH_MISMATCH' , class: 'HashMismatch' },
  '0x8A15003A': { status: 'Failed', retry: false, restart: 'none', symbol: 'BLOCKED_BY_POLICY' , class: 'Blocked' },
  '0x8A15010F': { status: 'Failed', retry: false, restart: 'none', symbol: 'INSTALL_BLOCKED_BY_POLICY' , class: 'Blocked' },
  '0x8A15001B': { status: 'Failed', retry: false, restart: 'none', symbol: 'MSSTORE_BLOCKED_BY_POLICY' , class: 'Blocked' },
  '0x8A15001C': { status: 'Failed', retry: false, restart: 'none', symbol: 'MSSTORE_APP_BLOCKED_BY_POLICY' , class: 'Blocked' },
  '0x8A150041': { status: 'Failed', retry: false, restart: 'none', symbol: 'PACKAGE_AGREEMENTS_NOT_ACCEPTED' , class: 'Permanent' },
  '0x8A150046': { status: 'Failed', retry: false, restart: 'none', symbol: 'SOURCE_AGREEMENTS_NOT_ACCEPTED' , class: 'Permanent' },
  '0x8A150105': { status: 'Failed', retry: false, restart: 'none', symbol: 'INSTALL_DISK_FULL' , class: 'Resource' },
  '0x8A150107': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_NO_NETWORK' , class: 'Network' },
  '0x8A150008': { status: 'Failed', retry: true, restart: 'none', symbol: 'DOWNLOAD_FAILED' , class: 'Download' },
  '0x8A150045': { status: 'Failed', retry: true, restart: 'none', symbol: 'SOURCE_OPEN_FAILED' , class: 'Source' },
  '0x8A150101': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_PACKAGE_IN_USE' , class: 'Transient' },
  '0x8A150102': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_INSTALL_IN_PROGRESS' , class: 'Transient' },
  '0x8A150103': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_FILE_IN_USE' , class: 'Transient' },
  '0x8A150111': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_PACKAGE_IN_USE_BY_APPLICATION' , class: 'Transient' },
  '0x8A150104': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_MISSING_DEPENDENCY' , class: 'Transient' },
  '0x8A150110': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_DEPENDENCIES' , class: 'Transient' },
  '0x8A150106': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_INSUFFICIENT_MEMORY' , class: 'Resource' },
  // Engine 1.4.0: the package's own installer failed; its exit code is kept separately (installerExitCode).
  '0x8A150006': { status: 'Failed', retry: true, restart: 'none', symbol: 'SHELLEXEC_INSTALL_FAILED' , class: 'Installer' },
  // Engine 1.5.0: the manifest forbids an elevated installation; the engine runs it once as the signed-in user without elevation.
  '0x8A150056': { status: 'Failed', retry: false, restart: 'none', symbol: 'INSTALLER_PROHIBITS_ELEVATION' , class: 'Elevation' },
};
