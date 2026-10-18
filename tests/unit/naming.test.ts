import { describe, expect, it } from 'vitest';
import { computerNameProblem, deriveComputerName, deriveUsername, usernameProblem } from '../../src/engine/naming';

describe('username derivation', () => {
  it.each([
    ['Alex', 'Alex'],
    ['  Alex  ', 'Alex'],
    ['Mary Ann', 'MaryAnn'],
    ['Zoë', 'Zoe'],
    ['José Álvarez-Núñez', 'JoseAlvarez-Nunez'],
    ["O'Brien", 'OBrien'],
    ['A/B\\C[D]:E;F|G=H,I+J*K?L<M>N"O%P', 'ABCDEFGHIJKLMNOP'],
    ['Christopher Alexander Longname', 'ChristopherAlexander'],
    ['Administrator', 'Administrator1'],
    ['guest', 'guest1'],
    ['dot.', 'dot'],
    ['...lead', 'lead'],
    ['李雷', ''],
  ])('%j → %j', (input, expected) => {
    expect(deriveUsername(input)).toBe(expected);
  });

  it('produces valid usernames whenever it produces anything', () => {
    for (const n of ['Alex', 'Mary Ann', 'Administrator', 'x'.repeat(40), 'a.b.c.', 'Ünïcödé Nämé']) {
      const u = deriveUsername(n);
      if (u) expect(usernameProblem(u)).toBeUndefined();
    }
  });

  it('is deterministic', () => {
    expect(deriveUsername('Zoë Smith')).toBe(deriveUsername('Zoë Smith'));
  });
});

describe('computer name derivation', () => {
  it.each([
    ['Alex', 'Alex-Computer'],
    ['Joe', 'Joe-Computer'],
    ['Christopher', 'Christ-Computer'],
    ['Mary Ann', 'MaryAn-Computer'],
    ['Zoë', 'Zoe-Computer'],
    ['Abcde-fgh', 'Abcde-Computer'],
    ['-Al', 'Al-Computer'],
    ['123', '123-Computer'],
    ['李雷', ''],
    ['', ''],
  ])('%j → %j', (input, expected) => {
    expect(deriveComputerName(input)).toBe(expected);
  });

  it('always fits 15 characters, keeps "-Computer" and stays valid', () => {
    for (const n of ['A', 'Alexandra', 'Bartholomew Jones', 'X-Y-Z-W', '1234567890']) {
      const c = deriveComputerName(n);
      expect(c.length).toBeLessThanOrEqual(15);
      expect(c.endsWith('-Computer')).toBe(true);
      expect(computerNameProblem(c)).toBeUndefined();
    }
  });
});

describe('name validation', () => {
  it('rejects bad usernames', () => {
    expect(usernameProblem('')).toMatch(/empty/);
    expect(usernameProblem('a'.repeat(21))).toMatch(/20/);
    expect(usernameProblem('a:b')).toMatch(/contain/);
    expect(usernameProblem('Administrator')).toMatch(/built-in/);
    expect(usernameProblem('end.')).toMatch(/period/);
  });

  it('rejects bad computer names', () => {
    expect(computerNameProblem('1234')).toMatch(/digits/);
    expect(computerNameProblem('has space')).toMatch(/whitespace/);
    expect(computerNameProblem('way-too-long-name')).toMatch(/15/);
    expect(computerNameProblem('a.b')).toMatch(/character/);
    expect(computerNameProblem('Zoë-PC')).toMatch(/ASCII/);
    expect(computerNameProblem('Good-PC')).toBeUndefined();
  });
});
