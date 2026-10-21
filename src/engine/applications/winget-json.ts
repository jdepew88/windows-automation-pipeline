import { KNOWN_SOURCES, SOURCE_DETAILS, type KnownSource, type PackageRef, type SourceDetails } from '../schema/applications';
import { isKnownSource, normalizeId, packageKey, unresolvedReason, VERSION } from './ids';

/**
 * Microsoft's native package list format, as written by `winget export` and read by `winget import`:
 * https://github.com/microsoft/winget-cli/blob/master/schemas/JSON/packages/packages.schema.2.0.json
 *
 * `validateWinGetDocument` checks every rule of that schema (required members, types, the
 * WinGetVersion pattern, CreationDate format, Scope enum, Packages minItems). Unknown members are
 * allowed by the schema and ignored here. Normalisation then applies this project's stricter
 * identifier rules, so nothing unsafe reaches a command line.
 */

export const WINGET_SCHEMA_URL = 'https://aka.ms/winget-packages.schema.2.0.json';
export const MAX_IMPORT_BYTES = 5 * 1024 * 1024;
export const MAX_IMPORT_PACKAGES = 2000;

export interface WinGetPackage {
  PackageIdentifier: string;
  Version?: string;
  Channel?: string;
  Scope?: 'user' | 'machine';
  InitialOverrideArguments?: string;
  InitialCustomSwitches?: string;
}

export interface WinGetDocument {
  $schema?: string;
  CreationDate?: string;
  WinGetVersion?: string;
  Sources: { SourceDetails: SourceDetails; Packages: WinGetPackage[] }[];
}

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);
const own = (o: Record<string, unknown>, k: string) => Object.prototype.hasOwnProperty.call(o, k);

/** RFC 3339 date-time (JSON Schema "date-time" format). */
const DATE_TIME = /^\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:\d{2})$/;
const WINGET_VERSION = /^[0-9]+\.[0-9]+\.[0-9]+(-preview)?$/;

/** Returns schema violations as "path: message" strings; empty when the document is valid. */
export function validateWinGetDocument(doc: unknown): string[] {
  const errors: string[] = [];
  const str = (o: Record<string, unknown>, k: string, path: string, required: boolean) => {
    if (!own(o, k)) {
      if (required) errors.push(`${path}: required property "${k}" is missing`);
      return;
    }
    if (typeof o[k] !== 'string') errors.push(`${path}.${k}: must be a string`);
  };
  if (!isObj(doc)) return ['$: the document must be a JSON object'];
  str(doc, 'WinGetVersion', '$', false);
  if (typeof doc.WinGetVersion === 'string' && !WINGET_VERSION.test(doc.WinGetVersion)) errors.push('$.WinGetVersion: must look like 1.6.2771 (or 1.6.2771-preview)');
  str(doc, 'CreationDate', '$', false);
  if (typeof doc.CreationDate === 'string' && !DATE_TIME.test(doc.CreationDate)) errors.push('$.CreationDate: must be an RFC 3339 date-time');
  if (!own(doc, 'Sources')) {
    errors.push('$: required property "Sources" is missing');
    return errors;
  }
  if (!Array.isArray(doc.Sources)) return [...errors, '$.Sources: must be an array'];
  doc.Sources.forEach((s, i) => {
    const sp = `$.Sources[${i}]`;
    if (!isObj(s)) return errors.push(`${sp}: must be an object`);
    if (!own(s, 'SourceDetails')) errors.push(`${sp}: required property "SourceDetails" is missing`);
    else if (!isObj(s.SourceDetails)) errors.push(`${sp}.SourceDetails: must be an object`);
    else for (const k of ['Name', 'Identifier', 'Argument', 'Type']) str(s.SourceDetails, k, `${sp}.SourceDetails`, true);
    if (!own(s, 'Packages')) return errors.push(`${sp}: required property "Packages" is missing`);
    if (!Array.isArray(s.Packages)) return errors.push(`${sp}.Packages: must be an array`);
    if (s.Packages.length < 1) errors.push(`${sp}.Packages: must contain at least 1 package`);
    s.Packages.forEach((p, j) => {
      const pp = `${sp}.Packages[${j}]`;
      if (!isObj(p)) return errors.push(`${pp}: must be an object`);
      str(p, 'PackageIdentifier', pp, true);
      for (const k of ['Version', 'Channel', 'InitialOverrideArguments', 'InitialCustomSwitches']) str(p, k, pp, false);
      if (own(p, 'Scope') && p.Scope !== 'user' && p.Scope !== 'machine') errors.push(`${pp}.Scope: must be "user" or "machine"`);
    });
    return undefined;
  });
  return errors;
}

/** Maps SourceDetails to a known source only when every identifying detail matches. */
export function identifySource(d: SourceDetails): KnownSource | undefined {
  for (const name of KNOWN_SOURCES) {
    const k = SOURCE_DETAILS[name];
    if (d.Identifier.toLowerCase() === k.Identifier.toLowerCase() && d.Type === k.Type && d.Argument.replace(/\/+$/, '').toLowerCase() === k.Argument.toLowerCase()) return name;
  }
  return undefined;
}

export interface WinGetImportResult {
  ok: boolean;
  /** Fatal problems (not JSON, schema violations). Nothing is imported when present. */
  errors: string[];
  warnings: string[];
  packages: PackageRef[];
  /** Entries that were not imported, with the reason. */
  rejected: { packageIdentifier: string; source: string; reason: string }[];
  meta: { winGetVersion?: string; creationDate?: string; sources: number };
}

export function looksLikeWinGetDocument(v: unknown): boolean {
  return isObj(v) && own(v, 'Sources') && !own(v, 'format');
}

/** Parses, validates and normalises a native WinGet package list. Never throws for bad input. */
export function importWinGetJson(text: string): WinGetImportResult {
  const fail = (errors: string[]): WinGetImportResult => ({ ok: false, errors, warnings: [], packages: [], rejected: [], meta: { sources: 0 } });
  if (text.length > MAX_IMPORT_BYTES) return fail([`File is larger than ${MAX_IMPORT_BYTES / 1024 / 1024} MB.`]);
  let raw: unknown;
  try {
    raw = JSON.parse(text.charCodeAt(0) === 0xfeff ? text.slice(1) : text);
  } catch (e) {
    return fail([`Not valid JSON: ${(e as Error).message}`]);
  }
  return importWinGetDocument(raw);
}

export function importWinGetDocument(raw: unknown): WinGetImportResult {
  const errors = validateWinGetDocument(raw);
  if (errors.length) return { ok: false, errors: errors.slice(0, 20), warnings: [], packages: [], rejected: [], meta: { sources: 0 } };
  const doc = raw as WinGetDocument;
  const warnings: string[] = [];
  const packages: PackageRef[] = [];
  const rejected: WinGetImportResult['rejected'] = [];
  const seen = new Set<string>();
  const total = doc.Sources.reduce((n, s) => n + s.Packages.length, 0);
  if (total > MAX_IMPORT_PACKAGES) return { ok: false, errors: [`The file lists ${total} packages; at most ${MAX_IMPORT_PACKAGES} are accepted.`], warnings: [], packages: [], rejected: [], meta: { sources: doc.Sources.length } };
  let droppedArgs = 0;
  let droppedChannels = 0;

  for (const s of doc.Sources) {
    const d = s.SourceDetails;
    const known = identifySource(d);
    // A source that only borrows a known name gets a distinct name, so it can never merge with (or
    // be installed as) the real winget/msstore package.
    const sourceName = known ?? (KNOWN_SOURCES.includes(d.Name.toLowerCase() as KnownSource) ? `${d.Name} (unverified)` : d.Name);
    if (!known) {
      warnings.push(
        KNOWN_SOURCES.includes(d.Name.toLowerCase() as KnownSource)
          ? `Source "${d.Name}" does not match Microsoft's ${d.Name} source (${d.Argument}); its packages are kept as unresolved and will not be installed.`
          : `Source "${d.Name}" (${d.Argument}) is not supported; its packages are kept as unresolved and will not be installed.`,
      );
    }
    for (const p of s.Packages) {
      const id = normalizeId(sourceName, p.PackageIdentifier);
      if (!id) {
        rejected.push({ packageIdentifier: p.PackageIdentifier, source: sourceName, reason: 'Empty PackageIdentifier.' });
        continue;
      }
      if (p.InitialOverrideArguments !== undefined || p.InitialCustomSwitches !== undefined) droppedArgs++;
      if (p.Channel !== undefined) droppedChannels++;
      const version = (p.Version ?? '').trim();
      const ref: PackageRef = {
        packageIdentifier: id,
        source: sourceName,
        displayName: id,
        version: version && VERSION.test(version) ? version : '',
        scope: p.Scope ?? '',
        ...(known ? {} : { sourceDetails: { Name: d.Name, Identifier: d.Identifier, Argument: d.Argument, Type: d.Type } }),
      };
      if (version && !VERSION.test(version)) warnings.push(`${id}: version "${version.slice(0, 40)}" was not accepted; the latest version will be used.`);
      if (known) {
        const reason = unresolvedReason(ref);
        if (reason) {
          rejected.push({ packageIdentifier: p.PackageIdentifier.slice(0, 128), source: sourceName, reason });
          continue;
        }
      } else if (id.length > 128 || /[\s"'`$;|&<>]/.test(id)) {
        rejected.push({ packageIdentifier: id.slice(0, 128), source: sourceName, reason: 'Identifier contains characters that are not allowed.' });
        continue;
      }
      const key = packageKey(ref);
      if (seen.has(key)) {
        warnings.push(`${id} (${sourceName}) is listed more than once; it is imported once.`);
        continue;
      }
      seen.add(key);
      packages.push(ref);
    }
  }
  if (droppedArgs) warnings.push(`${droppedArgs} package(s) carried InitialOverrideArguments/InitialCustomSwitches. Installer arguments from imported files are never used, so they were dropped.`);
  if (droppedChannels) warnings.push(`${droppedChannels} package(s) named a Channel, which this builder does not use; it was dropped.`);
  return { ok: true, errors: [], warnings, packages, rejected, meta: { winGetVersion: doc.WinGetVersion, creationDate: doc.CreationDate, sources: doc.Sources.length } };
}

/**
 * Writes a schema-valid package list for `winget import`. Only installable packages (known source,
 * valid identifier) are written; sources without packages are omitted (Packages needs ≥ 1 item).
 */
export function exportWinGetDocument(refs: readonly PackageRef[], now: Date | null = new Date()): WinGetDocument {
  const bySource = new Map<KnownSource, WinGetPackage[]>();
  const seen = new Set<string>();
  for (const r of refs) {
    const source = r.source.toLowerCase();
    if (!isKnownSource(source) || unresolvedReason(r) || seen.has(packageKey(r))) continue;
    seen.add(packageKey(r));
    const list = bySource.get(source as KnownSource) ?? [];
    const pkg: WinGetPackage = { PackageIdentifier: r.packageIdentifier };
    if (r.version) pkg.Version = r.version;
    if (r.scope) pkg.Scope = r.scope;
    list.push(pkg);
    bySource.set(source as KnownSource, list);
  }
  return {
    $schema: WINGET_SCHEMA_URL,
    // Optional in the schema; left out (now = null) where output must be reproducible.
    ...(now ? { CreationDate: now.toISOString() } : {}),
    Sources: KNOWN_SOURCES.filter((s) => bySource.has(s)).map((s) => ({ Packages: bySource.get(s)!, SourceDetails: { ...SOURCE_DETAILS[s] } })),
  };
}

export function exportWinGetJson(refs: readonly PackageRef[], now?: Date | null): string {
  return JSON.stringify(exportWinGetDocument(refs, now), null, 2) + '\n';
}
