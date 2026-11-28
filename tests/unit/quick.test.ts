import { describe, expect, it } from 'vitest';
import { generate } from '../../src/engine/pipeline';
import { resolveIdentity } from '../../src/engine/naming';
import { exportProfile, ownerDefaults } from '../../src/engine/profiles';
import { buildDeploymentPackage, buildManifest, updatePolicyPlan } from '../../src/engine/deployment';
import { ongoingPolicyDeferred } from '../../src/engine/windows-update';
import { resolveSelection } from '../../src/engine/applications/selection';
import { BUILTIN_PROFILES, builtinProfiles } from '../../src/engine/applications/builtin';
import {
  CUSTOMER_TYPES,
  STEPS,
  customerTypesFor,
  ackKey,
  blockingStep,
  computerNameInput,
  considerations,
  customizedSettings,
  isTypeSelected,
  reviewSummary,
  setComputerNameInput,
  setCustomerType,
  setLocationAllowed,
  setUpdateChoice,
  setUsernameInput,
  stepOfIssue,
  stepStatus,
  updateChoice,
  usernameInput,
} from '../../src/engine/quick';
import { wlanProfileName } from '../../src/features/wifi';
import { profile } from './helpers';
import ICONS from '../../src/data/apps/icons.json';
import { CATALOG, catalogEntryById, catalogRef } from '../../src/engine/applications/catalog';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const named = (fn: (p: ReturnType<typeof ownerDefaults>) => void = () => undefined) =>
  profile((p) => {
    p.accounts.personName = 'Alex';
    fn(p);
  });

describe('Phase 4.3 defaults', () => {
  it('new deployments start with Windows 11 Pro, x64, the predefined region and the owner update preference', () => {
    const p = ownerDefaults();
    expect(p.setup.editionMode).toBe('genericKey');
    expect(p.setup.editionId).toBe('pro');
    expect(p.setup.processorArchitectures).toEqual(['amd64']);
    expect(p.setup.languageMode).toBe('unattended');
    expect(updateChoice(p)).toBe('notify');
    expect(p.wifi.mode).toBe('interactive');
    // The x86 Visual C++ runtime stays in Core Essentials for 32-bit programs on x64 Windows.
    expect(BUILTIN_PROFILES.find((x) => x.id === 'core')!.packages.map((x) => x.packageIdentifier)).toEqual(expect.arrayContaining(['Microsoft.VCRedist.2015+.x64', 'Microsoft.VCRedist.2015+.x86']));
  });

  it('revision 1 (older deployments) keeps the Phase 4.2 defaults, except RustDesk (Phase 10: optional in Core Essentials)', () => {
    const defaults = (id: string) => builtinProfiles(1).find((x) => x.id === id)!.packages.map((x) => x.displayName);
    expect(defaults('gaming')).toEqual(['Steam', 'Epic Games Launcher']);
    expect(defaults('developer')).toEqual(['Git', 'Visual Studio Code', 'Python 3.14', 'Node.js (LTS)']);
    expect(defaults('core')).not.toContain('RustDesk');
    expect(builtinProfiles(1).find((x) => x.id === 'core')!.optional!.map((x) => x.displayName)).toContain('RustDesk');
  });

  it('new deployments use the rebuilt profiles (revision 2); Quick Deployment offers every type, older deployments only theirs', () => {
    const defaults = (id: string) => BUILTIN_PROFILES.find((x) => x.id === id)!.packages.map((x) => x.displayName);
    expect(ownerDefaults().applications.selection.profileRevision).toBe(2);
    expect(defaults('gaming')).toEqual(['Steam', 'Epic Games Launcher', 'Battle.net', 'GOG GALAXY', 'Ubisoft Connect', 'Rockstar Games Launcher', 'Discord']);
    expect(defaults('developer')).toEqual(['Git', 'Visual Studio Code', 'Python 3.14', 'Node.js (LTS)', 'GitHub CLI']);
    expect(CUSTOMER_TYPES.map((t) => t.profile)).toEqual(['everyday', 'gaming', 'music', 'student-office', 'creator', 'developer', 'network-engineer', 'remote-support', 'laptop', 'touch']);
    expect(customerTypesFor(ownerDefaults().applications.selection)).toEqual(CUSTOMER_TYPES);
    const old = { ...ownerDefaults().applications.selection, profileRevision: 1 as const };
    expect(customerTypesFor(old).map((t) => t.profile)).toEqual(['everyday', 'gaming', 'music', 'creator', 'developer', 'network-engineer', 'laptop', 'touch']);
  });
});

describe('shared configuration (wizard helpers edit the one profile)', () => {
  it('username and computer name fields map onto the existing account settings', () => {
    const p = ownerDefaults();
    setUsernameInput(p, 'Joe');
    expect(p.accounts.personName).toBe('Joe');
    expect(usernameInput(p)).toBe('Joe');
    expect(computerNameInput(p)).toBe('Joe-Computer');
    setComputerNameInput(p, 'DESKTOP-JOE');
    expect(p.accounts.computerNameMode).toBe('custom');
    expect(p.accounts.customComputerName).toBe('DESKTOP-JOE');
    setComputerNameInput(p, '');
    expect(p.accounts.computerNameMode).toBe('derived');
    p.accounts.usernameMode = 'custom';
    setUsernameInput(p, 'joe.admin');
    expect(p.accounts.customUsername).toBe('joe.admin');
    expect(p.accounts.personName).toBe('Joe');
  });

  it('customer types are the built-in profiles; overrides survive ticking and unticking types', () => {
    const p = ownerDefaults();
    setCustomerType(p, 'gaming', true);
    expect(isTypeSelected(p, 'gaming')).toBe(true);
    p.applications.selection.removed.push('winget:epicgames.epicgameslauncher');
    setCustomerType(p, 'music', true);
    setCustomerType(p, 'music', false);
    const r = resolveSelection(p.applications.selection);
    expect(r.packages.map((x) => x.key)).toContain('winget:valve.steam');
    expect(r.removed.map((x) => x.key)).toEqual(['winget:epicgames.epicgameslauncher']);
  });

  it('the update selector maps onto updates.mode; anything else is reported as custom', () => {
    const p = ownerDefaults();
    setUpdateChoice(p, 'recommended');
    expect(p.updates.mode).toBe('windowsDefault');
    setUpdateChoice(p, 'notify');
    expect(p.updates.mode).toBe('notifyInstall');
    p.updates.mode = 'notifyDownload';
    expect(updateChoice(p)).toBe('custom');
  });

  it('Advanced changes are detected as customizations', () => {
    const p = ownerDefaults();
    expect(customizedSettings(p, ['privacy.'])).toEqual([]);
    p.privacy.disableAdvertisingId = false;
    setLocationAllowed(p, true);
    expect(customizedSettings(p, ['privacy.']).map((x) => x.path).sort()).toEqual(['privacy.disableAdvertisingId', 'privacy.disableLocation']);
  });
});

describe('wizard steps and validation', () => {
  it('new deployments start with the local username "owner"; name and computer name stay independent', () => {
    const p = ownerDefaults();
    expect(usernameInput(p)).toBe('owner');
    expect(resolveIdentity(p.accounts).username).toBe('owner');
    expect(computerNameInput(p)).toBe('owner-Computer');
    expect(stepStatus(p, generate(p).issues, 'identity')).toBe('complete');
    expect(blockingStep(p, generate(p).issues, 'review')).toBeNull();
    // A typed computer name is kept when the username changes, and vice versa.
    setComputerNameInput(p, 'SHOP-PC01');
    setUsernameInput(p, 'Sam');
    expect(computerNameInput(p)).toBe('SHOP-PC01');
    expect(usernameInput(p)).toBe('Sam');
    setComputerNameInput(p, 'SHOP-PC02');
    expect(usernameInput(p)).toBe('Sam');
  });

  it('a missing username blocks every step after the first; defaults are not "incomplete"', () => {
    const p = ownerDefaults();
    setUsernameInput(p, '');
    const r = generate(p);
    expect(stepStatus(p, r.issues, 'identity')).toBe('incomplete');
    expect(blockingStep(p, r.issues, 'apps')).toBe('identity');
    const q = named();
    const r2 = generate(q);
    expect(stepStatus(q, r2.issues, 'identity')).toBe('complete');
    expect(stepStatus(q, r2.issues, 'type')).toBe('defaults');
    expect(stepStatus(q, r2.issues, 'network')).toBe('defaults');
    expect(stepStatus(q, r2.issues, 'apps')).toBe('defaults');
    expect(blockingStep(q, r2.issues, 'review')).toBeNull();
    // The review step waits for the acknowledgement of the empty-password administrator.
    expect(stepStatus(q, r2.issues, 'review')).toBe('incomplete');
    expect(stepStatus(q, r2.issues, 'review', (k) => k === ackKey(q, 'autologon-admin'))).toBe('complete');
  });

  it('Wi-Fi without SSID or password is reported at the network step', () => {
    const p = named((q) => (q.wifi.mode = 'parameters'));
    const r = generate(p);
    expect(r.ok).toBe(false);
    expect(r.issues.filter((i) => i.severity === 'error').map((i) => i.path).sort()).toEqual(['wifi.password', 'wifi.ssid']);
    expect(stepStatus(p, r.issues, 'network')).toBe('incomplete');
    expect(blockingStep(p, r.issues, 'apps')).toBe('network');
    expect(stepOfIssue({ path: 'wifi.ssid' })).toBe('network');
    expect(stepOfIssue({ path: 'applications.selection' })).toBe('apps');
    expect(stepOfIssue({ path: 'security.uacLevel' })).toBeNull();
  });

  it('an antivirus conflict is an apps-step error and blocks the review', () => {
    const p = named((q) => {
      for (const id of ['avast', 'avg']) q.applications.selection.added.push(catalogRef(catalogEntryById(id)!)!);
    });
    const r = generate(p);
    expect(r.ok).toBe(false);
    expect(r.issues.some((i) => i.severity === 'error' && stepOfIssue(i) === 'apps')).toBe(true);
    expect(blockingStep(p, r.issues, 'review')).toBe('apps');
  });

  it('has five steps in the requested order', () => {
    expect(STEPS.map((s) => s.id)).toEqual(['identity', 'type', 'network', 'apps', 'review']);
  });
});

describe('Final Review considerations: only when relevant', () => {
  it('owner defaults: empty-password administrator (ack), generic key, update approval, Bitwarden sign-in; RustDesk only when ticked', () => {
    const c = considerations(named());
    expect(c.map((x) => x.id)).toEqual(['autologon-admin', 'generic-key', 'update-approval', 'sign-in-apps']);
    const withRustDesk = considerations(named((q) => q.applications.selection.added.push(catalogRef(catalogEntryById('rustdesk')!)!)));
    expect(withRustDesk.map((x) => x.id)).toEqual(['autologon-admin', 'generic-key', 'update-approval', 'manual-apps', 'sign-in-apps']);
    expect(c.find((x) => x.id === 'autologon-admin')!.ack).toBeTruthy();
    expect(c.find((x) => x.id === 'generic-key')!.detail).toContain('does not license or activate');
  });

  it('no administrator warning without the risky combination; Wi-Fi secrets need consent', () => {
    const p = named((q) => {
      q.accounts.password = 'Secret#1';
      q.accounts.autoLogon = 'none';
      q.updates.mode = 'windowsDefault';
      q.wifi.mode = 'parameters';
      q.wifi.ssid = 'Home';
      q.wifi.password = 'wifi-pass-1';
    });
    const ids = considerations(p).map((x) => x.id);
    expect(ids).not.toContain('autologon-admin');
    expect(ids).not.toContain('update-approval');
    expect(ids).toEqual(expect.arrayContaining(['wifi-secret', 'wifi-driver']));
    expect(considerations(p).find((x) => x.id === 'wifi-secret')!.ack).toBeTruthy();
    // Acknowledgements are tied to the risk, so a different network asks again.
    const other = structuredClone(p);
    other.wifi.ssid = 'Office';
    expect(ackKey(p, 'wifi-secret')).not.toBe(ackKey(other, 'wifi-secret'));
  });

  it('the summary shows the effective configuration, never a password', () => {
    const p = named((q) => {
      q.wifi.mode = 'parameters';
      q.wifi.ssid = 'Home';
      q.wifi.password = 'never-show-me';
      setCustomerType(q, 'gaming', true);
      q.applications.selection.added.push(catalogRef(catalogEntryById('rustdesk')!)!);
    });
    const s = reviewSummary(p);
    expect(s.computer.computerName).toBe('Alex-Computer');
    expect(s.computer.edition).toBe('Windows 11 Pro');
    expect(s.computer.architecture).toBe('x64');
    expect(s.computer.computerTypes).toEqual(['Gamer']);
    expect(s.networking.password).toBe('Password entered (not shown)');
    expect(s.updates.timing).toContain('after the initial Windows Update stage');
    expect(s.applications.manual).toEqual(['Battle.net', 'RustDesk']);
    expect(JSON.stringify(s)).not.toContain('never-show-me');
  });
});

describe('ongoing Windows Update policy (separate from the initial update engine)', () => {
  // The embedded file itself (the finalization script only mentions its name in a comment).
  const POLICY_FILE = /<File path="[^"]*Set-UpdatePolicy\.ps1"/;
  it('engine on + notify mode: deferred to the monitor; the answer file does not write AUOptions', () => {
    const p = named();
    expect(ongoingPolicyDeferred(p)).toBe(true);
    const r = generate(p);
    expect(r.xml).not.toContain('/v "AUOptions"');
    expect(r.xml).toMatch(POLICY_FILE);
    expect(updatePolicyPlan(p)).toMatchObject({ mode: 'notifyInstall', applyAfter: 'windowsUpdate', values: { NoAutoUpdate: 0, AUOptions: 3 } });
    expect(buildManifest(p).manifest).toHaveProperty('updatePolicy.values.AUOptions', 3);
  });

  it('notify before download maps to AUOptions 2', () => {
    expect(updatePolicyPlan(named((q) => (q.updates.mode = 'notifyDownload')))!.values.AUOptions).toBe(2);
  });

  it('engine off: the policy is written during specialize exactly as before (no monitor step)', () => {
    const p = named((q) => (q.windowsUpdate.enabled = false));
    expect(ongoingPolicyDeferred(p)).toBe(false);
    const r = generate(p);
    expect(r.xml).toContain('/v "AUOptions" /t REG_DWORD /d 3');
    expect(r.xml).not.toMatch(POLICY_FILE);
    expect(updatePolicyPlan(p)).toBeNull();
  });

  it('Windows defaults: no policy anywhere, no updatePolicy in the manifest', () => {
    const p = named((q) => (q.updates.mode = 'windowsDefault'));
    const r = generate(p);
    expect(r.xml).not.toContain('AUOptions');
    expect(updatePolicyPlan(p)).toBeNull();
    expect(buildManifest(p).manifest).not.toHaveProperty('updatePolicy');
    expect(r.xml).not.toMatch(POLICY_FILE);
  });
});

describe('Wi-Fi provisioning', () => {
  it('profile names are netsh-safe; the SSID itself is kept exactly', () => {
    expect(wlanProfileName('HomeNet')).toBe('HomeNet');
    expect(wlanProfileName('Say "hi"')).toMatch(/^WiFi-[0-9A-F]{12}$/);
    expect(wlanProfileName('日本語')).toMatch(/^WiFi-E6/);
    expect(wlanProfileName(' lead')).toMatch(/^WiFi-/);
  });

  it('a 64-digit hex key is a network key; other passwords are passphrases', () => {
    const hex = 'a'.repeat(64);
    const r = generate(named((q) => Object.assign(q.wifi, { mode: 'parameters', ssid: 'Home', password: hex })));
    expect(r.ok).toBe(true);
    expect(r.embeddedFiles.find((f) => f.path.endsWith('Wifi.xml'))!.content).toContain('<keyType>networkKey</keyType>');
    const short = generate(named((q) => Object.assign(q.wifi, { mode: 'parameters', ssid: 'Home', password: 'short' })));
    expect(short.issues.find((i) => i.path === 'wifi.password')!.message).toContain('8–63');
  });

  it('SSIDs with quotes are accepted now (they were rejected before Phase 4.3)', () => {
    const r = generate(named((q) => Object.assign(q.wifi, { mode: 'parameters', ssid: 'Say "hi"', password: 'password-1' })));
    expect(r.ok).toBe(true);
  });

  it('the password is never in the exported profile, the review summary or the ZIP outside the answer file', () => {
    const p = named((q) => Object.assign(q.wifi, { mode: 'parameters', ssid: 'Home', password: 'zip-secret-123' }));
    expect(exportProfile(p)).not.toContain('zip-secret-123');
    const r = generate(p);
    const pkg = buildDeploymentPackage(p, r);
    expect(pkg.manifest.answerFile.containsSecrets).toBe(true);
    const json = JSON.stringify(pkg.manifest);
    expect(json).not.toContain('zip-secret-123');
    expect(pkg.warnings.join(' ')).toContain('Wi-Fi password');
  });
});

describe('application logos', () => {
  it('every logo belongs to a catalog app, exists as a bundled file and records its source and license', () => {
    const icons = (ICONS as { icons: Record<string, { file: string; source: string; license: string; kind: string }> }).icons;
    const ids = new Set(CATALOG.map((e) => e.id));
    expect(Object.keys(icons).length).toBeGreaterThanOrEqual(60);
    for (const [id, info] of Object.entries(icons)) {
      expect(ids.has(id), id).toBe(true);
      expect(existsSync(fileURLToPath(new URL(`../../public/${info.file}`, import.meta.url))), info.file).toBe(true);
      expect(info.source).toMatch(/^(simple-icons \d|https:\/\/raw\.githubusercontent\.com\/[^/]+\/[^/]+\/[0-9a-f]{40}\/)/);
      expect(info.license).not.toBe('');
      expect(['app', 'publisher']).toContain(info.kind);
    }
    for (const id of ['chrome', 'vlc', '7zip', 'bitwarden', 'steam', 'docker-desktop', 'wireshark', 'rufus', 'ventoy', 'qbittorrent', 'sabnzbd', 'syncthing']) expect(icons[id], id).toBeDefined();
  });
});
