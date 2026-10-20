import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { generate } from '../../src/engine/pipeline';
import { ownerDefaults } from '../../src/engine/profiles';
import { buildDeploymentPackage } from '../../src/engine/deployment';
import { readZip } from '../../src/engine/deployment/zip';

/**
 * Builds the fixture Deployment.Tests.ps1 runs against: the real deployment ZIP produced by the
 * generator, extracted into <dir>\usb exactly as a user would put it on a USB drive. The profile
 * is owner defaults with Windows Update on and two applications, one a test-only identifier with a non-ASCII name
 * (exercises the code-page path of the answer-file extraction).
 */
export function writeDeploymentFixture(dir: string): { packageId: string; files: number } {
  const p = ownerDefaults();
  p.accounts.personName = 'Alex';
  p.applications.selection.added.push(
    { packageIdentifier: 'Git.Git', source: 'winget', displayName: 'Git', version: '', scope: '' },
    // Test-only identifier (not in the catalog) so the non-ASCII display name reaches the engine config.
    { packageIdentifier: 'Example.TestPackage', source: 'winget', displayName: 'Zoë Test Package', version: '', scope: '' },
  );
  const r = generate(p);
  if (!r.ok) throw new Error(`fixture profile is invalid: ${JSON.stringify(r.issues)}`);
  const pkg = buildDeploymentPackage(p, r);
  rmSync(dir, { recursive: true, force: true });
  const usb = join(dir, 'usb');
  for (const e of readZip(pkg.zip)) {
    const target = join(usb, ...e.path.split('/'));
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, e.data);
  }
  writeFileSync(join(dir, 'package.zip'), pkg.zip);
  return { packageId: pkg.manifest.packageId, files: pkg.manifest.files.length };
}
