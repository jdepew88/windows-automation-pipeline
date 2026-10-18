import { NS, type XAttr, type XElement, type XNode } from './tree';

/**
 * Serializes an element tree as an answer file.
 *
 * - CRLF line endings, tab indentation (matches upstream output and Notepad-friendly editing).
 * - Every character outside printable ASCII is written as a numeric character reference. Windows
 *   Setup expects `encoding="utf-8"` but only reliably handles ASCII (documented in upstream
 *   `UnattendGenerator.Serialize`), so the output is pure ASCII while still being valid UTF-8.
 * - Characters that XML 1.0 cannot represent at all cause an {@link XmlCharacterError}.
 */

export class XmlCharacterError extends Error {
  constructor(public readonly codePoint: number) {
    super(`Character U+${codePoint.toString(16).toUpperCase().padStart(4, '0')} cannot be represented in XML 1.0.`);
  }
}

export function isXmlChar(cp: number): boolean {
  return (
    cp === 0x9 ||
    cp === 0xa ||
    cp === 0xd ||
    (cp >= 0x20 && cp <= 0xd7ff) ||
    (cp >= 0xe000 && cp <= 0xfffd) ||
    (cp >= 0x10000 && cp <= 0x10ffff)
  );
}

/** Returns the first code point that XML 1.0 cannot represent, or undefined. */
export function findInvalidXmlChar(s: string): number | undefined {
  for (const ch of s) {
    const cp = ch.codePointAt(0)!;
    // A lone surrogate is yielded as a single UTF-16 unit by the string iterator.
    if (!isXmlChar(cp) || (cp >= 0xd800 && cp <= 0xdfff)) return cp;
  }
  return undefined;
}

function escape(s: string, attribute: boolean): string {
  let out = '';
  for (const ch of s) {
    const cp = ch.codePointAt(0)!;
    if ((cp >= 0xd800 && cp <= 0xdfff) || !isXmlChar(cp)) throw new XmlCharacterError(cp);
    switch (ch) {
      case '&':
        out += '&amp;';
        continue;
      case '<':
        out += '&lt;';
        continue;
      case '>':
        out += '&gt;';
        continue;
      case '"':
        out += attribute ? '&quot;' : '"';
        continue;
    }
    if (attribute && (cp === 0x9 || cp === 0xa || cp === 0xd)) {
      out += `&#x${cp.toString(16).toUpperCase()};`;
    } else if (cp > 0x7e) {
      out += `&#x${cp.toString(16).toUpperCase()};`;
    } else {
      out += ch;
    }
  }
  return out;
}

export const escapeText = (s: string): string => escape(s, false);
export const escapeAttr = (s: string): string => escape(s, true);

interface Scope {
  defaultNs: string;
  prefixes: Map<string, string>; // uri -> prefix
}

const NL = '\r\n';
const IND = '\t';

/** Elements whose single text child is written on its own lines (embedded script files). */
export const BLOCK_ELEMENTS = new Set([`${NS.ext}|File`, `${NS.ext}|ExtractScript`]);

function qualify(e: XElement, scope: Scope, decls: string[], local: Scope): string {
  if (e.ns === local.defaultNs && e.prefix === undefined) return e.name;
  if (e.prefix !== undefined) {
    if (local.prefixes.get(e.ns) !== e.prefix) {
      decls.push(`xmlns:${e.prefix}="${escapeAttr(e.ns)}"`);
      local.prefixes.set(e.ns, e.prefix);
    }
    return `${e.prefix}:${e.name}`;
  }
  const known = scope.prefixes.get(e.ns);
  if (known) return `${known}:${e.name}`;
  decls.push(`xmlns="${escapeAttr(e.ns)}"`);
  local.defaultNs = e.ns;
  return e.name;
}

function qualifyAttr(a: XAttr, decls: string[], local: Scope): string {
  if (!a.ns) return a.name;
  let prefix = local.prefixes.get(a.ns);
  if (!prefix) {
    prefix = a.prefix ?? (a.ns === NS.wcm ? 'wcm' : `ns${local.prefixes.size + 1}`);
    decls.push(`xmlns:${prefix}="${escapeAttr(a.ns)}"`);
    local.prefixes.set(a.ns, prefix);
  }
  return `${prefix}:${a.name}`;
}

function normalizeNewlines(s: string): string {
  return s.replace(/\r\n|\r|\n/g, NL);
}

function writeElement(e: XElement, depth: number, scope: Scope, out: string[]): void {
  const local: Scope = { defaultNs: scope.defaultNs, prefixes: new Map(scope.prefixes) };
  const decls: string[] = [];
  const qname = qualify(e, scope, decls, local);
  for (const d of e.declare ?? []) {
    if (local.prefixes.get(d.uri) !== d.prefix) {
      decls.push(`xmlns:${d.prefix}="${escapeAttr(d.uri)}"`);
      local.prefixes.set(d.uri, d.prefix);
    }
  }
  const attrs = e.attrs.map((a) => `${qualifyAttr(a, decls, local)}="${escapeAttr(a.value)}"`);
  const open = [qname, ...decls, ...attrs].join(' ');
  const indent = IND.repeat(depth);

  if (e.children.length === 0) {
    out.push(`${indent}<${open} />`);
    return;
  }
  const onlyText = e.children.every((c) => c.kind === 'text');
  if (onlyText) {
    const value = e.children.map((c) => (c.kind === 'text' ? c.value : '')).join('');
    if (BLOCK_ELEMENTS.has(`${e.ns}|${e.name}`)) {
      out.push(`${indent}<${open}>${NL}${escapeText(normalizeNewlines(value.trim()))}${NL}${indent}</${qname}>`);
    } else {
      out.push(`${indent}<${open}>${escapeText(value)}</${qname}>`);
    }
    return;
  }
  out.push(`${indent}<${open}>`);
  for (const c of e.children) {
    if (c.kind === 'element') {
      writeElement(c, depth + 1, local, out);
    } else if (c.value.trim() !== '') {
      // Mixed content is not used by answer files; keep significant text rather than dropping it.
      out.push(`${IND.repeat(depth + 1)}${escapeText(c.value)}`);
    }
  }
  out.push(`${indent}</${qname}>`);
}

export function serialize(root: XElement): string {
  const out: string[] = ['<?xml version="1.0" encoding="utf-8"?>'];
  writeElement(root, 0, { defaultNs: '', prefixes: new Map() }, out);
  return out.join(NL) + NL;
}

/** Serializes a fragment (no XML declaration), e.g. an embedded Wi-Fi or AppLocker document. */
export function serializeFragment(root: XElement | XNode): string {
  if (root.kind === 'text') return escapeText(root.value);
  const out: string[] = [];
  writeElement(root, 0, { defaultNs: '', prefixes: new Map() }, out);
  return out.join(NL);
}
