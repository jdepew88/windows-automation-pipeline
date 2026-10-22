import { writeWifiFixture } from './wifi-fixture';

// vite-node tests/powershell/make-wifi-fixture.ts <dir>   (used by npm run test:ps)
const out = process.argv.at(-1);
if (!out || out.endsWith('.ts')) throw new Error('usage: vite-node tests/powershell/make-wifi-fixture.ts <dir>');
writeWifiFixture(out);
console.log(`Wi-Fi fixture in ${out}`);
