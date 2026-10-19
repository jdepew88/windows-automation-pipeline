import { writeFileSync, mkdirSync } from 'node:fs';
import { generate } from '../src/engine/pipeline';
import { ownerDefaults } from '../src/engine/profiles';

/**
 * Writes docs/samples/autounattend.sample.xml from the owner defaults with a sample name, plus the
 * Windows Update engine assets to docs/samples/windows-update/.
 */
const profile = ownerDefaults();
profile.accounts.personName = process.argv[2] ?? 'Alex';
const result = generate(profile);
for (const i of result.issues) console.log(`${i.severity}: ${i.path} ${i.message}`);
if (!result.ok || !result.xml) process.exit(1);
mkdirSync('docs/samples/windows-update', { recursive: true });
writeFileSync('docs/samples/autounattend.sample.xml', result.xml);
for (const a of result.assets) writeFileSync(`docs/samples/windows-update/${a.name}`, a.content);
console.log(`Wrote docs/samples/autounattend.sample.xml (${result.xml.length} bytes, ${result.embeddedFiles.length} embedded files) and ${result.assets.length} asset(s)`);
