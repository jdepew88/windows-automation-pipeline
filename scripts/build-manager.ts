import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { createZip, type ZipEntry } from '../src/engine/deployment/zip';
import { encodeFile } from '../src/engine/deployment';
import { sha256 } from '../src/engine/deployment/sha256';
import { catalogPolicy, MANAGER_NAME, MANAGER_VERSION } from '../src/engine/manager';

/**
 * Packages the standalone Application Manager (Phase 10) after `vite build`:
 *
 *   dist/downloads/windows-deployment-app-manager.zip
 *     AppManager/AppManager.ps1, Start-AppManager.cmd, Install-AppManager.ps1, README.txt,
 *     catalog-policy.json, files.json (SHA-256 of every file), lib/ (the Phase 5 engine's exit
 *     codes, the Phase 9 uninstall-record reader, the shared helpers), ui/ (dist/manager.html and
 *     only the assets it loads, plus the bundled logos).
 *
 * The website links to the ZIP; the page itself never runs anything. With --policy <file> it only
 * writes catalog-policy.json (for the PowerShell tests).
 *
 * Usage: vite-node scripts/build-manager.ts [--policy <file>]
 */

const args = process.argv.slice(2);
if (args[0] === '--policy') {
  writeFileSync(args[1]!, JSON.stringify(catalogPolicy(), null, 2) + '\n');
  process.exit(0);
}

const DIST = 'dist';
const ZIP = join(DIST, 'downloads', 'windows-deployment-app-manager.zip');
const crlf = (s: string) => s.replace(/\r?\n/g, '\r\n');
const files: { path: string; data: Uint8Array }[] = [];
const text = (path: string, content: string) => files.push({ path, data: encodeFile(path, /\.(cmd|txt)$/.test(path) ? crlf(content) : content) });

const script = (rel: string) => readFileSync(rel, 'utf8').replace(/^\uFEFF/, '');
text('AppManager.ps1', script('src/engine/manager/scripts/AppManager.ps1'));
text('Install-AppManager.ps1', script('src/engine/manager/scripts/Install-AppManager.ps1'));
text('Start-AppManager.cmd', script('src/engine/manager/scripts/Start-AppManager.cmd'));
text('lib/DeploymentCommon.ps1', script('src/engine/deployment/scripts/DeploymentCommon.ps1'));
text('lib/ApplicationEngine.ps1', script('src/engine/applications/scripts/ApplicationEngine.ps1'));
text('lib/DeploymentHealth.ps1', script('src/engine/health/scripts/DeploymentHealth.ps1'));
text('catalog-policy.json', JSON.stringify(catalogPolicy(), null, 2) + '\n');

// The page and the assets it references, transitively (shared chunks, styles); no source maps.
const page = join(DIST, 'manager.html');
if (!existsSync(page)) throw new Error('dist/manager.html is missing: run vite build first.');
const assets = readdirSync(join(DIST, 'assets')).filter((n) => !n.endsWith('.map'));
const seen = new Set<string>();
const queue = [readFileSync(page, 'utf8')];
while (queue.length) {
  const content = queue.pop()!;
  for (const n of assets) {
    if (seen.has(n) || !content.includes(n)) continue;
    seen.add(n);
    if (/\.(js|css)$/.test(n)) queue.push(readFileSync(join(DIST, 'assets', n), 'utf8'));
  }
}
files.push({ path: 'ui/manager.html', data: readFileSync(page) });
for (const n of [...seen].sort()) files.push({ path: `ui/assets/${n}`, data: readFileSync(join(DIST, 'assets', n)) });
for (const n of readdirSync(join(DIST, 'app-icons')).sort()) files.push({ path: `ui/app-icons/${n}`, data: readFileSync(join(DIST, 'app-icons', n)) });

text('README.txt', `${MANAGER_NAME} ${MANAGER_VERSION}

Browse the Windows Deployment Builder catalog, see what is installed, and install, update or
remove applications with WinGet, on a computer that is already set up. No USB drive and no
reinstallation are needed.

Start it
  Install-AppManager.ps1   (right-click > Run with PowerShell) adds "${MANAGER_NAME}" to
                           your Start menu, for you only; no administrator rights needed.
  Start-AppManager.cmd     runs it from this folder without installing.

How it works
  A small PowerShell program runs as you and serves the manager's page to this computer only
  (http://127.0.0.1, random port, a session key in the address). It runs WinGet for you. It never
  runs elevated by itself: when an installer needs administrator rights, Windows asks you (UAC).
  Closing its window stops it.

  Simulation mode is on until you switch it off: every action then shows the exact WinGet command
  and records "Simulated" without changing anything.

  WinGet is not Linux APT: it updates applications it can match to its sources, one installer at a
  time; it does not cover every program and cannot always tell the installed version.

Where things are kept
  %LOCALAPPDATA%\\WindowsDeploymentBuilder\\AppManager   history.jsonl (versioned operation
  history), profiles.json, settings.json, cached inventory and updates (shown while offline).

Remove it
  Install-AppManager.ps1 -Uninstall   (add -RemoveData to delete the history and profiles too).
  Applications installed with it stay installed.
`);

const list = { format: 'windows-deployment-builder/app-manager-files', version: MANAGER_VERSION, files: files.map((f) => ({ path: f.path, sha256: sha256(f.data), size: f.data.length })) };
files.push({ path: 'files.json', data: encodeFile('files.json', JSON.stringify(list, null, 2) + '\n') });

const entries: ZipEntry[] = files.map((f) => ({ path: `AppManager/${f.path}`, data: f.data }));
mkdirSync(dirname(ZIP), { recursive: true });
writeFileSync(ZIP, createZip(entries));
console.log(`Wrote ${ZIP}: ${entries.length} files (${seen.size} page assets).`);
