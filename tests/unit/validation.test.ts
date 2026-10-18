import { describe, expect, it } from 'vitest';
import { validateProfile } from '../../src/engine/validation/validate';
import { errorsOf, profile } from './helpers';

const paths = (errs: { path: string }[]) => errs.map((e) => e.path);

describe('cross-field validation (field-level messages, no output)', () => {
  it('requires a person name for the derived account', () => {
    expect(paths(errorsOf(profile(undefined, '')))).toContain('accounts.personName');
    expect(paths(errorsOf(profile(undefined, '李雷')))).toContain('accounts.personName');
  });

  it('rejects persistent auto-logon with a password', () => {
    const errs = errorsOf(profile((p) => (p.accounts.password = 'x')));
    expect(errs).toContainEqual(expect.objectContaining({ path: 'accounts.autoLogon', message: expect.stringMatching(/plain text/) }));
  });

  it('rejects auto-logon for a standard user', () => {
    expect(paths(errorsOf(profile((p) => (p.accounts.accountGroup = 'Users'))))).toContain('accounts.autoLogon');
  });

  it('rejects deleting sensitive files without a first logon', () => {
    expect(paths(errorsOf(profile((p) => (p.accounts.autoLogon = 'none'))))).toContain('setup.keepSensitiveFiles');
  });

  it('rejects computer name equal to username, and invalid custom names', () => {
    expect(paths(errorsOf(profile((p) => {
      p.accounts.computerNameMode = 'custom';
      p.accounts.customComputerName = 'Alex';
    })))).toContain('accounts.customComputerName');
    expect(paths(errorsOf(profile((p) => {
      p.accounts.computerNameMode = 'custom';
      p.accounts.customComputerName = '12345';
    })))).toContain('accounts.customComputerName');
    expect(paths(errorsOf(profile((p) => {
      p.accounts.usernameMode = 'custom';
      p.accounts.customUsername = 'Guest';
    })))).toContain('accounts.customUsername');
  });

  it('checks lockout and password-expiry ranges', () => {
    const errs = paths(errorsOf(profile((p) => {
      p.accounts.lockoutMode = 'custom';
      p.accounts.lockoutThreshold = 1000;
      p.accounts.lockoutDuration = 5;
      p.accounts.lockoutWindow = 10;
      p.accounts.passwordExpirationMode = 'custom';
      p.accounts.maxPasswordAge = 0;
    })));
    expect(errs).toEqual(expect.arrayContaining(['accounts.lockoutThreshold', 'accounts.lockoutWindow', 'accounts.maxPasswordAge']));
  });

  it('rejects the reboot workaround combined with a notify update mode', () => {
    expect(paths(errorsOf(profile((p) => (p.updates.preventAutomaticReboot = true))))).toContain('updates.preventAutomaticReboot');
  });

  it('validates product keys, architectures and catalog lookups', () => {
    const errs = paths(errorsOf(profile((p) => {
      p.setup.editionMode = 'customKey';
      p.setup.customProductKey = 'ABC';
      p.setup.processorArchitectures = [];
      p.setup.userLocale = 'xx-XX';
    })));
    expect(errs).toEqual(expect.arrayContaining(['setup.customProductKey', 'setup.processorArchitectures', 'setup.userLocale']));
  });

  it('validates Wi-Fi parameters and XML profiles', () => {
    expect(paths(errorsOf(profile((p) => {
      p.wifi.mode = 'parameters';
      p.wifi.ssid = '';
      p.wifi.password = 'short';
    })))).toEqual(expect.arrayContaining(['wifi.ssid', 'wifi.password']));
    expect(paths(errorsOf(profile((p) => {
      p.wifi.mode = 'profileXml';
      p.wifi.profileXml = '<WLANProfile><name>x</name>';
    })))).toContain('wifi.profileXml');
    expect(paths(errorsOf(profile((p) => {
      p.wifi.mode = 'profileXml';
      p.wifi.profileXml = '<WLANProfile><name>x</name></WLANProfile>';
    })))).toContain('wifi.profileXml');
  });

  it('validates AppLocker policy XML', () => {
    expect(paths(errorsOf(profile((p) => (p.security.appLockerMode = 'policy'))))).toContain('security.appLockerPolicyXml');
    expect(paths(errorsOf(profile((p) => {
      p.security.appLockerMode = 'policy';
      p.security.appLockerPolicyXml = '<AppLockerPolicy><oops></AppLockerPolicy>';
    })))).toContain('security.appLockerPolicyXml');
  });

  it('rejects removal of apps without a mechanism and unknown apps', () => {
    expect(paths(errorsOf(profile((p) => (p.bloatware.WindowsBackup = 'remove'))))).toContain('bloatware.WindowsBackup');
    expect(paths(errorsOf(profile((p) => (p.bloatware.NotAnApp = 'remove'))))).toContain('bloatware');
  });

  it('rejects invalid Start pins JSON', () => {
    expect(paths(errorsOf(profile((p) => {
      p.start.pinsMode = 'custom';
      p.start.pinsJson = '{nope';
    })))).toContain('start.pinsJson');
  });

  it('rejects characters that XML cannot carry, wherever they are', () => {
    const errs = errorsOf(profile((p) => p.scripts.firstLogon.push({ id: 'a', name: 'x', type: 'ps1', enabled: true, content: 'echo \u0001' })));
    expect(errs).toContainEqual(expect.objectContaining({ path: 'scripts.firstLogon.0.content' }));
  });

  it('warns (but still generates) for Wi-Fi passwords in the answer file', () => {
    const { issues } = validateProfile(profile((p) => {
      p.wifi.mode = 'parameters';
      p.wifi.ssid = 'Home';
      p.wifi.password = 'longenough';
    }));
    expect(issues).toEqual([expect.objectContaining({ severity: 'warning', path: 'wifi.mode' })]);
  });

  it('owner default with a name has no issues at all', () => {
    expect(validateProfile(profile()).issues).toEqual([]);
  });
});
