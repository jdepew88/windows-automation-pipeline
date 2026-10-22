import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { generate } from '../../src/engine/pipeline';
import { ownerDefaults } from '../../src/engine/profiles';

/**
 * Fixture for Wifi.Tests.ps1: the Wi-Fi files the REAL generator embeds in the answer file
 * (Wifi.xml and Add-WifiProfile.ps1) for networks with special characters, written to <dir>\<case>.
 */
export const WIFI_CASES = {
  special: { ssid: 'Café "Guest" & <Lab> \'5G\'', password: `p@ss&<wo>"rd'$x`, authentication: 'WPA2PSK', connect: true, nonBroadcast: true },
  unicode: { ssid: 'Wi‑Fi 日本語 🚀', password: 'unicode-pass-123', authentication: 'WPA3SAE', connect: false, nonBroadcast: false },
  plain: { ssid: 'HomeNet', password: 'correct horse battery', authentication: 'WPA2PSK', connect: false, nonBroadcast: false },
} as const;

export function writeWifiFixture(dir: string): void {
  rmSync(dir, { recursive: true, force: true });
  for (const [name, c] of Object.entries(WIFI_CASES)) {
    const p = ownerDefaults();
    p.accounts.personName = 'Alex';
    p.wifi = { ...p.wifi, mode: 'parameters', ssid: c.ssid, password: c.password, authentication: c.authentication, connectAutomatically: c.connect, nonBroadcast: c.nonBroadcast };
    const r = generate(p);
    if (!r.ok) throw new Error(`${name}: ${JSON.stringify(r.issues.filter((i) => i.severity === 'error'))}`);
    const out = join(dir, name);
    mkdirSync(out, { recursive: true });
    for (const f of r.embeddedFiles) {
      const leaf = f.path.split('\\').pop()!;
      if (leaf === 'Wifi.xml' || leaf === 'Add-WifiProfile.ps1') writeFileSync(join(out, leaf), f.path.endsWith('.ps1') ? `\uFEFF${f.content}` : f.content, 'utf8');
    }
    writeFileSync(join(out, 'case.json'), JSON.stringify({ ...c, ssidHex: [...new TextEncoder().encode(c.ssid)].map((b) => b.toString(16).padStart(2, '0').toUpperCase()).join('') }), 'utf8');
  }
}
