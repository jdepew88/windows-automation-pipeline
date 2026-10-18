import { describe, expect, it } from 'vitest';
import { ALL_SETTINGS, SECTIONS } from '../../src/features';
import { ownerDefaults } from '../../src/engine/profiles';
import { UPSTREAM_RESOURCES } from '../../src/engine/resources/upstream';
import { parseXml } from '../../src/engine/xml/parse';

/** Leaf paths of the profile. Map-like sections and arrays count as one setting. */
function leafPaths(obj: Record<string, unknown>, prefix = ''): string[] {
  const out: string[] = [];
  for (const [k, v] of Object.entries(obj)) {
    const p = prefix ? `${prefix}.${k}` : k;
    if (['schemaVersion', 'profileName'].includes(p)) continue;
    if (['bloatware', 'desktop.icons', 'start.folders'].includes(p) || Array.isArray(v) || typeof v !== 'object' || v === null) out.push(p);
    else out.push(...leafPaths(v as Record<string, unknown>, p));
  }
  return out;
}

describe('settings registry', () => {
  it('covers every profile field exactly once and nothing else', () => {
    const defined = ALL_SETTINGS.map((s) => s.path);
    expect(new Set(defined).size).toBe(defined.length);
    expect([...defined].sort()).toEqual(leafPaths(ownerDefaults()).sort());
  });

  it('gives every setting the required metadata', () => {
    const sections = new Set(SECTIONS.map((s) => s.id));
    for (const s of ALL_SETTINGS) {
      expect(sections.has(s.section), s.path).toBe(true);
      expect(s.label, s.path).not.toBe('');
      expect(s.applicability, s.path).not.toBe('');
      expect(s.mapping, s.path).not.toBe('');
      expect(s.stages.length, s.path).toBeGreaterThan(0);
      if (s.control === 'radio' || s.control === 'select') expect(s.choices, s.path).toBeDefined();
    }
  });

  it('offers every owner-default value among the declared choices', () => {
    const p = ownerDefaults() as unknown as Record<string, Record<string, unknown>>;
    for (const s of ALL_SETTINGS) {
      if (s.control !== 'radio' && s.control !== 'select') continue;
      const [a, b] = s.path.split('.') as [string, string];
      const value = p[a]![b];
      const choices = typeof s.choices === 'function' ? s.choices() : s.choices!;
      expect(choices.map((c) => c.value), s.path).toContain(value);
    }
  });

  it('keeps Basic view focused: FirstLogon visible, other script stages advanced', () => {
    const byPath = new Map(ALL_SETTINGS.map((s) => [s.path, s]));
    expect(byPath.get('scripts.firstLogon')!.advanced).toBe(false);
    for (const p of ['scripts.system', 'scripts.defaultUser', 'scripts.userOnce', 'advancedXml.components', 'output.answerFileName']) {
      expect(byPath.get(p)!.advanced, p).toBe(true);
    }
  });
});

describe('upstream resources', () => {
  it('embedded XML resources are well-formed', () => {
    for (const [name, content] of Object.entries(UPSTREAM_RESOURCES)) {
      if (name.endsWith('.xml')) expect(parseXml(content).errors, name).toEqual([]);
    }
  });
});
