import { writeFileSync, mkdirSync } from 'node:fs';
import { generate } from '../src/engine/pipeline';
import { ownerDefaults } from '../src/engine/profiles';

/** Writes docs/samples/autounattend.sample.xml from the owner defaults with a sample name. */
const profile = ownerDefaults();
profile.accounts.personName = process.argv[2] ?? 'Alex';
const result = generate(profile);
for (const i of result.issues) console.log(`${i.severity}: ${i.path} ${i.message}`);
if (!result.ok || !result.xml) process.exit(1);
mkdirSync('docs/samples', { recursive: true });
writeFileSync('docs/samples/autounattend.sample.xml', result.xml);
console.log(`Wrote docs/samples/autounattend.sample.xml (${result.xml.length} bytes, ${result.embeddedFiles.length} embedded files)`);
