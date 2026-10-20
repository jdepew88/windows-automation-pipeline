import type { SettingDef } from '../../engine/settings/types';
import type { Profile } from '../../engine/schema/profile';
import type { Issue } from '../../engine/validation/issues';
import { APP_ROOT, isReviewed, splitArgs } from '../../engine/applications';

/**
 * Additional Software: installers WinGet does not cover. Phase 3 provides the data model,
 * validation and the engine stage. Nothing is downloaded, and a user-entered entry is always a
 * manual follow-up: automatic execution needs an entry on the reviewed list
 * (engine/applications REVIEWED_INSTALLERS, empty in this release) plus a supplied file whose
 * SHA-256 and signature match.
 */

export const settings: SettingDef[] = [
  {
    path: 'additionalSoftware.items',
    section: 'additionalSoftware',
    label: 'Installers not available through WinGet',
    control: 'custom',
    description:
      'Record freeware or vendor installers with their official download page, checksum and switches. They run after the WinGet applications. This version never downloads anything; entries become a follow-up checklist in the results.',
    applicability: 'Windows 10/11; runs in the application stage (signed-in user, elevated)',
    stages: ['firstLogon'],
    mapping: `applications-config.json › additionalSoftware; supplied files in ${APP_ROOT}\\installers; follow-up in ${APP_ROOT}\\follow-up.txt`,
    advanced: false,
    verification: 'unverified',
  },
];

const FILE_NAME = /^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,119}$/;
const SHA256 = /^[0-9a-fA-F]{64}$/;
const TOKEN_PARAM = /(^|[?&])(token|access_token|auth|key|sig|signature|password|pwd|secret|x-amz-signature|se|sp)=/i;

export function validate(p: Profile, issues: Issue[]): void {
  const items = p.additionalSoftware.items;
  const seen = new Set<string>();
  items.forEach((i, n) => {
    const path = `additionalSoftware.items.${n}`;
    const err = (m: string) => issues.push({ severity: 'error', path, message: m });
    const warn = (m: string) => issues.push({ severity: 'warning', path, message: m });
    if (seen.has(i.id)) err('Duplicate entry id.');
    seen.add(i.id);
    if (!i.name.trim()) err('Give the installer a name.');
    if (i.downloadUrl) {
      let url: URL | undefined;
      try {
        url = new URL(i.downloadUrl);
      } catch {
        err('The download URL is not a valid URL.');
      }
      if (url) {
        if (url.protocol !== 'https:') err('Use the publisher\'s official https:// download page.');
        if (url.username || url.password) err('The URL contains a user name or password. Credentials must not be stored in profiles.');
        if (TOKEN_PARAM.test(url.search)) err('The URL appears to contain an access token or signature. Use the public download page instead; profiles must not carry credentials.');
      }
    }
    if (i.sha256 && !SHA256.test(i.sha256)) err('SHA-256 must be 64 hexadecimal characters.');
    if (i.fileName && !FILE_NAME.test(i.fileName)) err('Use a plain file name (letters, digits, spaces, . _ ( ) + -).');
    const { refused } = splitArgs(i.silentArgs);
    if (refused.length) err(`Silent arguments must not contain ${refused.join(' ')}.`);
    if (i.execution === 'automatic' && !isReviewed(i)) {
      err('Automatic execution is only available for installers on the reviewed list, and none are reviewed in this version. Choose "Manual follow-up".');
    }
    if (i.execution === 'automatic' && (!i.sha256 || !i.fileName)) err('Automatic execution needs the supplied file name and its SHA-256.');
    if (i.redistribution === 'restricted' && !i.manualSupply) warn('The licence restricts redistribution: supply the installer yourself on each machine.');
    if (i.interaction === 'required' && i.execution === 'automatic') err('An installer that needs interaction cannot run automatically.');
  });
}
