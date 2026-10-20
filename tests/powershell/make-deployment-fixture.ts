import { writeDeploymentFixture } from './deployment-fixture';

// vite-node tests/powershell/make-deployment-fixture.ts <dir>   (used by npm run test:ps)
const out = process.argv.at(-1);
if (!out || out.endsWith('.ts')) throw new Error('usage: vite-node tests/powershell/make-deployment-fixture.ts <dir>');
const info = writeDeploymentFixture(out);
console.log(`fixture ${info.packageId}: ${info.files} files in ${out}`);
