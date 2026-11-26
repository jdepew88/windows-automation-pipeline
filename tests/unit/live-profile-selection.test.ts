import { describe, expect, it } from 'vitest';
import { applicationsConfig, applicationAssets } from '../../src/engine/applications';
import { catalogEntryById, catalogRef, entryKey } from '../../src/engine/applications/catalog';
import { packageKey } from '../../src/engine/applications/ids';
import { deploymentChecklist, effectiveApps } from '../../src/engine/applications/preview';
import { addPackage, exportAppProfiles, importAppProfiles, pruneDetached, removePackage, saveAsNewProfile, toggleProfile } from '../../src/engine/applications/profiles';
import { attachedAdditions, expandProfile, allProfiles, installable, resolveSelection } from '../../src/engine/applications/selection';
import { buildDeploymentPackage } from '../../src/engine/deployment';
import { readZip } from '../../src/engine/deployment/zip';
import { exportProfile, importProfile, ownerDefaults } from '../../src/engine/profiles';
import type { ApplicationsSelection } from '../../src/engine/schema/applications';
import { setCustomerType } from '../../src/engine/quick';
import { generateOk, profile } from './helpers';

/**
 * Quick Deployment step 2: ticking and unticking profiles recalculates the selection, and the
 * per-application checkboxes, the Final Review and the generated package all describe one derived
 * selection (profiles + the user's own additions + recommendations ticked with their profiles − removals).
 */

const key = (catalogId: string) => entryKey(catalogEntryById(catalogId)!);
const ref = (catalogId: string) => catalogRef(catalogEntryById(catalogId)!)!;
// Revision 1 of the built-in profiles: Network Engineer inherits General Developer there, which these
// inheritance and recommendation rules need (revision 2 has no inheriting built-in profile).
const fresh = (): ApplicationsSelection => ({ ...structuredClone(ownerDefaults().applications.selection), profileRevision: 1 });
const keys = (s: ApplicationsSelection) => resolveSelection(s).packages.map((p) => p.key);
const defaultsOf = (s: ApplicationsSelection, id: string) => new Set(expandProfile(id, allProfiles(s)).map(packageKey));

describe('profile selection is recalculated on every change', () => {
  it('ticking a profile adds its defaults; unticking removes the ones only it contributed', () => {
    const s = fresh();
    const base = keys(s);
    toggleProfile(s, 'music', true);
    const withMusic = keys(s);
    const own = [...defaultsOf(s, 'music')].filter((k) => !base.includes(k));
    expect(own.length).toBeGreaterThan(0);
    for (const k of own) expect(withMusic).toContain(k);
    expect(withMusic.length).toBe(base.length + own.length);
    toggleProfile(s, 'music', false);
    expect(keys(s)).toEqual(base);
  });

  it('an app shared by two ticked profiles stays when one of them is unticked', () => {
    const s = fresh();
    toggleProfile(s, 'developer', true);
    toggleProfile(s, 'network-engineer', true);
    const git = key('git');
    expect(keys(s).filter((k) => k === git)).toHaveLength(1);
    toggleProfile(s, 'developer', false);
    // Network Engineer includes General Developer, so Git is still required.
    expect(keys(s)).toContain(git);
    toggleProfile(s, 'network-engineer', false);
    expect(keys(s)).not.toContain(git);
  });

  it('an individual exclusion overrides the profile; ticking it again restores it', () => {
    const s = fresh();
    toggleProfile(s, 'developer', true);
    const docker = key('vscode');
    removePackage(s, docker);
    expect(keys(s)).not.toContain(docker);
    expect(resolveSelection(s).removed.map((p) => p.key)).toContain(docker);
    addPackage(s, resolveSelection(s).removed.find((p) => p.key === docker)!.ref);
    expect(keys(s)).toContain(docker);
    expect(s.removed).toEqual([]);
    expect(s.added).toEqual([]);
  });

  it("the user's own additions survive unrelated profile changes", () => {
    const s = fresh();
    addPackage(s, ref('gimp'));
    expect(s.addedWith).toBeUndefined();
    for (const id of ['gaming', 'music', 'developer']) {
      toggleProfile(s, id, true);
      toggleProfile(s, id, false);
    }
    expect(keys(s)).toContain(key('gimp'));
  });

  it('a recommendation ticked while its profile is active leaves when that profile is unticked (with its dependency)', () => {
    const s = fresh();
    const base = keys(s);
    toggleProfile(s, 'developer', true);
    addPackage(s, ref('docker-desktop'));
    addPackage(s, ref('wireshark'));
    expect(keys(s)).toEqual(expect.arrayContaining([key('docker-desktop'), key('wsl'), key('wireshark')]));
    expect(s.addedWith).toEqual({ [key('docker-desktop')]: ['developer'], [key('wireshark')]: ['developer'] });
    toggleProfile(s, 'developer', false);
    expect(keys(s)).toEqual(base);
    expect(s.added).toEqual([]);
    expect(s.addedWith).toBeUndefined();
    // Ticking Developer again offers them as recommendations, unticked.
    toggleProfile(s, 'developer', true);
    expect(keys(s)).not.toContain(key('docker-desktop'));
    expect(resolveSelection(s).recommended.map((p) => p.key)).toContain(key('docker-desktop'));
  });

  it('a recommendation of two active profiles stays until both are unticked; inherited recommendations follow the including profile', () => {
    const s = fresh();
    toggleProfile(s, 'network-engineer', true);
    // Network Engineer includes General Developer, whose recommendations are offered too.
    const recs = resolveSelection(s).recommended;
    const inherited = recs.find((p) => p.origins.length === 1 && p.origins[0] === 'developer')!;
    const shared = recs.find((p) => p.origins.includes('developer') && p.origins.includes('network-engineer') && !p.origins.includes('core'))!;
    expect(inherited && shared).toBeTruthy();
    addPackage(s, inherited.ref);
    expect(s.addedWith![inherited.key]).toEqual(['developer']);
    toggleProfile(s, 'network-engineer', false);
    expect(keys(s)).not.toContain(inherited.key);
    // Developer ticked on its own as well: unticking Network Engineer keeps a recommendation both share.
    toggleProfile(s, 'developer', true);
    toggleProfile(s, 'network-engineer', true);
    addPackage(s, shared.ref);
    expect(s.addedWith![shared.key]!.sort()).toEqual(['developer', 'network-engineer']);
    toggleProfile(s, 'network-engineer', false);
    expect(keys(s)).toContain(shared.key);
    toggleProfile(s, 'developer', false);
    expect(keys(s)).not.toContain(shared.key);
  });

  it('a device recommendation ticked by the user leaves when the device answer changes', () => {
    const s = fresh();
    s.devices.phone = 'iphone';
    const rec = resolveSelection(s).recommended.find((p) => p.origins.includes('apple-devices'));
    expect(rec).toBeTruthy();
    addPackage(s, rec!.ref);
    expect(keys(s)).toContain(rec!.key);
    s.devices.phone = 'none';
    // The resolver already ignores it; pruning forgets it.
    expect(keys(s)).not.toContain(rec!.key);
    expect(attachedAdditions(s)).toEqual([]);
    pruneDetached(s);
    expect(s.added).toEqual([]);
  });

  it('repeated toggling never duplicates an app and ends where it started', () => {
    const s = fresh();
    toggleProfile(s, 'developer', true);
    removePackage(s, key('git'));
    addPackage(s, ref('gimp'));
    const start = JSON.stringify(s);
    for (let i = 0; i < 5; i++) {
      for (const id of ['music', 'gaming', 'network-engineer']) toggleProfile(s, id, true);
      // A recommendation of the profiles being toggled (not of Core Essentials or Developer, which stay).
      addPackage(s, resolveSelection(s).recommended.find((p) => !p.origins.some((o) => o === 'core' || o === 'developer'))!.ref);
      const k = keys(s);
      expect(new Set(k).size).toBe(k.length);
      for (const id of ['music', 'gaming', 'network-engineer']) toggleProfile(s, id, false);
    }
    expect(JSON.stringify(s)).toBe(start);
  });
});

describe('step 2 checklist, Final Review and the package agree', () => {
  const build = () =>
    profile((q) => {
      const s = q.applications.selection;
      setCustomerType(q, 'developer', true);
      setCustomerType(q, 'music', true);
      addPackage(s, ref('docker-desktop'));
      removePackage(s, key('git'));
      addPackage(s, ref('gimp'));
      setCustomerType(q, 'music', false);
    });

  it('the checklist ticks exactly the planned packages and lists exclusions unticked, each app once', () => {
    const p = build();
    const sel = p.applications.selection;
    const list = deploymentChecklist(sel);
    const r = resolveSelection(sel);
    expect(list.items.filter((x) => x.selected).map((x) => x.key).sort()).toEqual(r.packages.map((x) => x.key).sort());
    expect(list.items.filter((x) => !x.selected).map((x) => x.key)).toEqual([key('git')]);
    expect(list.items.find((x) => x.key === key('git'))!.excludedBy).toBe('Unticked by you');
    expect(new Set(list.items.map((x) => x.key)).size).toBe(list.items.length);
    // A new deployment (revision 2): the profile is now called "Developer".
    expect(list.items.find((x) => x.key === key('docker-desktop'))!.origin).toBe('Recommended by Developer, ticked by you');
    expect(list.items.find((x) => x.key === key('gimp'))!.origin).toBe('Added by you');
    expect(list.items.find((x) => x.key === key('wsl'))!.origin).toContain('Required by Docker Desktop');
    // Sorted by name, so ticking or unticking never moves a row.
    const names = list.items.map((x) => x.displayName.toLowerCase());
    expect(names).toEqual([...names].sort((a, b) => a.localeCompare(b, 'en', { sensitivity: 'base' })));
    expect(effectiveApps(sel).total).toBe(list.selected);
  });

  it('applications-config.json, winget-packages.json and the plan contain exactly the ticked apps', () => {
    const p = build();
    const sel = p.applications.selection;
    const list = deploymentChecklist(sel);
    const ticked = list.items.filter((x) => x.selected);
    const cfg = applicationsConfig(p);
    expect([...cfg.packages, ...cfg.manual].map((x) => x.key).sort()).toEqual(ticked.map((x) => x.key).sort());
    const pkg = buildDeploymentPackage(p, generateOk(p));
    const entries = readZip(pkg.zip);
    const text = (end: string) => new TextDecoder().decode(entries.find((e) => e.path.endsWith(end))!.data);
    expect(JSON.parse(text('applications-config.json'))).toEqual(cfg);
    const winget = JSON.parse(text('winget-packages.json')) as { Sources: { Packages: { PackageIdentifier: string }[] }[] };
    const ids = winget.Sources.flatMap((x) => x.Packages.map((y) => y.PackageIdentifier.toLowerCase())).sort();
    expect(ids).toEqual(installable(resolveSelection(sel)).map((x) => x.ref.packageIdentifier.toLowerCase()).sort());
    expect(ids).toContain('docker.dockerdesktop');
    expect(ids).not.toContain('git.git');
    const plan = text('applications-plan.txt');
    for (const x of ticked) expect(plan).toContain(x.displayName);
    expect(applicationAssets(p).length).toBeGreaterThan(0);
  });

  it('after unticking the profile, nothing it brought in remains anywhere', () => {
    const p = build();
    setCustomerType(p, 'developer', false);
    const cfg = applicationsConfig(p);
    const all = [...cfg.packages, ...cfg.manual].map((x) => x.key);
    for (const id of ['docker-desktop', 'wsl', 'vscode', 'python-314', 'nodejs-lts']) expect(all).not.toContain(key(id));
    expect(all).toContain(key('gimp'));
    expect(deploymentChecklist(p.applications.selection).items.some((x) => x.key === key('docker-desktop'))).toBe(false);
  });
});

describe('saved and imported profiles', () => {
  it('saving folds the linked recommendations into the saved profile, which reproduces the selection', () => {
    const s = fresh();
    toggleProfile(s, 'developer', true);
    addPackage(s, ref('docker-desktop'));
    const before = keys(s).sort();
    const saved = saveAsNewProfile(s, 'Dev box');
    expect(s.addedWith).toBeUndefined();
    expect(keys(s).sort()).toEqual(before);
    expect(saved.packages.map(packageKey)).toContain(key('docker-desktop'));
    // The saved profile is an ordinary profile: unticking it removes everything it selects.
    toggleProfile(s, saved.id, false);
    expect(keys(s)).toEqual([]);
    const round = importAppProfiles(exportAppProfiles([saved]), []);
    expect(round.profiles[0]!.packages.map(packageKey)).toEqual(saved.packages.map(packageKey));
  });

  it('a deployment profile with linked recommendations exports and imports unchanged; one without the field still imports', () => {
    const p = profile((q) => {
      setCustomerType(q, 'developer', true);
      addPackage(q.applications.selection, ref('docker-desktop'));
    });
    const back = importProfile(exportProfile(p));
    expect(back.errors).toEqual([]);
    expect(back.profile!.applications.selection.addedWith).toEqual({ [key('docker-desktop')]: ['developer'] });
    expect(keys(back.profile!.applications.selection)).toEqual(keys(p.applications.selection));
    const legacy = JSON.parse(exportProfile(p));
    delete legacy.applications.selection.addedWith;
    const old = importProfile(JSON.stringify(legacy));
    expect(old.errors).toEqual([]);
    // Without the link, Docker Desktop is the user's own addition and stays.
    setCustomerType(old.profile!, 'developer', false);
    expect(keys(old.profile!.applications.selection)).toContain(key('docker-desktop'));
  });
});
