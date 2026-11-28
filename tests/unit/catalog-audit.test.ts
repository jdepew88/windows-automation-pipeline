import { describe, expect, it } from 'vitest';
import audit from '../../docs/unified-app-catalog/catalog-audit.json';
import profilesV1 from '../../src/data/apps/profiles-v1.json';
import profilesV2 from '../../src/data/apps/profiles.json';
import { CATALOG, CATALOG_EXCLUDED, VERIFY_FILE, VerifySchema, catalogEntryById, isManual, methodOf } from '../../src/engine/applications/catalog';

/**
 * Catalog audit of 2026-11-27 (docs/unified-app-catalog/catalog-audit.md): every automated entry is
 * backed by a WinGet manifest or a Microsoft Store listing that was read, installs unattended, and
 * says how its installation is verified. This file deliberately avoids the profile loader
 * (builtin.ts), so the catalog checks run even when a profile revision refers to a removed entry.
 */

type Rec = {
  id: string; packageIdentifier: string | null; source: string; status: string; decision: string; reason: string; problems: string[];
  silent?: boolean; manifest?: { packageName: string; publisher: string; latestVersion: string; productCodes: string[] } | null; store?: { resolves: boolean; publisher: string };
  newPackageIdentifier?: string;
};
const RECORDS = audit.entries as unknown as Rec[];
const record = (id: string) => RECORDS.find((r) => r.id === id);
const automated = CATALOG.filter((e) => !isManual(e));
const lower = (s: string) => s.toLowerCase();

describe('catalog audit 2026-11-27: identity', () => {
  it('ids and package identifiers are unique (case-insensitive), and alternate ids never collide with another entry', () => {
    const ids = CATALOG.map((e) => lower(e.id));
    expect(new Set(ids).size).toBe(ids.length);
    const pkgs = CATALOG.filter((e) => e.packageIdentifier).map((e) => lower(e.packageIdentifier!));
    expect(new Set(pkgs).size).toBe(pkgs.length);
    const alternates = CATALOG.flatMap((e) => (e.alternateIds ?? []).map((a) => [lower(a), e.id] as const));
    expect(new Set(alternates.map(([a]) => a)).size).toBe(alternates.length);
    for (const [a, owner] of alternates) expect(pkgs.includes(a), `${owner}: alternate id ${a} is another entry's package`).toBe(false);
  });

  it('every catalog entry of the starting point has an audit record with a decision and a reason', () => {
    expect(audit.counts.before.entries).toBe(289);
    expect(RECORDS).toHaveLength(289);
    for (const r of RECORDS) {
      expect(['keep', 'repair', 'manual', 'remove'], r.id).toContain(r.decision);
      expect(r.reason.length, r.id).toBeGreaterThan(10);
    }
    for (const e of CATALOG) expect(record(e.id), e.id).toBeDefined();
    expect(audit.counts.after.entries).toBe(CATALOG.length);
    expect(audit.counts.after.automated).toBe(automated.length);
    expect(audit.counts.after.excluded).toBe(CATALOG_EXCLUDED.length);
  });

  it('every WinGet entry has a verified audit record of its own identifier, read from the pinned winget-pkgs commit', () => {
    expect(audit.commit).toMatch(/^[0-9a-f]{40}$/);
    for (const e of CATALOG.filter((x) => x.source === 'winget')) {
      const r = record(e.id)!;
      expect(r.status, e.id).toBe('verified');
      expect(lower(r.packageIdentifier ?? ''), e.id).toBe(lower(e.packageIdentifier!));
      expect(r.manifest?.packageName, e.id).toBeTruthy();
      expect(r.manifest?.publisher, e.id).toBeTruthy();
      expect(r.silent, e.id).toBe(true);
      expect(e.validation, e.id).toMatchObject({ status: 'verified', checkedAt: '2026-11-27' });
      expect(e.validation.method, e.id).toContain(audit.commit.slice(0, 8));
    }
  });

  it('every Store entry resolves in the msstore source (winget show), with its publisher recorded', () => {
    for (const e of CATALOG.filter((x) => x.source === 'msstore')) {
      const r = record(e.id)!;
      expect(r.status, e.id).toBe('verified');
      expect(r.store?.resolves, e.id).toBe(true);
      expect(r.store?.publisher, e.id).toBeTruthy();
      expect(e.validation, e.id).toMatchObject({ status: 'verified', checkedAt: '2026-11-27' });
      expect(e.validation.method, e.id).toContain(`winget show --id ${e.packageIdentifier} --exact --source msstore`);
    }
  });
});

describe('catalog audit 2026-11-27: unattended installation and verification', () => {
  it('every automated entry is silent or known to possibly prompt; nothing automated is left unreviewed', () => {
    for (const e of automated) {
      expect(['silent', 'mayPrompt'], e.id).toContain(e.interaction);
      if (e.interaction === 'mayPrompt') expect(record(e.id)!.reason, e.id).toMatch(/mayPrompt/);
    }
    expect(automated.filter((e) => e.interaction === 'silent').length).toBeGreaterThan(250);
  });

  it('verify blocks parse with the schema; file paths use the known roots; user-scope entries verify per user', () => {
    for (const e of CATALOG) {
      if (!e.verify) continue;
      expect(() => VerifySchema.parse(e.verify), e.id).not.toThrow();
      for (const f of e.verify.files ?? []) expect(f, e.id).toMatch(VERIFY_FILE);
      for (const u of e.verify.uninstall ?? []) expect(u, `${e.id}: "${u}" carries a version`).not.toMatch(/\d+\.\d+\.\d+/);
    }
    for (const e of automated.filter((x) => x.scope === 'user')) expect(e.verify?.perUser, e.id).toBe(true);
    expect(CATALOG.filter((e) => e.verify).length).toBeGreaterThan(80);
  });

  it('the physical-deployment apps: Sysinternals from the Store, Sublime Text 4, ChatGPT, Claude, Node.js LTS and Acrobat Reader', () => {
    const si = catalogEntryById('sysinternals')!;
    expect(si).toMatchObject({ source: 'msstore', packageIdentifier: '9P7KNL5RWT25', publisher: 'Microsoft Corporation', interaction: 'silent', alternateIds: ['Microsoft.Sysinternals.Suite'] });
    expect(record('sysinternals')!.reason).toMatch(/unversioned/);
    expect(catalogEntryById('sublime-text')).toMatchObject({ packageIdentifier: 'SublimeHQ.SublimeText.4', interaction: 'silent', verify: { files: ['%ProgramFiles%\\Sublime Text\\sublime_text.exe'] } });
    expect(catalogEntryById('sublime-text')!.detectNames).toContain('Sublime Text');
    const gpt = catalogEntryById('chatgpt')!;
    expect(gpt).toMatchObject({ source: 'msstore', packageIdentifier: '9PLM9XGG6VKS', verify: { perUser: true } });
    expect(gpt.verify!.appx).toBeUndefined(); // the Store listing does not name the package: never guessed
    expect(catalogEntryById('claude-desktop')).toMatchObject({ scope: 'user', verify: { appx: ['Claude'], perUser: true } });
    expect(catalogEntryById('claude-desktop')!.verify!.after).toBeUndefined();
    const node = catalogEntryById('nodejs-lts')!;
    expect(node).toMatchObject({ packageIdentifier: 'OpenJS.NodeJS.LTS', installerType: 'wix', scope: 'machine', verify: { uninstall: ['Node.js'] } });
    expect(CATALOG.some((e) => e.packageIdentifier === 'OpenJS.NodeJS')).toBe(false); // LTS only; Current is a separate package
    expect(catalogEntryById('acrobat-reader')).toMatchObject({ detectNames: ['Adobe Acrobat (64-bit)'], scope: 'machine', interaction: 'silent', reboot: 'mayRequire' });
  });

  it('Visual C++: x64 and x86 are separate entries of every family, each with its own evidence; descriptions say why both exist', () => {
    for (const fam of ['', '-2013', '-2012', '-2010']) {
      const x64 = catalogEntryById(`vcredist${fam}-x64`)!;
      const x86 = catalogEntryById(`vcredist${fam}-x86`)!;
      expect(x64.architectures, fam).toEqual(['x64']);
      expect(x86.architectures, fam).toEqual(['x86']);
      for (const e of [x64, x86]) {
        expect(e.description, e.id).toMatch(/32-bit programs/);
        expect(e.description, e.id).toMatch(/64-bit/);
      }
    }
    expect(catalogEntryById('vcredist-x64')!.verify!.registry).toEqual([{ key: 'HKLM\\SOFTWARE\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\X64', name: 'Installed', equals: '1', view: '64' }]);
    expect(catalogEntryById('vcredist-x86')!.verify!.registry).toEqual([{ key: 'HKLM\\SOFTWARE\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\X86', name: 'Installed', equals: '1', view: '32' }]);
    for (const [id, arch] of [['vcredist-2013-x64', 'x64'], ['vcredist-2013-x86', 'x86'], ['vcredist-2012-x64', 'x64'], ['vcredist-2012-x86', 'x86']] as const) {
      const names = [...(catalogEntryById(id)!.verify?.uninstall ?? []), ...(catalogEntryById(id)!.detectNames ?? [])];
      expect(names.some((n) => n.includes(`(${arch})`)), id).toBe(true);
    }
    // 2010: the manifests name no "Apps & features" display name, only the MSI product code WinGet matches.
    for (const id of ['vcredist-2010-x64', 'vcredist-2010-x86']) expect(record(id)!.manifest!.productCodes.length, id).toBeGreaterThan(0);
  });
});

describe('catalog audit 2026-11-27: conversions, removals and profiles', () => {
  it('every removal is an exclusion with the former id, its identifier and a precise reason; it is no catalog entry', () => {
    const removed = RECORDS.filter((r) => r.decision === 'remove');
    expect(removed.map((r) => r.id).sort()).toEqual(['amazon-music', 'whiteboard']);
    for (const r of removed) {
      const x = CATALOG_EXCLUDED.find((e) => e.removed?.formerId === r.id);
      expect(x, r.id).toMatchObject({ packageIdentifier: r.packageIdentifier, removed: { date: '2026-11-27', formerId: r.id } });
      expect(x!.reason.length, r.id).toBeGreaterThan(40);
      expect(catalogEntryById(r.id), r.id).toBeUndefined();
    }
    // The exclusions that existed before the audit carry no removal record.
    expect(CATALOG_EXCLUDED.filter((x) => x.removed)).toHaveLength(2);
  });

  it('conversions: Battle.net is a manual follow-up (its setup has no unattended mode); AIMP moved to the Store edition', () => {
    const bn = catalogEntryById('battlenet')!;
    expect(isManual(bn)).toBe(true);
    expect(bn).toMatchObject({ packageIdentifier: null, source: 'none', interaction: 'required', alternateIds: ['Blizzard.BattleNet'], manual: { url: 'https://download.battle.net/en-us/desktop' } });
    expect(catalogEntryById('aimp')).toMatchObject({ source: 'msstore', packageIdentifier: '9PCLLLH15SMT', alternateIds: ['AIMP.AIMP'] });
    expect(catalogEntryById('filezilla')!.manual!.reason).toMatch(/rechecked 2026-11-27/);
    expect(catalogEntryById('freefilesync')!.manual!.reason).toMatch(/rechecked 2026-11-27/);
  });

  it('manual entries carry a reason, instructions and an official https download', () => {
    for (const e of CATALOG.filter(isManual)) {
      expect(methodOf(e), e.id).toBe('manual');
      expect(e.manual!.reason.length, e.id).toBeGreaterThan(20);
      expect(e.manual!.instructions.length, e.id).toBeGreaterThan(20);
      expect(e.manual!.url, e.id).toMatch(/^https:\/\//);
      expect(e.validation.status, e.id).toBe('manual');
    }
  });

  it('revision 2 profiles refer only to catalog entries, automated except the manual follow-ups chosen deliberately', () => {
    const allowedManual = new Set(['battlenet', 'rustdesk', 'filezilla', 'freefilesync', 'spybot', 'launchbox', 'vmware-workstation', 'dotnet-framework-35']);
    for (const p of profilesV2.profiles) {
      for (const id of [...p.defaults, ...p.optional]) {
        const e = catalogEntryById(id);
        expect(e, `${p.id}: ${id}`).toBeDefined();
        if (isManual(e!)) expect(allowedManual.has(id), `${p.id}: ${id} is manual`).toBe(true);
      }
    }
  });

  it('revision 1 (frozen) refers to catalog entries or to removal records, never to an unknown id', () => {
    const v1 = profilesV1.profiles.flatMap((p) => [...p.defaults, ...p.optional]);
    const removedIds = new Set(CATALOG_EXCLUDED.flatMap((x) => (x.removed ? [x.removed.formerId] : [])));
    for (const id of v1) expect(!!catalogEntryById(id) || removedIds.has(id), id).toBe(true);
    expect(v1.filter((id) => removedIds.has(id))).toEqual(['whiteboard']);
  });
});
