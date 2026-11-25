import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { generate } from '../../src/engine/pipeline';
import { exportProfile, importProfile, ownerDefaults } from '../../src/engine/profiles';
import { applicationsConfig, planPreview, RETRY_TIMING } from '../../src/engine/applications';
import { ApplicationsResultSchema, FAILURE_CLASSES, PERMANENT_CLASSES, RETRIED_CLASSES, WINGET_EXIT_CODES } from '../../src/engine/applications/results';
import { buildDeploymentPackage, buildManifest, OUTCOME_CODES, packageFiles, RECOVERY_SCRIPT, STATE_SCHEMAS } from '../../src/engine/deployment';
import { reviewSummary } from '../../src/engine/quick';
import { generateOk, noApps, profile } from './helpers';
import recoverySource from '../../src/engine/deployment/scripts/DeploymentRecovery.ps1?raw';
import engineSource from '../../src/engine/applications/scripts/ApplicationEngine.ps1?raw';
import installerSource from '../../src/engine/applications/scripts/Install-ApplicationEngine.ps1?raw';
import commonSource from '../../src/engine/deployment/scripts/DeploymentCommon.ps1?raw';

/** Phase 5: resilient provisioning, resume and retry (the TypeScript side and static script checks). */

const fixture = (rel: string) => readFileSync(fileURLToPath(new URL(rel, import.meta.url)), 'utf8');

describe('Phase 5 defaults and compatibility', () => {
  it('new deployments: bounded automatic retry on, three attempts, continue after a failure, recovery tool included', () => {
    const a = ownerDefaults().applications;
    expect(a.maxAttemptsPerPackage).toBe(3);
    expect(a.recovery).toEqual({ automaticRetry: true, continueAfterFailure: true, includeRecoveryTool: true });
    const c = applicationsConfig(profile());
    expect(c.engineVersion).toBe('1.4.0');
    expect(c.retry).toEqual({ automatic: true, continueAfterFailure: true, ...RETRY_TIMING });
    expect(RETRY_TIMING).toEqual({ baseDelaySeconds: 60, maxDelaySeconds: 900, jitterRatio: 0.2, maxNetworkDeferrals: 6 });
  });

  it('a Phase 4.3 profile (no recovery block) imports with safe defaults and keeps its own attempt limit', () => {
    const r = importProfile(fixture('fixtures/p43-gaming.profile.json'));
    expect(r.errors).toEqual([]);
    expect(r.profile!.applications.recovery).toEqual({ automaticRetry: true, continueAfterFailure: true, includeRecoveryTool: true });
    expect(r.profile!.applications.maxAttemptsPerPackage).toBe(2);
    expect(r.warnings.join(' ')).toContain('applications.recovery');
    expect(r.profile!.applications.selection.selectedProfiles).toContain('gaming');
    expect(applicationsConfig(r.profile!).retry.automatic).toBe(true);
    expect(generate(r.profile!).ok).toBe(true);
  });

  it('older schema versions (Milestone 1, Phase 2, Phase 4) still import and get the recovery defaults', () => {
    for (const f of ['m1-owner-default.profile.json', 'p2-owner-default.profile.json', 'p4-owner-default.profile.json', 'p4-filled-gaming.profile.json']) {
      const r = importProfile(fixture(`fixtures/${f}`));
      expect(r.errors, f).toEqual([]);
      expect(r.profile!.applications.recovery.automaticRetry, f).toBe(true);
    }
  });

  it('a profile keeps an explicit recovery choice through export and import', () => {
    const p = profile((x) => {
      x.applications.recovery = { automaticRetry: false, continueAfterFailure: false, includeRecoveryTool: false };
    });
    const back = importProfile(exportProfile(p)).profile!;
    expect(back.applications.recovery).toEqual({ automaticRetry: false, continueAfterFailure: false, includeRecoveryTool: false });
    const c = applicationsConfig(back);
    expect(c.retry).toMatchObject({ automatic: false, continueAfterFailure: false });
    expect(planPreview(back)).toContain('1 per package (automatic retry off; use the recovery tool)');
    expect(planPreview(back)).toContain('the queue stops after the first failure');
  });

  it('rejects malformed recovery settings', () => {
    const bad = JSON.parse(exportProfile(profile()));
    bad.applications.recovery = { automaticRetry: 'yes', continueAfterFailure: true, includeRecoveryTool: true, runScript: 'calc.exe' };
    const r = importProfile(JSON.stringify(bad));
    expect(r.profile).toBeUndefined();
    expect(r.errors.map((e) => e.path)).toEqual(expect.arrayContaining(['applications.recovery.automaticRetry', 'applications.recovery']));
  });
});

describe('Phase 5 deployment package', () => {
  it('ships the recovery tool, embedded in the answer file, and declares recovery in the manifest', () => {
    const p = profile();
    const { manifest } = buildManifest(p);
    const entry = manifest.files.find((f) => f.path === RECOVERY_SCRIPT)!;
    expect(entry.embedded).toBe('Deployment\\scripts\\recovery\\DeploymentRecovery.ps1');
    expect(entry.textSha256).toMatch(/^[0-9A-F]{64}$/);
    expect(manifest.packageVersion).toBe('1.2.0');
    expect(manifest.generator.orchestrator).toBe('1.2.0');
    expect(manifest.recovery).toMatchObject({ tool: RECOVERY_SCRIPT, automaticRetry: true, maxAttemptsPerPackage: 3, continueAfterFailure: true, stateSchemas: STATE_SCHEMAS, outcomeCodes: OUTCOME_CODES });
    expect(manifest.paths.recoveryTool).toBe('C:\\ProgramData\\WindowsDeploymentBuilder\\Package\\scripts\\recovery\\DeploymentRecovery.ps1');
    const r = generateOk(p);
    expect(r.xml).toContain('<File path="C:\\Windows\\Setup\\Scripts\\Deployment\\scripts\\recovery\\DeploymentRecovery.ps1">');
    const pkg = buildDeploymentPackage(p, r);
    expect(pkg.entries.map((e) => e.path)).toContain('WindowsDeployment/scripts/recovery/DeploymentRecovery.ps1');
  });

  it('without the tool nothing is embedded for it; with both engines off the package adds nothing', () => {
    const p = profile((x) => (x.applications.recovery.includeRecoveryTool = false));
    expect(packageFiles(p).map((f) => f.path)).not.toContain(RECOVERY_SCRIPT);
    expect(buildManifest(p).manifest.recovery.tool).toBeNull();
    const off = profile((x) => {
      noApps(x);
      x.windowsUpdate.enabled = false;
    });
    expect(generateOk(off).xml).not.toContain('DeploymentRecovery.ps1');
  });

  it('the README explains automatic retry versus manual recovery', () => {
    const readme = packageFiles(profile()).find((f) => f.path === 'README.txt')!.content;
    expect(readme).toContain('Automatic retry: temporary failures');
    expect(readme).toContain('Manual recovery (technician');
    expect(readme).toContain('RetryFailed | Retry -Operation <id> | Resume | ExportDiagnostics');
  });

  it('outcome codes are stable and distinct; the recovery tool and DeploymentCommon use the same values', () => {
    expect(new Set(Object.values(OUTCOME_CODES)).size).toBe(Object.keys(OUTCOME_CODES).length);
    for (const [name, code] of Object.entries(OUTCOME_CODES)) expect(commonSource).toMatch(new RegExp(`${name} = ${code}\\b`));
  });

  it('Final Review says what happens when something fails, without adding controls to the wizard', () => {
    expect(reviewSummary(profile()).applications.recovery).toContain('retried automatically (up to 3 attempts');
    expect(reviewSummary(profile((x) => (x.applications.recovery.automaticRetry = false))).applications.recovery).toContain('No automatic retry');
  });
});

describe('Phase 5 retry classification and result schema', () => {
  it('integrity, policy, cancellation and "not found" codes are never retried automatically', () => {
    for (const [code, m] of Object.entries(WINGET_EXIT_CODES)) {
      if ((PERMANENT_CLASSES as readonly string[]).includes(m.class)) expect(m.retry, code).toBe(false);
      if (m.status === 'Failed' && m.retry) expect(RETRIED_CLASSES as readonly string[], code).toContain(m.class);
      expect(FAILURE_CLASSES as readonly string[]).toContain(m.class);
    }
    expect(WINGET_EXIT_CODES['0x8A150011']).toMatchObject({ class: 'Integrity', retry: false });
    expect(WINGET_EXIT_CODES['0x8A15003A']).toMatchObject({ class: 'Policy', retry: false });
    expect(WINGET_EXIT_CODES['0x8A15010C']).toMatchObject({ class: 'User', retry: false });
    expect(WINGET_EXIT_CODES['0x8A150107']).toMatchObject({ class: 'Network', retry: true });
  });

  it('result schema 2 rejects schema-1 results and malformed operations', () => {
    expect(ApplicationsResultSchema.safeParse({ schemaVersion: 1 }).success).toBe(false);
    const bad = { operationId: 'shell:calc', lifecycle: 'Hacked' };
    const r = ApplicationsResultSchema.safeParse({ schemaVersion: 2, packages: [bad] });
    expect(r.success).toBe(false);
  });
});

describe('Phase 5 scripts: static safety checks', () => {
  it('the recovery tool never evaluates input and only reaches the engines through their own functions', () => {
    for (const s of [recoverySource, engineSource]) {
      expect(s).not.toMatch(/Invoke-Expression|\biex\b|\[scriptblock\]::Create|Add-MpPreference|Set-MpPreference|Disable-NetFirewall|Set-NetFirewall|netsh advfirewall/i);
    }
    // Operation ids are matched against strict patterns before anything else.
    expect(engineSource).toContain("'^app:(winget|msstore):[a-z0-9][a-z0-9._+-]{0,127}$'");
    expect(engineSource).toContain("'^additional:[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'");
    // The only process the recovery tool starts itself is its own elevation prompt.
    expect(recoverySource.match(/Start-Process/g)).toHaveLength(1);
    expect(recoverySource).toContain("Start-Process -FilePath $ps -Verb RunAs");
  });

  it('diagnostics never collect answer files or Wi-Fi profiles, and the tool carries no literal key token', () => {
    expect(recoverySource).toContain("if ($f.Extension -in '.xml', '.wim', '.exe', '.msi') { continue }");
    // Every collected path is relative to the data root, and none names an answer file or Panther.
    const list = recoverySource.slice(recoverySource.indexOf('$script:DiagnosticFiles = @('), recoverySource.indexOf('function Export-WdrDiagnostics'));
    const paths = [...list.matchAll(/'([^']+)'/g)].map((m) => m[1]!);
    expect(paths.length).toBeGreaterThan(20);
    for (const x of paths) expect(x, x).toMatch(/^(Deployment|state|reports|Applications|Updates|Network|Drivers|Package)\\/);
    expect(list).not.toMatch(/autounattend|unattend\.xml|Panther|\.xml'/i);
    expect(recoverySource).not.toContain('keyMaterial');
  });

  it('Install-ApplicationEngine -Resume keeps the state and verifies its copies', () => {
    expect(installerSource).toMatch(/if \(-not \$Resume\) \{\s+foreach \(\$name in 'state\.json', 'state\.json\.bak', 'result\.json'/);
    expect(installerSource).toContain('does not match its source; refusing to register the task');
  });

  it('state files are written atomically with a backup in both the engine and the orchestrator', () => {
    for (const s of [engineSource, commonSource]) {
      expect(s).toContain('[System.IO.FileOptions]::WriteThrough');
      expect(s).toContain('[System.IO.File]::Replace($tmp, $Path');
    }
    expect(engineSource).toContain('function Save-WdaState { param([hashtable] $State, [hashtable] $Paths) Write-WdaJson $Paths.State $State -Backup }');
    expect(commonSource).toContain('function Save-WddState { param([hashtable] $Paths, [hashtable] $State) Write-WddJson $Paths.State $State -Backup }');
  });
});
