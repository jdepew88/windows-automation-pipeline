import type { GenContext } from '../../engine/context';
import type { SettingDef } from '../../engine/settings/types';
import { UPSTREAM_RESOURCES, type UpstreamResource } from '../../engine/resources/upstream';
import { regAdd } from '../shared';

const guest = (path: string, label: string, resource: string, iso: string): SettingDef => ({
  path,
  section: 'virtualization',
  label,
  control: 'checkbox',
  description: `For VM builds only. Installs silently at first logon when ${iso} is attached; otherwise it logs a message and does nothing.`,
  applicability: 'Windows 10/11 guests',
  stages: ['firstLogon'],
  mapping: `FirstLogon.ps1 → ${resource} (upstream)`,
  advanced: true,
  verification: 'upstream-tested',
});

export const settings: SettingDef[] = [
  {
    path: 'virtualization.disableCoreIsolation',
    section: 'virtualization',
    label: 'Disable Core Isolation (VBS / Memory integrity)',
    control: 'checkbox',
    description:
      'Owner default keeps Core Isolation in its Windows-managed state (on by default on compatible new installs). Nothing here installs or removes Hyper-V, Virtual Machine Platform, WSL2, Windows Sandbox, Docker, VMware or VirtualBox. Those are separate optional features or apps, left for later milestones and enabled only where needed.',
    applicability: 'Windows 11 on VBS-capable hardware',
    risk: 'Lowers kernel-level protection. Only for nested-virtualization edge cases.',
    stages: ['specialize'],
    mapping: 'HKLM\\System\\CurrentControlSet\\Control\\DeviceGuard\\EnableVirtualizationBasedSecurity = 0; …\\HypervisorEnforcedCodeIntegrity\\Enabled = 0',
    advanced: true,
    verification: 'upstream-tested',
  },
  guest('virtualization.vboxGuestAdditions', 'Install VirtualBox Guest Additions', 'VBoxGuestAdditions.ps1', 'VBoxGuestAdditions.iso'),
  guest('virtualization.vmwareTools', 'Install VMware Tools', 'VMwareTools.ps1', 'the VMware Tools ISO'),
  guest('virtualization.virtioGuestTools', 'Install VirtIO drivers, guest tools and QEMU Guest Agent', 'VirtIoGuestTools.ps1', 'virtio-win-*.iso'),
  guest('virtualization.parallelsTools', 'Install Parallels Tools', 'ParallelsTools.ps1', 'prl-tools-win-*.iso'),
];

export function modify(ctx: GenContext): void {
  const v = ctx.profile.virtualization;
  // Defender stays enabled in this project, so upstream installs guest tools at first logon.
  const install = (resource: UpstreamResource) => ctx.seq.firstLogon.invokeFile(ctx.embedFile(resource, UPSTREAM_RESOURCES[resource]));
  if (v.vboxGuestAdditions) install('VBoxGuestAdditions.ps1');
  if (v.vmwareTools) install('VMwareTools.ps1');
  if (v.virtioGuestTools) install('VirtIoGuestTools.ps1');
  if (v.parallelsTools) install('ParallelsTools.ps1');
}

export function modifyCoreIsolation(ctx: GenContext): void {
  if (!ctx.profile.virtualization.disableCoreIsolation) return;
  const dg = 'HKLM\\System\\CurrentControlSet\\Control\\DeviceGuard';
  ctx.seq.specialize.append(
    [
      regAdd(dg, 'EnableVirtualizationBasedSecurity', 0),
      regAdd(`${dg}\\Scenarios\\HypervisorEnforcedCodeIntegrity`, 'Enabled', 0),
      regAdd(`${dg}\\Scenarios\\HypervisorEnforcedCodeIntegrity`, 'EnabledBootId', 0),
      regAdd(`${dg}\\Scenarios\\HypervisorEnforcedCodeIntegrity`, 'WasEnabledBy', 0),
    ].join('\n'),
  );
}
