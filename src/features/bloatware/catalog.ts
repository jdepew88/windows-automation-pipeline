/**
 * App-removal catalog.
 *
 * Package/capability/feature identifiers and applicability come from upstream
 * `resource/Bloatware.json` (cschneegans/unattend-generator @ 27237f82, MIT). Owner-facing entries
 * that upstream groups together (Xbox) are split, and entries upstream lacks are marked as having
 * no removal mechanism instead of guessing an identifier.
 *
 * Removal is always tolerant: the generated script looks each selector up first and logs
 * "not installed" when it is missing. Identifiers that only exist on Windows 10 are harmless no-ops
 * on Windows 11.
 */

export type StepKind = 'package' | 'capability' | 'feature' | 'custom';

export interface BloatwareStep {
  kind: StepKind;
  /** Provisioned package DisplayName, capability name prefix (before `~`), or optional feature name. */
  selector?: string;
  appliesTo: string[];
}

export type BloatwareGroup = 'apps' | 'media' | 'communication' | 'xbox' | 'productivity' | 'system' | 'legacy';

export interface BloatwareEntry {
  id: string;
  label: string;
  group: BloatwareGroup;
  steps: BloatwareStep[];
  /** Extra non-package actions, keyed to fixed implementations in the bloatware modifier. */
  custom?: 'oneDrive' | 'teams' | 'notepad' | 'outlook' | 'devHome' | 'copilot' | 'gameDvr' | 'internetExplorer';
  /** When false, only Keep / Leave untouched are offered (no reliable removal mechanism). */
  removable: boolean;
  note?: string;
}

const W10 = 'Windows 10';
const W11 = 'Windows 11';
const pkg = (selector: string, ...appliesTo: string[]): BloatwareStep => ({ kind: 'package', selector, appliesTo });
const cap = (selector: string, ...appliesTo: string[]): BloatwareStep => ({ kind: 'capability', selector, appliesTo });
const feat = (selector: string, ...appliesTo: string[]): BloatwareStep => ({ kind: 'feature', selector, appliesTo });
const custom = (...appliesTo: string[]): BloatwareStep => ({ kind: 'custom', appliesTo });

export const BLOATWARE_GROUP_LABELS: Record<BloatwareGroup, string> = {
  apps: 'Inbox apps',
  media: 'Media',
  communication: 'Communication & cloud',
  xbox: 'Xbox & gaming',
  productivity: 'Productivity & tools',
  system: 'System components & features',
  legacy: 'Legacy (usually absent on Windows 11)',
};

export const BLOATWARE: BloatwareEntry[] = [
  // Inbox apps
  { id: 'Clock', label: 'Alarms & Clock', group: 'apps', removable: true, steps: [pkg('Microsoft.WindowsAlarms', W10, W11)] },
  { id: 'Calculator', label: 'Calculator', group: 'apps', removable: true, steps: [pkg('Microsoft.WindowsCalculator', W10, W11)] },
  { id: 'Camera', label: 'Camera', group: 'apps', removable: true, steps: [pkg('Microsoft.WindowsCamera', W10, W11)] },
  { id: 'Clipchamp', label: 'Clipchamp', group: 'media', removable: true, steps: [pkg('Clipchamp.Clipchamp', W11)] },
  { id: 'FeedbackHub', label: 'Feedback Hub', group: 'apps', removable: true, steps: [pkg('Microsoft.WindowsFeedbackHub', W10, W11)] },
  { id: 'GetHelp', label: 'Get Help', group: 'apps', removable: true, steps: [pkg('Microsoft.GetHelp', W10, W11)] },
  { id: 'Maps', label: 'Maps', group: 'apps', removable: true, steps: [pkg('Microsoft.WindowsMaps', W10, W11)] },
  { id: 'News', label: 'Microsoft News', group: 'apps', removable: true, steps: [pkg('Microsoft.BingNews', W11)] },
  { id: 'Weather', label: 'Weather', group: 'apps', removable: true, steps: [pkg('Microsoft.BingWeather', W10, W11)] },
  { id: 'GetStarted', label: 'Tips', group: 'apps', removable: true, steps: [pkg('Microsoft.Getstarted', W10, W11)] },
  { id: 'Photos', label: 'Microsoft Photos', group: 'media', removable: true, steps: [pkg('Microsoft.Windows.Photos', W10, W11)] },
  { id: 'ZuneMusic', label: 'Media Player (modern)', group: 'media', removable: true, steps: [pkg('Microsoft.ZuneMusic', W10, W11)] },
  { id: 'ZuneVideo', label: 'Movies & TV', group: 'media', removable: true, steps: [pkg('Microsoft.ZuneVideo', W10, W11)] },
  { id: 'VoiceRecorder', label: 'Sound Recorder / Voice Recorder', group: 'media', removable: true, steps: [pkg('Microsoft.WindowsSoundRecorder', W10, W11)] },
  { id: 'SnippingTool', label: 'Snipping Tool', group: 'productivity', removable: true, steps: [pkg('Microsoft.ScreenSketch', W10, W11), feat('Microsoft-SnippingTool', W10), cap('Microsoft.Windows.SnippingTool', W11)] },
  { id: 'StickyNotes', label: 'Sticky Notes', group: 'productivity', removable: true, steps: [pkg('Microsoft.MicrosoftStickyNotes', W10, W11)] },
  { id: 'ToDo', label: 'Microsoft To Do', group: 'productivity', removable: true, steps: [pkg('Microsoft.Todos', W11)] },
  { id: 'PowerAutomate', label: 'Power Automate', group: 'productivity', removable: true, steps: [pkg('Microsoft.PowerAutomateDesktop', W11)] },
  { id: 'Solitaire', label: 'Solitaire Collection', group: 'xbox', removable: true, steps: [pkg('Microsoft.MicrosoftSolitaireCollection', W10, W11)] },
  { id: 'Store', label: 'Microsoft Store', group: 'system', removable: true, steps: [pkg('Microsoft.WindowsStore', W10, W11), pkg('Microsoft.StorePurchaseApp', W10, W11)], note: 'Removing the Store also breaks later Store/WinGet msstore installs.' },
  { id: 'Paint', label: 'Paint', group: 'productivity', removable: true, steps: [cap('Microsoft.Windows.MSPaint', W10), pkg('Microsoft.Paint', W11)] },
  { id: 'Notepad', label: 'Notepad (modern)', group: 'productivity', removable: true, steps: [pkg('Microsoft.WindowsNotepad', W11), custom(W11)], custom: 'notepad' },
  { id: 'WindowsTerminal', label: 'Windows Terminal', group: 'productivity', removable: true, steps: [pkg('Microsoft.WindowsTerminal', W11)] },
  { id: 'DevHome', label: 'Dev Home', group: 'productivity', removable: true, steps: [custom('Windows 11 23H2'), pkg('Microsoft.Windows.DevHome', 'Windows 11 24H2')], custom: 'devHome', note: 'Retired by Microsoft in 2025; often absent on current media.' },
  { id: 'Office365', label: 'Microsoft 365 (Office) hub', group: 'productivity', removable: true, steps: [pkg('Microsoft.MicrosoftOfficeHub', W10, W11)] },
  { id: 'Family', label: 'Microsoft Family', group: 'apps', removable: true, steps: [pkg('MicrosoftCorporationII.MicrosoftFamily', W11)] },
  { id: 'BingSearch', label: 'Bing Search', group: 'apps', removable: true, steps: [pkg('Microsoft.BingSearch', 'Windows 11 24H2')] },
  { id: 'Copilot', label: 'Copilot app', group: 'apps', removable: true, steps: [pkg('Microsoft.Copilot', 'Windows 11 25H2'), custom(W11)], custom: 'copilot', note: 'Privacy section separately applies the Copilot policy.' },

  // Communication & cloud
  { id: 'MailCalendar', label: 'Mail & Calendar', group: 'communication', removable: true, steps: [pkg('microsoft.windowscommunicationsapps', W10, W11)], note: 'Retired; replaced by Outlook for Windows on current builds.' },
  { id: 'Outlook', label: 'Outlook for Windows', group: 'communication', removable: true, steps: [custom('Windows 11 23H2'), pkg('Microsoft.OutlookForWindows', 'Windows 11 24H2')], custom: 'outlook' },
  { id: 'People', label: 'People', group: 'communication', removable: true, steps: [pkg('Microsoft.People', W10, W11)] },
  { id: 'Teams', label: 'Teams (personal)', group: 'communication', removable: true, steps: [custom(W11), pkg('MicrosoftTeams', 'Windows 11 23H2'), pkg('MSTeams', 'Windows 11 24H2')], custom: 'teams' },
  { id: 'YourPhone', label: 'Phone Link', group: 'communication', removable: true, steps: [pkg('Microsoft.YourPhone', W10, W11)] },
  { id: 'QuickAssist', label: 'Quick Assist', group: 'communication', removable: true, steps: [cap('App.Support.QuickAssist', W10), pkg('MicrosoftCorporationII.QuickAssist', W11)] },
  { id: 'OneDrive', label: 'OneDrive', group: 'communication', removable: true, steps: [custom(W10, W11)], custom: 'oneDrive', note: 'Deletes OneDriveSetup.exe and the default-user Run entry, so new users get no setup prompt.' },

  // Xbox & gaming (upstream "Xbox Apps" split per owner decision)
  { id: 'XboxApp', label: 'Xbox app & gaming services', group: 'xbox', removable: true, steps: [pkg('Microsoft.GamingApp', W11), pkg('Microsoft.XboxApp', W10), pkg('Microsoft.Xbox.TCUI', W10, W11)], note: 'Gaming Services itself is installed from the Store later and is not provisioned in the image.' },
  { id: 'XboxGameBar', label: 'Xbox Game Bar', group: 'xbox', removable: true, steps: [pkg('Microsoft.XboxGamingOverlay', W10, W11), pkg('Microsoft.XboxGameOverlay', W10, W11), pkg('Microsoft.XboxSpeechToTextOverlay', W10, W11)], custom: 'gameDvr' },
  { id: 'XboxIdentityProvider', label: 'Xbox Identity Provider', group: 'xbox', removable: true, steps: [pkg('Microsoft.XboxIdentityProvider', W10, W11)] },
  { id: 'GameAssist', label: 'Game Assist', group: 'xbox', removable: true, steps: [pkg('Microsoft.Edge.GameAssist', 'Windows 11 27902.1000')] },

  // System components & features
  { id: 'WindowsBackup', label: 'Windows Backup', group: 'system', removable: false, steps: [], note: 'Part of the Windows shell package; there is no supported per-app removal, so only Keep / Leave untouched are offered.' },
  { id: 'Cortana', label: 'Cortana', group: 'system', removable: true, steps: [pkg('Microsoft.549981C3F5F10', W10, W11)], note: 'Retired; normally absent on current Windows 11 media.' },
  { id: 'Recall', label: 'Recall (optional feature)', group: 'system', removable: true, steps: [feat('Recall', 'Windows 11 24H2')], note: 'Privacy section separately applies the Recall snapshot policy.' },
  { id: 'InternetExplorer', label: 'Internet Explorer mode components', group: 'system', removable: true, steps: [cap('Browser.InternetExplorer', W10, W11), custom(W10, W11)], custom: 'internetExplorer' },
  { id: 'WindowsMediaPlayer', label: 'Windows Media Player (legacy)', group: 'media', removable: true, steps: [cap('Media.WindowsMediaPlayer', W10, W11)] },
  { id: 'MediaFeatures', label: 'Media Features', group: 'media', removable: true, steps: [feat('MediaPlayback', W10, W11)] },
  { id: 'WordPad', label: 'WordPad', group: 'legacy', removable: true, steps: [cap('Microsoft.Windows.WordPad', W10, W11)] },
  { id: 'NotepadClassic', label: 'Notepad (classic)', group: 'system', removable: true, steps: [cap('Microsoft.Windows.Notepad', W10), cap('Microsoft.Windows.Notepad.System', W11)] },
  { id: 'StepsRecorder', label: 'Steps Recorder', group: 'legacy', removable: true, steps: [cap('App.StepsRecorder', W10, W11)] },
  { id: 'MathInputPanel', label: 'Math Input Panel', group: 'system', removable: true, steps: [cap('MathRecognizer', W10, W11)] },
  { id: 'PowerShellISE', label: 'PowerShell ISE', group: 'system', removable: true, steps: [cap('Microsoft.Windows.PowerShell.ISE', W10, W11)] },
  { id: 'PowerShell2', label: 'PowerShell 2.0', group: 'system', removable: true, steps: [feat('MicrosoftWindowsPowerShellV2Root', W10, W11)] },
  { id: 'OpenSSHClient', label: 'OpenSSH Client', group: 'system', removable: true, steps: [cap('OpenSSH.Client', W10, W11)] },
  { id: 'RdpClient', label: 'Remote Desktop Connection client', group: 'system', removable: true, steps: [feat('Microsoft-RemoteDesktopConnection', W10, W11)] },
  { id: 'WindowsHello', label: 'Facial recognition (Windows Hello)', group: 'system', removable: true, steps: [cap('Hello.Face.18967', W10), cap('Hello.Face.Migration.18967', W10), cap('Hello.Face.20134', W11)] },
  { id: 'Handwriting', label: 'Handwriting (all languages)', group: 'system', removable: true, steps: [cap('Language.Handwriting', W10, W11)] },
  { id: 'Speech', label: 'Speech (all languages)', group: 'system', removable: true, steps: [cap('Language.Speech', W10, W11), cap('Language.TextToSpeech', W10, W11)] },
  { id: 'OneSync', label: 'OneSync', group: 'system', removable: true, steps: [cap('OneCoreUAP.OneSync', W10, W11)] },

  // Legacy (Windows 10–era packages; tolerant no-op on Windows 11)
  { id: '3DViewer', label: '3D Viewer', group: 'legacy', removable: true, steps: [pkg('Microsoft.Microsoft3DViewer', W10)] },
  { id: 'Paint3D', label: 'Paint 3D', group: 'legacy', removable: true, steps: [pkg('Microsoft.MSPaint', W10)] },
  { id: 'Skype', label: 'Skype', group: 'legacy', removable: true, steps: [pkg('Microsoft.SkypeApp', W10)] },
  { id: 'OneNote', label: 'OneNote for Windows 10', group: 'legacy', removable: true, steps: [pkg('Microsoft.Office.OneNote', W10)] },
  { id: 'MixedReality', label: 'Mixed Reality Portal', group: 'legacy', removable: true, steps: [pkg('Microsoft.MixedReality.Portal', W10)] },
  { id: 'Wallet', label: 'Microsoft Pay / Wallet', group: 'legacy', removable: true, steps: [pkg('Microsoft.Wallet', W10)] },
];

export const BLOATWARE_BY_ID: ReadonlyMap<string, BloatwareEntry> = new Map(BLOATWARE.map((b) => [b.id, b]));

/** True when any step targets a Windows 11 release. Windows 10–only entries are flagged in the UI. */
export function appliesToWindows11(entry: BloatwareEntry): boolean {
  return entry.steps.some((s) => s.appliesTo.some((a) => a.startsWith('Windows 11')));
}
