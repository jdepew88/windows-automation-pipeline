import type { Profile } from '../engine/schema/profile';
import { VerifiedPackageSchema, type VerifiedPackage } from '../engine/schema/drivers';
import {
  DRIVER_ENGINE_FILE,
  DRIVER_SOURCE_DATA,
  DRIVER_TOOL_BUNDLE,
  MEDIA_DRIVERS_DIR,
  MEDIA_WINPE_DRIVERS_DIR,
  driverToolBundle,
  hardwareSummary,
  importDriverBundleManifest,
  importHardwareInventory,
  reviewRows,
  verifiedPackageProblems,
  type HardwareInventory,
} from '../engine/drivers';
import { clear, download, h, uid } from './dom';
import { customShell, type CustomRenderer } from './form';
import { icon } from './icons';

/**
 * Phase 8: Hardware & Drivers (Advanced Configuration). The website never sees the target
 * computer: an inventory taken there earlier (read-only) can be imported to review it, and it
 * stays in this browser tab; only its summary is recorded in the profile. The offline bundle is
 * identified by its manifest only; no driver file passes through the website.
 */

interface Session {
  inventory?: HardwareInventory;
  fileName: string;
}
const session: Session = { fileName: '' };

function notice(target: HTMLElement, kind: 'info' | 'error', title: string, lines: string[] = []): void {
  clear(target);
  target.className = `app-status notice ${kind}`;
  target.append(icon(kind === 'error' ? 'xCircle' : 'info'), h('div', { class: 'notice-body' }, h('strong', {}, title), lines.length ? h('ul', {}, lines.slice(0, 12).map((l) => h('li', {}, l))) : null));
}

const win = (p: string) => p.replace(/\//g, '\\');

// 1. Hardware of the target computer (optional, read-only inventory) --------------------------------

export const driversHardwareEditor: CustomRenderer = (def, store) => {
  const status = h('div', { class: 'app-status', 'data-testid': 'drv-import-status', 'aria-live': 'polite' });
  const view = h('div', { class: 'drv-hardware', 'data-testid': 'drv-hardware' });
  const input = h('input', {
    type: 'file',
    accept: '.json,application/json',
    class: 'sr-only',
    tabindex: -1,
    'data-testid': 'drv-inventory-input',
    onchange: async () => {
      const file = input.files?.[0];
      input.value = '';
      if (!file) return;
      const r = importHardwareInventory(await file.text());
      if (!r.ok || !r.inventory) {
        notice(status, 'error', `Could not import ${file.name}`, r.errors);
        return;
      }
      session.inventory = r.inventory;
      session.fileName = file.name;
      store.update((p) => (p.drivers.hardware = hardwareSummary(r.inventory!)), true);
      notice(status, 'info', `Imported ${file.name}: ${r.inventory.devices.length} device(s)`, ['The list below is exactly what the read-only scan found on that computer. Nothing was installed, and the deployment inspects the hardware again after installation.']);
    },
  });
  const el = customShell(
    def,
    h(
      'div',
      {},
      h(
        'ol',
        { class: 'mig-steps' },
        h('li', {}, 'Download the hardware & driver tool and copy it to the target computer (only if Windows already runs on it): ', h('button', { type: 'button', class: 'btn', 'data-testid': 'drv-download-tool', onclick: () => download(DRIVER_TOOL_BUNDLE, driverToolBundle(), 'application/zip') }, icon('download'), DRIVER_TOOL_BUNDLE)),
        h('li', {}, 'Run ', h('code', {}, 'Inspect-Hardware.cmd'), ' there. It only reads (no administrator rights needed) and writes hardware-inventory.json without serial numbers, UUIDs, MAC addresses or user names.'),
        h('li', {}, 'Import the inventory here: ', h('button', { type: 'button', class: 'btn primary', 'data-testid': 'drv-import', onclick: () => input.click() }, icon('importIcon'), 'Import hardware inventory…'), input),
      ),
      status,
      view,
    ),
  );
  const sync = (p: Profile) => {
    clear(view);
    const inv = session.inventory;
    if (!inv) {
      const s = p.drivers.hardware;
      view.append(
        s
          ? h('p', { class: 'desc', 'data-testid': 'drv-hardware-summary' }, `Planned for a ${s.manufacturer} ${s.model} (inventory ${s.inventoryId}, ${s.collectedUtc.slice(0, 10)}): ${s.devices} device(s), ${s.needingAction} needing attention${s.setupCritical ? `, ${s.setupCritical} storage controller(s) Windows Setup may need a driver for` : ''}. Import the inventory again to see the devices.`, ' ', h('button', { type: 'button', class: 'linkish', onclick: () => store.update((q) => (q.drivers.hardware = null), true) }, 'Forget it'))
          : h('p', { class: 'empty', 'data-testid': 'drv-no-inventory' }, 'No inventory imported. That is fine: the deployment always identifies the hardware itself on the installed computer.'),
      );
      return;
    }
    const rows = reviewRows(inv);
    const attention = rows.filter((r) => r.attention);
    view.append(
      h('p', { class: 'drv-banner', 'data-testid': 'drv-banner' }, icon('info'), h('span', {}, `Pre-installation information: collected on ${inv.system.manufacturer} ${inv.system.model} on ${inv.collectedUtc.slice(0, 16).replace('T', ' ')} UTC by a read-only scan (${inv.system.osCaption}, build ${inv.system.osBuild}). The deployment inspects the hardware again on the installed computer and decides from that.`)),
      h('ul', { class: 'mig-counts', 'data-testid': 'drv-counts' }, h('li', {}, h('strong', {}, String(rows.length)), ' devices'), h('li', {}, h('strong', {}, String(attention.length)), ' need attention'), h('li', {}, h('strong', {}, String(rows.filter((r) => r.setupCritical).length)), ' Setup-critical')),
      h(
        'div',
        { class: 'drv-table', role: 'table', 'aria-label': 'Devices', 'data-testid': 'drv-review' },
        h('div', { class: 'drv-tr drv-th', role: 'row' }, ['Device', 'Current status', 'Action', 'Confidence'].map((c) => h('span', { role: 'columnheader' }, c))),
        rows.map((r) =>
          h(
            'details',
            { class: `drv-tr${r.attention ? ' attention' : ''}`, role: 'row', 'data-device': r.key },
            h('summary', {}, h('span', { role: 'cell' }, h('strong', {}, r.device), h('small', {}, `${r.category} · ${r.vendor}`)), h('span', { role: 'cell', class: 'drv-status' }, r.status), h('span', { role: 'cell' }, r.action, r.setupCritical ? h('span', { class: 'tag' }, 'Setup-critical') : null), h('span', { role: 'cell', class: `drv-conf ${r.confidence}` }, r.confidence)),
            h(
              'div',
              { class: 'drv-detail' },
              h('p', {}, r.reason),
              h('dl', { class: 'mig-facts' },
                h('dt', {}, 'Hardware IDs'), h('dd', {}, h('code', {}, r.details.hardwareIds.join('\n') || '—')),
                h('dt', {}, 'Compatible IDs'), h('dd', {}, h('code', {}, r.details.compatibleIds.join('\n') || '—')),
                h('dt', {}, 'Driver'), h('dd', {}, r.details.driver),
                h('dt', {}, 'INF'), h('dd', {}, r.details.inf || '—'),
                h('dt', {}, 'Problem code'), h('dd', {}, String(r.details.problemCode)),
                h('dt', {}, 'Instance'), h('dd', {}, h('code', {}, r.details.instanceId)),
                r.details.oemCustomized ? h('dt', {}, 'OEM') : null, r.details.oemCustomized ? h('dd', {}, 'Customized by the computer manufacturer (subsystem ID): its own driver is preferred') : null,
              ),
            ),
          ),
        ),
      ),
      h('div', { class: 'drv-apps', 'data-testid': 'drv-optional-apps', hidden: !inv.optionalApplications.length }, h('strong', {}, 'Optional vendor applications (never installed by the driver stage; add them to an application profile if you want them):'), h('ul', {}, inv.optionalApplications.map((a) => h('li', {}, `${a.name} (${a.vendor}): ${a.purpose}`)))),
      h('button', { type: 'button', class: 'linkish', onclick: () => { session.inventory = undefined; store.update((q) => (q.drivers.hardware = null), true); } }, 'Remove this inventory'),
    );
  };
  return { el, sync };
};

// 2. Offline driver bundle ---------------------------------------------------------------------------

export const driversBundleEditor: CustomRenderer = (def, store) => {
  const status = h('div', { class: 'app-status', 'data-testid': 'drv-bundle-status', 'aria-live': 'polite' });
  const info = h('div', { 'data-testid': 'drv-bundle' });
  const input = h('input', {
    type: 'file',
    accept: '.json,application/json',
    class: 'sr-only',
    tabindex: -1,
    'data-testid': 'drv-bundle-input',
    onchange: async () => {
      const file = input.files?.[0];
      input.value = '';
      if (!file) return;
      const r = importDriverBundleManifest(new Uint8Array(await file.arrayBuffer()));
      if (!r.ok || !r.reference) {
        notice(status, 'error', `Could not attach ${file.name}`, r.errors);
        return;
      }
      store.update((p) => {
        p.drivers.bundle = r.reference!;
        p.drivers.includeOfflinePackages = true;
      }, true);
      notice(status, 'info', `Attached bundle ${r.reference.folderName}: ${r.reference.packages.length} driver package(s)`, ['Only the manifest was read. Keep the bundle folder; the USB Preparation Assistant copies it to the drive.', ...r.warnings]);
    },
  });
  const el = customShell(def, h('div', {}, h('button', { type: 'button', class: 'btn', 'data-action': 'drv-attach-bundle', onclick: () => input.click() }, icon('archive'), 'Attach drivers-manifest.json…'), input, status, info));
  const sync = (p: Profile) => {
    clear(info);
    const b = p.drivers.bundle;
    if (!b) {
      info.append(
        h('p', { class: 'desc' }, 'Make a bundle with the hardware & driver tool, on a Windows installation with the same hardware (it exports the installed third-party drivers) or from INF drivers downloaded from the manufacturer:'),
        h('pre', { class: 'mig-cmd' }, `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\${DRIVER_ENGINE_FILE} -Mode Export -OutputPath E:\\${win(MEDIA_DRIVERS_DIR)}\npowershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\${DRIVER_ENGINE_FILE} -Mode Bundle -Path D:\\Drivers -OutputPath E:\\${win(MEDIA_DRIVERS_DIR)}`),
        h('p', { class: 'desc' }, 'Unsigned packages and installer programs are never part of a bundle. Vendor control panels and utilities are applications, not drivers.'),
      );
      return;
    }
    const critical = b.packages.filter((x) => x.setupCritical);
    info.append(
      h('dl', { class: 'mig-facts' },
        h('dt', {}, 'Bundle'), h('dd', {}, h('code', {}, b.folderName), ` from ${b.source.manufacturer} ${b.source.model} (${b.source.kind === 'driverStoreExport' ? 'driver store export' : 'technician folder'}, ${b.createdUtc.slice(0, 10)})`),
        h('dt', {}, 'Manifest SHA-256'), h('dd', {}, h('code', { 'data-testid': 'drv-bundle-hash' }, b.manifestSha256)),
        h('dt', {}, 'On the USB drive'), h('dd', {}, h('code', {}, `${win(MEDIA_DRIVERS_DIR)}\\${b.folderName}`), critical.length ? [' and ', h('code', {}, `${MEDIA_WINPE_DRIVERS_DIR}\\${b.folderName}`), ` (${critical.length} Setup-critical)`] : null),
      ),
      h(
        'div',
        { class: 'drv-table compact', role: 'table', 'aria-label': 'Packages', 'data-testid': 'drv-bundle-packages' },
        h('div', { class: 'drv-tr drv-th', role: 'row' }, ['Package', 'Class', 'Provider & version', 'Load during Windows Setup'].map((c) => h('span', { role: 'columnheader' }, c))),
        b.packages.map((x, n) => {
          const id = uid('drv');
          return h(
            'div',
            { class: 'drv-tr', role: 'row', 'data-package': x.id },
            h('span', { role: 'cell' }, h('strong', {}, x.inf), h('small', {}, `${x.architectures.join('/')} · ${x.hardwareIds} hardware ID(s)${x.whql ? ' · Microsoft-signed' : ''}`)),
            h('span', { role: 'cell' }, x.class),
            h('span', { role: 'cell' }, `${x.provider} ${x.version}`),
            h('span', { role: 'cell' }, h('input', { type: 'checkbox', id, checked: x.setupCritical, 'data-testid': `drv-setup-${x.id}`, onchange: (e: Event) => store.update((q) => (q.drivers.bundle!.packages[n]!.setupCritical = (e.target as HTMLInputElement).checked), true) }), h('label', { for: id, class: 'sr-only' }, `Load ${x.inf} during Windows Setup`)),
          );
        }),
      ),
      h('p', { class: 'desc' }, 'Only packages ticked "Load during Windows Setup" go to $WinPEDriver$ (storage controllers are ticked automatically). Every package is used only for a device whose hardware IDs it declares.'),
      h('button', { type: 'button', class: 'linkish', 'data-action': 'drv-detach-bundle', onclick: () => store.update((q) => ((q.drivers.bundle = null), (q.drivers.approvals = q.drivers.approvals.filter((a) => !a.packageId.startsWith('pkg-')))), true) }, 'Remove this bundle from the plan'),
    );
  };
  return { el, sync };
};

// 3. Verified packages (technician-entered download metadata) -----------------------------------------

export const driversVerifiedEditor: CustomRenderer = (def, store) => {
  const list = h('div', { class: 'mig-settings', 'data-testid': 'drv-verified' });
  const status = h('div', { class: 'app-status', 'aria-live': 'polite', 'data-testid': 'drv-verified-status' });
  const f = {
    name: h('input', { type: 'text', maxlength: 100, placeholder: 'Contoso 2.5GbE driver', 'aria-label': 'Name' }),
    vendor: h('input', { type: 'text', maxlength: 60, placeholder: 'Contoso', 'aria-label': 'Vendor' }),
    url: h('input', { type: 'url', maxlength: 500, placeholder: 'https://download.microsoft.com/…/driver.cab', 'aria-label': 'Download URL', 'data-testid': 'drv-verified-url' }),
    sha: h('input', { type: 'text', maxlength: 64, placeholder: 'SHA-256 (64 hex)', 'aria-label': 'SHA-256', spellcheck: false }),
    ids: h('textarea', { rows: 2, placeholder: 'PCI\\VEN_10EC&DEV_8125 (one per line)', 'aria-label': 'Hardware IDs' }),
    cls: h('input', { type: 'text', maxlength: 64, placeholder: 'Net', 'aria-label': 'Device class' }),
    version: h('input', { type: 'text', maxlength: 40, placeholder: '10.68.815.2026', 'aria-label': 'Version' }),
    arch: h('select', { 'aria-label': 'Architecture' }, ['amd64', 'arm64', 'x86'].map((a) => h('option', { value: a }, a))),
    format: h('select', { 'aria-label': 'Format' }, h('option', { value: 'cab' }, '.cab'), h('option', { value: 'zip' }, '.zip')),
  };
  const add = h('button', {
    type: 'button',
    class: 'btn',
    'data-testid': 'drv-verified-add',
    onclick: () => {
      const v: VerifiedPackage = {
        id: (f.name.value || f.vendor.value || 'package').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40) || 'package',
        name: f.name.value.trim(),
        vendor: f.vendor.value.trim(),
        url: f.url.value.trim(),
        sha256: f.sha.value.trim().toUpperCase(),
        format: f.format.value as 'cab' | 'zip',
        hardwareIds: f.ids.value.split(/\r?\n/).map((x) => x.trim().toUpperCase()).filter(Boolean),
        deviceClass: f.cls.value.trim(),
        version: f.version.value.trim(),
        architecture: f.arch.value as 'amd64' | 'arm64' | 'x86',
      };
      const parsed = VerifiedPackageSchema.safeParse(v);
      const problems = parsed.success ? verifiedPackageProblems(v) : parsed.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`);
      if (problems.length) {
        notice(status, 'error', 'Not added', problems);
        return;
      }
      store.update((p) => {
        let id = v.id;
        for (let n = 2; p.drivers.verifiedPackages.some((x) => x.id === id); n++) id = `${v.id.slice(0, 44)}-${n}`;
        p.drivers.verifiedPackages.push({ ...v, id });
      }, true);
      notice(status, 'info', `Added ${v.name}`, ['It is downloaded only if a device still needs it after Windows Update, and used only if the file has exactly this SHA-256.']);
      for (const x of [f.name, f.vendor, f.url, f.sha, f.ids, f.cls, f.version]) x.value = '';
    },
  }, icon('plus'), 'Add verified package');
  const el = customShell(
    def,
    h('div', {},
      list,
      h('details', { class: 'drv-add' },
        h('summary', {}, 'Add a package you verified'),
        h('p', { class: 'desc' }, `The URL must be the manufacturer's or Microsoft's own download host (${DRIVER_SOURCE_DATA.downloadHosts.join(', ')}); search pages and driver-updater sites are never used. Find Microsoft-signed INF packages in the Microsoft Update Catalog: ${DRIVER_SOURCE_DATA.microsoftCatalogUrl}`),
        h('div', { class: 'drv-form' }, f.name, f.vendor, f.url, f.sha, f.ids, f.cls, f.version, f.arch, f.format, add),
        status,
      ),
    ),
  );
  const sync = (p: Profile) => {
    clear(list);
    if (!p.drivers.verifiedPackages.length) list.append(h('p', { class: 'empty' }, 'None. Missing drivers come from Windows, Windows Update and the offline bundle, or are reported.'));
    p.drivers.verifiedPackages.forEach((v, n) =>
      list.append(
        h('div', { class: 'mig-row', 'data-verified': v.id },
          icon('package'),
          h('div', { class: 'mig-main' }, h('strong', {}, `${v.name} ${v.version}`), h('span', { class: 'mig-id' }, v.url), h('span', { class: 'mig-id' }, `SHA-256 ${v.sha256} · ${v.hardwareIds.join(', ')}`)),
          h('button', { type: 'button', class: 'linkish', onclick: () => store.update((q) => { q.drivers.verifiedPackages.splice(n, 1); q.drivers.approvals = q.drivers.approvals.filter((a) => a.packageId !== v.id); }, true) }, 'Remove'),
        ),
      ),
    );
  };
  return { el, sync };
};

// 4. Approved replacements of working drivers --------------------------------------------------------

export const driversApprovalsEditor: CustomRenderer = (def, store) => {
  const list = h('div', { class: 'mig-settings', 'data-testid': 'drv-approvals' });
  const pkg = h('select', { 'aria-label': 'Package', 'data-testid': 'drv-approval-package' });
  const hw = h('input', { type: 'text', maxlength: 220, placeholder: 'PCI\\VEN_10DE&DEV_2484&SUBSYS_146B10DE', 'aria-label': 'Hardware ID', 'data-testid': 'drv-approval-hwid' });
  const status = h('div', { class: 'app-status', 'aria-live': 'polite' });
  const add = h('button', {
    type: 'button',
    class: 'btn',
    onclick: () => {
      const id = hw.value.trim().toUpperCase();
      if (!pkg.value || !/^(PCI|USB|HDAUDIO|ACPI|HID|BTH|DISPLAY|INTELAUDIO|SWC|UEFI)\\[A-Z0-9_&.\-\\]{2,200}$/.test(id)) {
        notice(status, 'error', 'Choose a package and enter a hardware ID as Windows shows it');
        return;
      }
      store.update((p) => p.drivers.approvals.push({ packageId: pkg.value, hardwareId: id }), true);
      hw.value = '';
      clear(status);
    },
  }, icon('plus'), 'Approve');
  const el = customShell(def, h('div', {}, list, h('div', { class: 'drv-form' }, pkg, hw, add), status));
  const sync = (p: Profile) => {
    clear(list);
    clear(pkg);
    const options = [...(p.drivers.bundle?.packages.map((x) => [x.id, `${x.inf} ${x.version} (bundle)`] as const) ?? []), ...p.drivers.verifiedPackages.map((v) => [v.id, `${v.name} ${v.version} (verified package)`] as const)];
    for (const [value, label] of options) pkg.append(h('option', { value }, label));
    if (!p.drivers.approvals.length) list.append(h('p', { class: 'empty' }, p.drivers.optionalReplacements === 'approvedOnly' ? 'No replacement approved: every working driver is kept.' : 'Working drivers are never replaced (see "Replacing a working driver").'));
    p.drivers.approvals.forEach((a, n) =>
      list.append(h('div', { class: 'mig-row' }, icon('check'), h('div', { class: 'mig-main' }, h('strong', {}, options.find((o) => o[0] === a.packageId)?.[1] ?? a.packageId), h('span', { class: 'mig-id' }, a.hardwareId)), h('button', { type: 'button', class: 'linkish', onclick: () => store.update((q) => q.drivers.approvals.splice(n, 1), true) }, 'Remove'))),
    );
  };
  return { el, sync };
};
