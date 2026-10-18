import { describe, expect, it } from 'vitest';
import { generate } from '../../src/engine/pipeline';
import { ownerDefaults } from '../../src/engine/profiles';
import { getAttr, textContent, walk } from '../../src/engine/xml/tree';
import { NS } from '../../src/engine/xml/tree';
import { commandLines, component, components, embedded, find, generateOk, profile, texts } from './helpers';

describe('owner-default answer file', () => {
  const r = generateOk(profile());

  it('matches the snapshot', () => {
    expect(r.xml).toMatchSnapshot();
  });

  it('has only valid passes and the unattend/wcm namespaces on the root', () => {
    expect(r.root.name).toBe('unattend');
    expect(r.root.ns).toBe(NS.unattend);
    expect(r.xml).toContain('xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"');
    const passes = r.root.children.filter((c) => c.kind === 'element' && c.name === 'settings').map((s) => getAttr(s as never, 'pass'));
    expect(passes).toEqual(['offlineServicing', 'windowsPE', 'generalize', 'specialize', 'auditSystem', 'auditUser', 'oobeSystem']);
  });

  it('targets amd64 only, with WSIM identity attributes', () => {
    for (const e of walk(r.root)) {
      if (e.name !== 'component') continue;
      expect(getAttr(e, 'processorArchitecture')).toBe('amd64');
      expect(getAttr(e, 'publicKeyToken')).toBe('31bf3856ad364e35');
      expect(getAttr(e, 'language')).toBe('neutral');
      expect(getAttr(e, 'versionScope')).toBe('nonSxS');
    }
  });

  it('keeps disk selection interactive: no disk configuration or wipe', () => {
    const names = new Set([...walk(r.root)].map((e) => e.name));
    for (const forbidden of ['DiskConfiguration', 'Disk', 'CreatePartitions', 'ModifyPartitions', 'WillWipeDisk', 'ImageInstall', 'InstallTo', 'InstallToAvailablePartition']) {
      expect(names.has(forbidden)).toBe(false);
    }
    expect(r.xml).not.toMatch(/diskpart|clean\b|format\s+fs/i);
    expect(commandLines(r.root).windowsPE).toEqual([]);
  });

  it('selects Windows 11 Pro with the generic installation key and en-US settings', () => {
    const setup = component(r.root, 'windowsPE', 'Microsoft-Windows-Setup')!;
    expect(textContent(find(setup, 'UserData/ProductKey/Key')!)).toBe('VK7JG-NPHTM-C97JM-9MPGT-3V66T');
    expect(textContent(find(setup, 'UserData/ProductKey/WillShowUI')!)).toBe('OnError');
    expect(textContent(find(setup, 'UserData/AcceptEula')!)).toBe('true');
    const intl = component(r.root, 'oobeSystem', 'Microsoft-Windows-International-Core')!;
    expect(textContent(find(intl, 'InputLocale')!)).toBe('0409:00000409');
    expect(textContent(find(intl, 'UserLocale')!)).toBe('en-US');
    expect(textContent(find(component(r.root, 'windowsPE', 'Microsoft-Windows-International-Core-WinPE')!, 'UILanguage')!)).toBe('en-US');
    // Product key used for activation is NOT written (generic key only selects the edition).
    expect(find(component(r.root, 'specialize', 'Microsoft-Windows-Shell-Setup')!, 'ProductKey')).toBeUndefined();
  });

  it('creates one local administrator with auto-logon and derived names', () => {
    const shell = component(r.root, 'oobeSystem', 'Microsoft-Windows-Shell-Setup')!;
    const acct = find(shell, 'UserAccounts/LocalAccounts/LocalAccount')!;
    expect(getAttr(acct, 'action', NS.wcm)).toBe('add');
    expect(textContent(find(acct, 'Name')!)).toBe('Alex');
    expect(textContent(find(acct, 'Group')!)).toBe('Administrators');
    expect(textContent(find(shell, 'AutoLogon/Username')!)).toBe('Alex');
    expect(textContent(find(shell, 'AutoLogon/Enabled')!)).toBe('true');
    expect(textContent(find(component(r.root, 'specialize', 'Microsoft-Windows-Shell-Setup')!, 'ComputerName')!)).toBe('Alex-Computer');
    expect(textContent(find(shell, 'OOBE/HideOnlineAccountScreens')!)).toBe('true');
    expect(textContent(find(shell, 'OOBE/ProtectYourPC')!)).toBe('3');
    expect(textContent(find(shell, 'OOBE/HideWirelessSetupInOOBE')!)).toBe('false');
  });

  it('does not leak secrets in plain text', () => {
    expect(texts(r.root, 'PlainText')).toEqual(['false', 'false']);
    expect(r.xml).not.toMatch(/<PlainText>true/);
    expect(r.xml).not.toContain('keyMaterial');
  });

  it('maps FirstLogon to oobeSystem FirstLogonCommands with ordered commands', () => {
    const cl = commandLines(r.root);
    expect(cl.firstLogon).toEqual(['powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "C:\\Windows\\Setup\\Scripts\\FirstLogon.ps1"']);
    expect(cl.specialize[0]).toContain('$xml.unattend.Extensions.ExtractScript');
    expect(cl.specialize.slice(1)).toEqual([
      'powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "C:\\Windows\\Setup\\Scripts\\Specialize.ps1"',
      'reg.exe load "HKU\\DefaultUser" "C:\\Users\\Default\\NTUSER.DAT"',
      'powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "C:\\Windows\\Setup\\Scripts\\DefaultUser.ps1"',
      'reg.exe unload "HKU\\DefaultUser"',
    ]);
    expect(texts(r.root, 'Order')).toEqual(['1', '2', '3', '4', '5', '1']);
  });

  it('applies the owner security and system choices in the staged scripts', () => {
    const files = embedded(r.root);
    const sp = files.get('Specialize.ps1')!;
    expect(sp).toContain('/v "EnableLUA" /t REG_DWORD /d 1');
    expect(sp).toContain('/v "ConsentPromptBehaviorAdmin" /t REG_DWORD /d 5');
    expect(sp).toContain('/v "PromptOnSecureDesktop" /t REG_DWORD /d 0');
    expect(sp).toContain('/v "HiberbootEnabled" /t REG_DWORD /d 0');
    expect(sp).not.toMatch(/powercfg|hibernate/i);
    expect(sp).toContain("-ExecutionPolicy 'RemoteSigned'");
    expect(sp).toContain('/v "AUOptions" /t REG_DWORD /d 3');
    expect(sp).toContain('ExcludeWUDriversInQualityUpdate');
    expect(sp).not.toMatch(/SmartScreenEnabled|VerifiedAndReputablePolicyState|PreventDeviceEncryption|fDenyTSConnections|EnableVirtualizationBasedSecurity/);
    const du = files.get('DefaultUser.ps1')!;
    expect(du).toContain('/v "HideFileExt" /t REG_DWORD /d 0');
    expect(du).toContain('/v "TaskbarAl" /t REG_DWORD /d 0');
    expect(du).not.toContain('ShowTaskViewButton');
    expect(du).toContain('RunOnce');
    const fl = files.get('FirstLogon.ps1')!;
    expect(fl).toContain("Enable-ComputerRestore -Drive 'C:\\'");
    expect(fl).toContain("Remove-ItemProperty -LiteralPath 'Registry::HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon' -Name 'AutoLogonCount'");
    expect(fl).toContain('C:\\Windows\\Panther\\unattend.xml');
  });

  it('removes exactly the owner-selected apps and nothing marked Keep', () => {
    const pkg = embedded(r.root).get('RemovePackage.ps1')!;
    for (const id of ['Microsoft.BingNews', 'Clipchamp.Clipchamp', 'Microsoft.WindowsFeedbackHub', 'MSTeams', 'Microsoft.ZuneVideo', 'Microsoft.Getstarted']) {
      expect(pkg).toContain(`'${id}';`);
    }
    for (const kept of ['Microsoft.WindowsCalculator', 'Microsoft.WindowsStore', 'Microsoft.YourPhone', 'Microsoft.XboxIdentityProvider', 'Microsoft.549981C3F5F10', 'Microsoft.Windows.Photos']) {
      expect(pkg).not.toContain(kept);
    }
    expect(pkg).toMatch(/OSVersion\.Version\.Build -lt 22000/);
    expect(embedded(r.root).has('RemoveFeature.ps1')).toBe(false);
  });

  it('only contains ASCII', () => {
    expect(/^[\t\n\r\x20-\x7e]*$/.test(r.xml)).toBe(true);
  });
});

describe('variations', () => {
  it('interactive language removes both international components', () => {
    const r = generateOk(profile((p) => (p.setup.languageMode = 'interactive')));
    expect(component(r.root, 'windowsPE', 'Microsoft-Windows-International-Core-WinPE')).toBeUndefined();
    expect(component(r.root, 'oobeSystem', 'Microsoft-Windows-International-Core')).toBeUndefined();
  });

  it('fans out every component per architecture', () => {
    const r = generateOk(profile((p) => (p.setup.processorArchitectures = ['amd64', 'arm64'])));
    for (const pass of ['windowsPE', 'specialize', 'oobeSystem']) {
      const comps = components(r.root, pass);
      const names = comps.map((c) => getAttr(c, 'name'));
      expect(comps.filter((c) => getAttr(c, 'processorArchitecture') === 'amd64').length).toBe(comps.length / 2);
      expect(new Set(names).size).toBe(comps.length / 2);
    }
    expect(r.xml).toMatchSnapshot();
  });

  it('firmware key omits <Key> and never shows UI', () => {
    const r = generateOk(profile((p) => (p.setup.editionMode = 'firmware')));
    const pk = find(component(r.root, 'windowsPE', 'Microsoft-Windows-Setup')!, 'UserData/ProductKey')!;
    expect(find(pk, 'Key')).toBeUndefined();
    expect(textContent(find(pk, 'WillShowUI')!)).toBe('Never');
  });

  it('interactive edition uses the all-zero key with WillShowUI=Always', () => {
    const r = generateOk(profile((p) => (p.setup.editionMode = 'interactive')));
    const pk = find(component(r.root, 'windowsPE', 'Microsoft-Windows-Setup')!, 'UserData/ProductKey')!;
    expect(textContent(find(pk, 'Key')!)).toBe('00000-00000-00000-00000-00000');
    expect(textContent(find(pk, 'WillShowUI')!)).toBe('Always');
  });

  it('bypass requirements adds windowsPE LabConfig commands with order', () => {
    const r = generateOk(profile((p) => (p.setup.bypassRequirementsCheck = true)));
    const cl = commandLines(r.root).windowsPE;
    expect(cl).toHaveLength(3);
    expect(cl[0]).toBe('reg.exe add "HKLM\\SYSTEM\\Setup\\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f');
  });

  it('interactive local account removes UserAccounts/AutoLogon and hides online screens', () => {
    const r = generateOk(profile((p) => {
      p.accounts.accountMode = 'interactiveLocal';
      p.accounts.computerNameMode = 'random';
    }, ''));
    const shell = component(r.root, 'oobeSystem', 'Microsoft-Windows-Shell-Setup')!;
    expect(find(shell, 'UserAccounts')).toBeUndefined();
    expect(find(shell, 'AutoLogon')).toBeUndefined();
    expect(textContent(find(shell, 'OOBE/HideOnlineAccountScreens')!)).toBe('true');
  });

  it('first-logon-only auto-logon resets the counter instead of making it persistent', () => {
    const r = generateOk(profile((p) => (p.accounts.autoLogon = 'firstLogonOnly')));
    const fl = embedded(r.root).get('FirstLogon.ps1')!;
    expect(fl).toContain("-Name 'AutoLogonCount' -Type 'DWord' -Force -Value 0");
    expect(fl).not.toContain('AutoAdminLogon');
  });

  it('plain-text passwords only when obscuring is turned off', () => {
    const r = generateOk(profile((p) => {
      p.accounts.autoLogon = 'firstLogonOnly';
      p.accounts.password = 'S3cret&"<pw>';
      p.accounts.obscurePasswords = false;
    }));
    expect(texts(r.root, 'Value')).toContain('S3cret&"<pw>');
    expect(r.xml).toContain('S3cret&amp;"&lt;pw&gt;');
  });

  it('Wi-Fi parameters embed an escaped WLAN profile and remove the OOBE Wi-Fi switch', () => {
    const r = generateOk(profile((p) => {
      p.wifi.mode = 'parameters';
      p.wifi.ssid = "Café & Bar's <Net>";
      p.wifi.password = 'pa&ss"word<1>';
    }));
    expect(find(component(r.root, 'oobeSystem', 'Microsoft-Windows-Shell-Setup')!, 'OOBE/HideWirelessSetupInOOBE')).toBeUndefined();
    const wifi = embedded(r.root).get('Wifi.xml')!;
    expect(wifi).toContain('<keyMaterial>pa&amp;ss"word&lt;1&gt;</keyMaterial>');
    expect(wifi).toContain('<name>Caf&#xE9; &amp; Bar\'s &lt;Net&gt;</name>');
    expect(wifi).toContain('<hex>436166C3A9'); // UTF-8 bytes of "Café"
    expect(embedded(r.root).get('Specialize.ps1')).toContain("netsh.exe wlan connect name='Café & Bar''s <Net>'");
  });

  it('skip Wi-Fi hides the OOBE wireless page', () => {
    const r = generateOk(profile((p) => (p.wifi.mode = 'skip')));
    expect(textContent(find(component(r.root, 'oobeSystem', 'Microsoft-Windows-Shell-Setup')!, 'OOBE/HideWirelessSetupInOOBE')!)).toBe('true');
  });

  it('interactive express settings removes ProtectYourPC', () => {
    const r = generateOk(profile((p) => (p.privacy.expressSettings = 'interactive')));
    expect(find(component(r.root, 'oobeSystem', 'Microsoft-Windows-Shell-Setup')!, 'OOBE/ProtectYourPC')).toBeUndefined();
  });

  it('explicit time zone is written in specialize', () => {
    const r = generateOk(profile((p) => {
      p.setup.timeZoneMode = 'explicit';
      p.setup.timeZone = 'W. Europe Standard Time';
    }));
    expect(textContent(find(component(r.root, 'specialize', 'Microsoft-Windows-Shell-Setup')!, 'TimeZone')!)).toBe('W. Europe Standard Time');
  });

  it('a minimal profile with every optional action off still produces valid XML', () => {
    const r = generateOk(profile((p) => {
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
    expect(r.xml).not.toContain('Extensions');
    expect(r.xml).not.toContain('RunSynchronous');
    expect(r.xml).not.toContain('FirstLogonCommands');
    expect(r.xml).toMatchSnapshot();
  });
});

describe('account name edits propagate', () => {
  it.each([
    ['Sam', 'Sam', 'Sam-Computer'],
    ['Zoë Ålund', 'ZoeAlund', 'ZoeAlu-Computer'],
    ['Maximilian', 'Maximilian', 'Maximi-Computer'],
  ])('%j → user %j, computer %j', (name, user, computer) => {
    const r = generateOk(profile(undefined, name));
    const shell = component(r.root, 'oobeSystem', 'Microsoft-Windows-Shell-Setup')!;
    expect(textContent(find(shell, 'UserAccounts/LocalAccounts/LocalAccount/Name')!)).toBe(user);
    expect(textContent(find(shell, 'UserAccounts/LocalAccounts/LocalAccount/DisplayName')!)).toBe(name);
    expect(textContent(find(shell, 'AutoLogon/Username')!)).toBe(user);
    expect(textContent(find(component(r.root, 'specialize', 'Microsoft-Windows-Shell-Setup')!, 'ComputerName')!)).toBe(computer);
    expect(embedded(r.root).get('FirstLogon.ps1')).toContain(`-Name 'DefaultUserName' -Type 'String' -Value '${user}'`);
  });

  it('owner default without a name refuses to generate', () => {
    const r = generate(ownerDefaults());
    expect(r.ok).toBe(false);
    expect(r.issues).toContainEqual(expect.objectContaining({ path: 'accounts.personName', severity: 'error' }));
  });
});
