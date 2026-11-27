import { describe, expect, it } from 'vitest';
import { exportProfile, importProfile, ownerDefaults } from '../../src/engine/profiles';
import { SCHEMA_VERSION } from '../../src/engine/schema/profile';
import { engineConfig } from '../../src/engine/windows-update';
import { SETTINGS_BY_PATH } from '../../src/features';
import { generate } from '../../src/engine/pipeline';
import { embedded, generateOk, profile } from './helpers';

/**
 * Schema 10: "Install preview updates" (Windows and .NET Framework previews), separate from the other
 * optional updates. Default on; off excludes only the previews.
 */

/** The owner default as a schema 9 export: no previewUpdates, the given optionalUpdates. */
function asSchema9(optionalUpdates: 'install' | 'skip'): string {
  const j = JSON.parse(exportProfile(ownerDefaults())) as Record<string, unknown> & { windowsUpdate: Record<string, unknown> };
  j.schemaVersion = 9;
  delete j.windowsUpdate.previewUpdates;
  j.windowsUpdate.optionalUpdates = optionalUpdates;
  return JSON.stringify(j);
}

describe('schema 10: Install preview updates', () => {
  it('is schema 10; the owner default installs previews; the setting is an Advanced checkbox under Windows Update', () => {
    expect(SCHEMA_VERSION).toBe(10);
    expect(ownerDefaults().windowsUpdate.previewUpdates).toBe(true);
    const def = SETTINGS_BY_PATH.get('windowsUpdate.previewUpdates')!;
    expect(def).toMatchObject({ section: 'windowsUpdate', label: 'Install preview updates', control: 'checkbox', advanced: true });
    expect(def.description).toContain('Include optional Windows and .NET Framework preview updates during deployment.');
  });

  it('reaches the engine configuration, on and off, independently of optional drivers', () => {
    expect(engineConfig(profile()).previewUpdates).toBe(true);
    const off = engineConfig(profile((p) => (p.windowsUpdate.previewUpdates = false)));
    expect(off.previewUpdates).toBe(false);
    expect(off.optionalUpdates).toBe('install');
    expect(off.drivers).toBe(engineConfig(profile()).drivers);
    expect(off.settingsRefresh).toBe(true);
  });

  it('is in the config.json the answer file embeds', () => {
    const on = JSON.parse(embedded(generateOk(profile()).root).get('config.json')!) as { previewUpdates: boolean; engineVersion: string };
    expect(on).toMatchObject({ previewUpdates: true, engineVersion: '2.1.0' });
    const off = JSON.parse(embedded(generateOk(profile((p) => (p.windowsUpdate.previewUpdates = false))).root).get('config.json')!) as { previewUpdates: boolean };
    expect(off.previewUpdates).toBe(false);
  });

  it.each([
    ['install', true],
    ['skip', false],
  ] as const)('a schema 9 profile with optionalUpdates=%s keeps what it installed: previews %s', (optional, previews) => {
    const r = importProfile(asSchema9(optional));
    expect(r.errors).toEqual([]);
    expect(r.profile!.windowsUpdate.previewUpdates).toBe(previews);
    expect(r.profile!.windowsUpdate.optionalUpdates).toBe(optional);
    // Same answer file as the same profile saved at schema 10 with the same choices.
    const same = ownerDefaults();
    same.windowsUpdate.optionalUpdates = optional;
    same.windowsUpdate.previewUpdates = previews;
    const current = importProfile(exportProfile(same));
    expect(current.errors).toEqual([]);
    expect(generate(r.profile).xml).toBe(generate(current.profile).xml);
  });

  it('a schema 9 profile that skipped optional updates is told that previews stay off', () => {
    const r = importProfile(asSchema9('skip'));
    expect(r.warnings.join(' ')).toMatch(/Preview updates .* stay off/);
  });

  it('export and import keep the choice', () => {
    const p = profile((x) => (x.windowsUpdate.previewUpdates = false));
    const back = importProfile(exportProfile(p));
    expect(back.errors).toEqual([]);
    expect(back.profile!.windowsUpdate.previewUpdates).toBe(false);
  });
});
