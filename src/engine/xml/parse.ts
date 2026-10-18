import { DOMParser } from '@xmldom/xmldom';
import type { XAttr, XElement, XNode } from './tree';

export interface ParseResult {
  root?: XElement;
  errors: string[];
}

const ELEMENT_NODE = 1;
const TEXT_NODE = 3;
const CDATA_SECTION_NODE = 4;

// Structural subset of the DOM interfaces that xmldom provides, so this module also type-checks
// without DOM lib coupling.
interface DomNode {
  nodeType: number;
  nodeValue: string | null;
  childNodes: ArrayLike<DomNode>;
}
interface DomAttr {
  name: string;
  localName: string | null;
  prefix: string | null;
  namespaceURI: string | null;
  value: string;
}
interface DomElement extends DomNode {
  localName: string | null;
  tagName: string;
  prefix: string | null;
  namespaceURI: string | null;
  attributes: ArrayLike<DomAttr>;
}

function convert(node: DomElement): XElement {
  const attrs: XAttr[] = [];
  for (let i = 0; i < node.attributes.length; i++) {
    const a = node.attributes[i]!;
    if (a.name === 'xmlns' || a.prefix === 'xmlns') continue; // re-derived by the serializer
    const name = a.localName ?? a.name;
    attrs.push(a.namespaceURI ? { name, value: a.value, ns: a.namespaceURI, prefix: a.prefix ?? undefined } : { name, value: a.value });
  }
  const kids: XNode[] = [];
  for (let i = 0; i < node.childNodes.length; i++) {
    const c = node.childNodes[i]!;
    if (c.nodeType === ELEMENT_NODE) kids.push(convert(c as DomElement));
    else if (c.nodeType === TEXT_NODE || c.nodeType === CDATA_SECTION_NODE) kids.push({ kind: 'text', value: c.nodeValue ?? '' });
  }
  // Drop pure-whitespace text between child elements (formatting only).
  const hasElements = kids.some((k) => k.kind === 'element');
  const cleaned = hasElements ? kids.filter((k) => k.kind === 'element' || k.value.trim() !== '') : kids;
  return {
    kind: 'element',
    name: node.localName ?? node.tagName,
    ns: node.namespaceURI ?? '',
    prefix: node.prefix ?? undefined,
    attrs,
    children: cleaned,
  };
}

/** Parses a complete XML document. Never throws; well-formedness problems are returned as errors. */
export function parseXml(source: string): ParseResult {
  const errors: string[] = [];
  if (/<!DOCTYPE/i.test(source)) {
    return { errors: ['DOCTYPE declarations are not allowed.'] };
  }
  try {
    const parser = new DOMParser({
      onError: (level: string, message: string) => {
        if (level !== 'warning') errors.push(String(message).split('\n')[0]!.trim());
      },
    });
    const doc = parser.parseFromString(source, 'text/xml') as unknown as { documentElement: DomElement | null };
    if (errors.length > 0) return { errors };
    if (!doc.documentElement) return { errors: ['Document has no root element.'] };
    return { root: convert(doc.documentElement), errors };
  } catch (e) {
    const message = e instanceof Error ? e.message.split('\n')[0]!.trim() : String(e);
    if (!errors.includes(message)) errors.push(message);
    return { errors };
  }
}
