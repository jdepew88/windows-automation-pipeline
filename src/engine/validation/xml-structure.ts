import { COMPONENTS } from '../../data';
import { PASSES } from '../context';
import { NS, elements, getAttr, textContent, walk, type XElement } from '../xml/tree';
import type { Issue } from './issues';

const DISK_AUTOMATION = ['DiskConfiguration', 'WillWipeDisk', 'CreatePartitions', 'ModifyPartitions', 'ImageInstall', 'InstallTo', 'InstallToAvailablePartition'];
const KNOWN_COMPONENTS = new Set(COMPONENTS.map((c) => c.Id));

/**
 * Structural self-checks on a generated document: the subset of the unattend XSD that matters
 * (pass names, component identity attributes) plus project invariants (no disk automation,
 * unique component/pass/architecture, sequential Order values).
 *
 * Passing these checks does not mean Windows Setup will accept the file. Use WSIM and a VM.
 */
export function checkStructure(root: XElement): Issue[] {
  const issues: Issue[] = [];
  const err = (message: string) => issues.push({ severity: 'error', path: '', message: `Structure check failed: ${message}` });

  if (root.name !== 'unattend' || root.ns !== NS.unattend) err('root element must be <unattend> in the unattend namespace');

  const seenPasses = new Set<string>();
  const seenComponents = new Set<string>();
  for (const s of elements(root)) {
    if (s.ns === NS.ext) continue;
    if (s.name !== 'settings') {
      err(`unexpected root child <${s.name}>`);
      continue;
    }
    const pass = getAttr(s, 'pass') ?? '';
    if (!PASSES.includes(pass as never)) err(`invalid pass "${pass}"`);
    if (seenPasses.has(pass)) err(`duplicate settings pass "${pass}"`);
    seenPasses.add(pass);
    for (const c of elements(s)) {
      if (c.name !== 'component') {
        err(`<${c.name}> directly inside settings`);
        continue;
      }
      const name = getAttr(c, 'name') ?? '';
      const arch = getAttr(c, 'processorArchitecture') ?? '';
      if (!KNOWN_COMPONENTS.has(name)) err(`unknown component "${name}"`);
      if (!['x86', 'amd64', 'arm64'].includes(arch)) err(`component ${name} has invalid processorArchitecture "${arch}"`);
      if (!/^[0-9a-fA-F]{16}$/.test(getAttr(c, 'publicKeyToken') ?? '')) err(`component ${name} has invalid publicKeyToken`);
      if (getAttr(c, 'language') !== 'neutral') err(`component ${name} must have language="neutral"`);
      if (getAttr(c, 'versionScope') !== 'nonSxS') err(`component ${name} must have versionScope="nonSxS"`);
      const key = `${pass}|${name}|${arch}`;
      if (seenComponents.has(key)) err(`component ${name} appears twice in ${pass} for ${arch}`);
      seenComponents.add(key);
    }
  }

  for (const e of walk(root)) {
    if (e.ns === NS.unattend && DISK_AUTOMATION.includes(e.name)) err(`disk automation element <${e.name}> present`);
    if (['RunSynchronous', 'RunAsynchronous', 'FirstLogonCommands'].includes(e.name)) {
      const orders = elements(e).map((item) => {
        const o = elements(item).find((x) => x.name === 'Order');
        return o ? Number(textContent(o)) : NaN;
      });
      const sorted = [...orders].sort((a, b) => a - b);
      if (orders.some(Number.isNaN) || sorted.some((v, i) => v !== i + 1)) err(`<${e.name}> commands must have sequential <Order> values starting at 1 (custom XML must number its own commands)`);
    }
  }
  return issues;
}
