import { expect } from 'vitest';
import { generate, type GenerateResult } from '../../src/engine/pipeline';
import { ownerDefaults } from '../../src/engine/profiles';
import type { Profile } from '../../src/engine/schema/profile';
import { parseXml } from '../../src/engine/xml/parse';
import { NS, elements, getAttr, textContent, walk, type XElement } from '../../src/engine/xml/tree';

export function profile(mutate?: (p: Profile) => void, name = 'Alex'): Profile {
  const p = ownerDefaults();
  p.accounts.personName = name;
  mutate?.(p);
  return p;
}

/**
 * The Phase 4 owner default had an empty application selection; since Phase 4.2 Core Essentials
 * is selected. Tests about the engines-off / Milestone 1 output use this to clear it again.
 */
export function noApps(p: Profile): void {
  p.applications.selection.selectedProfiles = [];
}

export function generateOk(p: Profile): GenerateResult & { xml: string; root: XElement } {
  const r = generate(p);
  if (!r.ok) throw new Error(`Expected success, got: ${r.issues.map((i) => `${i.path}: ${i.message}`).join('; ')}`);
  const parsed = parseXml(r.xml!);
  expect(parsed.errors).toEqual([]);
  return { ...r, xml: r.xml!, root: parsed.root! };
}

export function errorsOf(p: unknown): { path: string; message: string }[] {
  const r = generate(p);
  expect(r.ok).toBe(false);
  expect(r.xml).toBeUndefined();
  return r.issues.filter((i) => i.severity === 'error').map(({ path, message }) => ({ path, message }));
}

export function components(root: XElement, pass: string): XElement[] {
  const s = elements(root).find((e) => e.name === 'settings' && getAttr(e, 'pass') === pass);
  return s ? elements(s) : [];
}

export function component(root: XElement, pass: string, name: string, arch = 'amd64'): XElement | undefined {
  return components(root, pass).find((c) => getAttr(c, 'name') === name && getAttr(c, 'processorArchitecture') === arch);
}

/** First descendant element matching a slash-separated local-name path. */
export function find(from: XElement, path: string): XElement | undefined {
  let cur: XElement | undefined = from;
  for (const part of path.split('/')) {
    cur = cur && elements(cur).find((e) => e.name === part);
  }
  return cur;
}

export function texts(root: XElement, name: string): string[] {
  return [...walk(root)].filter((e) => e.name === name && e.ns === NS.unattend).map(textContent);
}

/** Embedded file contents keyed by file name (after XML round-trip, i.e. as Windows reads them). */
export function embedded(root: XElement): Map<string, string> {
  const ext = elements(root).find((e) => e.name === 'Extensions' && e.ns === NS.ext);
  const out = new Map<string, string>();
  for (const f of ext ? elements(ext).filter((e) => e.name === 'File') : []) {
    out.set(getAttr(f, 'path')!.split('\\').pop()!, textContent(f).trim());
  }
  return out;
}

export function commandLines(root: XElement): { specialize: string[]; firstLogon: string[]; windowsPE: string[] } {
  const paths = (pass: string, comp: string, container: string, field: string) => {
    const c = component(root, pass, comp);
    const cont = c && find(c, container);
    return cont ? elements(cont).map((i) => textContent(find(i, field)!)) : [];
  };
  return {
    windowsPE: paths('windowsPE', 'Microsoft-Windows-Setup', 'RunSynchronous', 'Path'),
    specialize: paths('specialize', 'Microsoft-Windows-Deployment', 'RunSynchronous', 'Path'),
    firstLogon: paths('oobeSystem', 'Microsoft-Windows-Shell-Setup', 'FirstLogonCommands', 'CommandLine'),
  };
}
