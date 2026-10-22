import { execFile, execFileSync } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { generateOk, profile } from './helpers';
import { wingetArguments } from '../../src/engine/applications';
import { ApplicationsResultSchema, RestorationResultSchema, WINGET_EXIT_CODES } from '../../src/engine/applications/results';
import { importInventory } from '../../src/engine/migration/inventory';
import { importBackupManifest } from '../../src/engine/migration/backup';
import { matchInventory } from '../../src/engine/migration/matching';
import { SETTINGS_ADAPTERS } from '../../src/engine/migration/adapters';
import { writeDeploymentFixture } from '../powershell/deployment-fixture';
import { writeWifiFixture } from '../powershell/wifi-fixture';

/**
 * Runs Windows PowerShell 5.1 against the generated scripts. Only possible on Windows; skipped
 * elsewhere. Nothing here scans for, installs or restarts anything.
 */
const onWindows = process.platform === 'win32';
const ps = (args: string[]) => execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', ...args], { encoding: 'utf8' });
/**
 * The scenario suites run for a minute or more: run them without blocking the worker's event loop
 * (a blocked worker misses Vitest's RPC heartbeat and the run fails with "Timeout calling onTaskUpdate").
 */
const run = promisify(execFile);
const psAsync = async (args: string[]) => (await run('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', ...args], { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 })).stdout;
const script = (rel: string) => fileURLToPath(new URL(rel, import.meta.url));
const stripBom = (s: string) => (s.charCodeAt(0) === 0xfeff ? s.slice(1) : s);

/** Owner defaults plus a small selection, so the application engine is embedded too. */
const withApps = () =>
  profile((p) => {
    p.applications.selection.added.push(
      { packageIdentifier: 'Git.Git', source: 'winget', displayName: 'Git', version: '', scope: '' },
      { packageIdentifier: '9MSPC6MP8FM4', source: 'msstore', displayName: 'Whiteboard', version: '', scope: '' },
    );
  });

function parseAll(files: { path: string; content: string }[]): string {
  const dir = mkdtempSync(join(tmpdir(), 'wdb-parse-'));
  try {
    files.forEach((f, i) => writeFileSync(join(dir, `${i}-${f.path.split('\\').pop()}`), f.content, 'utf8'));
    return ps([
      '-Command',
      `$bad = 0; Get-ChildItem -LiteralPath '${dir}' -Filter *.ps1 | ForEach-Object { $t = $null; $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$t, [ref]$e); if ($e.Count) { $bad++; "$($_.Name): $($e[0].Message)" } }; "bad=$bad"`,
    ]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

describe.skipIf(!onWindows)('PowerShell (Windows only)', () => {
  it('every embedded .ps1 (owner defaults plus applications) parses without errors', () => {
    const files = generateOk(withApps()).embeddedFiles.filter((f) => f.path.endsWith('.ps1'));
    expect(files.length).toBeGreaterThanOrEqual(8);
    expect(parseAll(files).trim().split(/\r?\n/).at(-1)).toBe('bad=0');
  }, 60_000);

  it('Windows Update engine scenarios pass against the simulated Windows Update Agent', async () => {
    let out: string;
    try {
      out = await psAsync(['-File', script('../powershell/Engine.Tests.ps1')]);
    } catch (e) {
      throw new Error(`Engine.Tests.ps1 failed:\n${(e as { stdout?: string }).stdout ?? e}`);
    }
    expect(out).toMatch(/\b\d+ passed, 0 failed/);
  }, 180_000);

  it('application engine and bootstrap scenarios pass; every result.json matches the published schema', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'wda-results-'));
    try {
      let out: string;
      try {
        out = await psAsync(['-File', script('../powershell/Applications.Tests.ps1'), '-ResultOut', dir]);
      } catch (e) {
        throw new Error(`Applications.Tests.ps1 failed:\n${(e as { stdout?: string }).stdout ?? e}`);
      }
      expect(out).toMatch(/\b\d+ passed, 0 failed/);
      const all = readdirSync(dir);
      const results = all.filter((f) => !f.startsWith('restoration-'));
      expect(results.sort()).toEqual(['bootstrap-failed.json', 'failures.json', 'followup.json', 'offline.json', 'phase5-backup.json', 'phase5-example-after.json', 'phase5-example-before.json', 'phase5-exhausted.json', 'phase5-recovered.json', 'phase6-restored.json', 'succeeded.json']);
      // Phase 6: restoration.json written by the engine matches the published schema.
      expect(all.filter((f) => f.startsWith('restoration-'))).toEqual(['restoration-phase6.json']);
      const restoration = RestorationResultSchema.safeParse(JSON.parse(stripBom(readFileSync(join(dir, 'restoration-phase6.json'), 'utf8'))));
      expect(restoration.success ? [] : restoration.error.issues).toEqual([]);
      for (const f of results) {
        const parsed = ApplicationsResultSchema.safeParse(JSON.parse(stripBom(readFileSync(join(dir, f), 'utf8'))));
        expect(parsed.success ? [] : parsed.error.issues, f).toEqual([]);
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 240_000);

  it('deployment orchestrator scenarios pass against the real generated package (Phase 4)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'wdd-fixture-'));
    try {
      writeDeploymentFixture(dir);
      let out: string;
      try {
        out = await psAsync(['-File', script('../powershell/Deployment.Tests.ps1'), '-Fixture', dir]);
      } catch (e) {
        throw new Error(`Deployment.Tests.ps1 failed:\n${(e as { stdout?: string }).stdout ?? e}`);
      }
      expect(out).toMatch(/\b\d+ passed, 0 failed/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 240_000);

  it('inventory, backup and restore scenarios pass (Phase 6); the collector output imports into the website', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'wdb-migration-'));
    try {
      let out: string;
      try {
        out = await psAsync(['-File', script('../powershell/Migration.Tests.ps1'), '-Out', dir]);
      } catch (e) {
        throw new Error(`Migration.Tests.ps1 failed:\n${(e as { stdout?: string }).stdout ?? e}`);
      }
      expect(out).toMatch(/\b\d+ passed, 0 failed/);
      // The real collector's files, produced from a synthetic computer, pass the website's strict import.
      const inv = importInventory(readFileSync(join(dir, 'inventory.json'), 'utf8'));
      expect(inv.errors).toEqual([]);
      const items = matchInventory(inv.inventory!);
      expect(items.find((i) => i.catalog?.id === 'git')).toMatchObject({ confidence: 'exact', recommendation: 'restore' });
      expect(items.find((i) => i.app.displayName === 'Contoso Field Tool')).toMatchObject({ classification: 'unknown' });
      const manifestBytes = new Uint8Array(readFileSync(join(dir, 'backup-manifest.json')));
      const b = importBackupManifest(manifestBytes);
      expect(b.errors).toEqual([]);
      expect(inv.inventory!.backup!.manifestSha256).toBe(b.reference!.manifestSha256);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 240_000);

  it('the adapter definitions of WdbMigration.ps1 match the website (ids, modes, applications, item names and kinds)', () => {
    const lib = script('../../src/engine/migration/scripts/WdbMigration.ps1');
    const out = ps(['-Command', `. '${lib}' -Mode Library; foreach ($k in $script:WdbAdapters.Keys) { $a = $script:WdbAdapters[$k]; '{0}|{1}|{2}|{3}|{4}' -f $k, $a.restoreMode, $a.requiresApp, ($a.appKeys -join ','), (($a.items | ForEach-Object { "$($_.logical):$($_.kind)" }) -join ',') }`]);
    const fromPs = out.trim().split(/\r?\n/);
    const fromTs = SETTINGS_ADAPTERS.map((a) => `${a.id}|${a.restoreMode}|${a.requiresApp ? 'True' : 'False'}|${a.appKeys.join(',')}|${a.items.map((i) => `${i.logical}:${i.kind}`).join(',')}`);
    expect(fromPs).toEqual(fromTs);
  }, 60_000);

  it('Wi-Fi profile script scenarios pass against the generated Wifi.xml and script (Phase 4.3)', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'wdw-fixture-'));
    try {
      writeWifiFixture(dir);
      let out: string;
      try {
        out = await psAsync(['-File', script('../powershell/Wifi.Tests.ps1'), '-Fixture', dir]);
      } catch (e) {
        throw new Error(`Wifi.Tests.ps1 failed:\n${(e as { stdout?: string }).stdout ?? e}`);
      }
      expect(out).toMatch(/\b\d+ passed, 0 failed/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 120_000);

  it('the engine builds exactly the WinGet commands the preview shows', () => {
    const engine = script('../../src/engine/applications/scripts/ApplicationEngine.ps1');
    const cases = [
      { packageIdentifier: 'Git.Git', source: 'winget', version: '', scope: '' },
      { packageIdentifier: 'Notepad++.Notepad++', source: 'winget', version: '8.6.9', scope: 'machine' },
      { packageIdentifier: '9MSPC6MP8FM4', source: 'msstore', version: '', scope: 'user' },
    ];
    const cmd = cases
      .flatMap((c) => ['install', 'list', 'show'].map((verb) => `(Get-WdaArguments '${verb}' @{ packageIdentifier = '${c.packageIdentifier}'; source = '${c.source}'; version = '${c.version}'; scope = '${c.scope}' }) -join ' '`))
      .join('; ');
    const out = ps(['-Command', `. '${engine}'; ${cmd}`]).trim().split(/\r?\n/);
    const expected = cases.flatMap((c) => (['install', 'list', 'show'] as const).map((verb) => wingetArguments(verb, c).join(' ')));
    expect(out).toEqual(expected);
  }, 60_000);

  it('PowerShell and TypeScript map the same WinGet exit codes the same way (status, retry, restart, failure class)', () => {
    const engine = script('../../src/engine/applications/scripts/ApplicationEngine.ps1');
    const out = ps(['-Command', `. '${engine}'; $script:ExitCodes.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0}|{1}|{2}|{3}|{4}' -f $_.Name, $_.Value[0], $_.Value[1], $_.Value[2], $_.Value[4] }`]);
    const fromPs = out.trim().split(/\r?\n/).sort();
    const fromTs = Object.entries(WINGET_EXIT_CODES)
      .map(([code, m]) => `${code}|${m.status}|${m.retry ? 'True' : 'False'}|${m.restart}|${m.class}`)
      .sort();
    expect(fromPs).toEqual(fromTs);
  }, 60_000);
});
