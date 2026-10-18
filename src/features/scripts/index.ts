import type { GenContext } from '../../engine/context';
import { SCRIPTS_DIR } from '../../engine/context';
import type { SettingDef } from '../../engine/settings/types';
import type { Profile, Script, ScriptPhase, ScriptType } from '../../engine/schema/profile';
import type { Issue } from '../../engine/validation/issues';
import type { PowerShellSequence } from '../../engine/stages/sequences';

export interface PhaseInfo {
  phase: ScriptPhase;
  title: string;
  /** Execution context and timing, shown next to each editor. */
  context: string;
  allowedTypes: ScriptType[];
  advanced: boolean;
}

/** UI and file-numbering order (matches upstream's form order). */
export const PHASES: PhaseInfo[] = [
  {
    phase: 'firstLogon',
    title: 'FirstLogon scripts',
    context:
      'Run once, at the first sign-in after Windows is installed, in the automatically signed-in administrator session (oobeSystem FirstLogonCommands → FirstLogon.ps1). Setup does not wait for the network, so connectivity is not guaranteed.',
    allowedTypes: ['ps1', 'cmd', 'reg', 'vbs'],
    advanced: false,
  },
  {
    phase: 'system',
    title: 'System scripts',
    context:
      'Run as SYSTEM in the specialize pass, before any user account exists (Specialize.ps1). No user session, no desktop, and usually no network.',
    allowedTypes: ['ps1', 'cmd', 'reg', 'vbs'],
    advanced: true,
  },
  {
    phase: 'defaultUser',
    title: 'DefaultUser scripts',
    context:
      'Run as SYSTEM in specialize while the default user hive is loaded at HKU\\DefaultUser (DefaultUser.ps1). Changes apply to every account created afterwards. Use HKU\\DefaultUser\\ (.cmd), Registry::HKU\\DefaultUser\\ (.ps1) or [HKEY_USERS\\DefaultUser\\ (.reg), not HKCU.',
    allowedTypes: ['ps1', 'cmd', 'reg'],
    advanced: true,
  },
  {
    phase: 'userOnce',
    title: 'UserOnce scripts',
    context:
      'Run once for each user the first time that user signs in (RunOnce in the default profile → UserOnce.ps1), in the user\'s own non-elevated context.',
    allowedTypes: ['ps1', 'cmd', 'reg', 'vbs'],
    advanced: true,
  },
];

const FILE_ORDER: ScriptPhase[] = ['system', 'defaultUser', 'firstLogon', 'userOnce'];

export const settings: SettingDef[] = [
  ...PHASES.map(
    (ph): SettingDef => ({
      path: `scripts.${ph.phase}`,
      section: 'scripts',
      label: ph.title,
      control: 'custom',
      description: ph.context,
      applicability: 'Windows 10/11. VBScript is deprecated and may be removed from future Windows releases.',
      risk: 'Scripts run with high privileges during setup. Nothing is executed in the browser.',
      stages: ph.phase === 'firstLogon' ? ['firstLogon'] : ph.phase === 'userOnce' ? ['userOnce'] : ph.phase === 'defaultUser' ? ['defaultUser'] : ['specialize'],
      mapping: `Embedded ${SCRIPTS_DIR}\\unattend-NN.<ext>, invoked from the ${ph.phase === 'system' ? 'Specialize' : ph.phase === 'defaultUser' ? 'DefaultUser' : ph.phase === 'firstLogon' ? 'FirstLogon' : 'UserOnce'}.ps1 sequence`,
      advanced: ph.advanced,
      verification: 'upstream-tested',
    }),
  ),
  {
    path: 'scripts.restartExplorer',
    section: 'scripts',
    label: 'Restart File Explorer after UserOnce scripts',
    control: 'checkbox',
    description: 'Needed when UserOnce scripts change Explorer settings that are read only at startup.',
    applicability: 'All',
    stages: ['userOnce'],
    mapping: 'UserOnce.ps1: stop explorer.exe in the current session (it restarts automatically)',
    advanced: true,
    verification: 'upstream-tested',
  },
];

export function isEffective(s: Script): boolean {
  return s.enabled && s.content.trim() !== '';
}

export function validate(p: Profile, issues: Issue[]): void {
  const ids = new Set<string>();
  for (const ph of PHASES) {
    p.scripts[ph.phase].forEach((s, i) => {
      const path = `scripts.${ph.phase}.${i}`;
      if (ids.has(s.id)) issues.push({ severity: 'error', path, message: `Duplicate script id "${s.id}".` });
      ids.add(s.id);
      if (!ph.allowedTypes.includes(s.type)) {
        issues.push({ severity: 'error', path, message: `${ph.title} cannot use .${s.type} files.` });
      }
      if (s.enabled && s.content.trim() === '') {
        issues.push({ severity: 'warning', path, message: `"${s.name || `Script ${i + 1}`}" is empty and will be skipped.` });
      }
      if (ph.phase === 'defaultUser' && isEffective(s) && /HKEY_CURRENT_USER|HKCU[:\\]/i.test(s.content)) {
        issues.push({
          severity: 'warning',
          path,
          message: 'DefaultUser scripts run as SYSTEM, so HKCU there means the SYSTEM profile. Use HKU\\DefaultUser instead.',
        });
      }
    });
  }
}

function prepareContent(s: Script): string {
  if (s.type === 'reg') {
    const header = 'Windows Registry Editor Version 5.00';
    if (!s.content.trimStart().startsWith(header)) return `${header}\r\n\r\n${s.content}`;
  }
  return s.content;
}

export function modify(ctx: GenContext): void {
  const p = ctx.profile.scripts;
  if (p.restartExplorer) ctx.seq.userOnce.requestExplorerRestart();

  const targets: Record<ScriptPhase, PowerShellSequence> = {
    system: ctx.seq.specialize,
    defaultUser: ctx.seq.defaultUser,
    firstLogon: ctx.seq.firstLogon,
    userOnce: ctx.seq.userOnce,
  };

  let index = 0;
  for (const phase of FILE_ORDER) {
    for (const script of p[phase]) {
      if (!isEffective(script)) continue; // disabled or blank: no file, no command
      index++;
      const fileName = `unattend-${index.toString(16).padStart(2, '0')}.${script.type}`;
      const path = ctx.embedFile(fileName, prepareContent(script));
      const seq = targets[phase];
      switch (script.type) {
        case 'ps1':
          seq.invokeFile(path);
          break;
        case 'cmd':
          seq.append(`${path};`);
          break;
        case 'reg':
          seq.append(`${ctx.cmd.registry(`import "${path}"`)};`);
          break;
        case 'vbs':
          seq.append(`${ctx.cmd.vbScript(path)};`);
          break;
      }
    }
  }
}
