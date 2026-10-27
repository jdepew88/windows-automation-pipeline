import { describe, expect, it } from 'vitest';
import { commandLines, component, embedded, errorsOf, find, generateOk, profile } from './helpers';
import { exportProfile, hasSecrets, importProfile, ownerDefaults } from '../../src/engine/profiles';
import { buildDeploymentPackage } from '../../src/engine/deployment';
import { readZip } from '../../src/engine/deployment/zip';
import { SETTINGS_BY_PATH } from '../../src/features';
import { BYPASSES } from '../../src/features/setup';
import { obscurePassword } from '../../src/features/accounts';
import { elements, textContent, type XElement } from '../../src/engine/xml/tree';
import type { Profile } from '../../src/engine/schema/profile';

const labConfig = (value: string) => `reg.exe add "HKLM\\SYSTEM\\Setup\\LabConfig" /v ${value} /t REG_DWORD /d 1 /f`;
const setBypass = (p: Profile, path: string, on: boolean) => ((p.setup as Record<string, unknown>)[path.slice('setup.'.length)] = on);
const allOn = (p: Profile) => BYPASSES.forEach(([path]) => setBypass(p, path, true));

/** windowsPE › Microsoft-Windows-Setup › RunSynchronous items as [Order, Path]. */
function peCommands(root: XElement): [string, string][] {
  const rs = find(component(root, 'windowsPE', 'Microsoft-Windows-Setup')!, 'RunSynchronous');
  return rs ? elements(rs).map((i) => [textContent(find(i, 'Order')!), textContent(find(i, 'Path')!)]) : [];
}

describe('Windows 11 hardware-check bypasses', () => {
  it('are all off by default and the default answer file has no LabConfig command', () => {
    const d = ownerDefaults().setup;
    expect([d.bypassTpmCheck, d.bypassCpuCheck, d.bypassSecureBootCheck]).toEqual([false, false, false]);
    const r = generateOk(profile());
    expect(r.xml).not.toContain('LabConfig');
    expect(commandLines(r.root).windowsPE).toEqual([]);
  });

  it.each(BYPASSES.map(([path, , value]) => [path, value]))('%s alone adds only its own command (%s)', (path, value) => {
    const r = generateOk(profile((p) => setBypass(p, path, true)));
    expect(peCommands(r.root)).toEqual([['1', labConfig(value)]]);
    for (const [, , other] of BYPASSES) if (other !== value) expect(r.xml).not.toContain(other);
  });

  it('all three together run in order in windowsPE › Microsoft-Windows-Setup, edition and key unchanged', () => {
    const r = generateOk(profile(allOn));
    expect(peCommands(r.root)).toEqual([
      ['1', labConfig('BypassTPMCheck')],
      ['2', labConfig('BypassCPUCheck')],
      ['3', labConfig('BypassSecureBootCheck')],
    ]);
    // Nowhere else: not in specialize or a script.
    expect(r.xml.match(/LabConfig/g)).toHaveLength(3);
    const key = find(component(r.root, 'windowsPE', 'Microsoft-Windows-Setup')!, 'UserData/ProductKey')!;
    expect(textContent(find(key, 'Key')!)).toBe('VK7JG-NPHTM-C97JM-9MPGT-3V66T');
    expect(textContent(find(key, 'WillShowUI')!)).toBe('OnError');
    // Quotes need no escaping in element text; the file parses (generateOk) and the paths read back unchanged (above).
    expect(r.xml).toContain('<Path>reg.exe add "HKLM\\SYSTEM\\Setup\\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>');
  });

  it('keep Narrator first when both are on', () => {
    const r = generateOk(profile((p) => {
      allOn(p);
      p.setup.useNarrator = true;
    }));
    const paths = peCommands(r.root).map(([, path]) => path);
    expect(paths[0]).toContain('Narrator.exe');
    expect(paths.slice(1)).toEqual(BYPASSES.map(([, , v]) => labConfig(v)));
  });

  it('Windows 10 (x86 only) gets no bypass command and does not show the options; mixed media keeps them', () => {
    const r = generateOk(profile((p) => {
      allOn(p);
      p.setup.processorArchitectures = ['x86'];
    }));
    expect(r.xml).not.toContain('LabConfig');
    const x86 = profile((p) => (p.setup.processorArchitectures = ['x86']));
    for (const [path] of BYPASSES) {
      expect(SETTINGS_BY_PATH.get(path)!.visibleWhen!(x86), path).toBe(false);
      expect(SETTINGS_BY_PATH.get(path)!.visibleWhen!(profile()), path).toBe(true);
    }
    const mixed = generateOk(profile((p) => {
      allOn(p);
      p.setup.processorArchitectures = ['amd64', 'x86'];
    }));
    expect(commandLines(mixed.root).windowsPE).toEqual(BYPASSES.map(([, , v]) => labConfig(v)));
  });

  it('the ZIP answer file carries exactly the selected bypasses', () => {
    const p = profile((x) => {
      x.setup.bypassTpmCheck = true;
      x.setup.bypassSecureBootCheck = true;
    });
    const r = generateOk(p);
    const zip = readZip(buildDeploymentPackage(p, r).zip);
    const xml = new TextDecoder().decode(zip.find((e) => e.path === 'autounattend.xml')!.data);
    expect(xml).toBe(r.xml);
    expect(xml).toContain('/v BypassTPMCheck /t REG_DWORD /d 1 /f');
    expect(xml).toContain('/v BypassSecureBootCheck /t REG_DWORD /d 1 /f');
    expect(xml).not.toContain('BypassCPUCheck');
  });

  it('a schema 6 profile with the combined bypass keeps TPM and Secure Boot (RAM and CPU off), with a note', () => {
    const v6 = (on: boolean) => {
      const o = JSON.parse(exportProfile(profile())) as { schemaVersion: number; setup: Record<string, unknown> };
      o.schemaVersion = 6;
      delete o.setup.bypassTpmCheck;
      delete o.setup.bypassCpuCheck;
      delete o.setup.bypassSecureBootCheck;
      o.setup.bypassRequirementsCheck = on;
      return importProfile(JSON.stringify(o));
    };
    const on = v6(true);
    expect(on.errors).toEqual([]);
    expect(on.profile!.setup).toMatchObject({ bypassTpmCheck: true, bypassCpuCheck: false, bypassSecureBootCheck: true });
    expect(on.warnings.join(' ')).toMatch(/three separate options/);
    const off = v6(false);
    expect(off.profile!.setup).toMatchObject({ bypassTpmCheck: false, bypassCpuCheck: false, bypassSecureBootCheck: false });
    expect(off.warnings.join(' ')).not.toMatch(/three separate options/);
  });
});

describe('local account without an initial password', () => {
  const passwordless = (mutate?: (p: Profile) => void) =>
    profile((p) => {
      p.accounts.noInitialPassword = true;
      p.accounts.autoLogon = 'firstLogonOnly';
      mutate?.(p);
    });
  const passwordOf = (root: XElement, path: string) => {
    const pw = find(component(root, 'oobeSystem', 'Microsoft-Windows-Shell-Setup')!, path)!;
    return { value: textContent(find(pw, 'Value')!), plainText: textContent(find(pw, 'PlainText')!) };
  };

  it('is off by default; the owner default keeps its Base64 password element and persistent sign-in', () => {
    expect(ownerDefaults().accounts.noInitialPassword).toBe(false);
    const r = generateOk(profile());
    expect(passwordOf(r.root, 'UserAccounts/LocalAccounts/LocalAccount/Password')).toEqual({ value: obscurePassword('', 'Password'), plainText: 'false' });
    expect(embedded(r.root).get('FirstLogon.ps1')).toContain("-Name 'AutoAdminLogon' -Type 'String' -Value '1'");
  });

  it('writes an empty plain-text password: no placeholder, no Base64 substitute', () => {
    const r = generateOk(passwordless());
    for (const path of ['UserAccounts/LocalAccounts/LocalAccount/Password', 'AutoLogon/Password']) expect(passwordOf(r.root, path)).toEqual({ value: '', plainText: 'true' });
    expect(r.xml).not.toContain(obscurePassword('', 'Password'));
    expect(r.xml).not.toContain('<PlainText>false</PlainText>');
  });

  it('signs in automatically once only, and first-logon provisioning still runs', () => {
    const r = generateOk(passwordless());
    const shell = component(r.root, 'oobeSystem', 'Microsoft-Windows-Shell-Setup')!;
    expect(textContent(find(shell, 'AutoLogon/LogonCount')!)).toBe('1');
    const fl = embedded(r.root).get('FirstLogon.ps1')!;
    expect(fl).toContain("-Name 'AutoLogonCount' -Type 'DWord' -Force -Value 0");
    expect(fl).not.toContain('AutoAdminLogon');
    expect(fl).not.toContain('DefaultPassword');
    const firstLogon = commandLines(r.root).firstLogon;
    expect(firstLogon[0]).toContain('FirstLogon.ps1');
    expect(firstLogon.join('\n')).toContain('Initialize-Deployment.ps1');
  });

  it('refuses persistent automatic sign-in', () => {
    expect(errorsOf(passwordless((p) => (p.accounts.autoLogon = 'persistent')))).toEqual([expect.objectContaining({ path: 'accounts.autoLogon', message: expect.stringMatching(/without a password cannot keep automatic sign-in on/) })]);
  });

  it('without automatic sign-in: no AutoLogon element (keeping the files, as before)', () => {
    const r = generateOk(passwordless((p) => {
      p.accounts.autoLogon = 'none';
      p.setup.keepSensitiveFiles = true;
    }));
    expect(find(component(r.root, 'oobeSystem', 'Microsoft-Windows-Shell-Setup')!, 'AutoLogon')).toBeUndefined();
    expect(passwordOf(r.root, 'UserAccounts/LocalAccounts/LocalAccount/Password')).toEqual({ value: '', plainText: 'true' });
  });

  it('ignores a password typed earlier: it is not written and does not count as a secret', () => {
    const p = passwordless((x) => (x.accounts.password = 'S3cret!'));
    const r = generateOk(p);
    expect(r.xml).not.toContain('S3cret!');
    expect(r.xml).not.toContain(obscurePassword('S3cret!', 'Password'));
    expect(hasSecrets(p)).toBe(false);
  });

  it('an explicit password is unchanged (obscured, once)', () => {
    const r = generateOk(profile((p) => {
      p.accounts.password = 'S3cret!';
      p.accounts.autoLogon = 'firstLogonOnly';
    }));
    expect(passwordOf(r.root, 'UserAccounts/LocalAccounts/LocalAccount/Password')).toEqual({ value: obscurePassword('S3cret!', 'Password'), plainText: 'false' });
    expect(passwordOf(r.root, 'AutoLogon/Password')).toEqual({ value: obscurePassword('S3cret!', 'Password'), plainText: 'false' });
  });
});
