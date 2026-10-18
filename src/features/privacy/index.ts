import type { GenContext } from '../../engine/context';
import type { SettingDef } from '../../engine/settings/types';
import { child, remove } from '../../engine/xml/tree';
import { HKLM_POLICIES, HKU_DEFAULT, regAdd } from '../shared';

export const settings: SettingDef[] = [
  {
    path: 'privacy.expressSettings',
    section: 'privacy',
    label: 'OOBE privacy (express) settings',
    control: 'radio',
    choices: [
      { value: 'disableAll', label: 'Turn off all optional privacy settings (owner default)' },
      { value: 'enableAll', label: 'Accept all' },
      { value: 'interactive', label: 'Choose interactively in OOBE' },
    ],
    description: 'Covers the OOBE privacy page: location, Find my device, optional diagnostic data, inking & typing, tailored experiences and advertising ID.',
    applicability: 'Windows 10/11',
    stages: ['oobeSystem'],
    mapping: 'oobeSystem › Shell-Setup › OOBE/ProtectYourPC (3 = disable, 1 = enable, absent = interactive)',
    advanced: false,
    verification: 'upstream-tested',
  },
  {
    path: 'privacy.diagnosticData',
    section: 'privacy',
    label: 'Diagnostic data',
    control: 'radio',
    choices: [
      { value: 'required', label: 'Required diagnostic data only (policy)' },
      { value: 'windowsDefault', label: 'Windows default (user choice)' },
    ],
    description:
      'Windows 11 Pro cannot turn diagnostic data off completely. "Security"/0 is only honored by Enterprise/Education, and Pro treats it as Required. This sets the minimum Pro supports.',
    applicability: 'Windows 11 Pro: Required is the floor',
    stages: ['specialize'],
    mapping: `${HKLM_POLICIES}\\Windows\\DataCollection\\AllowTelemetry = 1`,
    advanced: false,
    verification: 'documented',
  },
  {
    path: 'privacy.disableAdvertisingId',
    section: 'privacy',
    label: 'Turn off the advertising ID',
    control: 'checkbox',
    description: 'Group Policy "Turn off the advertising ID".',
    applicability: 'Windows 10/11',
    stages: ['specialize'],
    mapping: `${HKLM_POLICIES}\\Windows\\AdvertisingInfo\\DisabledByGroupPolicy = 1`,
    advanced: false,
    verification: 'documented',
  },
  {
    path: 'privacy.disableTailoredExperiences',
    section: 'privacy',
    label: 'Do not use diagnostic data for tailored experiences',
    control: 'checkbox',
    description: 'User policy, applied to the default user profile so every new account inherits it.',
    applicability: 'Windows 10 1703+/11',
    stages: ['defaultUser'],
    mapping: `${HKU_DEFAULT}\\Software\\Policies\\Microsoft\\Windows\\CloudContent\\DisableTailoredExperiencesWithDiagnosticData = 1`,
    advanced: false,
    verification: 'documented',
  },
  {
    path: 'privacy.disableInkingTypingCollection',
    section: 'privacy',
    label: 'Turn off inking & typing personalization and online speech recognition',
    control: 'checkbox',
    description: 'Stops implicit collection of ink and typed text and online speech services. Local spell-check and handwriting recognition keep working.',
    applicability: 'Windows 10/11',
    stages: ['specialize', 'defaultUser'],
    mapping: `${HKLM_POLICIES}\\InputPersonalization\\AllowInputPersonalization = 0; ${HKLM_POLICIES}\\Windows\\TextInput\\AllowLinguisticDataCollection = 0; default user InputPersonalization\\RestrictImplicitInkCollection/RestrictImplicitTextCollection = 1, TrainedDataStore\\HarvestContacts = 0`,
    advanced: true,
    verification: 'documented',
  },
  {
    path: 'privacy.disableLocation',
    section: 'privacy',
    label: 'Turn off location services',
    control: 'checkbox',
    description: 'Device-wide policy. Apps, Find my device and automatic time-zone detection cannot use location.',
    applicability: 'Windows 10/11',
    risk: 'Automatic time zone and Find my device stop working. Set the time zone explicitly if needed.',
    stages: ['specialize'],
    mapping: `${HKLM_POLICIES}\\Windows\\LocationAndSensors\\DisableLocation = 1`,
    advanced: false,
    verification: 'documented',
  },
  {
    path: 'privacy.disableAppSuggestions',
    section: 'privacy',
    label: 'Disable suggested/sponsored apps and promotional content',
    control: 'checkbox',
    description: 'Stops Content Delivery Manager from silently installing sponsored apps and showing suggestions for new users.',
    applicability:
      'ContentDeliveryManager values: Windows 10/11 all editions. The DisableWindowsConsumerFeatures policy is honored only by Enterprise/Education.',
    stages: ['defaultUser', 'specialize'],
    mapping: `Default user …\\ContentDeliveryManager\\{ContentDeliveryAllowed, SilentInstalledAppsEnabled, SubscribedContent-*Enabled, …} = 0; ${HKLM_POLICIES}\\Windows\\CloudContent\\DisableWindowsConsumerFeatures = 1`,
    advanced: false,
    verification: 'upstream-tested',
  },
  {
    path: 'privacy.disableBingResults',
    section: 'privacy',
    label: 'Do not show Bing web results in Start search',
    control: 'checkbox',
    description: 'Start search shows only local results.',
    applicability: 'Windows 10/11',
    stages: ['defaultUser'],
    mapping: `${HKU_DEFAULT}\\Software\\Policies\\Microsoft\\Windows\\Explorer\\DisableSearchBoxSuggestions = 1`,
    advanced: true,
    verification: 'upstream-tested',
  },
  {
    path: 'privacy.disableCopilot',
    section: 'privacy',
    label: 'Turn off Windows Copilot (policy)',
    control: 'checkbox',
    description:
      'Sets the legacy "Turn off Windows Copilot" user policy. Newer builds ship Copilot as a Store app that this policy does not remove. Use the Copilot entry in App removal for that.',
    applicability: 'Windows 11 23H2+; effect varies by build',
    stages: ['defaultUser'],
    mapping: `${HKU_DEFAULT}\\Software\\Policies\\Microsoft\\Windows\\WindowsCopilot\\TurnOffWindowsCopilot = 1`,
    advanced: false,
    verification: 'upstream-tested',
  },
  {
    path: 'privacy.disableRecall',
    section: 'privacy',
    label: 'Turn off Recall snapshots',
    control: 'checkbox',
    description: 'Policy "Turn off saving snapshots for use with Recall". Recall exists only on Copilot+ PCs. Elsewhere this has no effect.',
    applicability: 'Windows 11 24H2+ Copilot+ PCs',
    stages: ['specialize'],
    mapping: `${HKLM_POLICIES}\\Windows\\WindowsAI\\DisableAIDataAnalysis = 1`,
    advanced: false,
    verification: 'documented',
  },
];

const APP_SUGGESTION_NAMES = [
  'ContentDeliveryAllowed',
  'FeatureManagementEnabled',
  'OEMPreInstalledAppsEnabled',
  'PreInstalledAppsEnabled',
  'PreInstalledAppsEverEnabled',
  'SilentInstalledAppsEnabled',
  'SoftLandingEnabled',
  'SubscribedContentEnabled',
  'SubscribedContent-310093Enabled',
  'SubscribedContent-338387Enabled',
  'SubscribedContent-338388Enabled',
  'SubscribedContent-338389Enabled',
  'SubscribedContent-338393Enabled',
  'SubscribedContent-353694Enabled',
  'SubscribedContent-353696Enabled',
  'SubscribedContent-353698Enabled',
  'SystemPaneSuggestionsEnabled',
];

export function modifyExpressSettings(ctx: GenContext): void {
  const oobe = child(ctx.component('oobeSystem', 'Microsoft-Windows-Shell-Setup'), 'OOBE')!;
  const elem = child(oobe, 'ProtectYourPC')!;
  switch (ctx.profile.privacy.expressSettings) {
    case 'interactive':
      remove(oobe, elem);
      break;
    case 'enableAll':
      elem.children = [{ kind: 'text', value: '1' }];
      break;
    case 'disableAll':
      elem.children = [{ kind: 'text', value: '3' }];
      break;
  }
}

export function modify(ctx: GenContext): void {
  const p = ctx.profile.privacy;
  const sp = ctx.seq.specialize;
  const du = ctx.seq.defaultUser;

  if (p.diagnosticData === 'required') sp.append(regAdd(`${HKLM_POLICIES}\\Windows\\DataCollection`, 'AllowTelemetry', 1));
  if (p.disableAdvertisingId) sp.append(regAdd(`${HKLM_POLICIES}\\Windows\\AdvertisingInfo`, 'DisabledByGroupPolicy', 1));
  if (p.disableTailoredExperiences) {
    du.append(regAdd(`${HKU_DEFAULT}\\Software\\Policies\\Microsoft\\Windows\\CloudContent`, 'DisableTailoredExperiencesWithDiagnosticData', 1));
  }
  if (p.disableInkingTypingCollection) {
    sp.append(
      [regAdd(`${HKLM_POLICIES}\\InputPersonalization`, 'AllowInputPersonalization', 0), regAdd(`${HKLM_POLICIES}\\Windows\\TextInput`, 'AllowLinguisticDataCollection', 0)].join('\n'),
    );
    du.append(
      [
        regAdd(`${HKU_DEFAULT}\\Software\\Microsoft\\InputPersonalization`, 'RestrictImplicitInkCollection', 1),
        regAdd(`${HKU_DEFAULT}\\Software\\Microsoft\\InputPersonalization`, 'RestrictImplicitTextCollection', 1),
        regAdd(`${HKU_DEFAULT}\\Software\\Microsoft\\InputPersonalization\\TrainedDataStore`, 'HarvestContacts', 0),
      ].join('\n'),
    );
  }
  if (p.disableLocation) sp.append(regAdd(`${HKLM_POLICIES}\\Windows\\LocationAndSensors`, 'DisableLocation', 1));
  if (p.disableAppSuggestions) {
    du.append(`$names = @(
${APP_SUGGESTION_NAMES.map((n) => `  '${n}';`).join('\n')}
);

foreach( $name in $names ) {
  reg.exe add "${HKU_DEFAULT}\\Software\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager" /v $name /t REG_DWORD /d 0 /f;
}`);
    sp.append(regAdd(`${HKLM_POLICIES}\\Windows\\CloudContent`, 'DisableWindowsConsumerFeatures', 1));
  }
  if (p.disableBingResults) du.append(regAdd(`${HKU_DEFAULT}\\Software\\Policies\\Microsoft\\Windows\\Explorer`, 'DisableSearchBoxSuggestions', 1));
  if (p.disableCopilot) du.append(regAdd(`${HKU_DEFAULT}\\Software\\Policies\\Microsoft\\Windows\\WindowsCopilot`, 'TurnOffWindowsCopilot', 1));
  if (p.disableRecall) sp.append(regAdd(`${HKLM_POLICIES}\\Windows\\WindowsAI`, 'DisableAIDataAnalysis', 1));
}
