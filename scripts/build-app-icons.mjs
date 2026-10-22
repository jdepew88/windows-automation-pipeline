// Builds the application logos shown in the catalog (Phase 4.3).
//
//   node scripts/build-app-icons.mjs
//
// Sources (nothing is hotlinked at run time; the output is committed):
//   1. Simple Icons (npm "simple-icons", pinned devDependency, CC0-1.0 data). Each brand path is
//      placed on a rounded tile in the brand's own colour. Brand marks remain trademarks of their
//      owners and are used only to identify the application (see docs/phase-4-3-quick-deployment-wizard/catalog-and-icons.md).
//   2. The application's own open-source repository, pinned to a commit (REPO_ICONS below).
// Everything else gets the UI's initials tile; no logo is drawn or invented here.
//
// Output: public/app-icons/<catalog id>.(svg|png) and src/data/apps/icons.json (provenance).
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(import.meta.url);
const icons = require('simple-icons');
const siVersion = JSON.parse(readFileSync(join(root, 'node_modules/simple-icons/package.json'), 'utf8')).version;
const catalog = JSON.parse(readFileSync(join(root, 'src/data/apps/catalog.json'), 'utf8')).entries;

// catalog id -> [Simple Icons slug, 'app' (the application's own mark) | 'publisher' (its publisher's mark)]
const SIMPLE = {
  chrome: ['googlechrome', 'app'],
  firefox: ['firefoxbrowser', 'app'],
  vlc: ['vlcmediaplayer', 'app'],
  '7zip': ['7zip', 'app'],
  bitwarden: ['bitwarden', 'app'],
  obsidian: ['obsidian', 'app'],
  quicklook: ['quicklook', 'app'],
  discord: ['discord', 'app'],
  zoom: ['zoom', 'app'],
  whatsapp: ['whatsapp', 'app'],
  thunderbird: ['thunderbird', 'app'],
  'google-drive': ['googledrive', 'app'],
  'apple-devices': ['apple', 'publisher'],
  'apple-music': ['applemusic', 'app'],
  itunes: ['itunes', 'app'],
  icloud: ['icloud', 'app'],
  'samsung-smart-switch': ['samsung', 'publisher'],
  'google-quick-share': ['google', 'publisher'],
  gimp: ['gimp', 'app'],
  audacity: ['audacity', 'app'],
  spotify: ['spotify', 'app'],
  'obs-studio': ['obsstudio', 'app'],
  steam: ['steam', 'app'],
  epic: ['epicgames', 'app'],
  battlenet: ['battledotnet', 'app'],
  'ea-app': ['ea', 'publisher'],
  'ubisoft-connect': ['ubisoft', 'publisher'],
  'gog-galaxy': ['gogdotcom', 'publisher'],
  retroarch: ['retroarch', 'app'],
  git: ['git', 'app'],
  'python-314': ['python', 'app'],
  'python-313': ['python', 'app'],
  'nodejs-lts': ['nodedotjs', 'app'],
  'github-desktop': ['github', 'publisher'],
  cursor: ['cursor', 'app'],
  'claude-code': ['claude', 'app'],
  'claude-desktop': ['claude', 'app'],
  'sublime-text': ['sublimetext', 'app'],
  notepadpp: ['notepadplusplus', 'app'],
  'docker-desktop': ['docker', 'app'],
  virtualbox: ['virtualbox', 'app'],
  wireshark: ['wireshark', 'app'],
  tailscale: ['tailscale', 'app'],
  wireguard: ['wireguard', 'app'],
  qbittorrent: ['qbittorrent', 'app'],
  syncthing: ['syncthing', 'app'],
  malwarebytes: ['malwarebytes', 'app'],
  avast: ['avast', 'publisher'],
  avira: ['avira', 'publisher'],
  'dotnet-desktop-8': ['dotnet', 'app'],
  'dotnet-desktop-10': ['dotnet', 'app'],
  'aspnetcore-8': ['dotnet', 'app'],
  'aspnetcore-10': ['dotnet', 'app'],
  'temurin-25-jre': ['eclipseadoptium', 'publisher'],
  'temurin-21-jre': ['eclipseadoptium', 'publisher'],
  'temurin-25-jdk': ['eclipseadoptium', 'publisher'],
  'dell-command-update': ['dell', 'publisher'],
  'lenovo-system-update': ['lenovo', 'publisher'],
  'lenovo-vantage': ['lenovo', 'publisher'],
  joplin: ['joplin', 'app'],
  rustdesk: ['rustdesk', 'app'],
  filezilla: ['filezilla', 'app'],
};

// Icons from the application's own repository, pinned to a commit.
const REPO_ICONS = {
  rufus: { repo: 'pbatard/rufus', commit: '3e696ab19010d7459c31537684522c98ba6a84a9', path: 'res/appstore/Images/Square44x44Logo.altform-unplated_targetsize-48.png', license: 'GPL-3.0 (Rufus repository)' },
  ventoy: { repo: 'ventoy/Ventoy', commit: '582704ca5be53ea3cd84f2c62965ccdf06585971', path: 'ICON/logo_64.png', license: 'GPL-3.0 (Ventoy repository)' },
  sabnzbd: { repo: 'sabnzbd/sabnzbd', commit: '9748bcf63f38035074d6cfad6a407812c3da59d7', path: 'icons/logo-arrow.svg', license: 'GPL-2.0-or-later (SABnzbd repository)' },
};

function luminance(hex) {
  const [r, g, b] = [0, 2, 4].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/** The brand path in white (or near-black on light brand colours) on a 64x64 tile of the brand colour. */
function tile(icon) {
  const glyph = luminance(icon.hex) > 0.45 ? '#111111' : '#FFFFFF';
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#${icon.hex}"/><path transform="translate(14 14) scale(1.5)" fill="${glyph}" d="${icon.path}"/></svg>\n`;
}

const outDir = join(root, 'public/app-icons');
rmSync(outDir, { recursive: true, force: true });
mkdirSync(outDir, { recursive: true });
const bySlug = new Map(Object.values(icons).map((i) => [i.slug, i]));
const ids = new Set(catalog.map((e) => e.id));
const manifest = {};

for (const [id, [slug, kind]] of Object.entries(SIMPLE)) {
  if (!ids.has(id)) throw new Error(`unknown catalog id ${id}`);
  const icon = bySlug.get(slug);
  if (!icon) throw new Error(`simple-icons ${siVersion} has no "${slug}"`);
  writeFileSync(join(outDir, `${id}.svg`), tile(icon));
  manifest[id] = { file: `app-icons/${id}.svg`, kind, title: icon.title, source: `simple-icons ${siVersion} (${slug})`, license: 'CC0-1.0 icon data; the mark is a trademark of its owner', guidelines: icon.guidelines ?? null };
}

for (const [id, r] of Object.entries(REPO_ICONS)) {
  if (!ids.has(id)) throw new Error(`unknown catalog id ${id}`);
  const url = `https://raw.githubusercontent.com/${r.repo}/${r.commit}/${r.path}`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  const bytes = new Uint8Array(await res.arrayBuffer());
  const ext = r.path.split('.').pop();
  writeFileSync(join(outDir, `${id}.${ext}`), bytes);
  manifest[id] = { file: `app-icons/${id}.${ext}`, kind: 'app', title: id, source: url, license: r.license, guidelines: null };
}

const sorted = Object.fromEntries(Object.entries(manifest).sort(([a], [b]) => a.localeCompare(b)));
writeFileSync(
  join(root, 'src/data/apps/icons.json'),
  JSON.stringify({ $comment: 'Generated by scripts/build-app-icons.mjs. Applications without an entry show the initials tile.', simpleIcons: siVersion, icons: sorted }, null, 2) + '\n',
);
console.log(`${Object.keys(sorted).length} of ${catalog.length} catalog apps have a logo`);
