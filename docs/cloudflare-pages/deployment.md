# Hosting on Cloudflare Pages (`deploy.88pockets.app`)

Branch `feature/cloudflare-pages-readiness`, from `main` `15fc2d5`. Nothing has been deployed, and no
DNS, mail or Cloudflare account setting was changed.

## Verdict

The whole Deployment Builder is a static site. Everything it does (Quick Deployment, the catalog,
Windows settings, `autounattend.xml`, the provisioning scripts and the ZIPs) runs in the visitor's
browser. Nothing is uploaded, and there is no server code, API or database. It works as a Cloudflare
Pages project without functions.

- **Linux build:** `npm ci && npm run build` was tested in a clean Linux container (Debian, Node 22,
  as the Pages build image): exit 0, the same output as on Windows.
- **Pages behaviour:** the build was tested with Cloudflare's local Pages emulator
  (`wrangler pages dev`, no account needed). Under it, the full browser suite passes with the
  production headers (288 tests; 6 skipped by design, as in every run), as do the new production
  tests (10).

## Cloudflare Pages settings

| Setting | Value |
|---|---|
| Framework preset | None |
| Build command | `npm run build` |
| Build output directory | `dist` |
| Root directory | (repository root) |
| Production branch | `main` |
| Node.js | 22, from `.node-version` (or set `NODE_VERSION=22`) |
| Environment variables | None required |

`npm run build` runs the typecheck, `vite build` and `scripts/build-manager.ts`. The last step packages
the Application Manager ZIP into `dist/downloads/`. It uses only Node's file system and the project's
own ZIP and SHA-256 code, with no PowerShell or Windows tools, so it works on Linux.

Optional variables:

| Variable | Effect |
|---|---|
| `WDB_SOURCEMAP=1` | Also writes source maps. Do **not** set it for the public site: they contain the full source of this private repository. |

### Deployment notes

- **Custom domain:** `deploy.88pockets.app` is added in the Pages project (Custom domains). Cloudflare
  then creates the DNS record for it. That is a DNS change, left for you to make.
- **Two pipelines:** the site is also set up as the Worker `windows-automation-pipeline`
  (`wrangler.jsonc`, `npm run deploy`, Workers Builds on pushes to `main`). If both stay connected to
  the repository, every push to `main` builds and publishes twice. Decide which one serves the site
  and disconnect the other. Both serve the same `dist/` with the same `_headers`.
- **Check the first build log for `wrangler.jsonc`:** Pages reads a Wrangler file only when it
  declares `pages_build_output_dir`, which this one does not. The first Pages build log should
  confirm that it is ignored. If Pages complains, use the Workers deployment or move the file
  aside; nothing in the build needs it.
- **Cloudflare features that inject scripts** must stay off for this hostname, or the CSP must be
  extended. They are Rocket Loader, automatic Web Analytics injection, Email Address Obfuscation,
  Zaraz and JavaScript challenges. The CSP blocks such scripts, and the page reports violations in
  the console. These are zone or hostname settings; none was changed.

## Security headers (`public/_headers`)

Generated from `scripts/security-headers.ts` by `npm run headers`. A unit test fails if the file,
the pages' `<meta>` policy and the health report template drift apart.

| Header | Value / reason |
|---|---|
| Content-Security-Policy | `default-src 'self'` (details below) |
| X-Content-Type-Options | `nosniff` |
| X-Frame-Options | `DENY` (and `frame-ancestors 'none'`): the builder cannot be framed |
| Referrer-Policy | `no-referrer` |
| Cross-Origin-Opener-Policy | `same-origin` |
| Cross-Origin-Resource-Policy | `same-origin` |
| Permissions-Policy | camera, microphone, geolocation, USB, serial, HID, Bluetooth, payment and sensors all off |
| Strict-Transport-Security | `max-age=31536000` for this host only (no `includeSubDomains`, so other 88pockets.app hosts and mail are unaffected) |
| Cache-Control (`/assets/*`) | `public, max-age=31536000, immutable` (content-hashed names); pages and downloads keep Pages' default revalidation |

### Content Security Policy

```
default-src 'self'; script-src 'self' 'sha256-…'; style-src 'self' 'sha256-…'; img-src 'self';
connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'
```

The policy is based on an audit of the frontend:

- **External resources:** none. There are no CDN scripts, web fonts, analytics or remote images. Logos
  are served from `/app-icons/`.
- **Inline code:** there is no inline script or event handler. The only inline code is the health
  report preview, an iframe with `srcdoc` that inherits the page's policy. Its one `<script>` and one
  `<style>` block are allowed by SHA-256 hash, computed from the template at build time.
- **Inline styles:** none, so `'unsafe-inline'` is not needed.
  - The package tree's indentation used a `style` attribute; it now uses `data-depth` and CSS.
  - The health template applied `style` attributes through `setAttribute`; it now uses
    `element.style.cssText`, which CSP does not restrict, with identical output.
- **No `eval` or `new Function`.** The only `innerHTML` is the built-in SVG icon set (static strings
  in the bundle).
- **Downloads** use `blob:` URLs on `<a download>`; CSP does not restrict them.
- **`connect-src 'self'`:** the builder makes no requests. The Application Manager page calls only
  its own origin, which is the local agent when it runs there.
- **`<meta>` copy:** the built pages also carry the policy as a `<meta>` tag (without
  `frame-ancestors`, which is header-only). It still applies when `dist/` is served by something
  else.
- **Development:** the source HTML holds a development policy with `'unsafe-inline'` styles and
  `ws:` added, because the Vite dev server injects styles and uses a WebSocket. Production builds
  replace it.

## What a hosted browser can and cannot do

The site generates files; it never runs them.

| Feature | Hosted site | Needs |
|---|---|---|
| Quick Deployment, Advanced settings, application catalog, profiles | Works | Browser |
| `autounattend.xml` and the deployment ZIP | Works (built in the browser, downloaded) | Browser |
| Installing Windows, running the provisioning | — | The target PC (Windows Setup runs the package) |
| USB Preparation Assistant | Download only; the page says a local Windows tool prepares the drive and the website never sees a disk | Windows, PowerShell, a USB drive |
| Hardware & driver tool, application inventory, settings backup | Download, and import of their JSON results | Windows, PowerShell on the source computer |
| Health report | Sample preview, labelled "Sample data … this website cannot know the target computer" | Runs on the installed computer |
| Application Manager | `/manager` browses the catalog. Without its local agent it says "a website cannot install software", offers the ZIP, and no action can start | Windows, PowerShell, WinGet (local agent) |

Browser storage holds only:

- view and theme preferences;
- saved application profiles (package lists);
- the Application Manager's per-session key, in sessionStorage, only when the local agent opened
  the page.

The deployment configuration, including the Wi-Fi password, local account password and product key,
is never stored in the browser.

## Distribution

### Deployment package

The deployment package ZIP is built in the browser:

- **Root:** `autounattend.xml` is the only file at the root. Everything else is under
  `WindowsDeployment/`: setup scripts, `scripts/<stage>/…`, config, profiles and docs.
- **Use:** extract the ZIP to the root of a Windows 11 installation USB, so `autounattend.xml` sits
  next to `setup.exe`.
- **Embedded copy:** the answer file also embeds the scripts the installation needs and extracts
  them under `C:\Windows\Setup\Scripts`. `WindowsDeployment/` is the readable copy, also used by
  `setup.cmd` on an already-installed Windows.
- **Checks:** every file listed in `deployment-manifest.json` is present with the stated SHA-256.
  This is verified in the production test from a real download, and in the unit tests.

### Application Manager ZIP

The Application Manager ZIP (`/downloads/windows-deployment-app-manager.zip`) should stay on the site:

- It is built from the same commit as the page that links to it, so the two always match. Its
  `files.json` lists the SHA-256 of every file.
- The GitHub repository is private, so release assets there would not be downloadable by customers.
- It contains only the manager's scripts, page and logos. No secrets, keys or personal paths were
  found in it.

Consider GitHub Releases only if the repository becomes public, or if the manager should be
versioned separately from the site.

## Security audit

| Area | Finding |
|---|---|
| Credentials, tokens, keys in the repository | None. Pattern scan of every tracked file; the only matches are test fixtures and the migration engine's secret-detection regex. |
| Personal paths in the build | None. No `C:\Users\…`, user names or e-mail addresses in `dist/` from Windows or Linux builds. |
| Source maps | **Fixed.** They contained the full source and were published by Pages, which ignores `.assetsignore` (a Workers-only file). They are now off unless `WDB_SOURCEMAP=1`. |
| Secrets in the generated ZIP | Only in `autounattend.xml`, where Windows Setup needs them: the account password in Windows' standard Base64 encoding (not encryption), and the Wi-Fi password in plain text. Both are warned about in Final Review. The profile copies in the ZIP have them removed. |
| Unsafe HTML | No `innerHTML` with data. The health template escapes the embedded JSON (tested with `</script>` payloads). |
| Script and XML generation | Values go through an escaping XML serializer and `psQuote`. Display names stay in JSON data, never in command lines. Unit tests cover quotes, `$()`, markup, hostile names and SSIDs. |
| External origins | None (CSP `default-src 'self'`; the production tests record any request to another origin and expect none). |
| Development files | `dist/` contains only the built pages, assets, logos, the manager ZIP, `404.html` and `_headers`, which Pages serves as a 404. |
| Public assets | `public/` holds the catalog logos, `_headers`, `404.html` and `.assetsignore` (used by the Workers deployment only). |
| Oversized imports | **Mitigated.** Deployment-profile and hardware-inventory imports now refuse files over 16 MB before parsing. Application profiles and migration inventories already had 5 MB limits. |

### npm advisories (`npm audit`, 2026-10-27)

| Package | Severity | Shipped to the browser? | Action |
|---|---|---|---|
| `zod` 3.25 | High (GHSA-mrhx-c7xc-m3w5: memory exhaustion validating oversized collections) | Yes | The fix is only in zod 4, a breaking upgrade of every schema. **Not upgraded.** Exposure is the visitor's own tab and only with a file they choose to import. Imports are now size-capped (above). Plan the zod 4 migration as its own change. |
| `vitest` 3, `@vitest/mocker`, `tinypool` | Critical / moderate | No (test runner) | Fixed only in vitest 5 (major). Affects the local test process with hostile test files only. Upgrade separately. |
| `wrangler` → `miniflare` → `undici` | High / moderate | No (local tooling; not used by the Pages build) | A non-breaking `npm audit fix` may resolve it. Left for a dependency-update change, so this branch does not move tooling versions. |

## Tests

| Command | What |
|---|---|
| `npm run typecheck`, `npm run lint`, `npm test` | Including `tests/unit/security-headers.test.ts`: `_headers` up to date, the policy strict, the template hashes right, no inline styles, import limits |
| `npm run test:e2e` | The regular browser suite (Vite preview of `dist/`) |
| `npm run test:e2e:production` | `tests/production/pages.spec.ts` against `dist/` in the Pages emulator, on desktop and Pixel 7 (details below) |
| `npm run preview:pages`, then `E2E_BASE_URL=http://127.0.0.1:8788 npm run test:e2e` | The whole regular suite under the production headers |

The production spec covers:

- every header, `.map` and `_headers` returning 404, and a real 404 page;
- Quick Deployment end to end with a downloaded ZIP checked file by file against its manifest;
- Advanced, the catalog, the health preview and both downloads with zero CSP violations and zero
  external requests;
- refresh, deep links and back/forward;
- the hosted Application Manager page.

Pages serves `manager.html` at `/manager` (a redirect). One existing test now accepts either URL.
