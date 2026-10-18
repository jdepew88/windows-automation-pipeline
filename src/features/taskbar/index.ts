import type { GenContext } from '../../engine/context';
import type { SettingDef } from '../../engine/settings/types';
import { UPSTREAM_RESOURCES } from '../../engine/resources/upstream';
import { HKLM_POLICIES, HKU_DEFAULT, regAdd } from '../shared';

const ADVANCED = `${HKU_DEFAULT}\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced`;
const SEARCH_VALUES = { hide: 0, icon: 1, box: 2, label: 3 } as const;

const EMPTY_TASKBAR_LAYOUT = `<LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1">
	<CustomTaskbarLayoutCollection PinListPlacement="Replace">
		<defaultlayout:TaskbarLayout>
			<taskbar:TaskbarPinList>
				<taskbar:DesktopApp DesktopApplicationLinkPath="#leaveempty" />
			</taskbar:TaskbarPinList>
		</defaultlayout:TaskbarLayout>
	</CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>`;

export const settings: SettingDef[] = [
  {
    path: 'taskbar.leftAlign',
    section: 'taskbar',
    label: 'Left-align taskbar icons',
    control: 'checkbox',
    description: '',
    applicability: 'Windows 11',
    stages: ['defaultUser'],
    mapping: `${ADVANCED}\\TaskbarAl = 0`,
    advanced: false,
    verification: 'upstream-tested',
  },
  {
    path: 'taskbar.search',
    section: 'taskbar',
    label: 'Taskbar search',
    control: 'radio',
    choices: [
      { value: 'icon', label: 'Search icon only (owner default)' },
      { value: 'box', label: 'Search box (Windows default)' },
      { value: 'label', label: 'Search icon and label' },
      { value: 'hide', label: 'Hide' },
    ],
    description: '',
    applicability: 'Windows 11',
    stages: ['userOnce'],
    mapping: 'UserOnce.ps1: HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Search\\SearchboxTaskbarMode = 0|1|2|3; restart Explorer',
    advanced: false,
    verification: 'upstream-tested',
  },
  {
    path: 'taskbar.hideTaskView',
    section: 'taskbar',
    label: 'Hide the Task View button',
    control: 'checkbox',
    description: 'Owner default keeps Task View visible.',
    applicability: 'Windows 10/11',
    stages: ['defaultUser'],
    mapping: `${ADVANCED}\\ShowTaskViewButton = 0`,
    advanced: false,
    verification: 'upstream-tested',
  },
  {
    path: 'taskbar.disableWidgets',
    section: 'taskbar',
    label: 'Disable Widgets',
    control: 'checkbox',
    description: 'Removes the Widgets board and taskbar button. The obsolete Chat button no longer exists on current builds, so nothing is done for it.',
    applicability: 'Windows 11',
    stages: ['specialize'],
    mapping: `${HKLM_POLICIES}\\Dsh\\AllowNewsAndInterests = 0`,
    advanced: false,
    verification: 'upstream-tested',
  },
  {
    path: 'taskbar.showAllTrayIcons',
    section: 'taskbar',
    label: 'Always show all notification-area icons',
    control: 'checkbox',
    description: 'On Windows 11 this uses a recurring logon task, because there is no static setting.',
    applicability: 'Windows 10/11',
    stages: ['defaultUser'],
    mapping: 'ShowAllTrayIcons.ps1/.xml (upstream): EnableAutoTray=0 on Windows 10; scheduled task promoting NotifyIconSettings on Windows 11',
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'taskbar.icons',
    section: 'taskbar',
    label: 'Pinned taskbar icons',
    control: 'radio',
    choices: [
      { value: 'default', label: 'Windows default pins' },
      { value: 'empty', label: 'Remove all pinned icons' },
    ],
    description: 'Custom taskbar layout XML is deferred to a later milestone.',
    applicability: 'Windows 11',
    stages: ['specialize', 'defaultUser', 'userOnce'],
    mapping: 'TaskbarLayoutModification.xml via StartLayoutFile/LockedStartLayout policy, unlocked after first logon by the UnlockStartLayout task (upstream)',
    advanced: true,
    verification: 'upstream-tested',
  },
];

export function modify(ctx: GenContext): void {
  const t = ctx.profile.taskbar;

  if (t.icons === 'empty') {
    // Upstream SetTaskbarIcons: locked layout applied to new users, unlocked by an event-triggered task.
    const path = ctx.embedFile('TaskbarLayoutModification.xml', EMPTY_TASKBAR_LAYOUT);
    ctx.seq.specialize.append(`${regAdd(`${HKLM_POLICIES}\\Windows\\CloudContent`, 'DisableCloudOptimizedContent', 1)}
[System.Diagnostics.EventLog]::CreateEventSource( 'UnattendGenerator', 'Application' );`);
    ctx.seq.defaultUser.append(`${regAdd(`${HKU_DEFAULT}\\Software\\Policies\\Microsoft\\Windows\\Explorer`, 'StartLayoutFile', path, 'REG_SZ')}
${regAdd(`${HKU_DEFAULT}\\Software\\Policies\\Microsoft\\Windows\\Explorer`, 'LockedStartLayout', 1)}`);
    ctx.embedFile('UnlockStartLayout.vbs', UPSTREAM_RESOURCES['UnlockStartLayout.vbs']);
    const task = ctx.embedFile('UnlockStartLayout.xml', UPSTREAM_RESOURCES['UnlockStartLayout.xml']);
    ctx.seq.specialize.append(`Register-ScheduledTask -TaskName 'UnlockStartLayout' -Xml $( Get-Content -LiteralPath '${task}' -Raw );`);
    ctx.seq.userOnce.append(
      `[System.Diagnostics.EventLog]::WriteEntry( 'UnattendGenerator', "User '$env:USERNAME' has requested to unlock the Start menu layout.", [System.Diagnostics.EventLogEntryType]::Information, 1 );`,
    );
  }

  if (t.showAllTrayIcons) {
    ctx.seq.defaultUser.append(UPSTREAM_RESOURCES['ShowAllTrayIcons.ps1']);
    ctx.embedFile('ShowAllTrayIcons.xml', UPSTREAM_RESOURCES['ShowAllTrayIcons.xml']);
  }
  if (t.hideTaskView) ctx.seq.defaultUser.append(regAdd(ADVANCED, 'ShowTaskViewButton', 0));
  if (t.disableWidgets) ctx.seq.specialize.append(regAdd(`${HKLM_POLICIES}\\Dsh`, 'AllowNewsAndInterests', 0));
  if (t.leftAlign) ctx.seq.defaultUser.append(regAdd(ADVANCED, 'TaskbarAl', 0));
}

/** Search mode is applied per user (upstream order: after Edge settings). */
export function modifySearch(ctx: GenContext): void {
  const mode = ctx.profile.taskbar.search;
  if (mode !== 'box') {
    ctx.seq.userOnce.append(
      `Set-ItemProperty -LiteralPath 'Registry::HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Search' -Name 'SearchboxTaskbarMode' -Type 'DWord' -Value ${SEARCH_VALUES[mode]};`,
    );
    ctx.seq.userOnce.requestExplorerRestart();
  }
}
