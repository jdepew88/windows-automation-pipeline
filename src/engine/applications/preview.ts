import type { AdditionalItem, ApplicationsSelection } from '../schema/applications';
import type { CatalogCategory, InstallMethod } from './catalog';
import { UNIVERSAL_PROFILES } from './builtin';
import { packageKey } from './ids';
import { ADDED, REQUIRED, allProfiles, expandProfile, installable, manualItems, resolveSelection, type PlannedPackage, type SelectionResult } from './selection';
import { isReviewed } from './index';

/**
 * Read-only views of the application selection for Quick Deployment: what one profile contributes
 * and what the whole deployment will install. Both are computed by `resolveSelection`, the same
 * function that produces applications-config.json, so a preview can never disagree with the package.
 */

export type AppKind = 'automatic' | 'manual' | 'unresolved';

export interface AppSummaryItem {
  key: string;
  displayName: string;
  /** Catalog id (for the logo); absent for packages added by identifier. */
  catalogId?: string;
  category?: CatalogCategory;
  kind: AppKind;
  method: InstallMethod;
  /** Why it is in the plan: "Core Essentials, Gaming", "Added by you", "Required by Docker Desktop". */
  origin: string;
}

const kindOf = (x: PlannedPackage): AppKind => (x.resolution === 'manual' ? 'manual' : x.resolution === 'unresolved' ? 'unresolved' : 'automatic');

const nameOf = (sel: Pick<ApplicationsSelection, 'profiles'>, id: string) => allProfiles(sel).find((p) => p.id === id)?.name ?? id;

function originText(sel: ApplicationsSelection, x: PlannedPackage, r: SelectionResult): string {
  const profiles = x.origins.filter((o) => o !== ADDED && o !== REQUIRED);
  const ordered = [...profiles.filter((o) => UNIVERSAL_PROFILES.includes(o)), ...profiles.filter((o) => !UNIVERSAL_PROFILES.includes(o))];
  const parts: string[] = [];
  if (ordered.length) parts.push(ordered.map((o) => nameOf(sel, o)).join(', '));
  const via = sel.addedWith?.[x.key];
  if (x.origins.includes(ADDED)) parts.push(via?.length ? `Recommended by ${via.map((o) => nameOf(sel, o)).join(', ')}, ticked by you` : 'Added by you');
  if (x.origins.includes(REQUIRED)) parts.push(`Required by ${x.requiredBy.map((k) => r.packages.find((p) => p.key === k)?.displayName ?? k).join(', ')}`);
  return parts.join(' · ');
}

const item = (sel: ApplicationsSelection, x: PlannedPackage, r: SelectionResult): AppSummaryItem => ({
  key: x.key,
  displayName: x.displayName,
  catalogId: x.catalog?.id,
  category: x.catalog?.category,
  kind: kindOf(x),
  method: x.method,
  origin: originText(sel, x, r),
});

export interface EffectiveApps {
  /** False when application provisioning is off: nothing is installed whatever is ticked. */
  enabled: boolean;
  automatic: AppSummaryItem[];
  manual: AppSummaryItem[];
  /** Selected but impossible to install (invalid identifier); generation reports them. */
  unresolved: AppSummaryItem[];
  /** Phase 9: Additional Software entries (installers WinGet does not cover), manual unless reviewed. */
  additional: AppSummaryItem[];
  /** Distinct selected applications (each counted once, however many profiles select it), plus Additional Software. */
  total: number;
}

/** An Additional Software entry as the application engine treats it (see applicationsConfig). */
const additionalItem = (i: AdditionalItem): AppSummaryItem => {
  const automatic = i.execution === 'automatic' && isReviewed(i);
  return {
    key: `additional:${i.id.toLowerCase()}`,
    displayName: i.name || i.fileName || 'Unnamed installer',
    kind: automatic ? 'automatic' : 'manual',
    method: automatic ? 'vendor' : 'manual',
    origin: automatic ? `Additional Software: ${i.fileName}, checksum and signature checked` : `Additional Software: manual follow-up${i.publisher ? ` (${i.publisher})` : ''}`,
  };
};

/** The applications this deployment installs or lists for follow-up, after every profile, addition and removal. */
export function effectiveApps(sel: ApplicationsSelection, enabled = true, r: SelectionResult = resolveSelection(sel), additionalSoftware: readonly AdditionalItem[] = []): EffectiveApps {
  if (!enabled) return { enabled, automatic: [], manual: [], unresolved: [], additional: [], total: 0 };
  const automatic = installable(r).map((x) => item(sel, x, r));
  const manual = manualItems(r).map((x) => item(sel, x, r));
  const unresolved = r.packages.filter((x) => x.resolution === 'unresolved').map((x) => item(sel, x, r));
  const additional = additionalSoftware.map(additionalItem);
  return { enabled, automatic, manual, unresolved, additional, total: r.packages.length + additional.length };
}

/** How one app of a profile preview relates to this deployment. */
export type PreviewStatus = 'included' | 'excluded' | 'wouldAdd';

export interface ProfilePreviewItem extends AppSummaryItem {
  /** direct: the profile's own default; inherited: from a profile it includes; device: from its saved device answers; dependency: needed by one of them. */
  via: 'direct' | 'inherited' | 'device' | 'dependency';
  /** The included profile, device profile, or the apps that need it. */
  viaText: string;
  status: PreviewStatus;
  /** For "excluded": who left it out of this deployment. */
  excludedBy?: string;
  /** Other active profiles of this deployment that also select it (shared apps are installed once). */
  alsoIn: string[];
}

export interface ProfilePreview {
  id: string;
  name: string;
  builtin: boolean;
  selected: boolean;
  items: ProfilePreviewItem[];
  /** Apps the profile includes and this deployment installs or lists (not excluded). */
  count: number;
  /** Recommendations shown unticked in Applications; not part of the profile's defaults. */
  optional: number;
  /** Apps a saved profile leaves out of the profiles it includes. */
  leftOut: string[];
}

const NO_DEVICES = { phone: 'none', ipad: false, extraIphone: false, androidTablet: false } as const;

/**
 * What one profile contributes, as `resolveSelection` computes it for that profile alone (its
 * defaults, the profiles it includes, a saved profile's device answers and exclusions, and the
 * dependencies), annotated with this deployment's state: ticking or unticking an app here is never
 * implied, and an app this deployment leaves out is shown as left out.
 */
export function profilePreview(sel: ApplicationsSelection, id: string, r: SelectionResult = resolveSelection(sel)): ProfilePreview | undefined {
  const profile = allProfiles(sel).find((p) => p.id === id);
  if (!profile) return undefined;
  const alone = resolveSelection({ ...sel, selectedProfiles: [id], devices: { ...NO_DEVICES }, added: [], removed: [] });
  const selected = sel.selectedProfiles.includes(id);
  // This deployment as it would be with the profile ticked (identical to `r` when it already is).
  const withIt = selected ? r : resolveSelection({ ...sel, selectedProfiles: [...sel.selectedProfiles, id] });
  const current = new Map(r.packages.map((p) => [p.key, p]));
  const after = new Set(withIt.packages.map((p) => p.key));
  const removed = new Map(withIt.removed.map((p) => [p.key, p]));
  const own = new Set(profile.packages.map(packageKey));
  const parents = profile.inherits.map((pid) => ({ name: nameOf(sel, pid), keys: new Set(expandProfile(pid, allProfiles(sel)).map(packageKey)) }));
  const items = alone.packages.map((x): ProfilePreviewItem => {
    const sources = x.origins.filter((o) => o !== ADDED && o !== REQUIRED);
    const devices = sources.filter((o) => alone.deviceProfiles.includes(o));
    const via: ProfilePreviewItem['via'] = own.has(x.key) ? 'direct' : sources.includes(id) ? 'inherited' : devices.length ? 'device' : 'dependency';
    const viaText =
      via === 'direct'
        ? ''
        : via === 'inherited'
          ? `From ${parents.filter((q) => q.keys.has(x.key)).map((q) => q.name).join(', ') || 'an included profile'}`
          : via === 'device'
            ? `From its saved device answers (${devices.map((o) => nameOf(sel, o)).join(', ')})`
            : `Required by ${x.requiredBy.map((k) => alone.packages.find((q) => q.key === k)?.displayName ?? k).join(', ')}`;
    const now = current.get(x.key);
    const rem = removed.get(x.key);
    const status: PreviewStatus = rem ? 'excluded' : now ? 'included' : after.has(x.key) ? 'wouldAdd' : 'excluded';
    const alsoIn = now ? now.origins.filter((o) => o !== id && o !== ADDED && o !== REQUIRED).map((o) => nameOf(sel, o)) : [];
    return {
      ...item(sel, x, alone),
      via,
      viaText,
      status,
      excludedBy: status === 'excluded' ? (rem?.removedBy && rem.removedBy !== 'user' ? `Left out by saved profile "${nameOf(sel, rem.removedBy)}"` : 'Unticked in this deployment') : undefined,
      alsoIn,
    };
  });
  const viaOrder = { direct: 0, inherited: 1, device: 2, dependency: 3 };
  items.sort((a, b) => viaOrder[a.via] - viaOrder[b.via]);
  return {
    id,
    name: profile.name,
    builtin: profile.builtin,
    selected,
    items,
    count: items.filter((x) => x.status !== 'excluded').length,
    optional: alone.recommended.length,
    leftOut: alone.removed.map((x) => x.displayName),
  };
}

export interface ChecklistItem extends AppSummaryItem {
  /** Ticked: installed (or listed for follow-up). Unticked: an active profile selects it, but this deployment leaves it out. */
  selected: boolean;
  /** For unticked items: who left it out. */
  excludedBy?: string;
  /** Selected items that other selected apps need (unticking them is allowed, with a warning). */
  requiredBy: string[];
}

export interface DeploymentChecklist {
  /** Every app the active profiles and individual changes bring in, each once, sorted by name so ticking never moves a row. */
  items: ChecklistItem[];
  /** Ticked items: exactly `resolveSelection(sel).packages`. */
  selected: number;
  /** Recommendations of the active profiles, ticked in the Applications step. */
  recommended: number;
}

/**
 * Step 2's per-application list: what is selected (the generated package installs exactly these)
 * and what an active profile would select but this deployment leaves out, so it can be ticked again.
 */
export function deploymentChecklist(sel: ApplicationsSelection, r: SelectionResult = resolveSelection(sel)): DeploymentChecklist {
  const name = (k: string) => r.packages.find((p) => p.key === k)?.displayName ?? k;
  const items: ChecklistItem[] = [
    ...r.packages.map((x) => ({ ...item(sel, x, r), selected: true, requiredBy: x.requiredBy.filter((k) => r.packages.some((p) => p.key === k)).map(name) })),
    ...r.removed.map((x) => ({
      ...item(sel, x, r),
      selected: false,
      excludedBy: x.removedBy && x.removedBy !== 'user' ? `Left out by saved profile "${nameOf(sel, x.removedBy)}"` : 'Unticked by you',
      requiredBy: [],
    })),
  ];
  items.sort((a, b) => a.displayName.localeCompare(b.displayName, 'en', { sensitivity: 'base' }) || a.key.localeCompare(b.key));
  return { items, selected: r.packages.length, recommended: r.recommended.length };
}
