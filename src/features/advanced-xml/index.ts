import type { GenContext } from '../../engine/context';
import { newComponent } from '../../engine/context';
import type { SettingDef } from '../../engine/settings/types';
import type { Profile } from '../../engine/schema/profile';
import type { Issue } from '../../engine/validation/issues';
import { COMPONENTS } from '../../data';
import { parseXml } from '../../engine/xml/parse';
import { NS, append, walk, type XElement } from '../../engine/xml/tree';

/** Elements that would automate disk selection or wiping. These are never accepted. */
export const FORBIDDEN_DISK_ELEMENTS = [
  'DiskConfiguration',
  'Disk',
  'CreatePartitions',
  'CreatePartition',
  'ModifyPartitions',
  'ModifyPartition',
  'WillWipeDisk',
  'ImageInstall',
  'InstallTo',
  'InstallToAvailablePartition',
];

export const settings: SettingDef[] = [
  {
    path: 'advancedXml.components',
    section: 'advancedXml',
    label: 'XML markup for more components',
    control: 'custom',
    description:
      'Adds settings for unattend components that this generator does not model. Enter only the inner markup of a <component>. The markup is parsed, and only known component names and valid passes are accepted. It may not overlap components the generator already writes.',
    applicability: 'Per component; see Microsoft unattend reference',
    risk: 'Settings are passed through without per-setting validation. Validate with Windows System Image Manager.',
    stages: ['windowsPE', 'specialize', 'oobeSystem'],
    mapping: 'settings[@pass] › component[@name] (one per selected architecture) with the parsed markup as children',
    advanced: true,
    verification: 'upstream-tested',
  },
];

export interface ParsedComponent {
  index: number;
  component: string;
  pass: string;
  children: XElement[];
}

/** Parses and checks each enabled entry. Returns usable entries; problems go to `issues`. */
export function parseComponents(p: Profile, issues: Issue[]): ParsedComponent[] {
  const out: ParsedComponent[] = [];
  const seen = new Set<string>();
  p.advancedXml.components.forEach((c, index) => {
    const path = `advancedXml.components.${index}`;
    const err = (message: string) => issues.push({ severity: 'error', path, message });
    if (!c.enabled) return;
    if (c.markup.trim() === '') {
      issues.push({ severity: 'warning', path, message: 'Empty component markup is skipped.' });
      return;
    }
    const info = COMPONENTS.find((k) => k.Id === c.component);
    if (!info) {
      const ci = COMPONENTS.find((k) => k.Id.toLowerCase() === c.component.toLowerCase());
      err(ci ? `Component names are case-sensitive: use "${ci.Id}".` : `"${c.component}" is not a known unattend component.`);
      return;
    }
    if (!info.Passes.includes(c.pass)) {
      err(`${c.component} is not valid in the ${c.pass} pass (valid: ${info.Passes.join(', ')}).`);
      return;
    }
    const key = `${c.pass}|${c.component}`;
    if (seen.has(key)) {
      err(`${c.component} in ${c.pass} is defined more than once. Merge the markup into one entry.`);
      return;
    }
    seen.add(key);
    const r = parseXml(`<root xmlns="${NS.unattend}" xmlns:wcm="${NS.wcm}">${c.markup}</root>`);
    if (!r.root) {
      err(`Markup is not well-formed XML: ${r.errors[0]}`);
      return;
    }
    const kids = r.root.children;
    if (kids.some((k) => k.kind === 'text' && k.value.trim() !== '')) {
      err('Markup must consist of elements only (text found outside elements).');
      return;
    }
    const elementsOnly = kids.filter((k): k is XElement => k.kind === 'element');
    if (elementsOnly.length === 0) {
      err('Markup contains no elements.');
      return;
    }
    for (const top of elementsOnly) {
      for (const e of walk(top)) {
        if (e.ns !== NS.unattend) {
          err(`Element <${e.name}> must be in the unattend namespace (${NS.unattend}), not "${e.ns}".`);
          return;
        }
        if (e.name === 'settings' || e.name === 'component') {
          err('Do not include <settings> or <component> elements; enter only the component\'s inner markup.');
          return;
        }
        if (FORBIDDEN_DISK_ELEMENTS.includes(e.name)) {
          err(`<${e.name}> is not allowed. This project never automates disk selection, partitioning or wiping.`);
          return;
        }
      }
    }
    out.push({ index, component: c.component, pass: c.pass, children: elementsOnly });
  });
  return out;
}

export function validate(p: Profile, issues: Issue[]): void {
  parseComponents(p, issues);
}

/** Inserts parsed components; rejects overlap with generator-owned components. */
export function modify(ctx: GenContext): Set<XElement> {
  const inserted = new Set<XElement>();
  const scratch: Issue[] = [];
  for (const c of parseComponents(ctx.profile, scratch)) {
    const pass = c.pass as Parameters<GenContext['settings']>[0];
    if (ctx.findComponent(pass, c.component)) {
      ctx.error(
        `advancedXml.components.${c.index}`,
        `${c.component} (${c.pass}) is already written by the generator. Overlapping insertions are rejected; change the corresponding setting instead.`,
      );
      continue;
    }
    const comp = newComponent(c.component);
    comp.children = c.children;
    append(ctx.settings(pass), comp);
    inserted.add(comp);
  }
  return inserted;
}
