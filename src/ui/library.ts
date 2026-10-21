import type { AppProfile, ApplicationsSelection } from '../engine/schema/applications';
import { exportAppProfiles, loadLibrary, mergeLibrary } from '../engine/applications/profiles';

/**
 * Custom application profiles saved in this browser (localStorage, the same JSON format as
 * "Export"). Only custom application profiles are stored: never the deployment profile, names,
 * passwords or Wi-Fi keys. Browser storage is local to this browser and can be cleared at any time,
 * so it is not a backup; JSON export stays the portable copy.
 *
 * Rules: profiles in the library are added to the current selection whenever it lacks them (after
 * a reload, a reset or an import), every custom profile of the selection is saved back, and a
 * profile leaves the library only through an explicit delete.
 */

export const LIBRARY_KEY = 'wdb.appProfiles';

export interface Storage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export class ProfileLibrary {
  private profiles: AppProfile[] = [];
  private lastSaved = '';
  /** Readable problems found while loading (corrupt or incompatible data). */
  readonly warnings: string[] = [];
  /** False when the browser refuses storage (private mode, blocked site data). */
  available = true;

  constructor(private readonly storage: Storage | null) {
    let text: string | null = null;
    try {
      text = storage?.getItem(LIBRARY_KEY) ?? null;
      if (!storage) this.available = false;
    } catch {
      this.available = false;
    }
    const r = loadLibrary(text);
    this.profiles = r.profiles;
    this.warnings.push(...r.warnings);
    this.lastSaved = text ?? '';
  }

  list(): readonly AppProfile[] {
    return this.profiles;
  }

  /** Adds library profiles missing from the selection; returns how many were added. */
  restoreInto(sel: ApplicationsSelection): number {
    return mergeLibrary(sel, this.profiles);
  }

  /** Saves every custom profile of the selection (new or changed ones replace the stored copy). */
  saveFrom(sel: ApplicationsSelection): void {
    const byId = new Map(this.profiles.map((p) => [p.id, p]));
    for (const p of sel.profiles) if (!p.builtin) byId.set(p.id, structuredClone(p));
    this.profiles = [...byId.values()];
    this.persist();
  }

  /** Explicit delete (the only way a profile leaves the library). */
  remove(id: string): void {
    this.profiles = this.profiles.filter((p) => p.id !== id);
    this.persist();
  }

  private persist(): void {
    const text = this.profiles.length ? exportAppProfiles(this.profiles, null) : '';
    if (text === this.lastSaved) return;
    try {
      if (!this.storage) throw new Error('no storage');
      this.storage.setItem(LIBRARY_KEY, text);
      this.lastSaved = text;
      this.available = true;
    } catch {
      this.available = false;
    }
  }
}

function browserStorage(): Storage | null {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

export const profileLibrary = new ProfileLibrary(browserStorage());
