import type { GenContext } from '../../engine/context';
import type { SettingDef } from '../../engine/settings/types';
import type { Profile } from '../../engine/schema/profile';
import type { Issue } from '../../engine/validation/issues';
import wifiScript from './Add-WifiProfile.ps1?raw';
import { parseXml } from '../../engine/xml/parse';
import { serializeFragment } from '../../engine/xml/serialize';
import { child, el, leaf, remove, textContent, type XElement } from '../../engine/xml/tree';

export const WLAN_NS = 'http://www.microsoft.com/networking/WLAN/profile/v1';
const WLAN_NS_V4 = 'http://www.microsoft.com/networking/WLAN/profile/v4';

const params = (p: Profile) => p.wifi.mode === 'parameters';

export const settings: SettingDef[] = [
  {
    path: 'wifi.mode',
    section: 'wifi',
    label: 'Wi-Fi during setup',
    control: 'radio',
    choices: [
      { value: 'interactive', label: 'Show the Wi-Fi page in OOBE and connect interactively (owner default)' },
      { value: 'skip', label: 'Skip Wi-Fi setup' },
      { value: 'parameters', label: 'Configure a network from SSID and password' },
      { value: 'profileXml', label: 'Import a WLAN profile XML (netsh wlan export profile)' },
    ],
    description:
      'Credentials entered here are written in plain text into the answer file and are never saved in the owner profile. Exported profiles leave them out by default.',
    applicability: 'Devices with a Wi-Fi adapter supported by inbox drivers',
    risk: 'SSID/password modes put the Wi-Fi key in the answer file. It is deleted from disk at first logon unless "Keep sensitive files" is on.',
    stages: ['oobeSystem', 'specialize'],
    mapping:
      'oobeSystem › Shell-Setup › OOBE/HideWirelessSetupInOOBE (false = interactive, true = skip). Profiles: embedded Wifi.xml and Add-WifiProfile.ps1. Specialize waits for WlanSvc, checks for a Wi-Fi adapter with a driver and runs netsh wlan add profile … user=all [connect]; without an adapter it retries once at the first sign-in. Result (no key): C:\\ProgramData\\WindowsDeploymentBuilder\\Network\\wifi-result.json.',
    advanced: false,
    verification: 'upstream-tested',
  },
  {
    path: 'wifi.ssid',
    section: 'wifi',
    label: 'Network name (SSID)',
    control: 'text',
    description: '1–32 bytes. Any characters, including spaces, quotes and non-Latin letters: the exact bytes are written as hex.',
    applicability: 'All',
    stages: ['specialize'],
    mapping: 'WLANProfile/name, SSIDConfig/SSID/name and hex',
    advanced: false,
    visibleWhen: params,
    verification: 'upstream-tested',
  },
  {
    path: 'wifi.authentication',
    section: 'wifi',
    label: 'Authentication',
    control: 'radio',
    choices: [
      { value: 'WPA2PSK', label: 'WPA2-Personal (AES)' },
      { value: 'WPA3SAE', label: 'WPA3-Personal (SAE, with WPA2 transition)' },
      { value: 'open', label: 'Open (no password)' },
    ],
    description: '',
    applicability: 'WPA3 requires a WPA3-capable adapter and driver',
    stages: ['specialize'],
    mapping: 'MSM/security/authEncryption/authentication + encryption',
    advanced: true,
    visibleWhen: params,
    verification: 'upstream-tested',
  },
  {
    path: 'wifi.password',
    section: 'wifi',
    label: 'Wi-Fi password',
    control: 'password',
    description: '8–63 characters.',
    applicability: 'All',
    risk: 'Stored in plain text in the answer file.',
    stages: ['specialize'],
    mapping: 'MSM/security/sharedKey/keyMaterial (protected=false)',
    advanced: false,
    visibleWhen: (p) => params(p) && p.wifi.authentication !== 'open',
    verification: 'upstream-tested',
  },
  {
    path: 'wifi.nonBroadcast',
    section: 'wifi',
    label: 'Connect even if the network is not broadcasting',
    control: 'checkbox',
    description: '',
    applicability: 'All',
    stages: ['specialize'],
    mapping: 'SSIDConfig/nonBroadcast = true',
    advanced: true,
    visibleWhen: params,
    verification: 'upstream-tested',
  },
  {
    path: 'wifi.connectAutomatically',
    section: 'wifi',
    label: 'Connect automatically',
    control: 'checkbox',
    description: '',
    applicability: 'All',
    stages: ['specialize'],
    mapping: 'connectionMode = auto, followed by netsh wlan connect',
    advanced: true,
    visibleWhen: params,
    verification: 'upstream-tested',
  },
  {
    path: 'wifi.profileXml',
    section: 'wifi',
    label: 'WLAN profile XML',
    control: 'textarea',
    placeholder: '<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1"> … </WLANProfile>',
    description: 'Export one with: netsh wlan export profile name="MyNet" key=clear',
    applicability: 'All',
    risk: 'Exports made with key=clear contain the password.',
    stages: ['specialize'],
    mapping: 'Embedded C:\\Windows\\Setup\\Scripts\\Wifi.xml',
    advanced: true,
    visibleWhen: (p) => p.wifi.mode === 'profileXml',
    verification: 'upstream-tested',
  },
];

const utf8Length = (s: string) => new TextEncoder().encode(s).length;

function hex(s: string): string {
  return [...new TextEncoder().encode(s)].map((b) => b.toString(16).padStart(2, '0').toUpperCase()).join('');
}

interface WifiProfile {
  doc: XElement;
  name: string;
  connectAutomatically: boolean;
}

function profileFromXml(xml: string): WifiProfile | string {
  const r = parseXml(xml);
  if (!r.root) return `WLAN profile XML is not well-formed: ${r.errors[0]}`;
  const root = r.root;
  if (root.name !== 'WLANProfile' || root.ns !== WLAN_NS) return `Root element must be <WLANProfile xmlns="${WLAN_NS}">.`;
  const name = child(root, 'name');
  const ssid = child(child(root, 'SSIDConfig') ?? root, 'SSID');
  if (!name || textContent(name).trim() === '') return 'WLAN profile must contain a <name>.';
  if (!ssid || (!child(ssid, 'name') && !child(ssid, 'hex'))) return 'WLAN profile must contain SSIDConfig/SSID/name or hex.';
  if (!child(root, 'MSM')) return 'WLAN profile must contain an <MSM> security section.';
  const mode = child(root, 'connectionMode');
  return { doc: root, name: textContent(name).trim(), connectAutomatically: mode ? textContent(mode).trim() === 'auto' : false };
}

/** Hex PSK (64 hex digits) instead of a passphrase. */
const HEX_KEY = /^[0-9a-fA-F]{64}$/;

/**
 * The WLAN profile name is only a local label: the network is matched by SSIDConfig/SSID/hex,
 * which carries the exact UTF-8 bytes. A name that netsh could mangle (quotes, non-ASCII) is
 * replaced by a stable ASCII label, so SSIDs with any characters work.
 */
export function wlanProfileName(ssid: string): string {
  return /^[\x20-\x7e]+$/.test(ssid) && !ssid.includes('"') && ssid.trim() === ssid ? ssid : `WiFi-${hex(ssid).slice(0, 12)}`;
}

function profileFromParameters(w: Profile['wifi']): WifiProfile {
  const ns = WLAN_NS;
  const name = wlanProfileName(w.ssid);
  const ssidConfig = el('SSIDConfig', ns, [el('SSID', ns, [leaf('hex', hex(w.ssid), ns), leaf('name', w.ssid, ns)])]);
  if (w.nonBroadcast) ssidConfig.children.push(leaf('nonBroadcast', 'true', ns));
  const auth = el('authEncryption', ns, [
    leaf('authentication', w.authentication === 'open' ? 'open' : w.authentication, ns),
    leaf('encryption', w.authentication === 'open' ? 'none' : 'AES', ns),
    leaf('useOneX', 'false', ns),
  ]);
  if (w.authentication === 'WPA3SAE') auth.children.push(leaf('transitionMode', 'true', WLAN_NS_V4));
  const security = el('security', ns, [auth]);
  if (w.authentication !== 'open') {
    security.children.push(el('sharedKey', ns, [leaf('keyType', HEX_KEY.test(w.password) ? 'networkKey' : 'passPhrase', ns), leaf('protected', 'false', ns), leaf('keyMaterial', w.password, ns)]));
  }
  const doc = el('WLANProfile', ns, [
    leaf('name', name, ns),
    ssidConfig,
    leaf('connectionType', 'ESS', ns),
    leaf('connectionMode', w.connectAutomatically ? 'auto' : 'manual', ns),
    el('MSM', ns, [security]),
  ]);
  return { doc, name, connectAutomatically: w.connectAutomatically };
}

export function validate(p: Profile, issues: Issue[]): void {
  const w = p.wifi;
  const err = (path: string, message: string) => issues.push({ severity: 'error', path, message });
  if (w.mode === 'parameters') {
    const len = utf8Length(w.ssid);
    if (len === 0) err('wifi.ssid', 'Enter the Wi-Fi network name (SSID). SSID must be 1–32 bytes long.');
    else if (len > 32) err('wifi.ssid', `SSID must be 1–32 bytes long (this one is ${len} bytes in UTF-8).`);
    if (w.authentication !== 'open') {
      if (w.password === '') err('wifi.password', 'Enter the Wi-Fi password, or choose "Open (no password)". WPA2/WPA3 passwords must be 8–63 printable ASCII characters.');
      else if (!HEX_KEY.test(w.password) && (w.password.length < 8 || w.password.length > 63 || /[^\x20-\x7e]/.test(w.password))) {
        err('wifi.password', 'WPA2/WPA3 passwords must be 8–63 printable ASCII characters (or a 64-digit hexadecimal key).');
      }
    }
  }
  if (w.mode === 'profileXml') {
    const r = profileFromXml(w.profileXml);
    if (typeof r === 'string') err('wifi.profileXml', r);
    else if (r.name.includes('"')) err('wifi.profileXml', 'Profile names containing double quotes are not supported.');
  }
  if ((w.mode === 'parameters' && w.authentication !== 'open') || (w.mode === 'profileXml' && /keyMaterial/i.test(w.profileXml))) {
    issues.push({ severity: 'warning', path: 'wifi.mode', message: 'The generated answer file (and the deployment ZIP) will contain the Wi-Fi password in plain text. Store it like a password: anyone with the USB drive or the ZIP can read it.' });
  }
}

export function modify(ctx: GenContext): void {
  const w = ctx.profile.wifi;
  const oobe = child(ctx.component('oobeSystem', 'Microsoft-Windows-Shell-Setup'), 'OOBE')!;
  const hide = child(oobe, 'HideWirelessSetupInOOBE')!;
  if (w.mode === 'interactive') {
    hide.children = [{ kind: 'text', value: 'false' }];
    return;
  }
  if (w.mode === 'skip') {
    hide.children = [{ kind: 'text', value: 'true' }];
    return;
  }
  remove(oobe, hide);
  const profile = w.mode === 'parameters' ? profileFromParameters(w) : (profileFromXml(w.profileXml) as WifiProfile);
  const xmlFile = ctx.embedFile('Wifi.xml', serializeFragment(profile.doc));
  // Phase 4.3: Add-WifiProfile.ps1 checks for the WLAN service and a Wi-Fi adapter with a driver,
  // adds the profile, records a result without the key and retries once at the first sign-in
  // (before the sensitive-file cleanup deletes Wifi.xml) if specialize had no adapter yet.
  const script = ctx.embedFile('Add-WifiProfile.ps1', wifiScript);
  const args = `-ProfilePath '${xmlFile}'${profile.connectAutomatically ? ' -Connect' : ''}`;
  ctx.seq.specialize.append(`& '${script}' -Stage Specialize ${args};`);
  ctx.seq.firstLogon.append(`& '${script}' -Stage FirstLogon ${args};`);
}
