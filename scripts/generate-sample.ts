import { writeFileSync, mkdirSync } from 'node:fs';
import { generate } from '../src/engine/pipeline';
import { ownerDefaults } from '../src/engine/profiles';

/**
 * Writes docs/samples/autounattend.sample.xml from the owner defaults with a sample name, plus the
 * Windows Update engine assets to docs/samples/windows-update/.
 *
 * The application engine is only generated when applications are selected, and the owner defaults
 * select none, so its sample assets come from a clearly labelled illustrative selection (not an
 * owner default) and go to docs/samples/applications/.
 *
 * Usage: generate-sample.ts [name] [applicationsOutDir]
 */
const profile = ownerDefaults();
profile.accounts.personName = process.argv[2] ?? 'Alex';
const result = generate(profile);
for (const i of result.issues) console.log(`${i.severity}: ${i.path} ${i.message}`);
if (!result.ok || !result.xml) process.exit(1);
mkdirSync('docs/samples/windows-update', { recursive: true });
writeFileSync('docs/samples/autounattend.sample.xml', result.xml);
for (const a of result.assets.filter((x) => x.group === 'windows-update')) writeFileSync(`docs/samples/windows-update/${a.name}`, a.content);
console.log(`Wrote docs/samples/autounattend.sample.xml (${result.xml.length} bytes, ${result.embeddedFiles.length} embedded files) and the Windows Update assets`);

const illustrative = ownerDefaults();
illustrative.accounts.personName = profile.accounts.personName;
illustrative.profileName = 'Illustrative sample (not an owner default)';
illustrative.applications.selection.added.push(
  { packageIdentifier: 'Git.Git', source: 'winget', displayName: 'Git', version: '', scope: '' },
  { packageIdentifier: '7zip.7zip', source: 'winget', displayName: '7-Zip', version: '', scope: '' },
  { packageIdentifier: 'Microsoft.WSL', source: 'winget', displayName: 'Windows Subsystem for Linux', version: '', scope: '' },
  { packageIdentifier: 'Docker.DockerDesktop', source: 'winget', displayName: 'Docker Desktop', version: '', scope: '' },
  { packageIdentifier: '9NKSQGP7F2NH', source: 'msstore', displayName: 'WhatsApp', version: '', scope: '' },
);
const apps = generate(illustrative);
if (!apps.ok) process.exit(1);
const out = process.argv[3] ?? 'docs/samples/applications';
mkdirSync(out, { recursive: true });
for (const a of apps.assets.filter((x) => x.group !== 'windows-update')) writeFileSync(`${out}/${a.name}`, a.content);
console.log(`Wrote ${apps.assets.filter((x) => x.group !== 'windows-update').length} application/orchestration asset(s) to ${out}`);
