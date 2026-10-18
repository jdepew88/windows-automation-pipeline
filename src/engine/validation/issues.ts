export type Severity = 'error' | 'warning';

export interface Issue {
  severity: Severity;
  /** Dotted profile path (e.g. `accounts.personName`) or `''` for document-level issues. */
  path: string;
  message: string;
}

export const hasErrors = (issues: readonly Issue[]): boolean => issues.some((i) => i.severity === 'error');
