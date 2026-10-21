import { describe, expect, it } from 'vitest';
import type { Script, ScriptPhase } from '../../src/engine/schema/profile';
import { generate } from '../../src/engine/pipeline';
import { commandLines, embedded, generateOk, noApps, profile } from './helpers';

const s = (id: string, type: Script['type'], content: string, enabled = true): Script => ({ id, name: id, type, enabled, content });

const HOSTILE = `Write-Host "Tom & Jerry's <script>" ; $x = '&amp;' # ]]> Ω`;

describe('custom scripts in the four stages', () => {
  it('empty lists produce no script files and no extra commands', () => {
    const r = generateOk(profile());
    const files = [...embedded(r.root).keys()];
    expect(files.some((f) => f.startsWith('unattend-'))).toBe(false);
  });

  it('blank or disabled entries never become phantom executions', () => {
    const base = generateOk(profile());
    const r = generateOk(profile((p) => {
      p.scripts.firstLogon.push(s('a', 'ps1', '   \n\t '), s('b', 'ps1', 'Write-Host hi', false));
      p.scripts.system.push(s('c', 'cmd', ''));
      p.scripts.userOnce.push(s('d', 'reg', '', false));
      p.scripts.defaultUser.push(s('e', 'ps1', '\n'));
    }));
    expect([...embedded(r.root).keys()].some((f) => f.startsWith('unattend-'))).toBe(false);
    expect(embedded(r.root).get('FirstLogon.ps1')).toBe(embedded(base.root).get('FirstLogon.ps1'));
    expect(commandLines(r.root)).toEqual(commandLines(base.root));
    expect(r.issues.filter((i) => i.severity === 'warning' && i.path.startsWith('scripts.')).map((i) => i.path).sort()).toEqual(['scripts.defaultUser.0', 'scripts.firstLogon.0', 'scripts.system.0']);
  });

  it('maps each stage to its sequence, preserving order and numbering files', () => {
    const r = generateOk(profile((p) => {
      p.scripts.system.push(s('sys1', 'ps1', 'Write-Output system'), s('sys2', 'cmd', 'echo system-cmd'));
      p.scripts.defaultUser.push(s('du', 'reg', '[HKEY_USERS\\DefaultUser\\Software\\Test]\r\n"A"=dword:00000001'));
      p.scripts.firstLogon.push(s('fl', 'vbs', 'WScript.Echo "first"'));
      p.scripts.userOnce.push(s('uo', 'ps1', 'Write-Output user'));
    }));
    const files = embedded(r.root);
    expect(files.get('unattend-01.ps1')).toBe('Write-Output system');
    expect(files.get('unattend-02.cmd')).toBe('echo system-cmd');
    expect(files.get('unattend-03.reg')).toMatch(/^Windows Registry Editor Version 5\.00\r?\n\r?\n\[HKEY_USERS\\DefaultUser\\Software\\Test\]/);
    expect(files.get('unattend-04.vbs')).toBe('WScript.Echo "first"');
    expect(files.get('unattend-05.ps1')).toBe('Write-Output user');

    const sp = files.get('Specialize.ps1')!;
    expect(sp.indexOf("& 'C:\\Windows\\Setup\\Scripts\\unattend-01.ps1';")).toBeLessThan(sp.indexOf('C:\\Windows\\Setup\\Scripts\\unattend-02.cmd;'));
    expect(files.get('DefaultUser.ps1')).toContain('reg.exe import "C:\\Windows\\Setup\\Scripts\\unattend-03.reg";');
    expect(files.get('FirstLogon.ps1')).toContain('cscript.exe //E:vbscript "C:\\Windows\\Setup\\Scripts\\unattend-04.vbs";');
    expect(files.get('UserOnce.ps1')).toContain("& 'C:\\Windows\\Setup\\Scripts\\unattend-05.ps1';");
    // UserOnce is wired through the default user's RunOnce key.
    expect(files.get('DefaultUser.ps1')).toContain('\\Microsoft\\Windows\\CurrentVersion\\RunOnce" /v "UnattendedSetup"');
  });

  it.each<ScriptPhase>(['system', 'defaultUser', 'firstLogon', 'userOnce'])('escapes script text exactly in %s', (phase) => {
    const r = generateOk(profile((p) => p.scripts[phase].push(s('x', 'ps1', HOSTILE))));
    expect(embedded(r.root).get('unattend-01.ps1')).toBe(HOSTILE);
    expect(r.xml).toContain('Tom &amp; Jerry\'s &lt;script&gt;');
    expect(r.xml).not.toContain('<script>');
  });

  it('rejects VBScript for DefaultUser', () => {
    const r = generate(profile((p) => p.scripts.defaultUser.push(s('v', 'vbs', 'x'))));
    expect(r.ok).toBe(false);
    expect(r.issues).toContainEqual(expect.objectContaining({ path: 'scripts.defaultUser.0', severity: 'error' }));
  });

  it('warns about HKCU in DefaultUser scripts', () => {
    const r = generate(profile((p) => p.scripts.defaultUser.push(s('h', 'cmd', 'reg add HKCU\\Software\\X /f'))));
    expect(r.ok).toBe(true);
    expect(r.issues).toContainEqual(expect.objectContaining({ path: 'scripts.defaultUser.0', severity: 'warning' }));
  });

  it('rejects duplicate script ids across stages', () => {
    const r = generate(profile((p) => {
      p.scripts.system.push(s('same', 'ps1', 'a'));
      p.scripts.userOnce.push(s('same', 'ps1', 'b'));
    }));
    expect(r.ok).toBe(false);
  });

  it('FirstLogon scripts alone still create the FirstLogonCommands entry', () => {
    const r = generateOk(profile((p) => {
      p.setup.keepSensitiveFiles = true;
      p.accounts.autoLogon = 'none';
      p.security.systemRestore = 'windowsDefault';
      p.windowsUpdate.enabled = false;
      noApps(p);
      p.scripts.firstLogon.push(s('only', 'cmd', 'echo hi'));
    }));
    expect(commandLines(r.root).firstLogon).toHaveLength(1);
    expect(embedded(r.root).get('FirstLogon.ps1')).toContain('unattend-01.cmd;');
  });
});
