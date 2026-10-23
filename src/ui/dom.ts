type Attrs = Record<string, string | number | boolean | undefined | ((e: Event) => void)>;
type Child = Node | string | null | undefined | false;

/** Listeners added by `h`, so `patchChildren` can move the current ones onto a reused element. */
const LISTENERS = new WeakMap<Element, Record<string, (e: Event) => void>>();

/** Tiny hyperscript helper. `on*` attributes become listeners; booleans toggle attributes. */
export function h<K extends keyof HTMLElementTagNameMap>(tag: K, attrs: Attrs = {}, ...children: (Child | Child[])[]): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === undefined || v === false) continue;
    if (typeof v === 'function') {
      const type = k.slice(2).toLowerCase();
      e.addEventListener(type, v);
      const map = LISTENERS.get(e) ?? {};
      map[type] = v;
      LISTENERS.set(e, map);
    } else if (v === true) e.setAttribute(k, '');
    else if (k === 'value' && 'value' in e) (e as HTMLInputElement).value = String(v);
    else e.setAttribute(k, String(v));
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined || c === false) continue;
    e.append(typeof c === 'string' ? document.createTextNode(c) : c);
  }
  return e;
}

export function clear(e: Element): void {
  while (e.firstChild) e.firstChild.remove();
}

/** Attributes that identify an element across renders (an app, a profile, a logo, …). */
const KEY_ATTRS = ['data-key', 'data-app', 'data-package', 'data-excluded', 'data-profile', 'data-type', 'data-logo', 'data-removed', 'data-manual', 'data-consideration', 'data-filter', 'data-view-mode'];

function nodeKey(n: Node): string | undefined {
  if (!(n instanceof Element)) return undefined;
  for (const a of KEY_ATTRS) {
    const v = n.getAttribute(a);
    if (v !== null) return `${n.tagName}|${a}=${v}`;
  }
  return undefined;
}

const sameKind = (a: Node, b: Node) =>
  a.nodeType === b.nodeType && (!(a instanceof Element) || (a.tagName === (b as Element).tagName && (!(a instanceof HTMLInputElement) || a.type === (b as HTMLInputElement).type)));

/** Makes `from` (in the document) look and behave like `to` (freshly built), keeping `from` itself. */
function morph(from: Node, to: Node): void {
  if (!(from instanceof Element) || !(to instanceof Element)) {
    if (from.nodeValue !== to.nodeValue) from.nodeValue = to.nodeValue;
    return;
  }
  for (const attr of [...from.attributes]) if (!to.hasAttribute(attr.name)) from.removeAttribute(attr.name);
  for (const attr of [...to.attributes]) if (from.getAttribute(attr.name) !== attr.value) from.setAttribute(attr.name, attr.value);
  const before = LISTENERS.get(from) ?? {};
  for (const [type, fn] of Object.entries(before)) from.removeEventListener(type, fn);
  const after = LISTENERS.get(to) ?? {};
  for (const [type, fn] of Object.entries(after)) from.addEventListener(type, fn);
  LISTENERS.set(from, { ...after });
  patchChildren(from, [...to.childNodes]);
  if (from instanceof HTMLInputElement && to instanceof HTMLInputElement) {
    if (from.checked !== to.checked) from.checked = to.checked;
    if (from.value !== to.value) from.value = to.value;
  } else if (from instanceof HTMLSelectElement && to instanceof HTMLSelectElement && from.value !== to.value) from.value = to.value;
}

/**
 * Replaces the children of `parent` with `next`, reusing the elements already shown (matched by
 * their key attribute, otherwise by position and tag) and updating them in place. Re-rendering a
 * list this way keeps its elements: the browser's scroll anchor (CSS overflow-anchor), keyboard
 * focus and loaded images survive a change, so the page does not jump when an item is ticked.
 */
export function patchChildren(parent: Node, children: readonly (Node | null | undefined | false)[]): void {
  const next = children.filter((c): c is Node => !!c);
  const old = [...parent.childNodes];
  const keyed = new Map<string, Node>();
  for (const n of old) {
    const k = nodeKey(n);
    if (k && !keyed.has(k)) keyed.set(k, n);
  }
  const used = new Set<Node>();
  let cursor = 0;
  const matches = next.map((n) => {
    const k = nodeKey(n);
    let match: Node | undefined;
    if (k) {
      const c = keyed.get(k);
      if (c && !used.has(c) && sameKind(c, n)) match = c;
    } else {
      while (cursor < old.length && (used.has(old[cursor]!) || nodeKey(old[cursor]!))) cursor++;
      const c = old[cursor];
      if (c && sameKind(c, n)) {
        match = c;
        cursor++;
      }
    }
    if (match) used.add(match);
    return match;
  });
  for (const n of old) if (!used.has(n)) parent.removeChild(n);
  next.forEach((n, i) => {
    const match = matches[i];
    const node = match ?? n;
    if (match) morph(match, n);
    const at = parent.childNodes[i] ?? null;
    if (at !== node) parent.insertBefore(node, at);
  });
}

/** Builds new content in a detached container and patches it into `parent` (see patchChildren). */
export function render(parent: Element, build: (into: HTMLElement) => void): void {
  const into = document.createElement('div');
  build(into);
  patchChildren(parent, [...into.childNodes]);
}

let counter = 0;
export const uid = (prefix: string): string => `${prefix}-${++counter}`;

export function download(fileName: string, content: string | Uint8Array, type: string): void {
  const blob = new Blob([content as BlobPart], { type });
  const url = URL.createObjectURL(blob);
  const a = h('a', { href: url, download: fileName });
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
