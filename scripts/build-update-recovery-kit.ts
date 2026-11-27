import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { ENGINE_VERSION, RECOVERY_KIT_FILE } from '../src/engine/windows-update';
import { buildRecoveryKit } from '../src/engine/windows-update/recovery-kit';

/**
 * Packages the standalone Windows Update recovery download:
 *   dist/downloads/windows-update-recovery.zip (WDB-WindowsUpdate/: engine, Retry Windows Update,
 *   README.txt, files.json). See src/engine/windows-update/recovery-kit.ts.
 *
 * Usage: vite-node scripts/build-update-recovery-kit.ts [--out <zip path>]
 */
const args = process.argv.slice(2);
const out = args[0] === '--out' && args[1] ? args[1] : join('dist', 'downloads', RECOVERY_KIT_FILE);
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, buildRecoveryKit());
console.log(`Wrote ${out} (Windows Update engine ${ENGINE_VERSION})`);
