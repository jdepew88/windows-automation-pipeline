/**
 * Reference data copied from upstream `resource/*.json` (cschneegans/unattend-generator @ 27237f82,
 * MIT License; see docs/upstream-attribution.md). Only re-formatted; contents unchanged.
 */
import imageLanguages from './upstream/ImageLanguage.json';
import userLocales from './upstream/UserLocale.json';
import keyboards from './upstream/KeyboardIdentifier.json';
import geoIds from './upstream/GeoId.json';
import timeOffsets from './upstream/TimeOffset.json';
import editions from './upstream/WindowsEdition.json';
import desktopIcons from './upstream/DesktopIcon.json';
import startFolders from './upstream/StartFolder.json';
import components from './upstream/Component.json';

export interface ImageLanguage {
  Id: string;
  DisplayName: string;
}
export interface UserLocale {
  Id: string;
  DisplayName: string;
  LCID: string;
  KeyboardLayout: string | null;
  GeoLocation: string | null;
}
export interface Keyboard {
  Id: string;
  DisplayName: string;
  Type: 'Keyboard' | 'IME';
}
export interface Keyed {
  Id: string;
  DisplayName: string;
}
export interface WindowsEdition {
  Id: string;
  DisplayName: string;
  ProductKey: string;
  Visible: boolean;
}
export interface DesktopIcon {
  Id: string;
  DisplayName: string;
  Guid: string;
}
export interface StartFolder {
  /** DisplayName without spaces, as upstream derives it. */
  Id: string;
  DisplayName: string;
  /** Base64 of the 16-byte folder GUID used in the VisiblePlaces value. */
  Bytes: string;
}
export interface ComponentInfo {
  Id: string;
  Passes: string[];
}

export const IMAGE_LANGUAGES = imageLanguages as ImageLanguage[];
export const USER_LOCALES = userLocales as UserLocale[];
export const KEYBOARDS = keyboards as Keyboard[];
export const GEO_LOCATIONS = geoIds as Keyed[];
export const TIME_ZONES = timeOffsets as Keyed[];
export const EDITIONS = editions as WindowsEdition[];
export const DESKTOP_ICONS = desktopIcons as DesktopIcon[];
export const START_FOLDERS: StartFolder[] = (startFolders as { DisplayName: string; Bytes: string }[]).map((f) => ({
  Id: f.DisplayName.replace(/ /g, ''),
  DisplayName: f.DisplayName,
  Bytes: f.Bytes,
}));
export const COMPONENTS = components as ComponentInfo[];

function index<T extends { Id: string }>(items: T[]): ReadonlyMap<string, T> {
  return new Map(items.map((i) => [i.Id.toLowerCase(), i]));
}

const maps = {
  imageLanguage: index(IMAGE_LANGUAGES),
  userLocale: index(USER_LOCALES),
  keyboard: index(KEYBOARDS),
  geo: index(GEO_LOCATIONS),
  timeZone: index(TIME_ZONES),
  edition: index(EDITIONS),
  component: index(COMPONENTS),
};

export const lookup = {
  imageLanguage: (id: string) => maps.imageLanguage.get(id.toLowerCase()),
  userLocale: (id: string) => maps.userLocale.get(id.toLowerCase()),
  keyboard: (id: string) => maps.keyboard.get(id.toLowerCase()),
  geo: (id: string) => maps.geo.get(id.toLowerCase()),
  timeZone: (id: string) => maps.timeZone.get(id.toLowerCase()),
  edition: (id: string) => maps.edition.get(id.toLowerCase()),
  /** Case-sensitive match is required in the answer file; this lookup is for diagnostics. */
  component: (id: string) => maps.component.get(id.toLowerCase()),
};
