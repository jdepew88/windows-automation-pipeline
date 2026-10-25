import { describe, expect, it } from 'vitest';
import { catalogEntryById, catalogRef } from '../../src/engine/applications/catalog';
import { applicationsConfig } from '../../src/engine/applications';
import { effectiveApps, profilePreview } from '../../src/engine/applications/preview';
import { resolveSelection } from '../../src/engine/applications/selection';
import { removePackage, saveAsNewProfile, toggleProfile } from '../../src/engine/applications/profiles';
import { profile } from './helpers';

/** Quick Deployment's read-only application views must say exactly what the package installs. */

const keys = (xs: { key: string }[]) => xs.map((x) => x.key).sort();

describe('effective application summary', () => {
  it('lists exactly the packages and manual follow-ups of applications-config.json, each once', () => {
    const p = profile((q) => {
      toggleProfile(q.applications.selection, 'gaming', true);
      toggleProfile(q.applications.selection, 'network-engineer', true);
      toggleProfile(q.applications.selection, 'developer', true);
      removePackage(q.applications.selection, 'winget:epicgames.epicgameslauncher');
    });
    const apps = effectiveApps(p.applications.selection, p.applications.enabled);
    const cfg = applicationsConfig(p);
    expect(keys(apps.automatic)).toEqual(keys(cfg.packages));
    expect(keys(apps.manual)).toEqual(keys(cfg.manual));
    expect(apps.total).toBe(apps.automatic.length + apps.manual.length + apps.unresolved.length);
    // Developer is ticked and also included by Network Engineer: Git appears once.
    expect(apps.automatic.filter((x) => x.displayName === 'Git')).toHaveLength(1);
    expect(apps.automatic.find((x) => x.displayName === 'Git')!.origin).toContain('Developer');
    // The explicit removal is not shown as selected.
    expect(apps.automatic.some((x) => x.key === 'winget:epicgames.epicgameslauncher')).toBe(false);
    // Dependencies are explained.
    expect(apps.automatic.find((x) => x.key === 'winget:microsoft.wsl')!.origin).toContain('Required by Docker Desktop');
  });

  it('separates manual follow-up (RustDesk) from automatic installs and lists nothing when provisioning is off', () => {
    const p = profile((q) => q.applications.selection.added.push(catalogRef(catalogEntryById('rustdesk')!)!));
    const apps = effectiveApps(p.applications.selection, true);
    expect(apps.manual.map((x) => x.displayName)).toContain('RustDesk');
    expect(apps.automatic.some((x) => x.displayName === 'RustDesk')).toBe(false);
    expect(apps.manual.every((x) => x.kind === 'manual')).toBe(true);
    const off = effectiveApps(p.applications.selection, false);
    expect(off).toMatchObject({ enabled: false, total: 0, automatic: [], manual: [] });
  });

  it('is empty for an empty selection', () => {
    const p = profile((q) => toggleProfile(q.applications.selection, 'core', false));
    expect(effectiveApps(p.applications.selection).total).toBe(0);
  });
});

describe('profile previews', () => {
  it('previews an unselected profile without selecting it', () => {
    const p = profile();
    const before = JSON.stringify(p.applications.selection);
    const pv = profilePreview(p.applications.selection, 'gaming')!;
    expect(JSON.stringify(p.applications.selection)).toBe(before);
    expect(pv.selected).toBe(false);
    expect(pv.items.map((x) => x.displayName)).toEqual(['Steam', 'Epic Games Launcher']);
    expect(pv.items.every((x) => x.status === 'wouldAdd' && x.via === 'direct')).toBe(true);
    expect(pv.count).toBe(2);
    expect(pv.optional).toBeGreaterThan(0);
  });

  it('marks inherited apps and dependencies and counts each app once', () => {
    const p = profile();
    const pv = profilePreview(p.applications.selection, 'network-engineer')!;
    expect(new Set(pv.items.map((x) => x.key)).size).toBe(pv.items.length);
    expect(pv.items.find((x) => x.displayName === 'Git')).toMatchObject({ via: 'inherited', viaText: 'From General Developer' });
    expect(pv.items.find((x) => x.key === 'winget:microsoft.wsl')).toMatchObject({ via: 'dependency', viaText: 'Required by Docker Desktop' });
    expect(pv.count).toBe(29);
  });

  it('never shows an app the deployment excludes as included, even when another profile shares it', () => {
    const p = profile((q) => {
      toggleProfile(q.applications.selection, 'gaming', true);
      removePackage(q.applications.selection, 'winget:valve.steam');
    });
    const sel = p.applications.selection;
    const gaming = profilePreview(sel, 'gaming')!;
    expect(gaming.items.find((x) => x.displayName === 'Steam')).toMatchObject({ status: 'excluded', excludedBy: 'Unticked in this deployment' });
    expect(gaming.count).toBe(1);
    // Untick Gaming: the removal is remembered, so ticking it again would still leave Steam out.
    toggleProfile(sel, 'gaming', false);
    expect(profilePreview(sel, 'gaming')!.items.find((x) => x.displayName === 'Steam')!.status).toBe('excluded');
  });

  it('shows Core Essentials apps shared with another active profile as already included', () => {
    const p = profile((q) => {
      q.applications.selection.added.push({ packageIdentifier: 'Valve.Steam', source: 'winget', displayName: 'Steam', version: '', scope: '' });
    });
    const pv = profilePreview(p.applications.selection, 'gaming')!;
    expect(pv.items.find((x) => x.displayName === 'Steam')!.status).toBe('included');
    expect(pv.items.find((x) => x.displayName === 'Epic Games Launcher')!.status).toBe('wouldAdd');
    const core = profilePreview(p.applications.selection, 'core')!;
    expect(core.selected).toBe(true);
    expect(core.items.every((x) => x.status === 'included')).toBe(true);
  });

  it('previews a saved profile with its exclusions and device answers', () => {
    const p = profile((q) => {
      const sel = q.applications.selection;
      toggleProfile(sel, 'gaming', true);
      removePackage(sel, 'winget:epicgames.epicgameslauncher');
      sel.devices.phone = 'iphone';
      const saved = saveAsNewProfile(sel, "Aunt's Computer");
      sel.selectedProfiles = ['core'];
      sel.removed = [];
      sel.devices.phone = 'none';
      expect(saved.id).toBeTruthy();
    });
    const sel = p.applications.selection;
    const id = sel.profiles[0]!.id;
    const pv = profilePreview(sel, id)!;
    expect(pv.builtin).toBe(false);
    expect(pv.selected).toBe(false);
    expect(pv.items.some((x) => x.displayName === 'Epic Games Launcher')).toBe(false);
    expect(pv.items.find((x) => x.displayName === 'Steam')!.status).toBe('wouldAdd');
    expect(pv.items.find((x) => x.via === 'device')?.viaText).toContain('iPhone');
    // Ticking it really produces what the preview said it would add.
    const withIt = resolveSelection({ ...sel, selectedProfiles: [...sel.selectedProfiles, id] });
    for (const x of pv.items.filter((i) => i.status !== 'excluded')) expect(withIt.packages.some((q) => q.key === x.key)).toBe(true);
  });

  it('returns nothing for an unknown profile', () => {
    expect(profilePreview(profile().applications.selection, 'nope')).toBeUndefined();
  });
});
