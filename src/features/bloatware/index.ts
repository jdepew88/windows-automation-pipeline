import type { GenContext } from '../../engine/context';
import type { SettingDef } from '../../engine/settings/types';
import type { Profile } from '../../engine/schema/profile';
import type { Issue } from '../../engine/validation/issues';
import { UPSTREAM_RESOURCES } from '../../engine/resources/upstream';
import { BLOATWARE, BLOATWARE_BY_ID, type BloatwareEntry, type StepKind } from './catalog';
import { HKU_DEFAULT } from '../shared';

export { BLOATWARE, BLOATWARE_BY_ID } from './catalog';

export const settings: SettingDef[] = [
  {
    path: 'bloatware',
    section: 'bloatware',
    label: 'App removal (Keep / Remove / Leave untouched)',
    control: 'custom',
    description:
      '"Keep" records that the app must not be removed. It never installs a missing app. "Leave untouched" takes no action. In M1 both generate no commands; "Keep" is kept for later bundles. Removal runs in specialize, before any user profile exists. It deprovisions packages for all users and skips anything not present.',
    applicability: 'Windows 11 (the removal script exits on builds < 22000); identifiers vary by build',
    risk: 'Some apps can only be restored from the Store. Removing Microsoft Store blocks Store/WinGet msstore sources.',
    stages: ['specialize', 'defaultUser', 'userOnce'],
    mapping:
      'RemovePackage.ps1 (Remove-AppxProvisionedPackage -AllUsers -Online), RemoveCapability.ps1 (Remove-WindowsCapability -Online), RemoveFeature.ps1 (Disable-WindowsOptionalFeature -Online -Remove -NoRestart), plus per-app registry/file steps; identifiers from upstream resource/Bloatware.json',
    advanced: true,
    verification: 'upstream-tested',
  },
];

export function validate(p: Profile, issues: Issue[]): void {
  for (const [id, action] of Object.entries(p.bloatware)) {
    const entry = BLOATWARE_BY_ID.get(id);
    if (!entry) {
      issues.push({ severity: 'error', path: 'bloatware', message: `Unknown app "${id}" in app-removal list.` });
    } else if (action === 'remove' && !entry.removable) {
      issues.push({ severity: 'error', path: `bloatware.${id}`, message: `${entry.label} has no supported removal mechanism. Choose Keep or Leave untouched.` });
    }
  }
}

/** Selected entries in deterministic (ID) order. */
export function selectedForRemoval(p: Profile): BloatwareEntry[] {
  return BLOATWARE.filter((b) => p.bloatware[b.id] === 'remove').sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

const REMOVERS: Record<Exclude<StepKind, 'custom'>, { type: string; get: string; filter: string; remove: string }> = {
  package: {
    type: 'Package',
    get: `{
  Get-AppxProvisionedPackage -Online;
}`,
    filter: `{
  $_.DisplayName -eq $selector;
}`,
    remove: `{
  [CmdletBinding()]
  param(
    [Parameter( Mandatory, ValueFromPipeline )]
    $InputObject
  );
  process {
    $InputObject | Remove-AppxProvisionedPackage -AllUsers -Online -ErrorAction 'Continue';
  }
}`,
  },
  capability: {
    type: 'Capability',
    get: `{
  Get-WindowsCapability -Online | Where-Object -Property 'State' -NotIn -Value @(
    'NotPresent';
    'Removed';
  );
}`,
    filter: `{
  ($_.Name -split '~')[0] -eq $selector;
}`,
    remove: `{
  [CmdletBinding()]
  param(
    [Parameter( Mandatory, ValueFromPipeline )]
    $InputObject
  );
  process {
    $InputObject | Remove-WindowsCapability -Online -ErrorAction 'Continue';
  }
}`,
  },
  feature: {
    type: 'Feature',
    get: `{
  Get-WindowsOptionalFeature -Online | Where-Object -Property 'State' -NotIn -Value @(
    'Disabled';
    'DisabledWithPayloadRemoved';
  );
}`,
    filter: `{
  $_.FeatureName -eq $selector;
}`,
    remove: `{
  [CmdletBinding()]
  param(
    [Parameter( Mandatory, ValueFromPipeline )]
    $InputObject
  );
  process {
    $InputObject | Disable-WindowsOptionalFeature -Online -Remove -NoRestart -ErrorAction 'Continue';
  }
}`,
  },
};

/** Platform gate added in this project: removal identifiers are curated for Windows 11 client. */
const PLATFORM_GUARD = `$os = Get-CimInstance -ClassName 'Win32_OperatingSystem';
if( [System.Environment]::OSVersion.Version.Build -lt 22000 -or $os.ProductType -ne 1 ) {
	"Skipping removal: expected Windows 11 client, found build $([System.Environment]::OSVersion.Version.Build), product type $($os.ProductType).";
	return;
}`;

function removerScript(kind: Exclude<StepKind, 'custom'>, selectors: string[]): string {
  const r = REMOVERS[kind];
  return [
    PLATFORM_GUARD,
    '$selectors = @(',
    ...selectors.map((s) => `\t'${s.replace(/'/g, "''")}';`),
    ');',
    `$getCommand = ${r.get};`,
    `$filterCommand = ${r.filter};`,
    `$removeCommand = ${r.remove};`,
    `$type = '${r.type}';`,
    UPSTREAM_RESOURCES['RemoveBloatware.ps1'],
  ].join('\n');
}

export function modify(ctx: GenContext): void {
  const selectors: Record<Exclude<StepKind, 'custom'>, string[]> = { package: [], capability: [], feature: [] };

  for (const bw of selectedForRemoval(ctx.profile)) {
    for (const step of bw.steps) {
      if (step.kind !== 'custom') {
        selectors[step.kind].push(step.selector!);
        continue;
      }
      switch (bw.custom) {
        case 'oneDrive':
          ctx.seq.specialize.append(`@(
  'C:\\Users\\Default\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\OneDrive.lnk';
  'C:\\Windows\\System32\\OneDriveSetup.exe';
  'C:\\Windows\\SysWOW64\\OneDriveSetup.exe';
) | Where-Object -FilterScript { [System.IO.File]::Exists( $_ ); } | Remove-Item -Verbose -ErrorAction 'Continue';`);
          ctx.seq.defaultUser.append(
            `Remove-ItemProperty -LiteralPath 'Registry::${HKU_DEFAULT}\\Software\\Microsoft\\Windows\\CurrentVersion\\Run' -Name 'OneDriveSetup' -Force -ErrorAction 'Continue';`,
          );
          break;
        case 'teams':
          ctx.seq.specialize.append('reg.exe add "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Communications" /v ConfigureChatAutoInstall /t REG_DWORD /d 0 /f;');
          break;
        case 'notepad':
          ctx.seq.specialize.append(`reg.exe add "HKCR\\.txt\\ShellNew" /v ItemName /t REG_EXPAND_SZ /d "@C:\\Windows\\system32\\notepad.exe,-470" /f;
reg.exe add "HKCR\\.txt\\ShellNew" /v NullFile /t REG_SZ /f;
reg.exe add "HKCR\\txtfilelegacy" /v FriendlyTypeName /t REG_EXPAND_SZ /d "@C:\\Windows\\system32\\notepad.exe,-469" /f;
reg.exe add "HKCR\\txtfilelegacy" /ve /t REG_SZ /d "Text Document" /f;`);
          ctx.seq.defaultUser.append(`reg.exe add "${HKU_DEFAULT}\\Software\\Microsoft\\Notepad" /v ShowStoreBanner /t REG_DWORD /d 0 /f;`);
          break;
        case 'outlook':
          ctx.seq.specialize.append(
            "Remove-Item -LiteralPath 'Registry::HKLM\\Software\\Microsoft\\WindowsUpdate\\Orchestrator\\UScheduler_Oobe\\OutlookUpdate' -Force -ErrorAction 'SilentlyContinue';",
          );
          break;
        case 'devHome':
          ctx.seq.specialize.append(
            "Remove-Item -LiteralPath 'Registry::HKLM\\Software\\Microsoft\\WindowsUpdate\\Orchestrator\\UScheduler_Oobe\\DevHomeUpdate' -Force -ErrorAction 'SilentlyContinue';",
          );
          break;
        case 'copilot':
          ctx.seq.userOnce.append("Get-AppxPackage -Name 'Microsoft.Windows.Ai.Copilot.Provider' | Remove-AppxPackage;");
          if (!ctx.profile.privacy.disableCopilot) {
            ctx.seq.defaultUser.append(`reg.exe add "${HKU_DEFAULT}\\Software\\Policies\\Microsoft\\Windows\\WindowsCopilot" /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f;`);
          }
          break;
        case 'internetExplorer':
          ctx.seq.defaultUser.append(`reg.exe add "${HKU_DEFAULT}\\Software\\Microsoft\\Internet Explorer\\LowRegistry\\Audio\\PolicyConfig\\PropertyStore" /f;`);
          break;
        default:
          throw new Error(`Bloatware entry ${bw.id} has a custom step without an implementation`);
      }
    }
    // Upstream attaches the GameDVR tweak to its combined Xbox entry; here it follows Game Bar.
    if (bw.custom === 'gameDvr') {
      ctx.seq.defaultUser.append(`reg.exe add "${HKU_DEFAULT}\\Software\\Microsoft\\Windows\\CurrentVersion\\GameDVR" /v AppCaptureEnabled /t REG_DWORD /d 0 /f;`);
    }
  }

  for (const kind of ['package', 'capability', 'feature'] as const) {
    if (selectors[kind].length === 0) continue;
    const name = `Remove${REMOVERS[kind].type}.ps1`;
    ctx.seq.specialize.invokeFile(ctx.embedFile(name, removerScript(kind, selectors[kind])));
  }
}
