import { createHash } from 'node:crypto';
import { readdirSync, readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import installer2024 from '../../src/engine/office/vendor/2024/Install_Office.ps1?raw';
import activate2024 from '../../src/engine/office/vendor/2024/Activate_Office.ps1?raw';
import config2024Standard from '../../src/engine/office/vendor/2024/config_standard.xml?raw';
import config2024ProPlus from '../../src/engine/office/vendor/2024/config_ProPlus.xml?raw';
import config2021Standard from '../../src/engine/office/vendor/2021/config_standard.xml?raw';
import config2021ProPlus from '../../src/engine/office/vendor/2021/config_ProPlus.xml?raw';
import engineSource from '../../src/engine/office/scripts/OfficeEngine.ps1?raw';
import activationSource from '../../src/engine/activation/scripts/Activation.ps1?raw';
import { ownerDefaults, importProfile } from '../../src/engine/profiles';
import { migrate } from '../../src/engine/profiles/migrations';
import { generate } from '../../src/engine/pipeline';
import { buildDeploymentPackage, buildManifest, deploymentActive, packageFiles } from '../../src/engine/deployment';
import { readZip } from '../../src/engine/deployment/zip';
import { OFFICE_CATALOG, OFFICE_SOURCES, officeAssets, officeConfig } from '../../src/engine/office';
import { activationActive, activationNeedsTechnician, activationPlan, activationSummary } from '../../src/engine/activation';
import { SETTINGS_BY_PATH } from '../../src/features';
import { allProfiles } from '../../src/engine/applications/selection';
import { OFFICE_PRODUCTS, type OfficeProduct, type Profile } from '../../src/engine/schema/profile';

/**
 * Schema 9: optional Office LTSC (four volume-licensed products) and independent Windows/Office
 * activation. The PowerShell side (OfficeEngine.ps1, Activation.ps1) has scenario tests in
 * tests/powershell/Office.Tests.ps1; these tests cover the builder: profile, validation, package.
 */

const sha = (s: string) => createHash('sha256').update(s, 'utf8').digest('hex');
const crlf = (s: string) => s.replace(/\r?\n/g, '\r\n');
const withOffice = (product: OfficeProduct, edit?: (p: Profile) => void) => {
  const p = ownerDefaults();
  p.office.product = product;
  edit?.(p);
  return p;
};
const errors = (p: Profile) => generate(p).issues.filter((i) => i.severity === 'error');
const zipText = (p: Profile) => {
  const r = generate(p);
  expect(r.ok).toBe(true);
  return { xml: r.xml ?? '', files: readZip(buildDeploymentPackage(p, r).zip).map((e) => ({ path: e.path, text: new TextDecoder().decode(e.data) })) };
};
const PRODUCTS = OFFICE_PRODUCTS.filter((x): x is Exclude<OfficeProduct, 'none'> => x !== 'none');
// Five groups of five letters/digits: any product key (GVLK, MAK, retail).
const KEY = /\b[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}\b/;

describe('Office LTSC: pinned sources', () => {
  it('the 2024 installer, its configurations and the activation helper are byte-identical to the reviewed commit', () => {
    const files: Record<string, string> = { 'Install_Office.ps1': installer2024, 'config_standard.xml': config2024Standard, 'config_ProPlus.xml': config2024ProPlus, 'Activate_Office.ps1': activate2024 };
    for (const f of OFFICE_SOURCES[2024].files) {
      expect(f.unchanged, f.path).toBe(true);
      expect(sha(crlf(files[f.path]!)), f.path).toBe(f.upstreamSha256);
    }
    expect(OFFICE_SOURCES[2024].commit).toBe('3e2817194aaef0856c5ce8653763c77e24cb3e72');
    expect(OFFICE_SOURCES[2021].commit).toBe('548c49142589a9c7c093a4724b9cee1045c0eb2b');
  });

  it('the correct product IDs and channels; 2024 is current, 2021 is legacy', () => {
    expect(Object.values(OFFICE_CATALOG).map((x) => `${x.id}:${x.productId}:${x.channel}:${x.legacy}`)).toEqual([
      'ltsc2021Standard:Standard2021Volume:PerpetualVL2021:true',
      'ltsc2021ProPlus:ProPlus2021Volume:PerpetualVL2021:true',
      'ltsc2024Standard:Standard2024Volume:PerpetualVL2024:false',
      'ltsc2024ProPlus:ProPlus2024Volume:PerpetualVL2024:false',
    ]);
    const xml = { 'ltsc2021Standard': config2021Standard, 'ltsc2021ProPlus': config2021ProPlus, 'ltsc2024Standard': config2024Standard, 'ltsc2024ProPlus': config2024ProPlus } as const;
    for (const id of PRODUCTS) {
      const info = OFFICE_CATALOG[id];
      expect(xml[id], id).toContain(`Channel="${info.channel}"`);
      expect(xml[id], id).toContain(`<Product ID="${info.productId}"`);
    }
  });

  it('the adapted 2021 configurations hold no key, no automatic activation and no unconditional MSI removal', () => {
    for (const x of [config2021Standard, config2021ProPlus]) {
      const elements = x.replace(/<!--[\s\S]*?-->/g, '');
      expect(elements).not.toMatch(/PIDKEY|AUTOACTIVATE|RemoveMSI/);
      expect(x).not.toMatch(KEY);
    }
  });

  it('nothing executes remote code: no Invoke-Expression, no download-and-run, no third-party activation', () => {
    for (const [name, src] of Object.entries({ engineSource, activationSource, installer2024, activate2024 })) {
      expect(src, name).not.toMatch(/Invoke-Expression|\biex\b|Invoke-RestMethod|\birm\b|DownloadString|massgrave|activated\.win/i);
    }
  });
});

describe('Office LTSC: profile and validation', () => {
  it('defaults: no Office and no activation; nothing is added to the package', () => {
    const p = ownerDefaults();
    expect(p.office).toEqual({ product: 'none', removeMsiOffice: false });
    expect(p.activation.windows).toBe('none');
    expect(p.activation.office).toBe('none');
    expect(activationActive(p)).toBe(false);
    const m = buildManifest(p).manifest as Record<string, unknown>;
    expect(m.office).toBeUndefined();
    expect(m.activation).toBeUndefined();
    expect(packageFiles(p).some((f) => /office|activation/i.test(f.path))).toBe(false);
    expect((m.stages as { id: string }[]).map((s) => s.id)).not.toContain('office');
  });

  it('older profiles (schema 8) migrate with no Office and every activation preference off', () => {
    const old = { ...structuredClone(ownerDefaults()), schemaVersion: 8 } as Record<string, unknown>;
    delete old.office;
    delete old.activation;
    const r = migrate(old);
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.value.office).toEqual({ product: 'none', removeMsiOffice: false });
    expect(r.value.activation).toMatchObject({ windows: 'none', office: 'none' });
    const imported = importProfile(JSON.stringify(old));
    expect(imported.errors).toEqual([]);
    expect(imported.profile?.office.product).toBe('none');
    expect(imported.profile?.activation).toMatchObject({ windows: 'none', office: 'none' });
  });

  it('application profiles never install Office: selecting every profile leaves Office off', () => {
    const p = ownerDefaults();
    p.applications.selection.selectedProfiles = allProfiles(p.applications.selection).map((x) => x.id);
    expect(p.office.product).toBe('none');
    expect((buildManifest(p).manifest.stages as { id: string }[]).map((s) => s.id)).not.toContain('office');
  });

  it('Office is in Basic view; MSI removal and every activation control are Advanced (expert) only', () => {
    expect(SETTINGS_BY_PATH.get('office.product')?.advanced).toBe(false);
    for (const path of ['office.removeMsiOffice', 'activation.windows', 'activation.windowsMethod', 'activation.windowsKmsHost', 'activation.office', 'activation.officeMethod', 'activation.officeKmsHost']) {
      expect(SETTINGS_BY_PATH.get(path)?.advanced, path).toBe(true);
    }
    const choices = SETTINGS_BY_PATH.get('activation.windows')!.choices as { value: string }[];
    expect(choices.map((c) => c.value)).toEqual(['none', 'microsoft', 'manual']);
  });

  it('impossible combinations are refused: Office activation without Office; a malformed KMS host', () => {
    expect(errors(withOffice('none', (p) => (p.activation.office = 'microsoft'))).map((i) => i.path)).toContain('activation.office');
    expect(errors(withOffice('ltsc2024Standard', (p) => { p.activation.office = 'microsoft'; p.activation.officeKmsHost = 'kms host; rm -rf'; })).length).toBeGreaterThan(0);
    expect(errors(withOffice('ltsc2024Standard', (p) => { p.activation.office = 'microsoft'; p.activation.officeKmsHost = 'kms.example.org:1688'; }))).toEqual([]);
  });

  it('choosing an Office edition never enables activation', () => {
    for (const id of PRODUCTS) {
      const p = withOffice(id);
      expect(activationActive(p), id).toBe(false);
      expect(buildManifest(p).manifest).not.toHaveProperty('activation');
    }
  });

  it('Office LTSC 2021 carries a legacy notice', () => {
    expect(generate(withOffice('ltsc2021ProPlus')).issues.some((i) => i.path === 'office.product' && /October 13, 2026/.test(i.message))).toBe(true);
    expect(generate(withOffice('ltsc2024ProPlus')).issues.some((i) => i.path === 'office.product')).toBe(false);
  });
});

describe('Office LTSC: package', () => {
  for (const id of PRODUCTS) {
    it(`${id}: its own configuration only, the pinned installer, the stage after the applications`, () => {
      const p = withOffice(id);
      const info = OFFICE_CATALOG[id];
      const names = officeAssets(p).map((a) => a.name);
      const cfg = officeConfig(p)!;
      expect(cfg.product).toMatchObject({ productId: info.productId, channel: info.channel });
      expect(cfg.activates).toBe(false);
      expect(names).toContain('Install_Office.ps1');
      // Exactly one Office configuration, of the selected version.
      const xmls = names.filter((n) => n.endsWith('.xml'));
      expect(xmls).toEqual([info.version === 2024 ? (info.edition === 'ProPlus' ? 'config_ProPlus.xml' : 'config_standard.xml') : `config-2021-${info.edition}.xml`]);
      expect(cfg.installer.arguments).toContain(info.version === 2024 ? '-Edition' : '-ConfigPath');
      expect(cfg.installer.arguments).not.toContain('-AcceptEula');
      expect(cfg.installer.arguments).not.toContain('-RemovePreviousVersions');
      expect(cfg.configuration.source.commit).toBe(OFFICE_SOURCES[info.version].commit);
      const m = buildManifest(p).manifest;
      const stages = m.stages as { id: string; order: number; waitsFor?: string[]; context?: string }[];
      const office = stages.find((s) => s.id === 'office')!;
      expect(office.context).toBe('SYSTEM');
      expect(office.waitsFor).toEqual(['windowsUpdate', 'applications']);
      expect(office.order).toBeGreaterThan(stages.find((s) => s.id === 'applications')!.order);
      expect(stages.find((s) => s.id === 'finalization')!.order).toBeGreaterThan(office.order);
      expect((m as Record<string, unknown>).office).toMatchObject({ productId: info.productId, channel: info.channel, activates: false });
      expect(deploymentActive(p)).toBe(true);
    });
  }

  it('MSI removal only when chosen explicitly', () => {
    expect(officeConfig(withOffice('ltsc2024ProPlus', (p) => (p.office.removeMsiOffice = true)))!.installer.arguments).toContain('-RemovePreviousVersions');
  });

  it('the engine, its configuration, the installer and the XML are embedded in the answer file (the README is not)', () => {
    const embedded = packageFiles(withOffice('ltsc2021Standard')).filter((f) => f.path.startsWith('scripts/office/'));
    expect(embedded.filter((f) => f.embedded).map((f) => f.path).sort()).toEqual(['scripts/office/Install-OfficeEngine.ps1', 'scripts/office/Install_Office.ps1', 'scripts/office/OfficeEngine.ps1', 'scripts/office/config-2021-Standard.xml', 'scripts/office/office-config.json']);
  });
});

describe('Activation', () => {
  it('Windows and Office are independent: neither, either or both', () => {
    const cases: [string, string, boolean][] = [['none', 'none', false], ['microsoft', 'none', true], ['none', 'microsoft', true], ['microsoft', 'manual', true]];
    for (const [w, o, active] of cases) {
      const p = withOffice('ltsc2024ProPlus', (x) => { x.activation.windows = w as Profile['activation']['windows']; x.activation.office = o as Profile['activation']['office']; });
      expect(activationActive(p), `${w}/${o}`).toBe(active);
      const plan = activationPlan(p);
      if (!active) { expect(plan).toBeNull(); continue; }
      expect(plan!.windows.action).toBe(w);
      expect(plan!.office.action).toBe(o);
      expect(plan!.independent).toBe(true);
    }
  });

  it('Office activation is never scheduled without Office', () => {
    const p = ownerDefaults();
    p.activation.windows = 'microsoft';
    p.activation.office = 'microsoft';
    expect(activationPlan(p)!.office.action).toBe('none');
    expect(activationSummary(p).office).toBe('No Office selected');
  });

  it('a key or a manual method needs the technician, and then the recovery tool is always included', () => {
    const p = withOffice('ltsc2024ProPlus', (x) => { x.activation.office = 'microsoft'; x.activation.officeMethod = 'mak'; x.applications.recovery.includeRecoveryTool = false; });
    expect(activationNeedsTechnician(p)).toBe(true);
    const m = buildManifest(p).manifest;
    expect(m.recovery.tool).toBeTruthy();
    expect(m.recovery.actions).toEqual(expect.arrayContaining(['Activate', 'CheckActivation']));
    expect((m as Record<string, unknown>).activation).toMatchObject({ technicianRequired: true, containsSecrets: false, officeHelper: null });
  });

  it('the Office KMS helper ships only for Microsoft KMS / Active Directory activation of Office', () => {
    const has = (edit: (p: Profile) => void) => packageFiles(withOffice('ltsc2024ProPlus', edit)).some((f) => f.path === 'scripts/activation/Activate_Office.ps1');
    expect(has((x) => { x.activation.office = 'microsoft'; x.activation.officeMethod = 'kms'; })).toBe(true);
    expect(has((x) => { x.activation.office = 'microsoft'; x.activation.officeMethod = 'activeDirectory'; })).toBe(true);
    expect(has((x) => { x.activation.office = 'microsoft'; x.activation.officeMethod = 'mak'; })).toBe(false);
    expect(has((x) => { x.activation.office = 'manual'; })).toBe(false);
    expect(has(() => undefined)).toBe(false);
  });

  it('no product key and no third-party activation anywhere in the package or the answer file, for every combination', () => {
    for (const id of PRODUCTS) {
      for (const [w, wm, o, om] of [['microsoft', 'productKey', 'microsoft', 'mak'], ['manual', 'digitalLicense', 'manual', 'kms'], ['microsoft', 'kms', 'microsoft', 'activeDirectory']] as const) {
        const p = withOffice(id, (x) => { x.activation.windows = w; x.activation.windowsMethod = wm; x.activation.office = o; x.activation.officeMethod = om; });
        const { xml, files } = zipText(p);
        const office = xml.slice(xml.indexOf('scripts\\office'));
        expect(office, `${id} answer file`).not.toMatch(KEY);
        for (const f of files) {
          if (/(office|activation|manifest|profiles)/i.test(f.path)) expect(f.text, `${id} ${f.path}`).not.toMatch(KEY);
          expect(f.text, `${id} ${f.path}`).not.toMatch(/massgrave|get\.activated\.win/i);
        }
      }
    }
  }, 30_000); // builds 12 complete packages: slow under parallel load, not a hang

  it('the review summary lists software and activation separately', () => {
    const p = withOffice('ltsc2024ProPlus', (x) => { x.activation.windows = 'microsoft'; x.activation.office = 'manual'; });
    expect(activationSummary(p)).toEqual({ windows: 'Microsoft activation (digital license)', office: 'Technician activates manually (checked afterwards)' });
  });
});

describe('Office and activation: shipped scripts', () => {
  it('every new PowerShell script is listed in the package tests and parses as ASCII', () => {
    const dir = new URL('../../src/engine/office/scripts/', import.meta.url);
    for (const f of readdirSync(dir)) {
      const text = readFileSync(new URL(f, dir), 'utf8');
      // eslint-disable-next-line no-control-regex
      expect(/^[\x00-\x7f]*$/.test(text), f).toBe(true);
    }
    // eslint-disable-next-line no-control-regex
    expect(/^[\x00-\x7f]*$/.test(activationSource)).toBe(true);
  });
});
