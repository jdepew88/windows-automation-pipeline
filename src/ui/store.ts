import { ownerDefaults } from '../engine/profiles';
import type { Profile } from '../engine/schema/profile';

/**
 * In-memory profile state. Deliberately not persisted: profiles (and any imported WinGet lists or
 * secrets) live only for this browser session unless exported by the user.
 */
type Listener = (p: Profile, structural: boolean) => void;

export class Store {
  private profile: Profile = ownerDefaults();
  private readonly listeners = new Set<Listener>();

  get(): Profile {
    return this.profile;
  }

  /** `structural` changes (mode switches, list edits, imports) require controls to re-sync. */
  update(mutate: (p: Profile) => void, structural = false): void {
    mutate(this.profile);
    this.emit(structural);
  }

  replace(p: Profile): void {
    this.profile = structuredClone(p);
    this.emit(true);
  }

  subscribe(l: Listener): void {
    this.listeners.add(l);
  }

  private emit(structural: boolean): void {
    for (const l of this.listeners) l(this.profile, structural);
  }
}

export function getPath(obj: unknown, path: string): unknown {
  return path.split('.').reduce<unknown>((o, k) => (o && typeof o === 'object' ? (o as Record<string, unknown>)[k] : undefined), obj);
}

export function setPath(obj: unknown, path: string, value: unknown): void {
  const parts = path.split('.');
  const last = parts.pop()!;
  const target = parts.reduce<Record<string, unknown>>((o, k) => o[k] as Record<string, unknown>, obj as Record<string, unknown>);
  target[last] = value;
}
