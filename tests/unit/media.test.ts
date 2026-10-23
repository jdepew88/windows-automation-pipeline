import { describe, expect, it } from 'vitest';
import { buildDeploymentPackage, buildManifest } from '../../src/engine/deployment';
import { readZip } from '../../src/engine/deployment/zip';
import { sha256, utf8 } from '../../src/engine/deployment/sha256';
import { ASSISTANT_BUNDLE, DISM_EDITIONS, MEDIA_LAYOUT, MICROSOFT_DOWNLOAD, WINDOWS_RELEASES, assistantBundle, assistantFiles, mediaBlock, mediaRequirements } from '../../src/engine/media';
import { lookup } from '../../src/data';
import assistantSource from '../../src/engine/media/scripts/WdbMediaAssistant.ps1?raw';
import engineSource from '../../src/engine/applications/scripts/ApplicationEngine.ps1?raw';
import { generateOk, profile } from './helpers';

/** Phase 7: the deployment package's media contract and the local USB Preparation Assistant. */

/** The body of one PowerShell function (from its declaration to the next top-level function). */
function fnBody(name: string): string {
  const start = assistantSource.indexOf(`function ${name} {`);
  if (start < 0) throw new Error(`no function ${name}`);
  const next = assistantSource.indexOf('\nfunction ', start + 10);
  return assistantSource.slice(start, next < 0 ? undefined : next);
}

describe('media contract in the deployment package', () => {
  it('the ZIP manifest pins the answer file and states edition, architecture and layout', () => {
    const p = profile();
    const r = generateOk(p);
    const pkg = buildDeploymentPackage(p, r);
    const entries = readZip(pkg.zip);
    const manifest = JSON.parse(new TextDecoder().decode(entries.find((e) => e.path === 'WindowsDeployment/deployment-manifest.json')!.data));
    const answer = entries.find((e) => e.path === 'autounattend.xml')!;
    expect(manifest.media.answerFile).toEqual({ fileName: 'autounattend.xml', size: answer.data.length, sha256: sha256(answer.data) });
    expect(manifest.media.requirements).toEqual({ editionMode: 'genericKey', editionId: 'pro', dismEditionId: 'Professional', editionName: 'Windows 11 Pro', architectures: ['amd64'], minimumBuild: 22000 });
    expect(manifest.media.layout).toEqual({ answerFile: 'autounattend.xml', packageDir: 'WindowsDeployment', backupsDir: 'WindowsDeployment/backups', driversDir: 'WindowsDeployment/drivers', setupDriversDir: '$WinPEDriver$' });
    // Phase 8: without a pinned driver bundle the media needs no driver files.
    expect(manifest.media.drivers).toBeUndefined();
    expect(manifest.media.usbRequiredAfterSetup).toBe(false);
    expect(manifest.media.backup).toBeNull();
    expect(pkg.manifest.media.contractVersion).toBe(1);
  });

  it('the answer file and its embedded runtime manifest are unchanged by Phase 7 (package scope only)', () => {
    const p = profile();
    const r = generateOk(p);
    expect(r.xml).not.toContain('"media"');
    expect('media' in buildManifest(p).manifest).toBe(false);
    const pkg = buildDeploymentPackage(p, r);
    expect(new TextDecoder().decode(readZip(pkg.zip).find((e) => e.path === 'autounattend.xml')!.data)).toBe(r.xml);
  });

  it('every builder edition maps to the EditionId of a Windows image; other edition modes state no edition', () => {
    for (const e of ['home', 'home_n', 'home_single', 'education', 'education_n', 'pro', 'pro_n', 'pro_education', 'pro_education_n', 'pro_workstations', 'pro_workstations_n', 'enterprise', 'enterprise_n']) {
      expect(lookup.edition(e), e).toBeDefined();
      expect(DISM_EDITIONS[e], e).toMatch(/^[A-Z][A-Za-z]+$/);
    }
    expect(mediaRequirements(profile((p) => (p.setup.editionId = 'home'))).dismEditionId).toBe('Core');
    expect(mediaRequirements(profile((p) => (p.setup.editionMode = 'interactive')))).toMatchObject({ dismEditionId: '', editionMode: 'interactive' });
    expect(mediaRequirements(profile((p) => (p.setup.processorArchitectures = ['amd64', 'arm64']))).architectures).toEqual(['amd64', 'arm64']);
  });

  it('the PowerShell assistant uses the same edition map and layout as the website and the engines', () => {
    for (const [id, dism] of Object.entries(DISM_EDITIONS)) expect(assistantSource, id).toContain(`${id} = '${dism}'`);
    expect(assistantSource).toContain(`$script:PackageDir = '${MEDIA_LAYOUT.packageDir}'`);
    expect(assistantSource).toContain(`$script:AnswerFile = '${MEDIA_LAYOUT.answerFile}'`);
    expect(assistantSource).toContain('Join-Path $new "backups\\$($pkg.Backup.folderName)"');
    // The application engine looks for the settings backup at exactly this place on every drive.
    expect(engineSource).toContain('"WindowsDeployment\\backups\\$FolderName"');
  });

  it('a migration package names its pinned backup and where it goes on the drive', () => {
    const p = profile((x) => {
      x.migration = {
        enabled: true,
        source: null,
        decisions: [],
        backup: { backupId: 'a1b2c3d4e5f60718', manifestSha256: 'A'.repeat(64), folderName: 'WDB-AppBackup-1', createdUtc: '', adapters: [{ id: 'git', items: 1, excluded: 0 }] },
        settings: [{ adapterId: 'git', enabled: true, conflict: 'keepExisting', installExtensions: false }],
        followUps: [],
      };
    });
    const b = mediaBlock(p, 'autounattend.xml', utf8('<x/>'));
    expect(b.backup).toEqual({ backupId: 'a1b2c3d4e5f60718', manifestSha256: 'A'.repeat(64), folderName: 'WDB-AppBackup-1', location: 'WindowsDeployment/backups/WDB-AppBackup-1' });
  });
});

describe('Windows release information (cached from Microsoft, offline capable)', () => {
  it('comes from the official release-health page, is dated, and lists Windows 11 builds', () => {
    expect(WINDOWS_RELEASES.source).toBe('https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information');
    expect(WINDOWS_RELEASES.verifiedUtc).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    const builds = WINDOWS_RELEASES.releases.map((r) => r.build);
    expect(new Set(builds).size).toBe(builds.length);
    expect(builds).toEqual(expect.arrayContaining([22000, 22621, 22631, 26100, 26200]));
    expect(Math.min(...builds)).toBe(WINDOWS_RELEASES.minimumBuild);
  });
});

describe('USB Preparation Assistant (static checks)', () => {
  it('ships as a bundle with the assistant, the Phase 6 and Phase 8 validators, the launcher, release data and a README', () => {
    const files = readZip(assistantBundle()).map((e) => e.path);
    expect(files).toEqual([
      'usb-preparation-assistant/WdbMediaAssistant.ps1',
      'usb-preparation-assistant/WdbMigration.ps1',
      'usb-preparation-assistant/DriverEngine.ps1',
      'usb-preparation-assistant/driver-sources.json',
      'usb-preparation-assistant/Prepare-InstallationUSB.cmd',
      'usb-preparation-assistant/windows-releases.json',
      'usb-preparation-assistant/README-USB-Assistant.txt',
    ]);
    expect(ASSISTANT_BUNDLE).toBe('usb-preparation-assistant.zip');
    const readme = assistantFiles().find((f) => f.path === 'README-USB-Assistant.txt')!.content;
    expect(readme).toContain(MICROSOFT_DOWNLOAD);
    expect(readme).toMatch(/ERASES the USB flash drive you choose/);
    expect(readme).toMatch(/does not mean the drive was booted/);
    const ps1 = readZip(assistantBundle()).find((e) => e.path.endsWith('WdbMediaAssistant.ps1'))!.data;
    expect([...ps1.slice(0, 3)]).toEqual([0xef, 0xbb, 0xbf]);
  });

  it('destructive disk and image operations exist only inside their adapter functions', () => {
    const bodies = ['Invoke-WdmPartitionDisk', 'Invoke-WdmSplitImage', 'Invoke-WdmExportImage', 'Mount-WdmIso', 'Dismount-WdmIso'].map(fnBody);
    const adapters = bodies.join('\n');
    const rest = bodies.reduce((src, b) => src.replace(b, ''), assistantSource);
    for (const cmd of ['Clear-Disk', 'Initialize-Disk', 'New-Partition', 'Format-Volume', 'Split-WindowsImage', 'Export-WindowsImage', 'Mount-DiskImage', 'Dismount-DiskImage']) {
      expect(adapters, cmd).toContain(cmd);
      // Mentions in comments and help text are allowed; no other code may call them.
      const calls = rest.split('\n').filter((l) => !/^\s*(#|\.|<#)/.test(l) && new RegExp(`(^|[;({|]\\s*)${cmd}\\b`).test(l.trim()));
      expect(calls, cmd).toEqual([]);
    }
    expect(fnBody('Invoke-WdmApply')).toContain('Assert-WdmTarget $Plan');
    expect(fnBody('Invoke-WdmApply')).toContain("if ($Confirm -cne [string] $Plan.target.confirmCode)");
  });

  it('never changes boot configuration, Secure Boot or security settings, and never executes package content', () => {
    expect(assistantSource).not.toMatch(/bcdedit|bcdboot|bootsect|Set-SecureBoot|Confirm-SecureBootUEFI\s+-|Remove-Partition|Set-Disk\b|\bdiskpart\b|Set-MpPreference|Add-MpPreference|Set-ExecutionPolicy|Invoke-Expression|\biex\b|DownloadString|Start-BitsTransfer/i);
    // The only network access is the optional, read-only release-page check.
    expect(assistantSource.match(/Invoke-WebRequest/g)).toHaveLength(1);
    expect(fnBody('Get-WdmOnlineReleasePage')).toContain('Invoke-WebRequest');
    // Package and backup content is read and hashed, never dot-sourced or started.
    expect(assistantSource).not.toMatch(/^[ \t]*\.[ \t]+\$pkg|& \$pkg|Start-Process[^\n]*\$pkg|^[ \t]*\.[ \t]+\(Join-Path \$pkg/m);
    expect(assistantSource).toContain("$script:WdmLibrary = Join-Path $PSScriptRoot 'WdbMigration.ps1'");
  });

  it('only removable USB flash drives can be erased, and identity is a fingerprint, not a letter', () => {
    const rules = fnBody('Test-WdmDiskEligibility');
    for (const rule of ["'Removable Media'", "'USB'", 'IsSystem', 'IsBoot', 'IsReadOnly', 'IsOffline', 'Test-WdmVentoy', 'MaxRemovableBytes', 'same identity']) expect(rules, rule).toContain(rule);
    expect(fnBody('Get-WdmDiskFingerprint')).not.toMatch(/DriveLetter|\.Number\b|Partitions/);
  });
});
