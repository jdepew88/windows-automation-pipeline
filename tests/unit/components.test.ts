import { describe, expect, it } from 'vitest';
import type { ComponentEntry } from '../../src/engine/schema/profile';
import { generate } from '../../src/engine/pipeline';
import { NS, getAttr, textContent } from '../../src/engine/xml/tree';
import { component, find, generateOk, profile } from './helpers';

const entry = (component: string, pass: ComponentEntry['pass'], markup: string, enabled = true): ComponentEntry => ({ id: `${component}-${pass}`, enabled, component, pass, markup });

function errors(markupEntries: ComponentEntry[]): string[] {
  const r = generate(profile((p) => p.advancedXml.components.push(...markupEntries)));
  expect(r.ok).toBe(false);
  return r.issues.filter((i) => i.severity === 'error').map((i) => `${i.path}: ${i.message}`);
}

describe('additional XML components', () => {
  it('merges a valid component into the right pass, per architecture, preserving namespaces', () => {
    const markup = `<Interfaces><Interface wcm:action="add"><Identifier>Ethernet</Identifier><Ipv4Settings><DhcpEnabled>true</DhcpEnabled></Ipv4Settings></Interface></Interfaces>`;
    const r = generateOk(profile((p) => {
      p.setup.processorArchitectures = ['amd64', 'arm64'];
      p.advancedXml.components.push(entry('Microsoft-Windows-TCPIP', 'specialize', markup));
    }));
    for (const arch of ['amd64', 'arm64']) {
      const c = component(r.root, 'specialize', 'Microsoft-Windows-TCPIP', arch)!;
      expect(c).toBeDefined();
      const iface = find(c, 'Interfaces/Interface')!;
      expect(getAttr(iface, 'action', NS.wcm)).toBe('add');
      expect(textContent(find(iface, 'Identifier')!)).toBe('Ethernet');
    }
    expect(r.xml).toContain('<Interface wcm:action="add">');
    expect(r.xml).toMatchSnapshot();
  });

  it('escapes text in user markup safely (no string concatenation)', () => {
    const r = generateOk(profile((p) => p.advancedXml.components.push(entry('Microsoft-Windows-TCPIP', 'specialize', '<X>a &amp; b &lt;c&gt; "d"</X>'))));
    expect(r.xml).toContain('<X>a &amp; b &lt;c&gt; "d"</X>');
  });

  it('skips disabled and blank entries', () => {
    const r = generateOk(profile((p) => p.advancedXml.components.push(entry('Microsoft-Windows-TCPIP', 'specialize', '<X/>', false), entry('Microsoft-Windows-DNS-Client', 'specialize', '  '))));
    expect(component(r.root, 'specialize', 'Microsoft-Windows-TCPIP')).toBeUndefined();
    expect(r.issues).toContainEqual(expect.objectContaining({ severity: 'warning', path: 'advancedXml.components.1' }));
  });

  it('rejects malformed markup', () => {
    expect(errors([entry('Microsoft-Windows-TCPIP', 'specialize', '<A><B></A>')]).join()).toMatch(/not well-formed/);
    expect(errors([entry('Microsoft-Windows-TCPIP', 'specialize', 'just text')]).join()).toMatch(/elements only/);
    expect(errors([entry('Microsoft-Windows-TCPIP', 'specialize', '</root><root>')]).join()).toMatch(/well-formed|elements/);
    expect(errors([entry('Microsoft-Windows-TCPIP', 'specialize', '<!DOCTYPE x><x/>')]).join()).toMatch(/DOCTYPE|well-formed/);
  });

  it('rejects unknown components, wrong case and invalid passes', () => {
    expect(errors([entry('Microsoft-Windows-Imaginary', 'specialize', '<X/>')]).join()).toMatch(/not a known unattend component/);
    expect(errors([entry('microsoft-windows-tcpip', 'specialize', '<X/>')]).join()).toMatch(/case-sensitive/);
    expect(errors([entry('Microsoft-Windows-TCPIP', 'oobeSystem', '<X/>')]).join()).toMatch(/not valid in the oobeSystem pass/);
  });

  it('rejects duplicate component/pass entries', () => {
    expect(errors([entry('Microsoft-Windows-TCPIP', 'specialize', '<X/>'), entry('Microsoft-Windows-TCPIP', 'specialize', '<Y/>')]).join()).toMatch(/more than once/);
  });

  it('rejects settings/component wrappers and foreign namespaces', () => {
    expect(errors([entry('Microsoft-Windows-TCPIP', 'specialize', '<component name="x"/>')]).join()).toMatch(/settings> or <component/);
    expect(errors([entry('Microsoft-Windows-TCPIP', 'specialize', '<X xmlns="urn:other"/>')]).join()).toMatch(/unattend namespace/);
  });

  it('rejects any disk automation', () => {
    expect(errors([entry('Microsoft-Windows-Shell-Setup', 'auditSystem', '<DiskConfiguration><WillWipeDisk>true</WillWipeDisk></DiskConfiguration>')]).join()).toMatch(/never automates disk/);
  });

  it('rejects insertions that conflict with generator-owned components', () => {
    const errs = errors([entry('Microsoft-Windows-Shell-Setup', 'oobeSystem', '<RegisteredOwner>X</RegisteredOwner>')]);
    expect(errs.join()).toMatch(/already written by the generator/);
    expect(errors([entry('Microsoft-Windows-Setup', 'windowsPE', '<EnableNetwork>true</EnableNetwork>')]).join()).toMatch(/already written/);
  });

  it('requires custom command lists to carry their own Order', () => {
    const r = generate(profile((p) => p.advancedXml.components.push(entry('Microsoft-Windows-Deployment', 'auditUser', '<RunSynchronous><RunSynchronousCommand wcm:action="add"><Path>cmd.exe</Path></RunSynchronousCommand></RunSynchronous>'))));
    expect(r.ok).toBe(false);
    expect(r.issues.map((i) => i.message).join()).toMatch(/Order/);
    const ok = generate(profile((p) => p.advancedXml.components.push(entry('Microsoft-Windows-Deployment', 'auditUser', '<RunSynchronous><RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>cmd.exe</Path></RunSynchronousCommand></RunSynchronous>'))));
    expect(ok.ok).toBe(true);
  });
});
