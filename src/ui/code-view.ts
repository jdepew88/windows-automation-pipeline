import { clear, h } from './dom';

/**
 * Read-only code viewer: line-number gutter plus lightweight XML highlighting. The highlighted
 * element's textContent is exactly the source text (numbers live in a separate, aria-hidden
 * gutter), so what is shown, copied and downloaded is the same string.
 */

const TAG = /<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|<\/?[\w:.-]+(?:[^>"']|"[^"]*"|'[^']*')*\/?>/g;
const TAG_PARTS = /^(<\/?)([\w:.-]+)([\s\S]*?)(\/?>)$/;
const ATTR = /(\s+)([\w:.-]+)(\s*=\s*)("[^"]*"|'[^']*')|([\s\S])/g;

const span = (cls: string, text: string) => h('span', { class: cls }, text);

function highlightTag(tag: string, out: Node[]): void {
  if (tag.startsWith('<!--')) return void out.push(span('x-com', tag));
  if (tag.startsWith('<![CDATA[')) return void out.push(span('x-cdata', tag));
  if (tag.startsWith('<?')) return void out.push(span('x-pi', tag));
  const m = TAG_PARTS.exec(tag);
  if (!m) return void out.push(document.createTextNode(tag));
  out.push(span('x-punc', m[1]!), span('x-tag', m[2]!));
  let plain = '';
  for (const a of m[3]!.matchAll(ATTR)) {
    if (a[5] !== undefined) {
      plain += a[5];
      continue;
    }
    if (plain) out.push(document.createTextNode(plain));
    plain = '';
    out.push(document.createTextNode(a[1]!), span('x-attr', a[2]!), span('x-punc', a[3]!), span('x-val', a[4]!));
  }
  if (plain) out.push(document.createTextNode(plain));
  out.push(span('x-punc', m[4]!));
}

export function highlightXml(xml: string): Node[] {
  const out: Node[] = [];
  let last = 0;
  for (const m of xml.matchAll(TAG)) {
    if (m.index > last) out.push(document.createTextNode(xml.slice(last, m.index)));
    highlightTag(m[0], out);
    last = m.index + m[0].length;
  }
  if (last < xml.length) out.push(document.createTextNode(xml.slice(last)));
  return out;
}

export interface CodeView {
  el: HTMLElement;
  code: HTMLElement;
  set(text: string, opts?: { highlight?: boolean; placeholder?: boolean }): void;
}

export function codeView(attrs: Record<string, string> = {}): CodeView {
  const gutter = h('pre', { class: 'gutter', 'aria-hidden': 'true' });
  const code = h('pre', { class: 'code', tabindex: 0, ...attrs });
  const el = h('div', { class: 'code-view' }, h('div', { class: 'code-scroll' }, gutter, code));
  let shown: string | undefined;
  return {
    el,
    code,
    set(text, opts = {}) {
      const key = `${opts.placeholder ? 'p' : opts.highlight ? 'h' : 't'}:${text}`;
      if (key === shown) return;
      shown = key;
      clear(code);
      el.classList.toggle('placeholder', Boolean(opts.placeholder));
      if (opts.placeholder) {
        gutter.textContent = '';
        code.textContent = text;
        return;
      }
      const lines = text.replace(/\r?\n$/, '').split(/\r?\n/).length;
      gutter.textContent = Array.from({ length: lines }, (_, i) => String(i + 1)).join('\n');
      if (opts.highlight) {
        code.append(...highlightXml(text));
        // Never show something other than the real text.
        if (code.textContent !== text) code.textContent = text;
      } else {
        code.textContent = text;
      }
    },
  };
}
