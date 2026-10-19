import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { generateOk, profile } from './helpers';

/**
 * Runs Windows PowerShell 5.1 against the generated scripts. Only possible on Windows; skipped
 * elsewhere. Nothing here scans for, installs or restarts anything.
 */
const onWindows = process.platform === 'win32';
const ps = (args: string[]) => execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', ...args], { encoding: 'utf8' });

describe.skipIf(!onWindows)('PowerShell (Windows only)', () => {
  it('every embedded .ps1 in the owner-default answer file parses without errors', () => {
    const dir = mkdtempSync(join(tmpdir(), 'wdb-parse-'));
    try {
      const files = generateOk(profile()).embeddedFiles.filter((f) => f.path.endsWith('.ps1'));
      expect(files.length).toBeGreaterThanOrEqual(5);
      files.forEach((f, i) => writeFileSync(join(dir, `${i}-${f.path.split('\\').pop()}`), f.content, 'utf8'));
      const out = ps([
        '-Command',
        `$bad = 0; Get-ChildItem -LiteralPath '${dir}' -Filter *.ps1 | ForEach-Object { $t = $null; $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$t, [ref]$e); if ($e.Count) { $bad++; "$($_.Name): $($e[0].Message)" } }; "bad=$bad"`,
      ]);
      expect(out.trim().split(/\r?\n/).at(-1)).toBe('bad=0');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 60_000);

  it('engine scenarios pass against the simulated Windows Update Agent', () => {
    const script = fileURLToPath(new URL('../powershell/Engine.Tests.ps1', import.meta.url));
    let out: string;
    try {
      out = ps(['-File', script]);
    } catch (e) {
      throw new Error(`Engine.Tests.ps1 failed:\n${(e as { stdout?: string }).stdout ?? e}`);
    }
    expect(out).toMatch(/\b\d+ passed, 0 failed/);
  }, 180_000);
});
