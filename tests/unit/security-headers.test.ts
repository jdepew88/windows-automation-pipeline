import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { contentSecurityPolicy, headersFile, inlineHashes } from '../../scripts/security-headers';
import { HEALTH_TEMPLATE } from '../../src/engine/health';
import { importProfile, MAX_PROFILE_BYTES } from '../../src/engine/profiles';
import { importHardwareInventory, MAX_HARDWARE_INVENTORY_BYTES } from '../../src/engine/drivers';

/**
 * The hosted site's security headers (Cloudflare Pages, public/_headers) and the Content-Security-
 * Policy of the pages come from scripts/security-headers.ts. `npm run headers` regenerates them.
 */

const read = (rel: string) => readFileSync(new URL(`../../${rel}`, import.meta.url), 'utf8');
const metaCsp = (html: string) => /Content-Security-Policy" content="([^"]+)"/.exec(html)![1]!;
const directives = (csp: string) => new Map(csp.split(';').map((d) => d.trim().split(/\s+/)).map(([k, ...v]) => [k!, v]));

describe('security headers', () => {
  it('public/_headers is up to date (run `npm run headers` after changing the policy or the health template)', () => {
    expect(read('public/_headers')).toBe(headersFile());
  });

  it('the source pages carry the development policy (Vite dev server), generated from the same definition', () => {
    for (const page of ['index.html', 'manager.html']) expect(metaCsp(read(page)), page).toBe(contentSecurityPolicy('development'));
  });

  it('the production policy allows only the site itself and the hashed health template blocks', () => {
    const csp = contentSecurityPolicy('production', { header: true });
    expect(csp).not.toMatch(/unsafe-inline|unsafe-eval|unsafe-hashes|ws:|wss:|https?:|data:|blob:|\*/);
    const d = directives(csp);
    expect(d.get('default-src')).toEqual(["'self'"]);
    expect(d.get('object-src')).toEqual(["'none'"]);
    expect(d.get('base-uri')).toEqual(["'none'"]);
    expect(d.get('form-action')).toEqual(["'none'"]);
    expect(d.get('frame-ancestors')).toEqual(["'none'"]);
    const { scripts, styles } = inlineHashes();
    expect(d.get('script-src')).toEqual(["'self'", ...scripts]);
    expect(d.get('style-src')).toEqual(["'self'", ...styles]);
    // frame-ancestors only works as a header; the <meta> leaves it out.
    expect(contentSecurityPolicy('production')).not.toContain('frame-ancestors');
  });

  it('the hashes are those of the template the page renders, which has exactly one script and one style block', () => {
    const t = HEALTH_TEMPLATE.replace(/\r\n/g, '\n');
    const blocks = (tag: string) => [...t.matchAll(new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`, 'g'))].map((m) => `'sha256-${createHash('sha256').update(m[1]!, 'utf8').digest('base64')}'`);
    expect(blocks('script')).toHaveLength(1);
    expect(blocks('style')).toHaveLength(1);
    expect(inlineHashes(HEALTH_TEMPLATE)).toEqual({ scripts: blocks('script'), styles: blocks('style') });
    // No inline style attributes in the template markup or event-handler attributes (both would be blocked).
    expect(t).not.toMatch(/<[a-z][^>]*\sstyle=/i);
    expect(t).not.toMatch(/<[a-z][^>]*\son[a-z]+=/i);
    expect(t).not.toContain('setAttribute(\'style\'');
  });

  it('development adds only what the Vite dev server needs', () => {
    const dev = directives(contentSecurityPolicy('development'));
    const prod = directives(contentSecurityPolicy('production'));
    expect(dev.get('style-src')).toEqual(["'self'", "'unsafe-inline'"]);
    expect(dev.get('connect-src')).toEqual(["'self'", 'ws:']);
    for (const k of ['default-src', 'script-src', 'img-src', 'object-src', 'base-uri', 'form-action']) expect(dev.get(k), k).toEqual(prod.get(k));
  });

  it('every response gets the baseline headers; hashed assets are cached for good', () => {
    const file = headersFile();
    for (const h of ['X-Content-Type-Options: nosniff', 'X-Frame-Options: DENY', 'Referrer-Policy: no-referrer', 'Cross-Origin-Opener-Policy: same-origin', 'Strict-Transport-Security: max-age=31536000']) expect(file).toContain(h);
    expect(file).not.toContain('includeSubDomains');
    expect(file).toMatch(/\/assets\/\*\n {2}Cache-Control: public, max-age=31536000, immutable/);
  });

  it('the source contains no inline style attributes or inline event handlers the policy would block', () => {
    const ui = ['src/ui/deployment.ts', 'src/ui/wizard.ts', 'src/ui/app-selection.ts', 'src/main.ts', 'src/manager/main.ts'].map(read).join('\n');
    expect(ui).not.toMatch(/\bstyle:\s*[`'"]/);
    expect(ui).not.toMatch(/setAttribute\(\s*'(style|on[a-z]+)'/);
  });
});

describe('import size limits (bounded validation work before the schema runs)', () => {
  it('a deployment profile larger than the limit is refused without parsing', () => {
    const r = importProfile(' '.repeat(MAX_PROFILE_BYTES + 1));
    expect(r.profile).toBeUndefined();
    expect(r.errors[0]!.message).toContain('larger than 16 MB');
  });

  it('a hardware inventory larger than the limit is refused without parsing', () => {
    const r = importHardwareInventory(' '.repeat(MAX_HARDWARE_INVENTORY_BYTES + 1));
    expect(r).toMatchObject({ ok: false });
    expect(r.errors[0]).toContain('larger than 16 MB');
  });
});
