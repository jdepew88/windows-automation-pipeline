import { SECRET_PATHS } from '.';

export interface Change {
  path: string;
  from: unknown;
  to: unknown;
}

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

/** Leaf-level differences between two profiles. Arrays are compared as a whole. */
export function diffProfiles(base: unknown, current: unknown, prefix = ''): Change[] {
  if (isObj(base) && isObj(current)) {
    const keys = [...new Set([...Object.keys(base), ...Object.keys(current)])].sort();
    return keys.flatMap((k) => diffProfiles(base[k], current[k], prefix ? `${prefix}.${k}` : k));
  }
  return JSON.stringify(base) === JSON.stringify(current) ? [] : [{ path: prefix, from: base, to: current }];
}

/** Display form of a value; secrets are masked. */
export function displayValue(path: string, v: unknown): string {
  if ((SECRET_PATHS as readonly string[]).includes(path)) return v === '' ? '(empty)' : '••••••';
  if (v === undefined) return '(none)';
  if (typeof v === 'string') return v === '' ? '(empty)' : v.length > 80 ? `${v.slice(0, 77)}…` : v;
  if (Array.isArray(v)) return v.length === 0 ? '(none)' : `${v.length} item(s)`;
  return JSON.stringify(v);
}
