import { readFileSync, writeFileSync } from 'node:fs';
import { contentSecurityPolicy, headersFile } from './security-headers';

/**
 * Writes public/_headers and the development Content-Security-Policy <meta> of the source pages
 * from scripts/security-headers.ts. Run it after changing the policy or the health report template
 * (its inline script and style are allowed by hash); tests/unit/security-headers.test.ts fails until then.
 */
writeFileSync(new URL('../public/_headers', import.meta.url), headersFile());
for (const page of ['index.html', 'manager.html']) {
  const file = new URL(`../${page}`, import.meta.url);
  const html = readFileSync(file, 'utf8');
  const next = html.replace(/(<meta http-equiv="Content-Security-Policy" content=")[^"]*(")/, (_m, a: string, b: string) => `${a}${contentSecurityPolicy('development')}${b}`);
  if (next === html && !html.includes(contentSecurityPolicy('development'))) throw new Error(`${page}: Content-Security-Policy <meta> not found`);
  writeFileSync(file, next);
}
console.log('Wrote public/_headers, index.html and manager.html (Content-Security-Policy)');
