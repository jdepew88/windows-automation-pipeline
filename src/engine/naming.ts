/**
 * Deterministic derivation of the local username and computer name from one person's name.
 *
 * Username rules follow upstream `Account.ValidateUsername` (max 20 chars, no `/\[]:;|=,+*?<>"%`, no
 * trailing period, not a built-in account name). Computer-name rules follow upstream
 * `CustomComputerNameSettings` (max 15 chars, no whitespace or listed punctuation, not all digits).
 * The derived computer name uses only letters, digits and hyphens for DNS/NetBIOS compatibility.
 */

export const COMPUTER_SUFFIX = '-Computer';
export const MAX_COMPUTER_NAME = 15;
export const MAX_USERNAME = 20;

const RESERVED_USERNAMES = [
  'administrator',
  'guest',
  'defaultaccount',
  'system',
  'network service',
  'local service',
  'none',
  'wdagutilityaccount',
];

const USERNAME_FORBIDDEN = /[/\\[\]:;|=,+*?<>"%]/;
const COMPUTER_FORBIDDEN = /[{|}~[\\\]^':;<=>?@!"#$%`()+/.,*&]/;

/** Strips diacritics (é → e) and other combining marks; collapses whitespace. */
export function toAsciiBase(name: string): string {
  return name
    .normalize('NFKD')
    .replace(/\p{M}+/gu, '')
    .replace(/\s+/g, ' ')
    .trim();
}

export function deriveDisplayName(personName: string): string {
  return personName.replace(/\s+/g, ' ').trim();
}

export function deriveUsername(personName: string): string {
  let base = toAsciiBase(personName)
    .replace(/[^A-Za-z0-9._-]/g, '')
    .replace(/^\.+/, '')
    .slice(0, MAX_USERNAME)
    .replace(/\.+$/, '');
  if (base && RESERVED_USERNAMES.includes(base.toLowerCase())) {
    base = `${base.slice(0, MAX_USERNAME - 1)}1`;
  }
  return base;
}

export function deriveComputerName(personName: string): string {
  const maxBase = MAX_COMPUTER_NAME - COMPUTER_SUFFIX.length; // 6
  const base = toAsciiBase(personName)
    .replace(/[^A-Za-z0-9-]/g, '')
    .replace(/-+/g, '-')
    .replace(/^-+/, '')
    .slice(0, maxBase)
    .replace(/-+$/, '');
  return base ? `${base}${COMPUTER_SUFFIX}` : '';
}

/** Returns a problem description, or undefined when the username is acceptable. */
export function usernameProblem(name: string): string | undefined {
  if (name.trim() === '') return 'Username is empty. Enter a name that contains letters or digits.';
  if (name !== name.trim()) return 'Username must not start or end with spaces.';
  if (name.length > MAX_USERNAME) return `Username must be at most ${MAX_USERNAME} characters.`;
  if (USERNAME_FORBIDDEN.test(name)) return 'Username must not contain / \\ [ ] : ; | = , + * ? < > " %.';
  if (name.endsWith('.')) return 'Username must not end with a period.';
  if (RESERVED_USERNAMES.includes(name.toLowerCase())) return `"${name}" is a built-in Windows account name.`;
  return undefined;
}

export function computerNameProblem(name: string): string | undefined {
  if (name.trim() === '') return 'Computer name is empty.';
  if (name.length > MAX_COMPUTER_NAME) return `Computer name must be at most ${MAX_COMPUTER_NAME} characters.`;
  if (/\s/.test(name)) return 'Computer name must not contain whitespace.';
  if (/^[0-9]+$/.test(name)) return 'Computer name must not consist of digits only.';
  if (COMPUTER_FORBIDDEN.test(name)) return 'Computer name contains a character Windows does not allow.';
  if (/[^\x21-\x7e]/.test(name)) return 'Computer name must use ASCII letters, digits and hyphens.';
  return undefined;
}

export interface Identity {
  displayName: string;
  username: string;
  /** Undefined when Windows should generate a random name. */
  computerName?: string;
}

export function resolveIdentity(a: {
  personName: string;
  usernameMode: 'derived' | 'custom';
  customUsername: string;
  computerNameMode: 'derived' | 'custom' | 'random';
  customComputerName: string;
}): Identity {
  const displayName = deriveDisplayName(a.personName);
  const username = a.usernameMode === 'custom' ? a.customUsername : deriveUsername(a.personName);
  const computerName =
    a.computerNameMode === 'random' ? undefined : a.computerNameMode === 'custom' ? a.customComputerName : deriveComputerName(a.personName);
  return { displayName: displayName || username, username, computerName };
}
