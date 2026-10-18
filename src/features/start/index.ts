import type { GenContext } from '../../engine/context';
import type { SettingDef } from '../../engine/settings/types';
import type { Profile } from '../../engine/schema/profile';
import type { Issue } from '../../engine/validation/issues';
import { START_FOLDERS } from '../../data';
import { UPSTREAM_RESOURCES } from '../../engine/resources/upstream';

export const settings: SettingDef[] = [
  {
    path: 'start.pinsMode',
    section: 'start',
    label: 'Start menu pins',
    control: 'radio',
    choices: [
      { value: 'default', label: 'Windows default pins (owner default)' },
      { value: 'empty', label: 'Remove all pins' },
      { value: 'custom', label: 'Use ConfigureStartPins JSON' },
    ],
    description: 'Applied through the Start/ConfigureStartPins MDM policy value.',
    applicability: 'Windows 11 (build ≥ 20000)',
    stages: ['specialize'],
    mapping: 'SetStartPins.ps1 (upstream): HKLM\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Start\\ConfigureStartPins',
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'start.pinsJson',
    section: 'start',
    label: 'ConfigureStartPins JSON',
    control: 'textarea',
    placeholder: '{"pinnedList":[{"desktopAppLink":"%ALLUSERSPROFILE%\\\\Microsoft\\\\Windows\\\\Start Menu\\\\Programs\\\\File Explorer.lnk"}]}',
    description: 'Must be valid JSON in the documented ConfigureStartPins format.',
    applicability: 'Windows 11',
    stages: ['specialize'],
    mapping: 'Value of ConfigureStartPins',
    advanced: true,
    visibleWhen: (p) => p.start.pinsMode === 'custom',
    verification: 'upstream-tested',
  },
  {
    path: 'start.foldersMode',
    section: 'start',
    label: 'Folders next to the power button',
    control: 'radio',
    choices: [
      { value: 'default', label: 'Windows default' },
      { value: 'custom', label: 'Show only the folders selected below' },
    ],
    description: '',
    applicability: 'Windows 11',
    stages: ['userOnce'],
    mapping: 'UserOnce.ps1: HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Start\\VisiblePlaces (REG_BINARY concatenated folder GUIDs)',
    advanced: false,
    verification: 'upstream-tested',
  },
  {
    path: 'start.folders',
    section: 'start',
    label: 'Folders on Start',
    control: 'custom',
    choices: () => START_FOLDERS.map((f) => ({ value: f.Id, label: f.DisplayName })),
    description: 'Owner default: Downloads, Personal folder, Pictures and Settings shown; the others hidden.',
    applicability: 'Windows 11',
    stages: ['userOnce'],
    mapping: 'GUID bytes from upstream resource/StartFolder.json',
    advanced: false,
    visibleWhen: (p) => p.start.foldersMode === 'custom',
    verification: 'upstream-tested',
  },
];

export function validate(p: Profile, issues: Issue[]): void {
  if (p.start.pinsMode === 'custom') {
    try {
      JSON.parse(p.start.pinsJson);
    } catch {
      issues.push({ severity: 'error', path: 'start.pinsJson', message: 'Start pins must be valid JSON.' });
    }
  }
  const known = new Set(START_FOLDERS.map((f) => f.Id));
  for (const id of Object.keys(p.start.folders)) {
    if (!known.has(id)) issues.push({ severity: 'error', path: 'start.folders', message: `Unknown Start folder "${id}".` });
  }
}

function base64ToBytes(b64: string): number[] {
  return [...atob(b64)].map((c) => c.charCodeAt(0));
}

function bytesToBase64(bytes: number[]): string {
  return btoa(String.fromCharCode(...bytes));
}

export function modifyPins(ctx: GenContext): void {
  const s = ctx.profile.start;
  if (s.pinsMode === 'default') return;
  const json = s.pinsMode === 'empty' ? '{"pinnedList":[]}' : s.pinsJson.trim();
  const ps1 = ctx.embedFile('SetStartPins.ps1', `$json = '${json.replace(/'/g, "''")}';\n${UPSTREAM_RESOURCES['SetStartPins.ps1']}`);
  ctx.seq.specialize.invokeFile(ps1);
}

export function modifyFolders(ctx: GenContext): void {
  const s = ctx.profile.start;
  if (s.foldersMode !== 'custom') return;
  const sorted = [...START_FOLDERS].sort((a, b) => (a.Id < b.Id ? -1 : 1));
  const bytes = sorted.filter((f) => s.folders[f.Id]).flatMap((f) => base64ToBytes(f.Bytes));
  ctx.seq.userOnce.append(
    `Set-ItemProperty -Path 'Registry::HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Start' -Name 'VisiblePlaces' -Value $( [convert]::FromBase64String('${bytesToBase64(bytes)}') ) -Type 'Binary';`,
  );
}
