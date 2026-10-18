/**
 * Minimal, namespace-aware XML element tree used to build answer files.
 *
 * We deliberately avoid string concatenation: every element carries its namespace URI and every text
 * value is escaped by the serializer. The model is framework-agnostic and runs in Node and browsers.
 */

export const NS = {
  unattend: 'urn:schemas-microsoft-com:unattend',
  wcm: 'http://schemas.microsoft.com/WMIConfig/2002/State',
  /** Namespace for this project's embedded-file extension block (ignored by Windows Setup). */
  ext: 'urn:windows-deployment-builder:extensions:v1',
} as const;

export interface XAttr {
  name: string;
  value: string;
  ns?: string;
  /** Preferred prefix when `ns` is set (e.g. `wcm`). */
  prefix?: string;
}

export interface XText {
  kind: 'text';
  value: string;
}

export interface XElement {
  kind: 'element';
  name: string;
  ns: string;
  /** Preferred prefix; undefined means "use a default namespace declaration". */
  prefix?: string;
  attrs: XAttr[];
  children: XNode[];
  /** Extra prefix declarations to emit on this element (e.g. `xmlns:wcm` on the root). */
  declare?: { prefix: string; uri: string }[];
}

export type XNode = XElement | XText;

export function el(name: string, ns: string = NS.unattend, children: XNode[] = [], attrs: XAttr[] = []): XElement {
  return { kind: 'element', name, ns, attrs, children };
}

export function text(value: string): XText {
  return { kind: 'text', value };
}

/** Element with a single text child, in the same namespace as its parent by default. */
export function leaf(name: string, value: string, ns: string = NS.unattend): XElement {
  return el(name, ns, [text(value)]);
}

export function elements(parent: XElement): XElement[] {
  return parent.children.filter((c): c is XElement => c.kind === 'element');
}

export function child(parent: XElement, name: string, ns: string = parent.ns): XElement | undefined {
  return elements(parent).find((c) => c.name === name && c.ns === ns);
}

export function children(parent: XElement, name: string, ns: string = parent.ns): XElement[] {
  return elements(parent).filter((c) => c.name === name && c.ns === ns);
}

export function getAttr(e: XElement, name: string, ns?: string): string | undefined {
  return e.attrs.find((a) => a.name === name && a.ns === ns)?.value;
}

export function setAttr(e: XElement, name: string, value: string, ns?: string, prefix?: string): void {
  const existing = e.attrs.find((a) => a.name === name && a.ns === ns);
  if (existing) {
    existing.value = value;
  } else {
    e.attrs.push(ns ? { name, value, ns, prefix } : { name, value });
  }
}

export function textContent(e: XNode): string {
  return e.kind === 'text' ? e.value : e.children.map(textContent).join('');
}

export function append<T extends XNode>(parent: XElement, node: T): T {
  parent.children.push(node);
  return node;
}

export function remove(parent: XElement, node: XNode): void {
  const i = parent.children.indexOf(node);
  if (i >= 0) parent.children.splice(i, 1);
}

/** Depth-first walk over all elements, including the root. */
export function* walk(root: XElement): Generator<XElement> {
  yield root;
  for (const c of elements(root)) yield* walk(c);
}

export function clone<T extends XNode>(node: T): T {
  if (node.kind === 'text') return { ...node };
  return {
    ...node,
    attrs: node.attrs.map((a) => ({ ...a })),
    children: node.children.map((c) => clone(c)),
  } as T;
}
