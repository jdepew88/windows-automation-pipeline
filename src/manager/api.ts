import type { Action, AgentState, OperationRecord } from '../engine/manager';

/**
 * The page's only channel to the local agent (AppManager.ps1). Every call carries the session
 * token the agent put after "#" in the address it opened; the token is moved to sessionStorage
 * and removed from the address bar. Without an agent (the page opened from the website) every
 * call fails with `NotConnected` and the page stays a read-only catalog.
 */

const TOKEN_KEY = 'wdb.manager.token';

export class NotConnected extends Error {}
export class Unauthorized extends Error {}

function readToken(): string {
  const fromHash = /^#([0-9a-f]{64})$/.exec(location.hash)?.[1];
  try {
    if (fromHash) {
      sessionStorage.setItem(TOKEN_KEY, fromHash);
      history.replaceState(null, '', location.pathname + location.search);
      return fromHash;
    }
    return sessionStorage.getItem(TOKEN_KEY) ?? '';
  } catch {
    return fromHash ?? '';
  }
}

const token = readToken();
export const hasToken = () => !!token;

async function call<T>(method: string, path: string, body?: unknown): Promise<T> {
  if (!token) throw new NotConnected('No session key');
  let res: Response;
  try {
    res = await fetch(path, {
      method,
      headers: { 'X-WDB-Token': token, ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
      body: body === undefined ? undefined : JSON.stringify(body),
      cache: 'no-store',
      credentials: 'omit',
    });
  } catch {
    throw new NotConnected('The Application Manager is not running');
  }
  if (res.status === 401) throw new Unauthorized('The session key was not accepted');
  const type = res.headers.get('content-type') ?? '';
  if (!type.includes('application/json')) {
    if (!res.ok) throw new NotConnected(`HTTP ${res.status}`);
    return (await res.text()) as T;
  }
  const json = (await res.json()) as T & { error?: string };
  if (!res.ok) throw new Error(json.error ?? `HTTP ${res.status}`);
  return json;
}

export interface PackageSpec {
  id: string;
  source: 'winget' | 'msstore';
  name: string;
  catalogId?: string;
  scope?: '' | 'user' | 'machine';
  version?: string;
  installedVersion?: string;
  acceptPackageAgreements?: boolean;
  confirmCaution?: boolean;
  attempt?: number;
  retryOf?: string;
}

export const api = {
  state: () => call<AgentState>('GET', '/api/state'),
  scan: (kind: 'inventory' | 'updates') => call<{ ok: boolean }>('POST', '/api/scan', { kind }),
  validate: (items: Pick<PackageSpec, 'id' | 'source'>[]) => call<{ ok: boolean }>('POST', '/api/validate', { items: items.map((i) => ({ id: i.id, source: i.source, scope: '', version: '' })) }),
  operate: (action: Action, items: PackageSpec[], confirm = '') =>
    call<{ ok: boolean; batchId: string; dryRun: boolean; commands: string[] }>('POST', '/api/operations', {
      action,
      confirm,
      items: items.map((i) => ({ scope: '', version: '', ...i })),
    }),
  cancel: () => call<{ ok: boolean; cancelled: number }>('POST', '/api/cancel'),
  settings: (s: { dryRun?: boolean; acceptSourceAgreements?: boolean }) => call<{ ok: boolean }>('POST', '/api/settings', s),
  loadProfiles: () => call<{ profiles: unknown }>('GET', '/api/profiles'),
  saveProfiles: (doc: unknown) => call<{ ok: boolean }>('PUT', '/api/profiles', doc),
  history: () => call<{ records: OperationRecord[] }>('GET', '/api/history'),
  report: (format: 'csv' | 'html' | 'json') => call<string | object>('GET', `/api/report?format=${format}`),
};
