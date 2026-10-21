import { describe, expect, it } from 'vitest';
import ownerJson from '../../profiles/owner-default.json';
import { exportProfile, hasSecrets, importProfile, ownerDefaults, stripSecrets } from '../../src/engine/profiles';
import { migrate } from '../../src/engine/profiles/migrations';
import { ProfileSchema, SCHEMA_VERSION } from '../../src/engine/schema/profile';
import { BLOATWARE } from '../../src/features/bloatware/catalog';
import { DESKTOP_ICONS, START_FOLDERS } from '../../src/data';

describe('owner-default profile', () => {
  const p = ownerDefaults();

  it('validates against the schema and equals the JSON file', () => {
    expect(ProfileSchema.safeParse(ownerJson).success).toBe(true);
    expect(p).toEqual(ownerJson);
  });

  it('records the owner decisions from the specification', () => {
    expect(p.setup).toMatchObject({ languageMode: 'unattended', imageLanguage: 'en-US', userLocale: 'en-US', keyboard: '00000409', geoLocation: '244', editionMode: 'genericKey', editionId: 'pro', diskMode: 'interactive' });
    expect(p.accounts).toMatchObject({ accountMode: 'unattendedLocal', accountGroup: 'Administrators', password: '', autoLogon: 'persistent', computerNameMode: 'derived', usernameMode: 'derived', lockoutMode: 'default', passwordExpirationMode: 'default' });
    expect(p.security).toMatchObject({ uacLevel: 'noDim', disableSmartScreen: false, disableSmartAppControl: false, systemRestore: 'enable', preventDeviceEncryption: false, enableRemoteDesktop: false, processAudit: 'disabled', disableInsiderBuilds: true, appLockerMode: 'none' });
    expect(p.privacy.expressSettings).toBe('disableAll');
    expect(p.updates).toEqual({ mode: 'notifyInstall', excludeDrivers: true, preventAutomaticReboot: false });
    expect(p.system).toMatchObject({ disableFastStartup: true, disableErrorReporting: true, powerShellExecutionPolicy: 'remoteSigned', hardenSystemDriveAcl: false, enableLongPaths: false, deleteJunctions: false, disableLastAccess: false, turnOffSystemSounds: false, deleteWindowsOld: false, disableAutomaticRestartSignOn: false, disableWpbt: false, preventDeviceApps: true, disablePointerPrecision: true, hideEdgeFirstRun: true, disableEdgeStartupBoost: true, makeEdgeUninstallable: false });
    expect(p.explorer).toMatchObject({ showFileExtensions: true, hiddenFiles: 'hideAll', launchToThisPC: true, classicContextMenu: false, removeShortcutArrows: true });
    expect(p.taskbar).toMatchObject({ leftAlign: true, search: 'icon', hideTaskView: false, disableWidgets: true });
    expect(Object.entries(p.desktop.icons).filter(([, v]) => v).map(([k]) => k)).toEqual(['RecycleBin']);
    expect(p.desktop.deleteEdgeShortcut).toBe(true);
    expect(Object.entries(p.start.folders).filter(([, v]) => v).map(([k]) => k).sort()).toEqual(['Downloads', 'PersonalFolder', 'Pictures', 'Settings']);
    expect(p.start.pinsMode).toBe('default');
    expect(p.virtualization).toEqual({ disableCoreIsolation: false, vboxGuestAdditions: false, vmwareTools: false, virtioGuestTools: false, parallelsTools: false });
    expect(p.wifi.mode).toBe('interactive');
    expect(p.wifi.password).toBe('');
    expect(p.scripts).toEqual({ system: [], defaultUser: [], firstLogon: [], userOnce: [], restartExplorer: false });
    expect(p.advancedXml.components).toEqual([]);
    expect(p.output.answerFileName).toBe('autounattend.xml');
    expect(p.deferred).toEqual({ installPowerShell7: true });
  });

  it('starts application provisioning with Core Essentials only (Phase 4.2), no saved profiles, no devices', () => {
    const sel = p.applications.selection;
    expect(sel.profiles).toEqual([]);
    expect(sel.selectedProfiles).toEqual(['core']);
    expect(sel.devices).toEqual({ phone: 'none', ipad: false, extraIphone: false, androidTablet: false });
    expect(sel.added).toEqual([]);
    expect(sel.removed).toEqual([]);
    expect(p.additionalSoftware.items).toEqual([]);
    expect(p.applications).toMatchObject({ enabled: true, coordination: 'updatesFirst', restartPolicy: 'whenRequired', registerAppInstaller: true, onlineRepair: false });
  });

  it('has an explicit decision for every catalog app, icon and Start folder', () => {
    expect(Object.keys(p.bloatware).sort()).toEqual(BLOATWARE.map((b) => b.id).sort());
    expect(Object.keys(p.desktop.icons).sort()).toEqual(DESKTOP_ICONS.map((i) => i.Id).sort());
    expect(Object.keys(p.start.folders).sort()).toEqual(START_FOLDERS.map((f) => f.Id).sort());
  });

  it('sets the specified bloatware decisions', () => {
    const remove = ['3DViewer', 'Clipchamp', 'FeedbackHub', 'Maps', 'News', 'Wallet', 'Teams', 'MixedReality', 'ZuneVideo', 'OneNote', 'People', 'QuickAssist', 'Skype', 'GetStarted', 'Weather', 'OneDrive'];
    const keep = ['Clock', 'Calculator', 'Camera', 'DevHome', 'GetHelp', 'MailCalendar', 'ZuneMusic', 'Photos', 'Store', 'ToDo', 'Paint3D', 'PowerAutomate', 'SnippingTool', 'Solitaire', 'VoiceRecorder', 'StickyNotes', 'WindowsBackup', 'XboxApp', 'XboxGameBar', 'XboxIdentityProvider', 'YourPhone'];
    for (const id of remove) expect(p.bloatware[id], id).toBe('remove');
    for (const id of keep) expect(p.bloatware[id], id).toBe('keep');
    expect(p.bloatware.Cortana).toBe('untouched');
    expect(Object.values(p.bloatware).filter((v) => v === 'remove')).toHaveLength(remove.length);
  });

  it('returns independent copies (reset cannot be corrupted by edits)', () => {
    const a = ownerDefaults();
    a.accounts.personName = 'Changed';
    a.bloatware.Calculator = 'remove';
    expect(ownerDefaults().accounts.personName).toBe('');
    expect(ownerDefaults().bloatware.Calculator).toBe('keep');
  });
});

describe('import/export', () => {
  const edited = () => {
    const p = ownerDefaults();
    p.accounts.personName = 'Zoë';
    p.accounts.password = 'pw';
    p.accounts.autoLogon = 'firstLogonOnly';
    p.wifi = { ...p.wifi, mode: 'parameters', ssid: 'Net', password: 'wifipassword' };
    p.scripts.firstLogon.push({ id: 's1', name: 'Hello', type: 'ps1', enabled: true, content: "Write-Host 'hi & bye'" });
    p.scripts.system.push({ id: 's2', name: '', type: 'cmd', enabled: false, content: 'echo off' });
    p.advancedXml.components.push({ id: 'c1', enabled: true, component: 'Microsoft-Windows-TCPIP', pass: 'specialize', markup: '<IcmpRedirectsEnabled>false</IcmpRedirectsEnabled>' });
    p.bloatware.Calculator = 'remove';
    p.desktop.icons.ThisPC = true;
    p.applications.selection.added.push({ packageIdentifier: 'Git.Git', source: 'winget', displayName: 'Git', version: '', scope: '' });
    p.applications.selection.selectedProfiles = ['developer'];
    p.additionalSoftware.items.push({ id: 'a1', name: 'Tool', publisher: 'Pub', downloadUrl: 'https://example.org/tool', installerType: 'exe', fileName: 'tool.exe', sha256: '', silentArgs: '/S', prerequisites: '', interaction: 'unknown', manualSupply: true, license: 'Freeware', redistribution: 'unknown', execution: 'manual', notes: '' });
    return p;
  };

  it('round-trips every field when secrets are included', () => {
    const p = edited();
    const r = importProfile(exportProfile(p, { includeSecrets: true }));
    expect(r.errors).toEqual([]);
    expect(r.profile).toEqual(p);
  });

  it('strips passwords by default and round-trips everything else', () => {
    const p = edited();
    const json = exportProfile(p);
    expect(json).not.toContain('wifipassword');
    expect(json).not.toMatch(/"password": "pw"/);
    const r = importProfile(json);
    expect(r.profile).toEqual(stripSecrets(p));
    expect(hasSecrets(p)).toBe(true);
    expect(hasSecrets(r.profile!)).toBe(false);
  });

  it('owner defaults contain no secrets', () => {
    expect(hasSecrets(ownerDefaults())).toBe(false);
  });

  it('fills missing fields from owner defaults with a warning', () => {
    const r = importProfile(JSON.stringify({ schemaVersion: 1, accounts: { personName: 'Kim' }, bloatware: { Calculator: 'remove' } }));
    expect(r.errors).toEqual([]);
    expect(r.profile!.accounts.personName).toBe('Kim');
    expect(r.profile!.accounts.autoLogon).toBe('persistent');
    expect(r.profile!.bloatware.Calculator).toBe('remove');
    expect(r.profile!.bloatware.Clipchamp).toBe('remove');
    expect(r.warnings.join(' ')).toMatch(/Filled \d+ missing field/);
  });

  it('reports field-level errors for wrong types, enums and unknown keys', () => {
    const r = importProfile(JSON.stringify({ ...ownerDefaults(), taskbar: { ...ownerDefaults().taskbar, search: 'giant' }, accounts: { ...ownerDefaults().accounts, autoLogon: true, extra: 1 } }));
    expect(r.profile).toBeUndefined();
    const paths = r.errors.map((e) => e.path);
    expect(paths).toContain('taskbar.search');
    expect(paths).toContain('accounts.autoLogon');
    expect(r.errors.some((e) => e.path === 'accounts' && /extra/.test(e.message))).toBe(true);
  });

  it('rejects disk automation smuggled in via diskMode', () => {
    const r = importProfile(JSON.stringify({ ...ownerDefaults(), setup: { ...ownerDefaults().setup, diskMode: 'wipeDisk0' } }));
    expect(r.errors.map((e) => e.path)).toContain('setup.diskMode');
  });

  it('rejects non-JSON, non-objects, missing and future schema versions', () => {
    expect(importProfile('{').errors[0]!.message).toMatch(/Not valid JSON/);
    expect(importProfile('[]').errors[0]!.message).toMatch(/object/);
    expect(importProfile('{"setup":{}}').errors[0]!.message).toMatch(/schemaVersion/);
    expect(importProfile(JSON.stringify({ schemaVersion: SCHEMA_VERSION + 1 })).errors[0]!.message).toMatch(/newer/);
  });
});

describe('migrations', () => {
  it('runs registered migrations in order and records notes', () => {
    const r = migrate(
      { schemaVersion: 1, a: 1 },
      { 1: (v) => ({ value: { ...v, b: 2 }, note: 'added b' }), 2: (v) => ({ value: { ...v, c: 3 } }) },
      3,
    );
    expect(r).toEqual({ ok: true, value: { schemaVersion: 3, a: 1, b: 2, c: 3 }, notes: ['added b'] });
  });

  it('fails when a step is missing', () => {
    expect(migrate({ schemaVersion: 1 }, {}, 2)).toEqual({ ok: false, error: 'No migration from schema version 1 to 2.' });
  });

  it('is a no-op for the current version', () => {
    const r = migrate({ schemaVersion: SCHEMA_VERSION, x: 1 });
    expect(r).toEqual({ ok: true, value: { schemaVersion: SCHEMA_VERSION, x: 1 }, notes: [] });
  });
});
