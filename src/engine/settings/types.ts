import type { Profile } from '../schema/profile';

/** Where a setting takes effect. `deferred` = recorded only; `none` = no generated action. */
export type Stage =
  | 'windowsPE'
  | 'specialize'
  | 'oobeSystem'
  | 'defaultUser'
  | 'userOnce'
  | 'firstLogon'
  | 'deferred'
  | 'none';

export type SectionId =
  | 'setup'
  | 'accounts'
  | 'security'
  | 'privacy'
  | 'updates'
  | 'windowsUpdate'
  | 'applications'
  | 'additionalSoftware'
  | 'system'
  | 'explorer'
  | 'taskbar'
  | 'desktop'
  | 'start'
  | 'personalization'
  | 'bloatware'
  | 'virtualization'
  | 'wifi'
  | 'scripts'
  | 'advancedXml'
  | 'output'
  | 'deferred';

export type Control = 'checkbox' | 'radio' | 'select' | 'text' | 'password' | 'number' | 'textarea' | 'custom';

export interface Choice {
  value: string;
  label: string;
  description?: string;
}

/**
 * Declarative description of one profile setting. The UI, the settings-mapping documentation and
 * the coverage tests are all driven from these definitions. Default values live only in
 * `profiles/owner-default.json`.
 */
export interface SettingDef {
  /** Dotted path into {@link Profile}. */
  path: string;
  section: SectionId;
  label: string;
  control: Control;
  choices?: Choice[] | (() => Choice[]);
  description: string;
  /** Windows versions/editions where the mechanism is known to apply. */
  applicability: string;
  /** Risk or caveat shown next to the control. */
  risk?: string;
  stages: Stage[];
  /** Traceable mapping: XML element path, registry value, policy, or command. */
  mapping: string;
  advanced: boolean;
  /** Hide the control unless this returns true (values are kept either way). */
  visibleWhen?: (p: Profile) => boolean;
  placeholder?: string;
  /** Validation status of the mechanism itself. */
  verification?: 'upstream-tested' | 'documented' | 'unverified';
}

export interface SectionDef {
  id: SectionId;
  title: string;
  intro?: string;
}
