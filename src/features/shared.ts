/** `reg.exe add` line for a PowerShell sequence. Values are DWORD unless stated. */
export function regAdd(key: string, name: string, data: string | number, type: 'REG_DWORD' | 'REG_SZ' | 'REG_EXPAND_SZ' = 'REG_DWORD'): string {
  const d = typeof data === 'number' ? String(data) : `"${data}"`;
  return `reg.exe add "${key}" /v "${name}" /t ${type} /d ${d} /f;`;
}

export const HKLM_POLICIES = 'HKLM\\SOFTWARE\\Policies\\Microsoft';
/** Default user hive mounted during the DefaultUser stage. */
export const HKU_DEFAULT = 'HKU\\DefaultUser';
