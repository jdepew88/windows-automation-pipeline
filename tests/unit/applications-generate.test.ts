import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { generate } from '../../src/engine/pipeline';
import { importProfile } from '../../src/engine/profiles';
import { SCHEMA_VERSION, type Profile } from '../../src/engine/schema/profile';
import type { AdditionalItem, PackageRef } from '../../src/engine/schema/applications';
import {
  APP_ENGINE_VERSION,
  APP_STAGING_DIR,
  EMBEDDED_APP_FILES,
  applicationAssets,
  applicationsConfig,
  isReviewed,
  planPreview,
  splitArgs,
  wingetArguments,
} from '../../src/engine/applications';
import { importWinGetJson, validateWinGetDocument } from '../../src/engine/applications/winget-json';
import { FINAL_STATUSES, PACKAGE_STATUSES, RESULTS_JSON_SCHEMA } from '../../src/engine/applications/results';
import { orchestrationContract } from '../../src/engine/orchestration';
import { DRIVER_STAGE } from '../../src/engine/drivers/contract';
import engineSource from '../../src/engine/applications/scripts/ApplicationEngine.ps1?raw';
import bootstrapSource from '../../src/engine/applications/scripts/WinGetBootstrap.ps1?raw';
import installerSource from '../../src/engine/applications/scripts/Install-ApplicationEngine.ps1?raw';
import wuEngineSource from '../../src/engine/windows-update/scripts/WindowsUpdateEngine.ps1?raw';
import { commandLines, embedded, errorsOf, generateOk, noApps, profile } from './helpers';

const fixture = (name: string) => readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8');
const M1_XML = fixture('m1-owner-default-alex.xml');
const ref = (packageIdentifier: string, source = 'winget', extra: Partial<PackageRef> = {}): PackageRef => ({ packageIdentifier, source, displayName: packageIdentifier, version: '', scope: '', ...extra });
// Exactly Git + Whiteboard (no Core Essentials), as in Phase 3.
const withApps = (mutate?: (p: Profile) => void) =>
  profile((p) => {
    noApps(p);
    p.applications.selection.added.push(ref('Git.Git', 'winget', { displayName: 'Git' }), ref('9MSPC6MP8FM4', 'msstore', { displayName: 'Whiteboard' }));
    mutate?.(p);
  });
const item = (extra: Partial<AdditionalItem> = {}): AdditionalItem => ({
  id: 'i1',
  name: 'Vendor Tool',
  publisher: 'Vendor',
  downloadUrl: 'https://vendor.example/download',
  installerType: 'exe',
  fileName: 'vendor-setup.exe',
  sha256: 'a'.repeat(64),
  silentArgs: '/S',
  prerequisites: '',
  interaction: 'unknown',
  manualSupply: true,
  license: 'Freeware',
  redistribution: 'unknown',
  execution: 'manual',
  notes: '',
  ...extra,
});

describe('earlier milestones are preserved', () => {
  it('empty selection (the Phase 4 owner default): no application files, no extra FirstLogon command', () => {
    const r = generateOk(profile(noApps));
    expect(r.embeddedFiles.some((f) => f.path.startsWith(APP_STAGING_DIR))).toBe(false);
    expect(commandLines(r.root).firstLogon).toHaveLength(2);
    expect(r.assets.map((a) => a.name)).toEqual(['WindowsUpdateEngine.ps1', 'Install-UpdateEngine.ps1', 'config.json', 'README-WindowsUpdate.txt', 'orchestration.json']);
  });

  it('Milestone 1: both engines off reproduce the Milestone 1 answer file byte for byte', () => {
    const r = generate(profile((p) => {
      p.windowsUpdate.enabled = false;
      noApps(p);
    }));
    expect(r.xml).toBe(M1_XML);
    expect(r.assets).toEqual([]);
  });

  it('a Phase 2 (schema v2) profile imports with an empty selection and generates the same XML as today\'s defaults', () => {
    const v2 = JSON.parse(fixture('p2-owner-default.profile.json')) as Record<string, unknown>;
    expect(v2.schemaVersion).toBe(2);
    (v2.accounts as Record<string, unknown>).personName = 'Alex';
    const r = importProfile(JSON.stringify(v2));
    expect(r.errors).toEqual([]);
    expect(r.profile!.schemaVersion).toBe(SCHEMA_VERSION);
    expect(r.profile!.applications.selection.selectedProfiles).toEqual([]);
    expect(r.profile!.deferred).toEqual({ installPowerShell7: true });
    expect(generate(r.profile).xml).toBe(generate(profile(noApps)).xml);
  });

  it('a Milestone 1 profile with recorded WinGet IDs moves them to an unselected profile; the XML is unchanged', () => {
    const v1 = JSON.parse(fixture('m1-owner-default.profile.json')) as Record<string, unknown>;
    (v1.accounts as Record<string, unknown>).personName = 'Alex';
    (v1.deferred as Record<string, unknown>).wingetPackages = ['Git.Git', 'git.git', 'not a valid id'];
    const r = importProfile(JSON.stringify(v1));
    expect(r.errors).toEqual([]);
    const legacy = r.profile!.applications.selection.profiles.find((p) => p.id === 'imported-legacy')!;
    expect(legacy.packages.map((p) => p.packageIdentifier)).toEqual(['Git.Git']);
    expect(r.profile!.applications.selection.selectedProfiles).toEqual([]);
    // Since schema v4 the (empty) built-in profiles are templates and are not stored.
    expect(r.profile!.applications.selection.profiles.map((p) => p.id)).toEqual(['imported-legacy']);
    expect(r.warnings.join(' ')).toMatch(/1 WinGet package ID\(s\).*1 invalid ID\(s\) were dropped/);
    expect(generate(r.profile).xml).toBe(M1_XML);
  });
});

describe('answer file with applications selected', () => {
  const r = generateOk(withApps());

  it('embeds the engine files in the Applications staging folder', () => {
    expect(r.embeddedFiles.filter((f) => f.path.startsWith(APP_STAGING_DIR)).map((f) => f.path.slice(APP_STAGING_DIR.length + 1))).toEqual([...EMBEDDED_APP_FILES]);
  });

  it('embeds the application installer; the orchestrator (last FirstLogon command) runs it after the update engine', () => {
    const fl = commandLines(r.root).firstLogon;
    expect(fl).toHaveLength(2);
    expect(fl[1]).toContain('Deployment\\scripts\\bootstrap\\Initialize-Deployment.ps1');
    expect(r.embeddedFiles.map((f) => f.path)).toContain(`${APP_STAGING_DIR}\\Install-ApplicationEngine.ps1`);
  });

  it('round-trips the scripts and both JSON files exactly through the XML', () => {
    const e = embedded(r.root);
    expect(e.get('ApplicationEngine.ps1')).toBe(engineSource.replace(/\r?\n/g, '\n').trim());
    expect(e.get('WinGetBootstrap.ps1')).toBe(bootstrapSource.replace(/\r?\n/g, '\n').trim());
    expect(e.get('Install-ApplicationEngine.ps1')).toBe(installerSource.replace(/\r?\n/g, '\n').trim());
    expect(JSON.parse(e.get('applications-config.json')!)).toEqual(applicationsConfig(withApps()));
    const native = JSON.parse(e.get('winget-packages.json')!);
    expect(validateWinGetDocument(native)).toEqual([]);
    expect(importWinGetJson(e.get('winget-packages.json')!).packages.map((p) => p.packageIdentifier)).toEqual(['Git.Git', '9MSPC6MP8FM4']);
  });

  it('works without Windows Update automation (no waiting)', () => {
    const c = applicationsConfig(withApps((p) => (p.windowsUpdate.enabled = false)));
    expect(c.coordination.windowsUpdate.enabled).toBe(false);
    const g = generateOk(withApps((p) => (p.windowsUpdate.enabled = false)));
    expect(commandLines(g.root).firstLogon).toHaveLength(2);
  });

  it('generates nothing for applications while the stage is turned off', () => {
    const g = generateOk(withApps((p) => (p.applications.enabled = false)));
    expect(g.embeddedFiles.some((f) => f.path.startsWith(APP_STAGING_DIR))).toBe(false);
    expect(g.assets.some((a) => a.group === 'applications')).toBe(false);
  });

  it('is reproducible (no timestamps in generated files)', () => {
    expect(generate(withApps()).xml).toBe(generate(withApps()).xml);
  });
});

describe('engine configuration and commands', () => {
  it('maps the selection and policy', () => {
    const c = applicationsConfig(withApps());
    expect(c).toMatchObject({
      engineVersion: APP_ENGINE_VERSION,
      taskName: 'Applications',
      restartPolicy: 'whenRequired',
      registerAppInstaller: true,
      onlineRepair: false,
      maxReboots: 3,
      maxAttemptsPerPackage: 2,
      coordination: { policy: 'updatesFirst', windowsUpdate: { enabled: true, stateFile: 'C:\\ProgramData\\WindowsDeploymentBuilder\\Updates\\state.json' } },
    });
    expect(c.packages.map((p) => `${p.source}:${p.packageIdentifier}`)).toEqual(['winget:Git.Git', 'msstore:9MSPC6MP8FM4']);
    expect(c.unresolved).toEqual([]);
  });

  it('builds explicit, non-interactive WinGet commands from validated tokens only', () => {
    expect(wingetArguments('install', ref('Git.Git'))).toEqual(['install', '--id', 'Git.Git', '--exact', '--source', 'winget', '--silent', '--no-upgrade', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity']);
    expect(wingetArguments('install', ref('Mozilla.Firefox', 'winget', { version: '131.0.3', scope: 'machine' }))).toContain('--version');
    expect(wingetArguments('list', ref('Git.Git'))).toEqual(['list', '--id', 'Git.Git', '--exact', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity']);
  });

  it('keeps display names out of command lines (names with quotes or $() stay in JSON data)', () => {
    const p = withApps((x) => (x.applications.selection.added[0]!.displayName = 'Git "$(calc)" & stuff'));
    const r = generateOk(p);
    expect(r.ok).toBe(true);
    for (const line of commandLines(r.root).firstLogon) expect(line).not.toContain('calc');
    expect(planPreview(p)).toContain('winget install --id Git.Git --exact --source winget');
  });

  it('lists unresolved packages separately so they are reported, not installed', () => {
    const p = withApps((x) => x.applications.selection.added.push({ ...ref('Contoso.Tool', 'contoso'), sourceDetails: { Name: 'contoso', Identifier: 'C', Argument: 'https://c.example', Type: 'Microsoft.Rest' } }));
    const c = applicationsConfig(p);
    expect(c.unresolved.map((u) => u.packageIdentifier)).toEqual(['Contoso.Tool']);
    expect(c.packages.map((x) => x.packageIdentifier)).not.toContain('Contoso.Tool');
    expect(planPreview(p)).toMatch(/Not installed \(unresolved/);
  });

  it('marks interaction-required and catalog notes in the plan preview', () => {
    const p = withApps((x) => x.applications.selection.added.push(ref('Insecure.Nmap')));
    expect(planPreview(p)).toMatch(/Nmap[\s\S]*installer may prompt/);
  });
});

describe('deployment assets and contracts', () => {
  const assets = applicationAssets(withApps());

  it('offers the native WinGet list, profile, scripts, config, plan, results schema and README', () => {
    expect(assets.map((a) => a.name)).toEqual([
      'ApplicationEngine.ps1',
      'WinGetBootstrap.ps1',
      'Install-ApplicationEngine.ps1',
      'applications-config.json',
      'winget-packages.json',
      'application-profile.json',
      'applications-plan.txt',
      'applications-results.schema.json',
      'README-Applications.txt',
    ]);
    for (const a of assets) {
      expect(a.group).toBe('applications');
      expect(a.content.replace(/\r\n/g, ''), a.name).not.toContain('\n');
    }
    const full = generateOk(withApps()).assets.map((a) => a.name);
    expect(full.at(-1)).toBe('orchestration.json');
  });

  it('exports the selection in the builder profile format (re-importable)', () => {
    const json = JSON.parse(assets.find((a) => a.name === 'application-profile.json')!.content);
    expect(json.format).toBe('windows-deployment-builder/app-profiles');
    expect(json.profiles[0].packages).toHaveLength(2);
  });

  it('publishes a results schema consistent with the status vocabulary', () => {
    expect(RESULTS_JSON_SCHEMA.properties.status.enum).toEqual([...FINAL_STATUSES]);
    expect(RESULTS_JSON_SCHEMA.properties.packages.items.properties.status.enum).toEqual([...PACKAGE_STATUSES]);
    expect(PACKAGE_STATUSES).toEqual(['Pending', 'Installing', 'Succeeded', 'AlreadyInstalled', 'Skipped', 'SkippedByUser', 'RequiresInteraction', 'RequiresRestart', 'Failed', 'Unavailable']);
  });

  it('describes stages, order, locks and the Phase 4 driver hand-off in orchestration.json', () => {
    const o = orchestrationContract(withApps());
    expect(o.stages.map((s) => [s.id, s.order, s.enabled, s.implemented])).toEqual([
      ['windowsUpdate', 1, true, true],
      ['applications', 2, true, true],
      ['drivers', 3, false, false],
    ]);
    expect(o.stages[1]!.waitsFor).toEqual(['windowsUpdate']);
    expect(o.coordination.installLock).toBe('C:\\ProgramData\\WindowsDeploymentBuilder\\state\\install.lock');
    expect(o.stages[2]).toMatchObject({ inventory: DRIVER_STAGE.inventoryFile, marker: DRIVER_STAGE.marker, waitsFor: ['windowsUpdate'] });
  });

  it('keeps PowerShell and TypeScript paths and versions in step', () => {
    expect(engineSource).toContain(`$script:EngineVersion = '${APP_ENGINE_VERSION}'`);
    for (const needle of ["'Applications'", "'applications.done'", "'result.json'", "'install.lock'", "'restart-pending.json'"]) expect(engineSource).toContain(needle);
  });

  it('shares one identical coordination block between the two engines', () => {
    const region = (s: string) => {
      const t = s.replace(/\r\n/g, '\n');
      return t.slice(t.indexOf('# region WDB coordination'), t.indexOf('# endregion WDB coordination'));
    };
    expect(region(engineSource).length).toBeGreaterThan(1000);
    expect(region(engineSource)).toBe(region(wuEngineSource));
  });

  it('uses only documented interfaces: no Invoke-Expression, no third-party downloads, no security bypasses', () => {
    for (const src of [engineSource, bootstrapSource, installerSource]) {
      expect(src).not.toMatch(/Invoke-Expression|\biex\b|DownloadString|Set-MpPreference|Add-MpPreference|-SkipPublisherCheck|Set-ExecutionPolicy|bitsadmin|github\.com\/[^ ]*\/releases/i);
    }
    expect(bootstrapSource).toContain('Add-AppxPackage -RegisterByFamilyName -MainPackage');
    expect(bootstrapSource).toContain('Repair-WinGetPackageManager');
    expect(bootstrapSource).toMatch(/O=Microsoft Corporation/);
  });
});

describe('validation', () => {
  it('accepts the owner defaults and a normal selection', () => {
    expect(generate(profile()).ok).toBe(true);
    expect(generate(withApps()).ok).toBe(true);
  });

  it('rejects application installation for a standard-user account', () => {
    expect(errorsOf(withApps((p) => (p.accounts.accountGroup = 'Users'))).map((e) => e.path)).toContain('applications.enabled');
  });

  it('rejects Store packages while the Microsoft Store is removed', () => {
    const errs = errorsOf(withApps((p) => (p.bloatware.Store = 'remove')));
    expect(errs).toEqual([expect.objectContaining({ path: 'applications.selection', message: expect.stringMatching(/Microsoft Store/) })]);
  });

  it('rejects invalid identifiers for known sources; warns for unsupported sources', () => {
    expect(errorsOf(withApps((p) => p.applications.selection.added.push(ref('Bad Id'))))[0]!.message).toMatch(/not a valid winget PackageIdentifier/);
    const w = generate(withApps((p) => p.applications.selection.added.push(ref('Contoso.Tool', 'contoso'))));
    expect(w.ok).toBe(true);
    expect(w.issues.some((i) => i.severity === 'warning' && /not supported/.test(i.message))).toBe(true);
  });

  it('rejects missing selected profiles and inheritance cycles', () => {
    expect(errorsOf(profile((p) => (p.applications.selection.selectedProfiles = ['ghost'])))[0]!.message).toMatch(/does not exist/);
    const custom = (id: string, inherits: string[]) => ({ id, name: id, category: 'custom' as const, description: '', builtin: false, inherits, packages: [] });
    const cyc = errorsOf(
      profile((p) => {
        p.applications.selection.profiles.push(custom('a', ['b']), custom('b', ['a']));
      }),
    );
    expect(cyc.some((e) => /inherits itself/.test(e.message))).toBe(true);
  });

  it.each([
    ['maxReboots', 11],
    ['maxAttemptsPerPackage', 0],
    ['packageTimeoutMinutes', 4],
    ['networkWaitMinutes', 61],
    ['maxRuntimeHours', 25],
    ['waitForUpdatesHours', 0],
    ['rebootWarningSeconds', 601],
  ] as const)('rejects %s = %d', (key, value) => {
    expect(errorsOf(withApps((p) => (p.applications[key] = value)))).toEqual([expect.objectContaining({ path: `applications.${key}`, message: expect.stringMatching(/between/) })]);
  });

  it('accepts an empty selection even with odd limits (nothing is generated)', () => {
    expect(generate(profile((p) => (p.applications.maxReboots = 99))).ok).toBe(false);
    expect(generate(profile((p) => {
      p.applications.enabled = false;
      p.applications.maxReboots = 99;
    })).ok).toBe(true);
  });
});

describe('Additional Software', () => {
  const errors = (i: Partial<AdditionalItem>) => errorsOf(profile((p) => p.additionalSoftware.items.push(item(i)))).map((e) => e.message);

  it('a recorded installer is a manual follow-up, embedded as data only', () => {
    const p = profile((x) => x.additionalSoftware.items.push(item()));
    const r = generateOk(p);
    const cfg = JSON.parse(embedded(r.root).get('applications-config.json')!);
    expect(cfg.additionalSoftware).toEqual([expect.objectContaining({ name: 'Vendor Tool', execution: 'manual', silentArgs: ['/S'], sha256: 'A'.repeat(64) })]);
    expect(planPreview(p)).toMatch(/Vendor Tool: manual follow-up \(https:\/\/vendor\.example\/download\)/);
    expect(r.xml).not.toMatch(/Invoke-WebRequest[^\n]*vendor\.example/);
  });

  it('refuses automatic execution for installers that are not on the reviewed list', () => {
    expect(errors({ execution: 'automatic' }).join(' ')).toMatch(/reviewed list/);
  });

  it('allows automatic execution only for an exact reviewed match', () => {
    const reviewed = [{ name: 'Vendor Tool', sha256: 'A'.repeat(64), installerType: 'exe' as const, silentArgs: '/S' }];
    expect(isReviewed(item({ execution: 'automatic' }), reviewed)).toBe(true);
    expect(isReviewed(item({ execution: 'automatic', silentArgs: '/S /D=C:\\x' }), reviewed)).toBe(false);
    expect(isReviewed(item({ execution: 'automatic', sha256: 'b'.repeat(64) }), reviewed)).toBe(false);
  });

  it.each([
    [{ downloadUrl: 'http://vendor.example/setup.exe' }, /https/],
    [{ downloadUrl: 'https://user:pass@vendor.example/setup.exe' }, /user name or password/],
    [{ downloadUrl: 'https://cdn.example/setup.exe?token=abc123' }, /access token/],
    [{ downloadUrl: 'not a url' }, /not a valid URL/],
    [{ sha256: 'abc' }, /64 hexadecimal/],
    [{ fileName: '..\\..\\Windows\\evil.exe' }, /plain file name/],
    [{ silentArgs: '/S & calc.exe' }, /must not contain &/],
    [{ silentArgs: '/S; Remove-Item C:\\' }, /must not contain ;/],
    [{ silentArgs: '$(calc)' }, /must not contain \$/],
    [{ name: '' }, /name/],
  ] as [Partial<AdditionalItem>, RegExp][])('rejects %o', (i, message) => {
    expect(errors(i).join(' ')).toMatch(message);
  });

  it('splits documented switches without inventing any', () => {
    expect(splitArgs('/S /D="C:\\Program Files\\Tool" ALLUSERS=1')).toEqual({ tokens: ['/S', '/D=C:\\Program Files\\Tool', 'ALLUSERS=1'], refused: [] });
    expect(splitArgs('  /qn   "INSTALLDIR=C:\\A B"  ')).toEqual({ tokens: ['/qn', 'INSTALLDIR=C:\\A B'], refused: [] });
    expect(splitArgs('')).toEqual({ tokens: [], refused: [] });
  });
});
