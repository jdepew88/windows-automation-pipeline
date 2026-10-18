import type { GenContext } from '../../engine/context';
import type { SettingDef } from '../../engine/settings/types';
import type { Profile } from '../../engine/schema/profile';
import type { Issue } from '../../engine/validation/issues';
import { psQuote } from '../../engine/stages/commands';
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
      'oobeSystem › Shell-Setup › OOBE/HideWirelessSetupInOOBE (false = interactive, true = skip). Profiles: embedded Wifi.xml, then Specialize.ps1 waits for WlanSvc and runs netsh wlan add profile … user=all [connect].',
    advanced: false,
    verification: 'upstream-tested',
  },
  {
    path: 'wifi.ssid',
    section: 'wifi',
    label: 'Network name (SSID)',
    control: 'text',
    description: '1–32 bytes.',
    applicability: 'All',
    stages: ['specialize'],
    mapping: 'WLANProfile/name, SSIDConfig/SSID/name and hex',
    advanced: true,
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
    advanced: true,
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

function profileFromParameters(w: Profile['wifi']): WifiProfile {
  const ns = WLAN_NS;
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
    security.children.push(el('sharedKey', ns, [leaf('keyType', 'passPhrase', ns), leaf('protected', 'false', ns), leaf('keyMaterial', w.password, ns)]));
  }
  const doc = el('WLANProfile', ns, [
    leaf('name', w.ssid, ns),
    ssidConfig,
    leaf('connectionType', 'ESS', ns),
    leaf('connectionMode', w.connectAutomatically ? 'auto' : 'manual', ns),
    el('MSM', ns, [security]),
  ]);
  return { doc, name: w.ssid, connectAutomatically: w.connectAutomatically };
}

export function validate(p: Profile, issues: Issue[]): void {
  const w = p.wifi;
  const err = (path: string, message: string) => issues.push({ severity: 'error', path, message });
  if (w.mode === 'parameters') {
    const len = utf8Length(w.ssid);
    if (len < 1 || len > 32) err('wifi.ssid', 'SSID must be 1–32 bytes long.');
    if (w.ssid.includes('"')) err('wifi.ssid', 'SSIDs containing double quotes are not supported; use the profile XML option.');
    if (w.authentication !== 'open' && (w.password.length < 8 || w.password.length > 63 || /[^\x20-\x7e]/.test(w.password))) {
      err('wifi.password', 'WPA2/WPA3 passwords must be 8–63 printable ASCII characters.');
    }
  }
  if (w.mode === 'profileXml') {
    const r = profileFromXml(w.profileXml);
    if (typeof r === 'string') err('wifi.profileXml', r);
    else if (r.name.includes('"')) err('wifi.profileXml', 'Profile names containing double quotes are not supported.');
  }
  if ((w.mode === 'parameters' && w.authentication !== 'open') || (w.mode === 'profileXml' && /keyMaterial/i.test(w.profileXml))) {
    issues.push({ severity: 'warning', path: 'wifi.mode', message: 'The generated answer file will contain the Wi-Fi password in plain text. Store it like a password.' });
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
  ctx.seq.specialize.append(`$name = 'WlanSvc';
$start = [datetime]::Now;
$timeout = $start.AddMinutes( 1 );
$params = @{
  Id = 1;
  ParentId = 0;
  Activity = "Waiting for service '\${name}' to start.";
};
while( $true ) {
	if( $service = Get-Service -Name $name -ErrorAction 'SilentlyContinue' ) {
		if( $service.Status -eq 'Running' ) {
			break;
		}
	}
	if( [datetime]::Now -gt $timeout ) {
		"Service '\${name}' did not start in time." | Write-Warning;
		break;
	}
	Write-Progress @params -PercentComplete $(
		100 * ( [datetime]::Now - $start ).Ticks / ( $timeout - $start ).Ticks
	);
	Start-Sleep -Seconds 5;
}
Write-Progress @params -Completed;`);
  ctx.seq.specialize.append(`netsh.exe wlan add profile filename="${xmlFile}" user=all;`);
  if (profile.connectAutomatically) {
    ctx.seq.specialize.append(`netsh.exe wlan connect name=${psQuote(profile.name)} ssid=${psQuote(profile.name)};`);
  }
}
