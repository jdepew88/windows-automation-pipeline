import { KNOWN_SOURCES, type KnownSource, type PackageRef } from '../schema/applications';

/**
 * Package identifier rules. These are deliberately stricter than WinGet itself: every value that
 * reaches a generated command line must match one of these patterns, so no quoting, spaces or
 * shell metacharacters can ever occur in it.
 */

/** winget community repository IDs: 2-8 dot-separated segments of letters, digits, _ + - (each ≤ 32). */
export const WINGET_ID = /^(?=.{3,128}$)[A-Za-z0-9][A-Za-z0-9_+-]{0,31}(?:\.[A-Za-z0-9_+-]{1,32}){1,7}$/;
/** Microsoft Store product IDs: 9xxxxxxxxxxx (12) or XPxxxxxxxxxxxx (14). */
export const MSSTORE_ID = /^(?:9[A-Z0-9]{11}|XP[A-Z0-9]{12})$/;
/** Version pins passed to --version. */
export const VERSION = /^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$/;

export const isKnownSource = (s: string): s is KnownSource => (KNOWN_SOURCES as readonly string[]).includes(s);

/**
 * Pseudo-source for catalog entries that have no WinGet or Store package (manual follow-up, Phase
 * 4.2). The identifier is the catalog id. Such a reference is never passed to WinGet.
 */
export const CATALOG_SOURCE = 'catalog';
export const CATALOG_ID = /^[a-z0-9][a-z0-9-]{0,47}$/;

/** Stable de-duplication key: source + PackageIdentifier, case-insensitive (WinGet IDs are). */
export function packageKey(ref: Pick<PackageRef, 'source' | 'packageIdentifier'>): string {
  return `${ref.source.toLowerCase()}:${ref.packageIdentifier.toLowerCase()}`;
}

/** Normalises the identifier for its source (Store IDs are upper case). */
export function normalizeId(source: string, id: string): string {
  const t = id.trim();
  return source.toLowerCase() === 'msstore' ? t.toUpperCase() : t;
}

/** Why a package cannot be installed by the engine, or undefined when it can. */
export function unresolvedReason(ref: Pick<PackageRef, 'source' | 'packageIdentifier' | 'version'>): string | undefined {
  const source = ref.source.toLowerCase();
  if (source === CATALOG_SOURCE) return CATALOG_ID.test(ref.packageIdentifier) ? undefined : `"${ref.packageIdentifier}" is not a catalog id.`;
  if (!isKnownSource(source)) return `Source "${ref.source}" is not supported (only winget and msstore). The package is kept but not installed.`;
  if (source === 'winget' && !WINGET_ID.test(ref.packageIdentifier)) return `"${ref.packageIdentifier}" is not a valid winget PackageIdentifier (for example Publisher.Package).`;
  if (source === 'msstore' && !MSSTORE_ID.test(ref.packageIdentifier)) return `"${ref.packageIdentifier}" is not a Microsoft Store product ID (for example 9NBLGGH4NNS1).`;
  if (ref.version && !VERSION.test(ref.version)) return `Version "${ref.version}" contains characters that are not allowed.`;
  return undefined;
}
