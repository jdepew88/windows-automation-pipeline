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
/** Phase 5: failure classes. The first group is retried automatically, the second never. */
export const RETRIED_CLASSES = ['Network', 'Transient', 'Timeout', 'Resource', 'Unknown'] as const;
export const PERMANENT_CLASSES = ['Permanent', 'Integrity', 'Policy', 'User', 'Manual'] as const;
export const FAILURE_CLASSES = ['', 'Success', 'Restart', ...RETRIED_CLASSES, ...PERMANENT_CLASSES, 'Dependency', 'Budget', 'Interrupted'] as const;
export const DETECTION_STATES = ['', 'Installed', 'InstalledRequiresRestart', 'NotInstalled', 'Unconfirmed', 'Unknown'] as const;

const Attempt = z
  .object({
    trigger: z.enum(['automatic', 'manual']),
    attempt: z.number().int().min(0),
    startUtc: z.string().nullable().optional(),
    endUtc: z.string().nullable().optional(),
    result: z.string(),
    exitCode: z.string().optional(),
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
  operationId: z.string().regex(/^(app|additional):/),
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

const PackageResult = z
  .object({
    key: z.string(),
    name: z.string(),
    packageIdentifier: z.string(),
    source: z.string(),
    status: z.enum(PACKAGE_STATUSES),
    attempts: z.number().int().min(0),
    exitCode: z.string(),
    message: z.string(),
    timestampUtc: z.string(),
    ...Resilience,
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
    counts: z
      .object({ total: count, succeeded: count, alreadyInstalled: count, skipped: count, skippedByUser: count, requiresInteraction: count, requiresRestart: count, failed: count, unavailable: count, pending: count })
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
  })
  .strict();
export type ApplicationsResult = z.infer<typeof ApplicationsResultSchema>;

const str = { type: 'string' } as const;
const int = { type: 'integer', minimum: 0 } as const;
const nullableStr = { type: ['string', 'null'] } as const;
const resilienceProps = {
  operationId: { type: 'string', pattern: '^(app|additional):' },
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
const item = (extra: Record<string, unknown>, required: string[]) => ({
  type: 'object',
  additionalProperties: false,
  required: [...required, ...RESILIENCE_REQUIRED],
  properties: { ...extra, status: { enum: [...PACKAGE_STATUSES] }, attempts: int, exitCode: str, message: str, timestampUtc: str, ...resilienceProps },
});

/** JSON Schema (draft 2020-12) of result.json, published as applications-results.schema.json. */
export const RESULTS_JSON_SCHEMA = {
  $schema: 'https://json-schema.org/draft/2020-12/schema',
  $id: 'https://windows-deployment-builder.local/schemas/applications-result.v2.json',
  title: 'Windows Deployment Builder application stage result',
  description:
    'Written by ApplicationEngine.ps1 to C:\\ProgramData\\WindowsDeploymentBuilder\\Applications\\result.json when the stage reaches a final status. Every selected package appears in "packages" with a terminal status, or "Pending" when it was not attempted. Schema 2 (engine 1.2.0) adds each operation\'s lifecycle, failure class and attempt history, and "outstanding": the work the deployment recovery tool can retry or resume.',
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
      properties: { total: int, succeeded: int, alreadyInstalled: int, skipped: int, skippedByUser: int, requiresInteraction: int, requiresRestart: int, failed: int, unavailable: int, pending: int },
    },
    packages: {
      type: 'array',
      items: item({ key: str, name: str, packageIdentifier: str, source: str }, ['key', 'name', 'packageIdentifier', 'source', 'status', 'attempts', 'exitCode', 'message', 'timestampUtc']),
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
  },
} as const;

/** WinGet exit codes the engine maps explicitly (mirrors $script:ExitCodes in ApplicationEngine.ps1). */
export const WINGET_EXIT_CODES: Record<string, { status: (typeof PACKAGE_STATUSES)[number]; retry: boolean; restart: 'none' | 'later' | 'now' | 'initiated'; symbol: string; class: (typeof FAILURE_CLASSES)[number] }> = {
  '0x00000000': { status: 'Succeeded', retry: false, restart: 'none', symbol: 'S_OK' , class: 'Success' },
  '0x8A150061': { status: 'AlreadyInstalled', retry: false, restart: 'none', symbol: 'PACKAGE_ALREADY_INSTALLED' , class: 'Success' },
  '0x8A15010D': { status: 'AlreadyInstalled', retry: false, restart: 'none', symbol: 'INSTALL_ALREADY_INSTALLED' , class: 'Success' },
  '0x8A15002B': { status: 'AlreadyInstalled', retry: false, restart: 'none', symbol: 'UPDATE_NOT_APPLICABLE' , class: 'Success' },
  '0x8A15010E': { status: 'AlreadyInstalled', retry: false, restart: 'none', symbol: 'INSTALL_DOWNGRADE' , class: 'Success' },
  '0x8A150109': { status: 'RequiresRestart', retry: false, restart: 'later', symbol: 'INSTALL_REBOOT_REQUIRED_TO_FINISH' , class: 'Restart' },
  '0x8A15010A': { status: 'RequiresRestart', retry: true, restart: 'now', symbol: 'INSTALL_REBOOT_REQUIRED_FOR_INSTALL' , class: 'Restart' },
  '0x8A15010B': { status: 'RequiresRestart', retry: false, restart: 'initiated', symbol: 'INSTALL_REBOOT_INITIATED' , class: 'Restart' },
  '0x00000BC2': { status: 'RequiresRestart', retry: false, restart: 'later', symbol: 'ERROR_SUCCESS_REBOOT_REQUIRED (3010)' , class: 'Restart' },
  '0x00000669': { status: 'RequiresRestart', retry: false, restart: 'initiated', symbol: 'ERROR_SUCCESS_REBOOT_INITIATED (1641)' , class: 'Restart' },
  '0x8A150014': { status: 'Unavailable', retry: false, restart: 'none', symbol: 'NO_APPLICATIONS_FOUND' , class: 'Permanent' },
  '0x8A150113': { status: 'Unavailable', retry: false, restart: 'none', symbol: 'INSTALL_SYSTEM_NOT_SUPPORTED' , class: 'Permanent' },
  '0x8A150016': { status: 'Failed', retry: false, restart: 'none', symbol: 'MULTIPLE_APPLICATIONS_FOUND' , class: 'Permanent' },
  '0x8A15010C': { status: 'RequiresInteraction', retry: false, restart: 'none', symbol: 'INSTALL_CANCELLED_BY_USER' , class: 'User' },
  '0x8A150011': { status: 'Failed', retry: false, restart: 'none', symbol: 'INSTALLER_HASH_MISMATCH' , class: 'Integrity' },
  '0x8A15003A': { status: 'Failed', retry: false, restart: 'none', symbol: 'BLOCKED_BY_POLICY' , class: 'Policy' },
  '0x8A15010F': { status: 'Failed', retry: false, restart: 'none', symbol: 'INSTALL_BLOCKED_BY_POLICY' , class: 'Policy' },
  '0x8A15001B': { status: 'Failed', retry: false, restart: 'none', symbol: 'MSSTORE_BLOCKED_BY_POLICY' , class: 'Policy' },
  '0x8A15001C': { status: 'Failed', retry: false, restart: 'none', symbol: 'MSSTORE_APP_BLOCKED_BY_POLICY' , class: 'Policy' },
  '0x8A150041': { status: 'Failed', retry: false, restart: 'none', symbol: 'PACKAGE_AGREEMENTS_NOT_ACCEPTED' , class: 'Permanent' },
  '0x8A150046': { status: 'Failed', retry: false, restart: 'none', symbol: 'SOURCE_AGREEMENTS_NOT_ACCEPTED' , class: 'Permanent' },
  '0x8A150105': { status: 'Failed', retry: false, restart: 'none', symbol: 'INSTALL_DISK_FULL' , class: 'Resource' },
  '0x8A150107': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_NO_NETWORK' , class: 'Network' },
  '0x8A150008': { status: 'Failed', retry: true, restart: 'none', symbol: 'DOWNLOAD_FAILED' , class: 'Network' },
  '0x8A150045': { status: 'Failed', retry: true, restart: 'none', symbol: 'SOURCE_OPEN_FAILED' , class: 'Network' },
  '0x8A150101': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_PACKAGE_IN_USE' , class: 'Transient' },
  '0x8A150102': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_INSTALL_IN_PROGRESS' , class: 'Transient' },
  '0x8A150103': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_FILE_IN_USE' , class: 'Transient' },
  '0x8A150111': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_PACKAGE_IN_USE_BY_APPLICATION' , class: 'Transient' },
  '0x8A150104': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_MISSING_DEPENDENCY' , class: 'Transient' },
  '0x8A150110': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_DEPENDENCIES' , class: 'Transient' },
  '0x8A150106': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_INSUFFICIENT_MEMORY' , class: 'Resource' },
};
