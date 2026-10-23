import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { generateOk, noApps, profile } from './helpers';
import { ownerDefaults, importProfile } from '../../src/engine/profiles';
import { applicationsConfig } from '../../src/engine/applications';
import { removePackage, toggleProfile } from '../../src/engine/applications/profiles';
import { effectiveApps } from '../../src/engine/applications/preview';
import { engineConfig } from '../../src/engine/windows-update';
import { driversConfig } from '../../src/engine/drivers';
import { buildDeploymentPackage, buildManifest, packageFiles } from '../../src/engine/deployment';
import { reviewSummary } from '../../src/engine/quick';
import { validateProfile } from '../../src/engine/validation/validate';
import {
  CustomerHandoffSchema,
  EDITION_IDS,
  HEALTH_CATEGORIES,
  HEALTH_EXIT_CODES,
  HEALTH_STATES,
  HEALTH_TEMPLATE,
  HealthReportSchema,
  PHASE5_OUTCOME_MAP,
  customizationAdapters,
  healthActive,
  healthConfig,
  renderHealthTemplate,
  sampleHealthReport,
} from '../../src/engine/health';
import engineSource from '../../src/engine/health/scripts/DeploymentHealth.ps1?raw';
import type { Profile } from '../../src/engine/schema/profile';

const fixture = (name: string) => readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8');
const validate = (p: Profile) => validateProfile(p).issues;
/** The specialize script, where policies are written (the health engine itself only reads them). */
const specialize = (p: Profile) => generateOk(p).embeddedFiles.find((f) => f.path.endsWith('Specialize.ps1'))!.content;

const additional = (p: Profile, execution: 'manual' | 'automatic' = 'manual') =>
  p.additionalSoftware.items.push({ id: 'contoso-tool', name: 'Contoso Field Tool', publisher: 'Contoso Ltd.', downloadUrl: 'https://contoso.example/tool', installerType: 'exe', fileName: 'tool.exe', sha256: 'A'.repeat(64), silentArgs: '/S', prerequisites: '', interaction: 'none', manualSupply: true, license: '', redistribution: 'unknown', execution, notes: '' });

describe('verification plan (health-config.json)', () => {
  it('expects exactly the applications the deployment installs or lists, never the catalog', () => {
    const p = profile((q) => {
      toggleProfile(q.applications.selection, 'gaming', true);
      removePackage(q.applications.selection, 'winget:epicgames.epicgameslauncher');
      additional(q);
      q.health.optionalApps = ['winget:valve.steam'];
    });
    const c = healthConfig(p);
    const cfg = applicationsConfig(p);
    const keys = c.applications.items.map((x) => x.key);
    expect(keys).toEqual([...cfg.packages.map((x) => x.key), ...cfg.manual.map((x) => x.key), 'additional:contoso-tool']);
    expect(keys).not.toContain('winget:epicgames.epicgameslauncher');
    expect(new Set(keys).size).toBe(keys.length);
    const by = new Map(c.applications.items.map((x) => [x.key, x]));
    expect(by.get('winget:valve.steam')).toMatchObject({ kind: 'automatic', required: false });
    expect(by.get('winget:google.chrome')).toMatchObject({ kind: 'automatic', required: true, operationId: 'app:winget:google.chrome' });
    expect(by.get('catalog:rustdesk')).toMatchObject({ kind: 'manual', required: false, method: 'manual' });
    expect(by.get('catalog:rustdesk')!.instructions).toBeTruthy();
    expect(by.get('additional:contoso-tool')).toMatchObject({ kind: 'manual', required: false, url: 'https://contoso.example/tool' });
    expect(c.applications.deselected).toContain('winget:epicgames.epicgameslauncher');
  });

  it('records the expected Windows identity: edition id, owner account, computer name, account rights', () => {
    const c = healthConfig(ownerDefaults());
    expect(c.windows).toMatchObject({ editionMode: 'genericKey', editionName: 'Windows 11 Pro', expectedEditionIds: ['Professional'], architectures: ['amd64'], minimumBuild: 22000 });
    expect(c.account).toEqual({ mode: 'unattendedLocal', username: 'owner', expectedGroup: 'Administrators', autoLogon: 'persistent' });
    expect(c.identity).toEqual({ computerNameMode: 'derived', computerName: 'owner-Computer' });
    expect(Object.keys(EDITION_IDS).sort()).toEqual(['education', 'education_n', 'enterprise', 'enterprise_n', 'home', 'home_n', 'home_single', 'pro', 'pro_education', 'pro_education_n', 'pro_n', 'pro_workstations', 'pro_workstations_n']);
    expect(healthConfig(profile((q) => (q.setup.editionMode = 'interactive'))).windows.expectedEditionIds).toEqual([]);
    expect(healthConfig(profile((q) => (q.accounts.computerNameMode = 'random'))).identity.computerName).toBeNull();
  });

  it('verification adapters cover only settings this repository implements, with the values their features write', () => {
    const ids = customizationAdapters(ownerDefaults()).map((a) => `${a.id}:${a.registry.name}=${a.registry.expected}:${a.scope}`);
    expect(ids).toEqual(['explorer.showFileExtensions:HideFileExt=0:user', 'explorer.launchToThisPC:LaunchTo=1:user', 'taskbar.leftAlign:TaskbarAl=0:user', 'system.disableFastStartup:HiberbootEnabled=0:machine']);
    const xml = generateOk(ownerDefaults());
    const all = xml.embeddedFiles.map((f) => f.content).join('\n');
    for (const a of customizationAdapters(ownerDefaults())) expect(all, a.id).toContain(a.registry.name);
    expect(customizationAdapters(profile((q) => (q.explorer.showFileExtensions = false))).map((a) => a.id)).not.toContain('explorer.showFileExtensions');
  });

  it('carries the security expectations of the Security section and no switch to skip security checks', () => {
    const c = healthConfig(ownerDefaults());
    expect(c.security).toEqual({ uac: { level: 'noDim', enableLua: 1, consentPromptBehaviorAdmin: 5, promptOnSecureDesktop: 0 }, smartScreenExpected: true, deviceEncryptionPrevented: false });
    expect(Object.keys(ownerDefaults().health).sort()).toEqual(['customerNotes', 'customerReport', 'enabled', 'keepHistory', 'networkRequirement', 'openReportAfterDeployment', 'optionalApps', 'storageObservations', 'technicianReport']);
  });
});

describe('Windows Update drivers during provisioning (audit correction)', () => {
  it('new deployments let Windows Update offer compatible drivers; the driver stage receives the same policy', () => {
    const p = ownerDefaults();
    expect(p.updates.excludeDrivers).toBe(false);
    expect(engineConfig(p).drivers).toBe('include');
    expect(driversConfig(p).windowsUpdate.drivers).toBe('include');
    expect(buildManifest(p).manifest.drivers).toMatchObject({ policy: { useWindowsUpdate: true, windowsUpdateDrivers: 'include' } });
    expect(healthConfig(p).windowsUpdate.drivers).toBe('include');
    expect(specialize(p)).not.toContain('ExcludeWUDriversInQualityUpdate');
  });

  it('an older profile keeps its explicit policy (and is warned about the conflict); an organization policy is never overwritten', () => {
    const raw = JSON.parse(fixture('p5-network-engineer.profile.json')) as Record<string, unknown>;
    (raw.accounts as Record<string, unknown>).personName = 'Alex';
    const r = importProfile(JSON.stringify(raw));
    expect(r.errors).toEqual([]);
    const p = r.profile!;
    expect(p.updates.excludeDrivers).toBe(true);
    expect(engineConfig(p).drivers).toBe('exclude');
    expect(specialize(p)).toContain('/v "ExcludeWUDriversInQualityUpdate" /t REG_DWORD /d 1');
    p.drivers.enabled = true;
    expect(validate(p).filter((i) => i.path === 'updates.excludeDrivers')).toEqual([expect.objectContaining({ severity: 'warning', message: expect.stringMatching(/will not offer compatible drivers/) })]);
    // The health engine reports a blocking policy as a warning; it never writes the policy.
    expect(engineSource).not.toMatch(/Set-ItemProperty|New-ItemProperty|reg\.exe add|SetValue\(/);
  });
});

describe('profiles and packages', () => {
  it('older profiles get verification off (schema 6 migration) and produce the package they did', () => {
    for (const f of ['p43-gaming.profile.json', 'p5-network-engineer.profile.json', 'p4-owner-default.profile.json']) {
      const raw = JSON.parse(fixture(f)) as Record<string, unknown>;
      (raw.accounts as Record<string, unknown>).personName = 'Alex';
      const r = importProfile(JSON.stringify(raw));
      expect(r.errors, f).toEqual([]);
      expect(r.profile!.health.enabled, f).toBe(false);
      expect(r.warnings.join(' '), f).toMatch(/Deployment verification and health reports .* turned off for this older profile/);
      expect(packageFiles(r.profile!).some((x) => x.path.startsWith('scripts/health/')), f).toBe(false);
      expect('verification' in buildManifest(r.profile!).manifest, f).toBe(false);
    }
  });

  it('new deployments ship the engine, its plan and template (embedded) and declare read-only verification', () => {
    const p = ownerDefaults();
    p.accounts.personName = 'Alex';
    const files = packageFiles(p).filter((f) => f.path.startsWith('scripts/health/'));
    expect(files.map((f) => `${f.path}|${f.embedded ?? ''}`)).toEqual([
      'scripts/health/DeploymentHealth.ps1|Deployment\\scripts\\health\\DeploymentHealth.ps1',
      'scripts/health/health-config.json|Deployment\\scripts\\health\\health-config.json',
      'scripts/health/HealthReport.html|Deployment\\scripts\\health\\HealthReport.html',
      'scripts/health/deployment-health.schema.json|',
      'scripts/health/README-Health.txt|',
    ]);
    const m = buildManifest(p);
    expect(m.manifest.files.filter((f) => f.embedded && f.path.startsWith('scripts/health/')).every((f) => f.textSha256)).toBe(true);
    expect(m.manifest).toMatchObject({ verification: { enabled: true, readOnly: true, tool: 'scripts/health/DeploymentHealth.ps1' }, paths: { healthTool: 'C:\\ProgramData\\WindowsDeploymentBuilder\\Package\\scripts\\health\\DeploymentHealth.ps1' }, generator: { healthEngine: '1.0.0' } });
    const pkg = buildDeploymentPackage(p, generateOk(p));
    expect(pkg.entries.some((e) => e.path === 'WindowsDeployment/scripts/health/DeploymentHealth.ps1')).toBe(true);
    expect(generateOk(p).xml).toContain('DeploymentHealth.ps1');
  });

  it('verification is off when nothing runs after installation, even if it is enabled', () => {
    const p = profile((q) => {
      q.windowsUpdate.enabled = false;
      noApps(q);
    });
    expect(p.health.enabled).toBe(true);
    expect(healthActive(p)).toBe(false);
    expect(packageFiles(p).some((x) => x.path.startsWith('scripts/health/'))).toBe(false);
  });

  it('technician notes may not carry passwords or keys; stale optional applications are reported', () => {
    expect(validate(profile((q) => (q.health.customerNotes = 'Wi-Fi password: hunter22'))).filter((i) => i.path === 'health.customerNotes')).toEqual([expect.objectContaining({ severity: 'error' })]);
    expect(validate(profile((q) => (q.health.customerNotes = 'Key VK7JG-NPHTM-C97JM-9MPGT-3V66T'))).some((i) => i.path === 'health.customerNotes')).toBe(true);
    expect(validate(profile((q) => (q.health.customerNotes = 'Your files are in Documents. Call 555-0100.'))).some((i) => i.path === 'health.customerNotes')).toBe(false);
    expect(validate(profile((q) => (q.health.optionalApps = ['winget:valve.steam']))).filter((i) => i.path === 'health.optionalApps')).toEqual([expect.objectContaining({ severity: 'warning' })]);
  });
});

describe('Final Review: Additional Software and verification are visible before deployment', () => {
  it('lists Additional Software with the selected applications and in the summary', () => {
    const p = profile((q) => additional(q));
    const apps = effectiveApps(p.applications.selection, true, undefined, p.additionalSoftware.items);
    expect(apps.additional).toEqual([expect.objectContaining({ key: 'additional:contoso-tool', displayName: 'Contoso Field Tool', kind: 'manual' })]);
    expect(apps.total).toBe(apps.automatic.length + apps.manual.length + apps.unresolved.length + 1);
    const s = reviewSummary(p);
    expect(s.applications.additional).toEqual(['Contoso Field Tool (manual follow-up)']);
    expect(s.verification.final).toMatch(/^Automatic and read-only/);
    expect(s.verification.reports).toMatch(/technician dashboard, customer handoff, machine-readable JSON/);
    expect(s.verification.restoration).toBe('No backup restoration');
    expect(reviewSummary(profile((q) => (q.health.enabled = false))).verification.final).toMatch(/^Off/);
    expect(effectiveApps(p.applications.selection, false, undefined, p.additionalSoftware.items).total).toBe(0);
  });
});

describe('report contract and template', () => {
  it('the template is ASCII, has one data slot, and inserted data cannot leave its script element', () => {
    // eslint-disable-next-line no-control-regex
    expect(/^[\x00-\x7f]*$/.test(HEALTH_TEMPLATE)).toBe(true);
    expect(HEALTH_TEMPLATE.split('__WDB_HEALTH_DATA__').length).toBe(2);
    expect(HEALTH_TEMPLATE).not.toMatch(/<(script|link)[^>]+(src|href)=/i);
    const html = renderHealthTemplate({ mode: 'technician', report: { name: '</script><img src=x onerror=alert(1)>', x: 'a&b<!--' } });
    expect(html.match(/<\/script>/g)!.length).toBe(2);
    expect(html).toContain('\\u003c/script\\u003e');
    expect(html).not.toContain('<!--"');
  });

  it('the website allows exactly the template script by its hash (Content-Security-Policy), nothing broader', async () => {
    const { createHash } = await import('node:crypto');
    const scripts = [...HEALTH_TEMPLATE.replace(/\r\n/g, '\n').matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]!);
    expect(scripts).toHaveLength(1);
    const hash = createHash('sha256').update(scripts[0]!, 'utf8').digest('base64');
    const index = readFileSync(fileURLToPath(new URL('../../index.html', import.meta.url)), 'utf8');
    const csp = /Content-Security-Policy" content="([^"]+)"/.exec(index)![1]!;
    expect(csp).toContain(`script-src 'self' 'sha256-${hash}';`);
    expect(csp).not.toMatch(/unsafe-inline'[^;]*;\s*style|script-src[^;]*unsafe/);
  });

  it('sample reports are valid reports, clearly marked as sample data', () => {
    const t = sampleHealthReport('technician') as { sample: boolean; report: unknown };
    expect(t.sample).toBe(true);
    const parsed = HealthReportSchema.safeParse(t.report);
    expect(parsed.success ? [] : parsed.error.issues).toEqual([]);
    const c = sampleHealthReport('customer', 'Notes') as { handoff: unknown };
    expect(CustomerHandoffSchema.safeParse(c.handoff).success).toBe(true);
    expect(HEALTH_TEMPLATE).toContain('SAMPLE DATA');
  });

  it('PowerShell and TypeScript share the states, exit codes, categories and the Phase 5 outcome mapping', () => {
    const list = (name: string) => (new RegExp(`\\$script:${name} = @\\(([^)]*)\\)`).exec(engineSource)?.[1] ?? '').split(',').map((s) => s.trim().replace(/'/g, ''));
    expect(list('WdhStates')).toEqual([...HEALTH_STATES]);
    const codes = /\$script:WdhExitCodes = @\{([^}]*)\}/.exec(engineSource)![1]!;
    expect(Object.fromEntries(codes.split(';').map((x) => x.split('=').map((y) => y.trim())).map(([k, v]) => [k, Number(v)]))).toEqual(HEALTH_EXIT_CODES);
    const cats = /\$script:WdhCategoryNames = \[ordered\]@\{([\s\S]*?)\n\}/.exec(engineSource)![1]!;
    const fromPs = [...cats.matchAll(/(\w+) = '([^']+)'/g)].map((m) => `${m[1]}=${m[2]}`);
    expect(fromPs).toEqual(HEALTH_CATEGORIES.map((c) => `${c.id}=${c.name}`));
    const map = /\$map = @\{ (Succeeded = [\s\S]*?) \}\n/.exec(engineSource)![1]!;
    const fromPsMap = Object.fromEntries([...map.matchAll(/(\w+) = @\('(\w+)', '(\w+)'\)/g)].map((m) => [m[1], { finding: m[2], severity: m[3] }]));
    expect(fromPsMap).toEqual(PHASE5_OUTCOME_MAP);
  });
});

describe('static safety of the health engine', () => {
  const body = (name: string) => {
    const i = engineSource.indexOf(`function ${name} {`);
    const j = engineSource.indexOf('\nfunction ', i + 10);
    return engineSource.slice(i, j < 0 ? undefined : j);
  };

  it('verification never installs, removes, restarts, resets or changes Windows; side effects are confined to named actions', () => {
    const forbidden = /\b(Install-Package|Uninstall-[A-Z]\w*|Restart-Computer|Stop-Computer|Set-Service|Stop-Service|Start-Service|Disable-[A-Z]\w*|Enable-[A-Z]\w*|Reset-[A-Z]\w*|Format-Volume|Repair-Volume|Set-MpPreference|Set-NetFirewallProfile|Suspend-BitLocker|Add-LocalGroupMember|Remove-LocalGroupMember|Set-LocalUser|Rename-Computer)\b|pnputil|winget(\.exe)? install|chkdsk|manage-bde|shutdown\.exe/;
    expect(engineSource).not.toMatch(forbidden);
    // The only deletions: archived report history (its own files) and the separately confirmed backup cleanup.
    const removals = [...engineSource.matchAll(/Remove-Item[^\n]*/g)].map((m) => m[0]);
    expect(removals.length).toBe(5);
    expect(body('Invoke-WdhCleanupBackups')).toMatch(/ConfirmationRequired/);
    expect(body('Invoke-WdhCleanupBackups')).toMatch(/StartsWith\(\$root/);
    expect(body('Invoke-WdhCleanupBackups')).toMatch(/ReparsePoint/);
    // Scheduled tasks: only the self-removing startup re-check, registered at the end of a deployment with a pending restart.
    expect([...engineSource.matchAll(/Register-ScheduledTask/g)].length).toBe(1);
    expect(body('Invoke-WdhVerify')).not.toMatch(/Register-WdhRecheckTask/);
  });

  it('never reads a password, product key or recovery key', () => {
    expect(engineSource).not.toMatch(/GetValue\('DefaultPassword'/);
    expect(engineSource).not.toMatch(/\.RecoveryPassword\b|KeyProtectorId|BackupToAAD|PartialProductKey\s*[,|)]|OA3xOriginalProductKey|DigitalProductId/);
    expect(body('Get-WdhActivation')).toMatch(/-Property LicenseStatus, Name, Description/);
  });

  it('no shipped script interpolates "$scope:name:" (an error under StrictMode, which the scripts enable)', () => {
    const root = fileURLToPath(new URL('../../src/engine', import.meta.url));
    const walk = (d: string): string[] => readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(d, e.name)) : e.name.endsWith('.ps1') ? [join(d, e.name)] : []));
    const bad = walk(root).flatMap((f) => readFileSync(f, 'utf8').split(/\r?\n/).map((l, i) => ({ f, i: i + 1, l })).filter((x) => /"[^"]*\$(script|global|local|private):\w+:[^:]/.test(x.l)));
    expect(bad.map((x) => `${x.f}:${x.i}`)).toEqual([]);
  });
});
