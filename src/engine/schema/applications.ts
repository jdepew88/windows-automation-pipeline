import { z } from 'zod';

/**
 * Phase 3 application provisioning: package references, application profiles and Additional
 * Software entries. Shared by the deployment profile schema, the internal application-profile file
 * format and the catalog.
 */

/** Sources the engine can install from. Anything else is preserved but unresolved. */
export const KNOWN_SOURCES = ['winget', 'msstore'] as const;
export type KnownSource = (typeof KNOWN_SOURCES)[number];

/** `SourceDetails` exactly as `winget export` writes them (checked against winget 1.29 `source export`). */
export const SOURCE_DETAILS: Record<KnownSource, { Name: string; Identifier: string; Argument: string; Type: string }> = {
  winget: { Name: 'winget', Identifier: 'Microsoft.Winget.Source_8wekyb3d8bbwe', Argument: 'https://cdn.winget.microsoft.com/cache', Type: 'Microsoft.PreIndexed.Package' },
  msstore: { Name: 'msstore', Identifier: 'StoreEdgeFD', Argument: 'https://storeedgefd.dsx.mp.microsoft.com/v9.0', Type: 'Microsoft.Rest' },
};

export const SourceDetailsSchema = z
  .object({
    Name: z.string().min(1).max(64),
    Identifier: z.string().max(256),
    Argument: z.string().max(2048),
    Type: z.string().max(128),
  })
  .strict();
export type SourceDetails = z.infer<typeof SourceDetailsSchema>;

/**
 * One package, identified by PackageIdentifier + source (never by display name). `displayName` is
 * for people only. Empty `version`/`scope` mean "latest" / "installer default".
 */
export const PackageRefSchema = z
  .object({
    packageIdentifier: z.string().min(1).max(128),
    source: z.string().min(1).max(64),
    displayName: z.string().max(200),
    version: z.string().max(64),
    scope: z.enum(['', 'user', 'machine']),
    /** Only for sources other than winget/msstore, kept so exports stay faithful. */
    sourceDetails: SourceDetailsSchema.optional(),
  })
  .strict();
export type PackageRef = z.infer<typeof PackageRefSchema>;

export const APP_PROFILE_CATEGORIES = ['core', 'everyday', 'gaming', 'developer', 'network', 'music', 'devices', 'laptop', 'touch', 'custom'] as const;
export const AppProfileCategorySchema = z.enum(APP_PROFILE_CATEGORIES);
export type AppProfileCategory = z.infer<typeof AppProfileCategorySchema>;

export const APP_PROFILE_ID = /^[a-z0-9][a-z0-9-]{0,47}$/;

/**
 * Phase 4.2: the customer's devices. Only the kind of device is recorded, never a device name,
 * serial number, account or phone number. Several devices of different ecosystems can coexist.
 */
export const DevicesSchema = z
  .object({
    /** The customer's primary smartphone. */
    phone: z.enum(['none', 'iphone', 'android']),
    ipad: z.boolean(),
    extraIphone: z.boolean(),
    androidTablet: z.boolean(),
  })
  .strict();
export type Devices = z.infer<typeof DevicesSchema>;
export const NO_DEVICES: Devices = { phone: 'none', ipad: false, extraIphone: false, androidTablet: false };

const UtcStamp = z.string().max(40);

export const AppProfileSchema = z
  .object({
    id: z.string().regex(APP_PROFILE_ID, 'Use 1-48 lowercase letters, digits or hyphens.'),
    name: z.string().min(1).max(80),
    category: AppProfileCategorySchema,
    description: z.string().max(500),
    /** Built-in profiles are templates defined in src/data/apps/profiles.json; they are never stored or edited. */
    builtin: z.boolean(),
    /** Other profiles whose packages this one includes (composition): its parents. */
    inherits: z.array(z.string().max(48)).max(10),
    /** Packages this profile selects (its defaults, or a saved profile's explicit additions). */
    packages: z.array(PackageRefSchema).max(500),
    /** Recommended but not selected: shown unticked while the profile is active (Phase 4.2). */
    optional: z.array(PackageRefSchema).max(500).optional(),
    /** Package keys ("source:id") this profile leaves out while it is selected (Phase 4.2). */
    excluded: z.array(z.string().max(200)).max(1000).optional(),
    /** Device answers saved with the profile; combined with the deployment's own (Phase 4.2). */
    devices: DevicesSchema.optional(),
    createdUtc: UtcStamp.optional(),
    updatedUtc: UtcStamp.optional(),
  })
  .strict();
export type AppProfile = z.infer<typeof AppProfileSchema>;

export const ApplicationsSelectionSchema = z
  .object({
    /** Custom (saved or imported) profiles. Built-in profiles come from the application data. */
    profiles: z.array(AppProfileSchema).max(50),
    /** Profiles combined for this deployment, in order (built-in or custom ids). */
    selectedProfiles: z.array(z.string().max(48)).max(50),
    /** The customer's devices; they add the matching device recommendations. */
    devices: DevicesSchema,
    /** Individually added packages (on top of the selected profiles). */
    added: z.array(PackageRefSchema).max(500),
    /** Package keys ("source:id", lower case) removed from the combined selection. */
    removed: z.array(z.string().max(200)).max(1000),
  })
  .strict();
export type ApplicationsSelection = z.infer<typeof ApplicationsSelectionSchema>;

/**
 * Phase 5: reliability and recovery. Older profiles have no `recovery` block; the importer fills it
 * from owner defaults (bounded automatic retry on, the recovery tool included), and the engine has
 * the same defaults for configurations generated before engine 1.2.0.
 */
export const RecoverySchema = z
  .object({
    /** Retry transient failures automatically (bounded by maxAttemptsPerPackage, with backoff). */
    automaticRetry: z.boolean(),
    /** Keep installing independent applications after one fails. */
    continueAfterFailure: z.boolean(),
    /** Ship the technician recovery tool (DeploymentRecovery.ps1) and its desktop shortcut. */
    includeRecoveryTool: z.boolean(),
  })
  .strict();
export type Recovery = z.infer<typeof RecoverySchema>;

export const ApplicationsSchema = z
  .object({
    enabled: z.boolean(),
    selection: ApplicationsSelectionSchema,
    /** Phase 3 implements only the conservative policy; the field exists for later policies. */
    coordination: z.enum(['updatesFirst']),
    restartPolicy: z.enum(['whenRequired', 'never']),
    registerAppInstaller: z.boolean(),
    onlineRepair: z.boolean(),
    maxReboots: z.number().int(),
    maxAttemptsPerPackage: z.number().int(),
    packageTimeoutMinutes: z.number().int(),
    networkWaitMinutes: z.number().int(),
    maxRuntimeHours: z.number().int(),
    waitForUpdatesHours: z.number().int(),
    rebootWarningSeconds: z.number().int(),
    recovery: RecoverySchema,
  })
  .strict();
export type Applications = z.infer<typeof ApplicationsSchema>;

export const AdditionalItemSchema = z
  .object({
    id: z.string().min(1).max(64),
    name: z.string().max(100),
    publisher: z.string().max(100),
    downloadUrl: z.string().max(2048),
    installerType: z.enum(['exe', 'msi', 'msix', 'zip', 'other']),
    /** File name the installer is supplied under (…\Applications\installers\<fileName>). */
    fileName: z.string().max(120),
    sha256: z.string().max(64),
    silentArgs: z.string().max(1000),
    prerequisites: z.string().max(500),
    interaction: z.enum(['none', 'required', 'unknown']),
    manualSupply: z.boolean(),
    license: z.string().max(200),
    redistribution: z.enum(['allowed', 'restricted', 'unknown']),
    /** "automatic" is accepted only for installers on the reviewed list (see features/additional-software). */
    execution: z.enum(['manual', 'automatic']),
    notes: z.string().max(1000),
  })
  .strict();
export type AdditionalItem = z.infer<typeof AdditionalItemSchema>;

export const AdditionalSoftwareSchema = z
  .object({
    items: z.array(AdditionalItemSchema).max(50),
  })
  .strict();
