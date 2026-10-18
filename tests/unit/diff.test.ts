import { describe, expect, it } from 'vitest';
import { ownerDefaults } from '../../src/engine/profiles';
import { diffProfiles, displayValue } from '../../src/engine/profiles/diff';

describe('profile diff (Advanced review)', () => {
  it('is empty for owner defaults and lists leaf changes', () => {
    const p = ownerDefaults();
    expect(diffProfiles(ownerDefaults(), p)).toEqual([]);
    p.taskbar.search = 'box';
    p.bloatware.Calculator = 'remove';
    p.scripts.firstLogon.push({ id: 'a', name: '', type: 'ps1', enabled: true, content: 'x' });
    expect(diffProfiles(ownerDefaults(), p).map((c) => c.path)).toEqual(['bloatware.Calculator', 'scripts.firstLogon', 'taskbar.search']);
  });

  it('masks secrets in display', () => {
    expect(displayValue('accounts.password', 'hunter2')).toBe('••••••');
    expect(displayValue('wifi.password', '')).toBe('(empty)');
    expect(displayValue('taskbar.search', 'icon')).toBe('icon');
  });
});
