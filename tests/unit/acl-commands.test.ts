import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

/**
 * Static guard for the first bare-metal deployment failure (the behaviour itself is tested with
 * real NTFS folders in tests/powershell/Acl.Tests.ps1, Windows only):
 * "icacls <dir> /inheritance:r /grant:r *SID:(OI)(CI)F ... /T" left every file protected with no
 * entries, and with /C icacls still exited with 0, so the failure was never noticed.
 */

const SRC = fileURLToPath(new URL('../../src', import.meta.url));
const scripts = (dir: string): string[] =>
  readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    return statSync(p).isDirectory() ? scripts(p) : /\.(ps1|ts)$/.test(n) ? [p] : [];
  });
const icaclsLines = scripts(SRC).flatMap((f) =>
  readFileSync(f, 'utf8')
    .split(/\r?\n/)
    .map((line, i) => ({ where: `${f.slice(SRC.length + 1)}:${i + 1}`, line }))
    .filter((x) => /icacls(\.exe)?\b/i.test(x.line) && !/^\s*(#|\/\/|\*)/.test(x.line)),
);

describe('icacls calls in shipped scripts', () => {
  it('none applies inheritable (OI)/(CI) grants recursively with /T', () => {
    const bad = icaclsLines.filter((x) => /\/T\b/.test(x.line) && /\((OI|CI)\)/.test(x.line));
    expect(bad).toEqual([]);
  });

  it('a call whose exit code is checked does not use /C (which makes icacls exit with 0 on failure)', () => {
    const checked = icaclsLines.filter((x) => /\/grant|\/reset/.test(x.line) && !/\/T\b/.test(x.line) && /&\s*icacls/.test(x.line));
    expect(checked.length).toBeGreaterThanOrEqual(10);
    expect(checked.filter((x) => /\/C\b/.test(x.line))).toEqual([]);
  });

  it('every folder-protection function protects the folder itself and repairs damaged items below', () => {
    const files = ['deployment/scripts/Stage-Deployment.ps1', 'windows-update/scripts/Install-UpdateEngine.ps1', 'drivers/scripts/Install-DriverEngine.ps1', 'applications/scripts/Install-ApplicationEngine.ps1', 'applications/scripts/ApplicationEngine.ps1'];
    for (const f of files) {
      const text = readFileSync(join(SRC, 'engine', f), 'utf8');
      expect(text, f).toContain('& icacls.exe $Root /inheritance:r /grant:r @Grant /Q | Out-Null');
      expect(text, f).toContain('& icacls.exe $item.FullName /reset /Q | Out-Null');
    }
  });
});
