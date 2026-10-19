import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { generate } from '../../src/engine/pipeline';
import { importProfile } from '../../src/engine/profiles';
import {
  COMPLETION_MARKER,
  ENGINE_VERSION,
  STAGING_DIR,
  engineConfig,
  parseKbList,
  updateEngineAssets,
} from '../../src/engine/windows-update';
import engineSource from '../../src/engine/windows-update/scripts/WindowsUpdateEngine.ps1?raw';
import installerSource from '../../src/engine/windows-update/scripts/Install-UpdateEngine.ps1?raw';
import { commandLines, embedded, errorsOf, generateOk, profile } from './helpers';

const fixture = (name: string) => readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8');
/** Owner-default answer file for "Alex" as published with Milestone 1 (commit 24854a4). */
const M1_XML = fixture('m1-owner-default-alex.xml');

describe('Milestone 1 output is preserved', () => {
  it('engine disabled: owner defaults produce the Milestone 1 answer file byte for byte', () => {
    const r = generate(profile((p) => (p.windowsUpdate.enabled = false)));
    expect(r.ok).toBe(true);
    expect(r.xml).toBe(M1_XML);
    expect(r.assets).toEqual([]);
  });

  it('a schema v1 profile exported by Milestone 1 imports with the engine off and the same XML', () => {
    const v1 = JSON.parse(fixture('m1-owner-default.profile.json')) as Record<string, unknown>;
    expect(v1.schemaVersion).toBe(1);
    (v1.accounts as Record<string, unknown>).personName = 'Alex';
    const imported = importProfile(JSON.stringify(v1));
    expect(imported.errors).toEqual([]);
    expect(imported.profile!.schemaVersion).toBe(2);
    expect(imported.profile!.windowsUpdate.enabled).toBe(false);
    expect(imported.warnings.join(' ')).toMatch(/Windows Update automation .* turned off/);
    expect(generate(imported.profile).xml).toBe(M1_XML);
  });

  it('a v1 profile that somehow already has the section keeps it', () => {
    const v1 = JSON.parse(fixture('m1-owner-default.profile.json')) as Record<string, unknown>;
    v1.windowsUpdate = { enabled: true };
    expect(importProfile(JSON.stringify(v1)).profile!.windowsUpdate.enabled).toBe(true);
  });
});

describe('engine enabled (owner default)', () => {
  const r = generateOk(profile());

  it('embeds the engine, installer and config in the staging folder', () => {
    const files = r.embeddedFiles.filter((f) => f.path.startsWith(STAGING_DIR)).map((f) => f.path.slice(STAGING_DIR.length + 1));
    expect(files).toEqual(['WindowsUpdateEngine.ps1', 'Install-UpdateEngine.ps1', 'config.json']);
  });

  it('round-trips script text exactly through the XML (as Windows extracts it)', () => {
    const e = embedded(r.root);
    expect(e.get('WindowsUpdateEngine.ps1')).toBe(engineSource.replace(/\r?\n/g, '\n').trim());
    expect(e.get('Install-UpdateEngine.ps1')).toBe(installerSource.replace(/\r?\n/g, '\n').trim());
    expect(JSON.parse(e.get('config.json')!)).toEqual(engineConfig(profile()));
  });

  it('installs the engine as the very last FirstLogon command', () => {
    const fl = commandLines(r.root).firstLogon;
    expect(fl).toHaveLength(2);
    expect(fl.at(-1)).toBe(`powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "${STAGING_DIR}\\Install-UpdateEngine.ps1"`);
  });

  it('respects the hidden-window setting', () => {
    const hidden = generateOk(profile((p) => (p.setup.hidePowerShellWindows = true)));
    expect(commandLines(hidden.root).firstLogon.at(-1)).toContain('-WindowStyle "Hidden"');
  });

  it('still contains no disk automation', () => {
    expect(r.xml).not.toMatch(/DiskConfiguration|diskpart|clean\b|format\s+fs/i);
  });

  it('works when it is the only embedded content', () => {
    const only = generateOk(profile((p) => {
      p.accounts.accountMode = 'interactiveMicrosoft';
      p.accounts.computerNameMode = 'random';
      p.setup.keepSensitiveFiles = true;
      for (const k of Object.keys(p.bloatware)) p.bloatware[k] = 'untouched';
      Object.assign(p.privacy, { diagnosticData: 'windowsDefault', disableAdvertisingId: false, disableTailoredExperiences: false, disableInkingTypingCollection: false, disableLocation: false, disableAppSuggestions: false, disableBingResults: false, disableCopilot: false, disableRecall: false });
      Object.assign(p.system, { disableFastStartup: false, disableErrorReporting: false, powerShellExecutionPolicy: 'windowsDefault', preventDeviceApps: false, disablePointerPrecision: false, hideEdgeFirstRun: false, disableEdgeStartupBoost: false });
      Object.assign(p.explorer, { showFileExtensions: false, launchToThisPC: false, removeShortcutArrows: false });
      Object.assign(p.taskbar, { leftAlign: false, search: 'box', disableWidgets: false });
      Object.assign(p.desktop, { deleteEdgeShortcut: false, iconsMode: 'default' });
      p.start.foldersMode = 'default';
      p.security.uacLevel = 'windowsDefault';
      p.security.systemRestore = 'windowsDefault';
      p.security.disableInsiderBuilds = false;
      p.updates.mode = 'windowsDefault';
      p.updates.excludeDrivers = false;
    }, ''));
    const cl = commandLines(only.root);
    expect(cl.specialize).toHaveLength(1);
    expect(cl.specialize[0]).toContain('ExtractScript');
    expect(cl.firstLogon).toEqual([expect.stringContaining('Install-UpdateEngine.ps1')]);
  });
});

describe('engine configuration', () => {
  it('maps the owner defaults', () => {
    expect(engineConfig(profile())).toMatchObject({
      engineVersion: ENGINE_VERSION,
      dataRoot: 'C:\\ProgramData\\WindowsDeploymentBuilder',
      drivers: 'exclude',
      featureUpdates: 'skip',
      optionalUpdates: 'skip',
      microsoftUpdate: false,
      maxReboots: 10,
      maxAttemptsPerUpdate: 2,
      maxRuntimeHours: 6,
      networkWaitMinutes: 15,
      confirmationScans: 1,
      resetComponentsOnce: true,
      rebootWarningSeconds: 60,
      excludedKbs: [],
    });
  });

  it('"follow policy" for drivers tracks the M1 driver exclusion', () => {
    expect(engineConfig(profile((p) => (p.updates.excludeDrivers = false))).drivers).toBe('include');
    expect(engineConfig(profile((p) => (p.windowsUpdate.drivers = 'exclude'))).drivers).toBe('exclude');
  });

  it('parses KB lists leniently and de-duplicates', () => {
    expect(parseKbList('KB5034441, 5005463 kb5034441\nKB12')).toEqual({ kbs: ['KB5034441', 'KB5005463'], invalid: ['KB12'] });
    expect(engineConfig(profile((p) => (p.windowsUpdate.excludedKbs = 'kb5034441 5005463'))).excludedKbs).toEqual(['KB5034441', 'KB5005463']);
  });

  it('offers four downloadable assets with CRLF line endings', () => {
    const assets = updateEngineAssets(profile());
    expect(assets.map((a) => a.name)).toEqual(['WindowsUpdateEngine.ps1', 'Install-UpdateEngine.ps1', 'config.json', 'README-WindowsUpdate.txt']);
    for (const a of assets) {
      expect(a.content.replace(/\r\n/g, ''), a.name).not.toContain('\n');
      const nonAscii = [...a.content].filter((ch) => !(ch === '\t' || ch === '\n' || ch === '\r' || (ch >= ' ' && ch <= '~')));
      expect(nonAscii, a.name).toEqual([]);
    }
    expect(assets[3]!.content).toContain(COMPLETION_MARKER);
    expect(generateOk(profile()).assets.map((a) => a.name)).toEqual(assets.map((a) => a.name));
  });

  it('keeps the TypeScript and PowerShell engine versions in step', () => {
    expect(engineSource).toContain(`$script:EngineVersion = '${ENGINE_VERSION}'`);
  });

  it('ships no Deep Freeze or third-party module code', () => {
    for (const src of [engineSource, installerSource]) {
      expect(src).not.toMatch(/DeepFreeze|Deep Freeze|DFC\.exe|PSWindowsUpdate|Install-Module|PSGallery/i);
    }
  });
});

describe('validation', () => {
  it('rejects including drivers while the driver policy withholds them', () => {
    expect(errorsOf(profile((p) => (p.windowsUpdate.drivers = 'include')))).toEqual([
      expect.objectContaining({ path: 'windowsUpdate.drivers', message: expect.stringMatching(/conflicts/) }),
    ]);
    expect(generate(profile((p) => {
      p.windowsUpdate.drivers = 'include';
      p.updates.excludeDrivers = false;
    })).ok).toBe(true);
  });

  it.each([
    ['maxReboots', 0],
    ['maxReboots', 31],
    ['maxAttemptsPerUpdate', 6],
    ['maxRuntimeHours', 25],
    ['networkWaitMinutes', 0],
    ['confirmationScans', 6],
    ['rebootWarningSeconds', 601],
  ] as const)('rejects %s = %d with a field-level error', (key, value) => {
    expect(errorsOf(profile((p) => (p.windowsUpdate[key] = value)))).toEqual([
      expect.objectContaining({ path: `windowsUpdate.${key}`, message: expect.stringMatching(/between/) }),
    ]);
  });

  it('rejects malformed KB numbers', () => {
    expect(errorsOf(profile((p) => (p.windowsUpdate.excludedKbs = 'KB5034441, oops')))).toEqual([
      expect.objectContaining({ path: 'windowsUpdate.excludedKbs', message: expect.stringContaining('oops') }),
    ]);
  });

  it('ignores engine settings while the engine is disabled', () => {
    expect(generate(profile((p) => {
      p.windowsUpdate.enabled = false;
      p.windowsUpdate.maxReboots = 0;
      p.windowsUpdate.drivers = 'include';
    })).ok).toBe(true);
  });
});
