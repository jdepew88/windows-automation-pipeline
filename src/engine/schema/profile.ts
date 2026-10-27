import { z } from 'zod';
import { AdditionalSoftwareSchema, ApplicationsSchema } from './applications';
import { MigrationSchema } from './migration';
import { DriversSchema } from './drivers';
import { HealthSchema } from './health';

/**
 * The typed deployment profile. One flat object per section; "mode" fields choose between
 * alternatives while sibling fields keep their values, so switching modes (or Basic/Advanced views)
 * never discards user input.
 *
 * Bump {@link SCHEMA_VERSION} and add a migration in `migrations.ts` for any breaking change.
 */
export const SCHEMA_VERSION = 7;

export const ScriptTypeSchema = z.enum(['ps1', 'cmd', 'reg', 'vbs']);
export type ScriptType = z.infer<typeof ScriptTypeSchema>;

export const ScriptPhaseSchema = z.enum(['system', 'defaultUser', 'firstLogon', 'userOnce']);
export type ScriptPhase = z.infer<typeof ScriptPhaseSchema>;

export const ScriptSchema = z
  .object({
    id: z.string().min(1).max(64),
    name: z.string().max(100),
    type: ScriptTypeSchema,
    enabled: z.boolean(),
    content: z.string().max(200_000),
  })
  .strict();
export type Script = z.infer<typeof ScriptSchema>;

export const PassSchema = z.enum(['offlineServicing', 'windowsPE', 'generalize', 'specialize', 'auditSystem', 'auditUser', 'oobeSystem']);
export type Pass = z.infer<typeof PassSchema>;

export const ComponentEntrySchema = z
  .object({
    id: z.string().min(1).max(64),
    enabled: z.boolean(),
    component: z.string().max(200),
    pass: PassSchema,
    markup: z.string().max(200_000),
  })
  .strict();
export type ComponentEntry = z.infer<typeof ComponentEntrySchema>;

export const ArchitectureSchema = z.enum(['x86', 'amd64', 'arm64']);
export type Architecture = z.infer<typeof ArchitectureSchema>;

export const BloatwareActionSchema = z.enum(['keep', 'remove', 'untouched']);
export type BloatwareAction = z.infer<typeof BloatwareActionSchema>;

const bool = z.boolean();

export const ProfileSchema = z
  .object({
    schemaVersion: z.literal(SCHEMA_VERSION),
    profileName: z.string().max(100),

    setup: z
      .object({
        languageMode: z.enum(['unattended', 'interactive']),
        imageLanguage: z.string(),
        userLocale: z.string(),
        keyboard: z.string(),
        geoLocation: z.string(),
        editionMode: z.enum(['genericKey', 'interactive', 'firmware', 'customKey']),
        editionId: z.string(),
        customProductKey: z.string().max(29),
        /** Windows PE disk selection is always interactive in this project; no other value is accepted. */
        diskMode: z.literal('interactive'),
        /** Windows 11 Setup LabConfig bypasses, one per check (schema version 7). */
        bypassTpmCheck: bool,
        bypassCpuCheck: bool,
        bypassSecureBootCheck: bool,
        bypassNetworkCheck: bool,
        processorArchitectures: z.array(ArchitectureSchema),
        timeZoneMode: z.enum(['implicit', 'explicit']),
        timeZone: z.string(),
        useConfigurationSet: bool,
        useNarrator: bool,
        hidePowerShellWindows: bool,
        keepSensitiveFiles: bool,
      })
      .strict(),

    accounts: z
      .object({
        accountMode: z.enum(['unattendedLocal', 'interactiveLocal', 'interactiveMicrosoft']),
        personName: z.string().max(64),
        usernameMode: z.enum(['derived', 'custom']),
        customUsername: z.string().max(64),
        accountGroup: z.enum(['Administrators', 'Users']),
        password: z.string().max(127),
        /** Create the account without a password: no Password value, and no persistent automatic sign-in. */
        noInitialPassword: bool,
        autoLogon: z.enum(['persistent', 'firstLogonOnly', 'none']),
        obscurePasswords: bool,
        hideOnlineAccountScreens: bool,
        computerNameMode: z.enum(['derived', 'custom', 'random']),
        customComputerName: z.string().max(64),
        lockoutMode: z.enum(['default', 'disabled', 'custom']),
        lockoutThreshold: z.number().int(),
        lockoutDuration: z.number().int(),
        lockoutWindow: z.number().int(),
        passwordExpirationMode: z.enum(['default', 'unlimited', 'custom']),
        maxPasswordAge: z.number().int(),
      })
      .strict(),

    security: z
      .object({
        uacLevel: z.enum(['alwaysNotify', 'windowsDefault', 'noDim', 'neverNotify', 'disabled']),
        disableSmartScreen: bool,
        disableSmartAppControl: bool,
        systemRestore: z.enum(['windowsDefault', 'enable', 'disable']),
        preventDeviceEncryption: bool,
        enableRemoteDesktop: bool,
        processAudit: z.enum(['disabled', 'enabled', 'enabledWithCommandLine']),
        disableInsiderBuilds: bool,
        appLockerMode: z.enum(['none', 'policy']),
        appLockerPolicyXml: z.string().max(500_000),
      })
      .strict(),

    privacy: z
      .object({
        expressSettings: z.enum(['disableAll', 'enableAll', 'interactive']),
        diagnosticData: z.enum(['required', 'windowsDefault']),
        disableAdvertisingId: bool,
        disableTailoredExperiences: bool,
        disableInkingTypingCollection: bool,
        disableLocation: bool,
        disableAppSuggestions: bool,
        disableBingResults: bool,
        disableCopilot: bool,
        disableRecall: bool,
      })
      .strict(),

    updates: z
      .object({
        mode: z.enum(['windowsDefault', 'notifyDownload', 'notifyInstall']),
        excludeDrivers: bool,
        preventAutomaticReboot: bool,
      })
      .strict(),

    /** Phase 2: unattended Windows Update engine started at the end of FirstLogon. */
    windowsUpdate: z
      .object({
        enabled: bool,
        drivers: z.enum(['followPolicy', 'include', 'exclude']),
        featureUpdates: z.enum(['skip', 'install']),
        optionalUpdates: z.enum(['skip', 'install']),
        microsoftUpdate: bool,
        maxReboots: z.number().int(),
        maxAttemptsPerUpdate: z.number().int(),
        maxRuntimeHours: z.number().int(),
        networkWaitMinutes: z.number().int(),
        confirmationScans: z.number().int(),
        resetComponentsOnce: bool,
        rebootWarningSeconds: z.number().int(),
        /** Comma/space separated KB numbers that are never installed. */
        excludedKbs: z.string().max(2000),
      })
      .strict(),

    /** Phase 3: WinGet application provisioning (runs as the signed-in user after Windows Update). */
    applications: ApplicationsSchema,

    /** Phase 3: installers that WinGet does not cover (data model; manual follow-up by default). */
    additionalSoftware: AdditionalSoftwareSchema,

    /** Phase 6: application inventory review, migration profile and settings restore plan. */
    migration: MigrationSchema,

    /** Phase 8: hardware-aware driver policy (detection happens on the installed computer). */
    drivers: DriversSchema,

    /** Phase 9: independent end-of-deployment verification, health reports and customer handoff. */
    health: HealthSchema,

    system: z
      .object({
        disableFastStartup: bool,
        disableErrorReporting: bool,
        powerShellExecutionPolicy: z.enum(['windowsDefault', 'remoteSigned']),
        hardenSystemDriveAcl: bool,
        enableLongPaths: bool,
        deleteJunctions: bool,
        disableLastAccess: bool,
        turnOffSystemSounds: bool,
        deleteWindowsOld: bool,
        disableAutomaticRestartSignOn: bool,
        disableWpbt: bool,
        preventDeviceApps: bool,
        disablePointerPrecision: bool,
        hideEdgeFirstRun: bool,
        disableEdgeStartupBoost: bool,
        makeEdgeUninstallable: bool,
      })
      .strict(),

    explorer: z
      .object({
        showFileExtensions: bool,
        hiddenFiles: z.enum(['hideAll', 'showHidden', 'showAll']),
        launchToThisPC: bool,
        classicContextMenu: bool,
        hideInfoTip: bool,
        removeShortcutArrows: bool,
        showEndTask: bool,
      })
      .strict(),

    taskbar: z
      .object({
        leftAlign: bool,
        search: z.enum(['hide', 'icon', 'box', 'label']),
        hideTaskView: bool,
        disableWidgets: bool,
        showAllTrayIcons: bool,
        icons: z.enum(['default', 'empty']),
      })
      .strict(),

    desktop: z
      .object({
        deleteEdgeShortcut: bool,
        iconsMode: z.enum(['default', 'custom']),
        icons: z.record(z.string(), bool),
      })
      .strict(),

    start: z
      .object({
        pinsMode: z.enum(['default', 'empty', 'custom']),
        pinsJson: z.string().max(100_000),
        foldersMode: z.enum(['default', 'custom']),
        folders: z.record(z.string(), bool),
      })
      .strict(),

    personalization: z
      .object({
        visualEffects: z.enum(['default', 'bestAppearance', 'bestPerformance']),
        stickyKeys: z.enum(['default', 'disabled']),
      })
      .strict(),

    bloatware: z.record(z.string(), BloatwareActionSchema),

    virtualization: z
      .object({
        disableCoreIsolation: bool,
        vboxGuestAdditions: bool,
        vmwareTools: bool,
        virtioGuestTools: bool,
        parallelsTools: bool,
      })
      .strict(),

    wifi: z
      .object({
        mode: z.enum(['interactive', 'skip', 'parameters', 'profileXml']),
        ssid: z.string().max(64),
        password: z.string().max(64),
        authentication: z.enum(['open', 'WPA2PSK', 'WPA3SAE']),
        nonBroadcast: bool,
        connectAutomatically: bool,
        profileXml: z.string().max(100_000),
      })
      .strict(),

    scripts: z
      .object({
        system: z.array(ScriptSchema),
        defaultUser: z.array(ScriptSchema),
        firstLogon: z.array(ScriptSchema),
        userOnce: z.array(ScriptSchema),
        restartExplorer: bool,
      })
      .strict(),

    advancedXml: z
      .object({
        components: z.array(ComponentEntrySchema),
      })
      .strict(),

    output: z
      .object({
        answerFileName: z.enum(['autounattend.xml', 'notautounattend.xml']),
      })
      .strict(),

    /**
     * Extension points for later milestones. Recorded and round-tripped, never executed.
     * (v3 moved the former `wingetPackages` list into `applications`; see migrations.ts.)
     */
    deferred: z
      .object({
        installPowerShell7: bool,
      })
      .strict(),
  })
  .strict();

export type Profile = z.infer<typeof ProfileSchema>;
export type SectionKey = Exclude<keyof Profile, 'schemaVersion' | 'profileName'>;
