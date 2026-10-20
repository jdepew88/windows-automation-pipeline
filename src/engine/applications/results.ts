import { z } from 'zod';

/**
 * Result contract of the application engine (<dataRoot>\Applications\result.json). The engine
 * writes it; the future orchestrator and the deployment ZIP read it. The JSON Schema below is
 * published as an asset; the Zod schema validates engine output in the tests.
 */

export const PACKAGE_STATUSES = ['Pending', 'Installing', 'Succeeded', 'AlreadyInstalled', 'Skipped', 'RequiresInteraction', 'RequiresRestart', 'Failed', 'Unavailable'] as const;
export const TERMINAL_STATUSES = ['Succeeded', 'AlreadyInstalled', 'Skipped', 'RequiresInteraction', 'Failed', 'Unavailable'] as const;
export const FINAL_STATUSES = ['Succeeded', 'CompletedWithFollowUp', 'CompletedWithFailures', 'Failed', 'Offline'] as const;
/** Final statuses for which the completion marker is written. */
export const MARKER_STATUSES = ['Succeeded', 'CompletedWithFollowUp', 'CompletedWithFailures'] as const;
export const BOOTSTRAP_STATUSES = ['NotRun', 'Healthy', 'Repaired', 'NeedsRepair', 'Unsupported', 'Failed'] as const;

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
  })
  .strict();

const count = z.number().int().min(0);

export const ApplicationsResultSchema = z
  .object({
    schemaVersion: z.literal(1),
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
      .object({ total: count, succeeded: count, alreadyInstalled: count, skipped: count, requiresInteraction: count, requiresRestart: count, failed: count, unavailable: count, pending: count })
      .strict(),
    packages: z.array(PackageResult),
    additionalSoftware: z.array(AdditionalResult),
    followUp: z.array(z.string()),
  })
  .strict();
export type ApplicationsResult = z.infer<typeof ApplicationsResultSchema>;

const str = { type: 'string' } as const;
const int = { type: 'integer', minimum: 0 } as const;
const item = (extra: Record<string, unknown>, required: string[]) => ({
  type: 'object',
  additionalProperties: false,
  required,
  properties: { ...extra, status: { enum: [...PACKAGE_STATUSES] }, attempts: int, exitCode: str, message: str, timestampUtc: str },
});

/** JSON Schema (draft 2020-12) of result.json, published as applications-results.schema.json. */
export const RESULTS_JSON_SCHEMA = {
  $schema: 'https://json-schema.org/draft/2020-12/schema',
  $id: 'https://windows-deployment-builder.local/schemas/applications-result.v1.json',
  title: 'Windows Deployment Builder application stage result',
  description:
    'Written by ApplicationEngine.ps1 to C:\\ProgramData\\WindowsDeploymentBuilder\\Applications\\result.json when the stage reaches a final status. Every selected package appears in "packages" with a terminal status, or "Pending" when it was not attempted (Failed/Offline runs; run the installer again to resume).',
  type: 'object',
  additionalProperties: false,
  required: ['schemaVersion', 'stage', 'status', 'reason', 'engineVersion', 'finishedUtc', 'starts', 'reboots', 'bootstrap', 'counts', 'packages', 'additionalSoftware', 'followUp'],
  properties: {
    schemaVersion: { const: 1 },
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
      required: ['total', 'succeeded', 'alreadyInstalled', 'skipped', 'requiresInteraction', 'requiresRestart', 'failed', 'unavailable', 'pending'],
      properties: { total: int, succeeded: int, alreadyInstalled: int, skipped: int, requiresInteraction: int, requiresRestart: int, failed: int, unavailable: int, pending: int },
    },
    packages: {
      type: 'array',
      items: item({ key: str, name: str, packageIdentifier: str, source: str }, ['key', 'name', 'packageIdentifier', 'source', 'status', 'attempts', 'exitCode', 'message', 'timestampUtc']),
    },
    additionalSoftware: { type: 'array', items: item({ id: str, name: str }, ['id', 'name', 'status', 'attempts', 'exitCode', 'message', 'timestampUtc']) },
    followUp: { type: 'array', items: str },
  },
} as const;

/** WinGet exit codes the engine maps explicitly (mirrors $script:ExitCodes in ApplicationEngine.ps1). */
export const WINGET_EXIT_CODES: Record<string, { status: (typeof PACKAGE_STATUSES)[number]; retry: boolean; restart: 'none' | 'later' | 'now' | 'initiated'; symbol: string }> = {
  '0x00000000': { status: 'Succeeded', retry: false, restart: 'none', symbol: 'S_OK' },
  '0x8A150061': { status: 'AlreadyInstalled', retry: false, restart: 'none', symbol: 'PACKAGE_ALREADY_INSTALLED' },
  '0x8A15010D': { status: 'AlreadyInstalled', retry: false, restart: 'none', symbol: 'INSTALL_ALREADY_INSTALLED' },
  '0x8A15002B': { status: 'AlreadyInstalled', retry: false, restart: 'none', symbol: 'UPDATE_NOT_APPLICABLE' },
  '0x8A15010E': { status: 'AlreadyInstalled', retry: false, restart: 'none', symbol: 'INSTALL_DOWNGRADE' },
  '0x8A150109': { status: 'RequiresRestart', retry: false, restart: 'later', symbol: 'INSTALL_REBOOT_REQUIRED_TO_FINISH' },
  '0x8A15010A': { status: 'RequiresRestart', retry: true, restart: 'now', symbol: 'INSTALL_REBOOT_REQUIRED_FOR_INSTALL' },
  '0x8A15010B': { status: 'RequiresRestart', retry: false, restart: 'initiated', symbol: 'INSTALL_REBOOT_INITIATED' },
  '0x00000BC2': { status: 'RequiresRestart', retry: false, restart: 'later', symbol: 'ERROR_SUCCESS_REBOOT_REQUIRED (3010)' },
  '0x00000669': { status: 'RequiresRestart', retry: false, restart: 'initiated', symbol: 'ERROR_SUCCESS_REBOOT_INITIATED (1641)' },
  '0x8A150014': { status: 'Unavailable', retry: false, restart: 'none', symbol: 'NO_APPLICATIONS_FOUND' },
  '0x8A150113': { status: 'Unavailable', retry: false, restart: 'none', symbol: 'INSTALL_SYSTEM_NOT_SUPPORTED' },
  '0x8A150016': { status: 'Failed', retry: false, restart: 'none', symbol: 'MULTIPLE_APPLICATIONS_FOUND' },
  '0x8A15010C': { status: 'RequiresInteraction', retry: false, restart: 'none', symbol: 'INSTALL_CANCELLED_BY_USER' },
  '0x8A150011': { status: 'Failed', retry: false, restart: 'none', symbol: 'INSTALLER_HASH_MISMATCH' },
  '0x8A15003A': { status: 'Failed', retry: false, restart: 'none', symbol: 'BLOCKED_BY_POLICY' },
  '0x8A15010F': { status: 'Failed', retry: false, restart: 'none', symbol: 'INSTALL_BLOCKED_BY_POLICY' },
  '0x8A15001B': { status: 'Failed', retry: false, restart: 'none', symbol: 'MSSTORE_BLOCKED_BY_POLICY' },
  '0x8A15001C': { status: 'Failed', retry: false, restart: 'none', symbol: 'MSSTORE_APP_BLOCKED_BY_POLICY' },
  '0x8A150041': { status: 'Failed', retry: false, restart: 'none', symbol: 'PACKAGE_AGREEMENTS_NOT_ACCEPTED' },
  '0x8A150046': { status: 'Failed', retry: false, restart: 'none', symbol: 'SOURCE_AGREEMENTS_NOT_ACCEPTED' },
  '0x8A150105': { status: 'Failed', retry: false, restart: 'none', symbol: 'INSTALL_DISK_FULL' },
  '0x8A150107': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_NO_NETWORK' },
  '0x8A150008': { status: 'Failed', retry: true, restart: 'none', symbol: 'DOWNLOAD_FAILED' },
  '0x8A150045': { status: 'Failed', retry: true, restart: 'none', symbol: 'SOURCE_OPEN_FAILED' },
  '0x8A150101': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_PACKAGE_IN_USE' },
  '0x8A150102': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_INSTALL_IN_PROGRESS' },
  '0x8A150103': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_FILE_IN_USE' },
  '0x8A150111': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_PACKAGE_IN_USE_BY_APPLICATION' },
  '0x8A150104': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_MISSING_DEPENDENCY' },
  '0x8A150110': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_DEPENDENCIES' },
  '0x8A150106': { status: 'Failed', retry: true, restart: 'none', symbol: 'INSTALL_INSUFFICIENT_MEMORY' },
};
