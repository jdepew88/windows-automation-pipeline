import { describe, expect, it } from 'vitest';
import { installable, manualItems, resolveSelection } from '../../src/engine/applications/selection';
import { CATALOG_EXCLUDED, catalogEntryById, entryForFormerKey, removalForCatalogId } from '../../src/engine/applications/catalog';
import type { ApplicationsSelection, PackageRef } from '../../src/engine/schema/applications';
import { profile } from './helpers';
import { generate } from '../../src/engine/pipeline';
import { applicationsConfig } from '../../src/engine/applications';

/**
 * Catalog audit 2026-11: saved profiles that name an app removed from the automated catalog, or an app
 * that moved to another source, load safely, keep their other selections, and never install the
 * removed app or a silent substitute.
 */

const base = (mutate: (s: ApplicationsSelection) => void = () => {}): ApplicationsSelection => {
  const s = structuredClone(profile().applications.selection);
  s.selectedProfiles = [];
  s.added = [];
  s.removed = [];
  mutate(s);
  return s;
};
const ref = (source: string, id: string, displayName = ''): PackageRef => ({ source, packageIdentifier: id, displayName, version: '', scope: '' });
const keys = (r: ReturnType<typeof resolveSelection>) => installable(r).map((p) => p.key);

describe('apps removed from the automated catalog', () => {
  it('every removal has a reason, a date and its former id, and the former id is no longer an entry', () => {
    const removed = CATALOG_EXCLUDED.filter((x) => x.removed);
    expect(removed.map((x) => x.removed!.formerId).sort()).toEqual(['amazon-music', 'whiteboard']);
    for (const x of removed) {
      expect(x.reason.length).toBeGreaterThan(20);
      expect(catalogEntryById(x.removed!.formerId)).toBeUndefined();
      expect(removalForCatalogId(x.removed!.formerId)).toBe(x);
    }
  });

  it.each([
    ['its Store id', ref('msstore', '9MSPC6MP8FM4', 'Microsoft Whiteboard')],
    ['its catalog id', ref('catalog', 'whiteboard')],
  ])('a saved selection naming it by %s: kept, warned about, never installed; other apps still install', (_, removedRef) => {
    const r = resolveSelection(base((s) => s.added.push(removedRef, ref('winget', 'Git.Git', 'Git'))));
    const p = r.packages.find((x) => x.key.endsWith(removedRef.packageIdentifier.toLowerCase()))!;
    expect(p.resolution).toBe('unresolved');
    expect(p.reason).toMatch(/removed from the automated catalog on 2026-11-27: .*not installed; remove it or choose another application/);
    expect(keys(r)).not.toContain(p.key);
    expect(keys(r)).toContain('winget:git.git');
    expect(r.notices.some((n) => n.key === p.key && n.kind === 'warning')).toBe(true);
  });

  it('a deployment profile that still selects a removed app generates: a warning, never an error, and the app is not in the engine plan', () => {
    const p = profile((x) => x.applications.selection.added.push(ref('msstore', '9MSPC6MP8FM4', 'Microsoft Whiteboard')));
    const r = generate(p);
    expect(r.ok).toBe(true);
    expect(r.issues.filter((i) => i.severity === 'error')).toEqual([]);
    expect(r.issues.some((i) => i.severity === 'warning' && /Microsoft Whiteboard was removed from the automated catalog/.test(i.message))).toBe(true);
    // Not in the engine's install list; reported to it as unresolved (with the reason) instead.
    const cfg = applicationsConfig(p);
    expect(cfg.packages.some((x) => x.packageIdentifier === '9MSPC6MP8FM4')).toBe(false);
    expect(cfg.unresolved.find((x) => x.packageIdentifier === '9MSPC6MP8FM4')?.reason).toMatch(/removed from the automated catalog/);
  });

  it('the frozen revision-1 Touchscreen profile still loads; its removed Whiteboard is reported, the rest is planned', () => {
    const r = resolveSelection(base((s) => {
      s.profileRevision = 1;
      s.selectedProfiles = ['touch'];
    }));
    const wb = r.packages.find((x) => x.key === 'catalog:whiteboard');
    // An optional app of the profile: offered, never installed.
    expect(wb === undefined || wb.resolution === 'unresolved').toBe(true);
    expect([...r.packages, ...r.recommended].every((x) => x.key !== 'msstore:9mspc6mp8fm4' || x.resolution === 'unresolved')).toBe(true);
  });
});

describe('apps that moved source or became manual (formerKeys)', () => {
  it('the former keys map to the same application', () => {
    expect(entryForFormerKey('winget:microsoft.sysinternals.suite')?.id).toBe('sysinternals');
    expect(entryForFormerKey('winget:aimp.aimp')?.id).toBe('aimp');
    expect(entryForFormerKey('winget:blizzard.battlenet')?.id).toBe('battlenet');
    expect(entryForFormerKey('winget:git.git')).toBeUndefined();
  });

  it('Sysinternals saved under its WinGet id installs from the Microsoft Store, with a note; the stale WinGet package is never used', () => {
    const r = resolveSelection(base((s) => s.added.push(ref('winget', 'Microsoft.Sysinternals.Suite', 'Sysinternals Suite'))));
    expect(keys(r)).toContain('msstore:9p7knl5rwt25');
    expect(keys(r)).not.toContain('winget:microsoft.sysinternals.suite');
    expect(r.notices.find((n) => n.key === 'msstore:9p7knl5rwt25')?.message).toMatch(/saved as winget:microsoft\.sysinternals\.suite; it is now installed from the Microsoft Store as 9P7KNL5RWT25.*not a replacement/);
  });

  it('a deselection saved under the former key keeps the app deselected when a profile includes it', () => {
    const on = resolveSelection(base((s) => (s.selectedProfiles = ['network-engineer'])));
    const sel = (r: ReturnType<typeof resolveSelection>) => [...r.packages, ...r.recommended].some((x) => x.key === 'msstore:9p7knl5rwt25' && r.packages.includes(x));
    const off = resolveSelection(base((s) => {
      s.selectedProfiles = ['network-engineer'];
      s.removed = ['winget:microsoft.sysinternals.suite'];
    }));
    if (sel(on)) expect(sel(off)).toBe(false);
    expect(off.packages.some((x) => x.key === 'winget:microsoft.sysinternals.suite')).toBe(false);
  });

  it('Battle.net saved under its WinGet id becomes a manual follow-up, never an unattended attempt', () => {
    const r = resolveSelection(base((s) => s.added.push(ref('winget', 'Blizzard.BattleNet', 'Battle.net'))));
    expect(keys(r).some((k) => k.includes('battlenet'))).toBe(false);
    expect(manualItems(r).map((p) => p.catalog?.id)).toContain('battlenet');
  });
});
