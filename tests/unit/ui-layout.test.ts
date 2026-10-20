import { describe, expect, it } from 'vitest';
import { ALL_SETTINGS, SECTIONS } from '../../src/features';
import { FIELD_GROUPS, NAV_GROUPS } from '../../src/ui/layout';

describe('UI layout (presentation only)', () => {
  it('puts every setting of a grouped section into exactly one card', () => {
    for (const [section, groups] of Object.entries(FIELD_GROUPS)) {
      const paths = ALL_SETTINGS.filter((s) => s.section === section).map((s) => s.path);
      const grouped = groups!.flatMap((g) => g.paths);
      expect(grouped.slice().sort(), section).toEqual(paths.slice().sort());
    }
  });

  it('gives every section with settings, plus Review, exactly one sidebar page entry', () => {
    const withSettings = SECTIONS.filter((s) => ALL_SETTINGS.some((d) => d.section === s.id)).map((s) => s.id as string);
    const pageItems = NAV_GROUPS.flatMap((g) => g.items).filter((i) => i.target === `section-${i.page}`).map((i) => i.page as string);
    expect(pageItems.slice().sort()).toEqual([...withSettings, 'review'].sort());
  });
});
