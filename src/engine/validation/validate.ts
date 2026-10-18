import { ProfileSchema, type Profile } from '../schema/profile';
import { findInvalidXmlChar } from '../xml/serialize';
import { VALIDATORS } from '../../features';
import type { Issue } from './issues';

/** Every string anywhere in the profile must be representable in XML 1.0. */
function checkCharacters(value: unknown, path: string, issues: Issue[]): void {
  if (typeof value === 'string') {
    const cp = findInvalidXmlChar(value);
    if (cp !== undefined) {
      issues.push({
        severity: 'error',
        path,
        message: `Contains character U+${cp.toString(16).toUpperCase().padStart(4, '0')}, which cannot appear in an XML answer file.`,
      });
    }
  } else if (Array.isArray(value)) {
    value.forEach((v, i) => checkCharacters(v, `${path}.${i}`, issues));
  } else if (value && typeof value === 'object') {
    for (const [k, v] of Object.entries(value)) checkCharacters(v, path ? `${path}.${k}` : k, issues);
  }
}

/**
 * Full validation: schema (types, enums, unknown keys), XML-representable characters and
 * cross-field rules from every feature. Errors block generation; warnings do not.
 */
export function validateProfile(input: unknown): { profile?: Profile; issues: Issue[] } {
  const parsed = ProfileSchema.safeParse(input);
  if (!parsed.success) {
    return {
      issues: parsed.error.issues.map((i) => ({ severity: 'error' as const, path: i.path.join('.'), message: i.message })),
    };
  }
  const issues: Issue[] = [];
  checkCharacters(parsed.data, '', issues);
  for (const v of VALIDATORS) v(parsed.data, issues);
  return { profile: parsed.data, issues };
}
