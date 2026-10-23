import { z } from 'zod';

/**
 * Phase 9: Deployment Verification & Health. What the installed computer checks at the end of the
 * deployment (DeploymentHealth.ps1) and which reports it writes. Nothing here can switch off the
 * integrity of the results or the security checks: those always run when verification is on.
 */

// eslint-disable-next-line no-control-regex
const text = (max: number) => z.string().max(max).regex(/^[^\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]*$/);

/** A package key of the selection (winget:git.git, msstore:9np83lwlpz9k, catalog:rustdesk). */
export const HEALTH_APP_KEY = /^(winget|msstore|catalog|additional):[a-z0-9._+-]{1,128}$/;

export const HealthSchema = z
  .object({
    /** Ships the health engine and runs it automatically when the deployment reaches its end. */
    enabled: z.boolean(),
    technicianReport: z.boolean(),
    customerReport: z.boolean(),
    /** Keeps every earlier report under reports\health\history (otherwise the first and the previous one). */
    keepHistory: z.boolean(),
    /** Read-only SMART/NVMe reliability counters where Windows exposes them. */
    storageObservations: z.boolean(),
    /** Opens the technician report once, from the progress window, when the deployment finishes. */
    openReportAfterDeployment: z.boolean(),
    /** auto: Internet is required only while outstanding work needs it. */
    networkRequirement: z.enum(['auto', 'required', 'notRequired']),
    /** Selected applications whose absence does not block delivery (ReadyWithWarnings instead of NeedsAttention). */
    optionalApps: z.array(z.string().regex(HEALTH_APP_KEY)).max(200),
    /** Printed in the customer handoff report. No passwords or keys: the field is checked. */
    customerNotes: text(2000),
  })
  .strict();
export type Health = z.infer<typeof HealthSchema>;
