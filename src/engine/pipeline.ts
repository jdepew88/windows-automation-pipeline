import { GenContext } from './context';
import { resolveIdentity } from './naming';
import type { Profile } from './schema/profile';
import { CommandError } from './stages/commands';
import { checkStructure } from './validation/xml-structure';
import { hasErrors, type Issue } from './validation/issues';
import { validateProfile } from './validation/validate';
import { XmlCharacterError, serialize } from './xml/serialize';
import { NS, clone, elements, getAttr, setAttr, walk, type XElement } from './xml/tree';
import * as f from '../features';
import { updateEngineAssets, type DeploymentAsset } from './windows-update';

export interface GenerateResult {
  ok: boolean;
  issues: Issue[];
  /** Serialized answer file; present only when there are no errors. */
  xml?: string;
  fileName: string;
  /** Files embedded for extraction during specialize (for review/debugging). */
  embeddedFiles: { path: string; content: string }[];
  /** Separately downloadable deployment files (Windows Update engine); present only when ok. */
  assets: DeploymentAsset[];
}

/** Removes leaf elements without children or attributes (upstream EmptyElementsModifier). */
function pruneEmpty(root: XElement): void {
  let changed = true;
  while (changed) {
    changed = false;
    for (const e of walk(root)) {
      const before = e.children.length;
      e.children = e.children.filter((c) => c.kind !== 'element' || c.children.length > 0 || c.attrs.length > 0 || c.declare);
      if (e.children.length !== before) changed = true;
    }
  }
}

/** Adds <Order> and wcm:action="add" to generated command lists (upstream OrderModifier). */
function numberCommands(root: XElement, userComponents: Set<XElement>): void {
  for (const pass of elements(root).filter((e) => e.name === 'settings')) {
    for (const comp of elements(pass)) {
      if (userComponents.has(comp)) continue;
      for (const container of walk(comp)) {
        if (!['RunSynchronous', 'RunAsynchronous', 'FirstLogonCommands'].includes(container.name)) continue;
        elements(container).forEach((item, i) => {
          item.children.unshift({ kind: 'element', name: 'Order', ns: NS.unattend, attrs: [], children: [{ kind: 'text', value: String(i + 1) }] });
          setAttr(item, 'action', 'add', NS.wcm, 'wcm');
        });
      }
    }
  }
}

/** Emits one copy of each component per selected architecture (upstream ProcessorArchitectureModifier). */
function fanOutArchitectures(root: XElement, archs: string[]): void {
  for (const pass of elements(root).filter((e) => e.name === 'settings')) {
    const next: typeof pass.children = [];
    for (const c of pass.children) {
      if (c.kind === 'element' && c.name === 'component' && getAttr(c, 'processorArchitecture') !== undefined) {
        for (const arch of archs) {
          const copy = clone(c);
          setAttr(copy, 'processorArchitecture', arch);
          next.push(copy);
        }
      } else {
        next.push(c);
      }
    }
    pass.children = next;
  }
}

function emitSequences(ctx: GenContext): void {
  const { seq, cmd } = ctx;
  if (!seq.specialize.isEmpty) {
    const ps1 = ctx.embedFile(seq.specialize.fileName, seq.specialize.getScript());
    ctx.appendCommand('specialize', cmd.powerShellFile(ps1));
  }
  if (!seq.userOnce.isEmpty) {
    const ps1 = ctx.embedFile(seq.userOnce.fileName, seq.userOnce.getScript());
    // Quoting exactly as upstream UserOnceModifier: " becomes \"" inside reg.exe /d "…".
    const command = cmd.powerShellFile(ps1).replace(/"/g, '\\""');
    seq.defaultUser.append(
      `reg.exe add "HKU\\DefaultUser\\Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce" /v "UnattendedSetup" /t REG_SZ /d "${command}" /f;`,
    );
  }
  if (!seq.defaultUser.isEmpty) {
    const ps1 = ctx.embedFile(seq.defaultUser.fileName, seq.defaultUser.getScript());
    ctx.appendCommand('specialize', cmd.registry('load "HKU\\DefaultUser" "C:\\Users\\Default\\NTUSER.DAT"'));
    ctx.appendCommand('specialize', cmd.powerShellFile(ps1));
    ctx.appendCommand('specialize', cmd.registry('unload "HKU\\DefaultUser"'));
  }
  f.accounts.modifyDeleteSensitive(ctx);
  if (!seq.firstLogon.isEmpty) {
    const ps1 = ctx.embedFile(seq.firstLogon.fileName, seq.firstLogon.getScript());
    ctx.appendCommand('firstLogon', cmd.powerShellFile(ps1));
  }
}

function build(profile: Profile): GenContext {
  const ctx = new GenContext(profile, resolveIdentity(profile.accounts));

  f.accounts.modifyComputerName(ctx);
  f.setup.modify(ctx);
  f.accounts.modify(ctx);
  f.bloatware.modify(ctx);
  f.privacy.modifyExpressSettings(ctx);
  f.wifi.modify(ctx);
  pruneEmpty(ctx.root);
  f.accounts.modifyPolicies(ctx);

  f.taskbar.modify(ctx);
  f.explorer.modify(ctx);
  f.security.modify(ctx);
  f.system.modify(ctx);
  f.updates.modify(ctx);
  f.privacy.modify(ctx);
  f.desktop.modify(ctx);
  f.virtualization.modify(ctx);
  f.taskbar.modifySearch(ctx);
  f.start.modifyPins(ctx);
  f.personalization.modifyEffects(ctx);
  f.desktop.modifyIcons(ctx);
  f.start.modifyFolders(ctx);
  f.personalization.modifyStickyKeys(ctx);
  f.virtualization.modifyCoreIsolation(ctx);

  f.setup.modifyTimeZone(ctx);
  f.security.modifyAppLocker(ctx);
  f.scripts.modify(ctx);
  emitSequences(ctx);
  f.windowsUpdate.modify(ctx);

  const userComponents = f.advancedXml.modify(ctx);
  numberCommands(ctx.root, userComponents);
  fanOutArchitectures(ctx.root, profile.setup.processorArchitectures);
  return ctx;
}

/**
 * Validates a profile and, if it has no errors, produces the answer file. Never throws for user
 * input: every problem is returned as an issue.
 */
export function generate(input: unknown): GenerateResult {
  const fallbackName = 'autounattend.xml';
  const { profile, issues } = validateProfile(input);
  const fileName = profile?.output.answerFileName ?? fallbackName;
  if (!profile || hasErrors(issues)) return { ok: false, issues, fileName, embeddedFiles: [], assets: [] };

  let ctx: GenContext;
  try {
    ctx = build(profile);
  } catch (e) {
    if (e instanceof CommandError || e instanceof XmlCharacterError) {
      return { ok: false, issues: [...issues, { severity: 'error', path: '', message: e.message }], fileName, embeddedFiles: [], assets: [] };
    }
    throw e;
  }
  const all = [...issues, ...ctx.issues, ...checkStructure(ctx.root)];
  if (hasErrors(all)) return { ok: false, issues: all, fileName, embeddedFiles: [], assets: [] };

  try {
    return { ok: true, issues: all, xml: serialize(ctx.root), fileName, embeddedFiles: ctx.files, assets: updateEngineAssets(profile) };
  } catch (e) {
    if (e instanceof XmlCharacterError) {
      return { ok: false, issues: [...all, { severity: 'error', path: '', message: e.message }], fileName, embeddedFiles: [], assets: [] };
    }
    throw e;
  }
}
