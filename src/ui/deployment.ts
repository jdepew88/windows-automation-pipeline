import type { GenerateResult } from '../engine/pipeline';
import type { Profile } from '../engine/schema/profile';
import { DATA_ROOT } from '../engine/windows-update';
import { PACKAGE_DIR, PACKAGE_ROOT, RESUME_SCRIPT, STATUS_SCRIPT, buildDeploymentPackage, type DeploymentPackage } from '../engine/deployment';
import { ASSISTANT_BUNDLE, ASSISTANT_SCRIPT, MICROSOFT_DOWNLOAD, WINDOWS_RELEASES, assistantBundle, mediaRequirements } from '../engine/media';
import { settingsRestoreActive } from '../engine/migration/plan';
import { driverMediaBlock } from '../engine/drivers';
import { clear, download, h } from './dom';
import { icon, type IconName } from './icons';

/** The ZIP for the current configuration, built on demand (in the browser, offline). */
export function currentPackage(p: Profile, result: GenerateResult): DeploymentPackage | null {
  return result.ok ? buildDeploymentPackage(p, result) : null;
}

export function downloadPackage(pkg: DeploymentPackage): void {
  download(pkg.fileName, pkg.zip, 'application/zip');
}

const kb = (n: number) => (n < 1024 ? `${n} B` : `${Math.ceil(n / 1024)} KB`);
const ROLE_LABELS: Record<string, string> = {
  'answer-file': 'answer file',
  manifest: 'manifest',
  entry: 'entry point',
  orchestrator: 'orchestrator',
  engine: 'engine',
  configuration: 'configuration',
  profile: 'profile',
  documentation: 'documentation',
};

export interface DeploymentPageHandle {
  el: HTMLElement;
  update(p: Profile, result: GenerateResult): void;
}

const card = (cls: string, ...children: (Node | null)[]) => h('section', { class: `card ${cls}` }, ...children);
const head = (title: string, ico: IconName, desc?: string) => h('div', { class: 'card-head' }, h('div', { class: 'card-title' }, icon(ico), h('h3', {}, title)), desc ? h('p', { class: 'card-desc' }, desc) : null);

export function renderDeploymentPage(): DeploymentPageHandle {
  let pkg: DeploymentPackage | null = null;
  let profileRef: Profile | undefined;
  let resultRef: GenerateResult | undefined;
  const ensure = () => (pkg ??= profileRef && resultRef ? currentPackage(profileRef, resultRef) : null);

  const status = h('div', { class: 'status-card', 'data-testid': 'package-status', 'aria-live': 'polite' });
  const sizeLabel = h('span', { class: 'btn-sub' });
  const downloadBtn = h(
    'button',
    { type: 'button', class: 'btn primary hero', 'data-action': 'download-package', onclick: () => { const x = ensure(); if (x) downloadPackage(x); } },
    icon('archive'),
    h('span', { class: 'btn-stack' }, h('span', { class: 'btn-label' }, 'Download deployment package'), sizeLabel),
  );
  const xmlOnly = h('button', { type: 'button', class: 'btn wide', 'data-action': 'download-xml-only', onclick: () => resultRef?.ok && resultRef.xml && download(resultRef.fileName, resultRef.xml, 'application/xml') }, icon('fileCode'), h('span', { class: 'btn-label' }, 'Download autounattend.xml only'));
  const contents = h('ul', { class: 'pkg-tree', 'data-testid': 'package-contents' });
  const stages = h('ol', { class: 'pkg-stages', 'data-testid': 'package-stages' });
  const usbAnswer = h('span', {});
  const usbNeeds = h('p', { class: 'desc', 'data-testid': 'usb-requirements' });
  const usbBackup = h('p', { class: 'desc', 'data-testid': 'usb-backup-note' });
  const usbDrivers = h('p', { class: 'desc', 'data-testid': 'usb-drivers-note' });
  const assistantBtn = h(
    'button',
    { type: 'button', class: 'btn primary', 'data-action': 'download-usb-assistant', onclick: () => download(ASSISTANT_BUNDLE, assistantBundle(), 'application/zip') },
    icon('download'),
    h('span', { class: 'btn-stack' }, h('span', { class: 'btn-label' }, 'Download the USB Preparation Assistant'), h('span', { class: 'btn-sub' }, ASSISTANT_BUNDLE)),
  );

  const el = h(
    'section',
    { class: 'page deployment', id: 'section-deployment', 'data-page': 'deployment', 'aria-labelledby': 'title-deployment', hidden: true },
    h(
      'header',
      { class: 'page-head' },
      h('div', { class: 'page-icon' }, icon('usb')),
      h(
        'div',
        {},
        h('h2', { id: 'title-deployment', tabindex: -1 }, 'Deployment package'),
        h('p', { class: 'intro' }, 'One ZIP for a USB installation: the answer file plus every script, setting and check the installed computer needs. Built in this browser; nothing is uploaded.'),
      ),
    ),
    h(
      'div',
      { class: 'review-grid' },
      h(
        'div',
        { class: 'review-main' },
        status,
        card(
          'choices-card',
          head('What to download', 'download', 'Three ways to take the configuration with you.'),
          h(
            'div',
            { class: 'dl-options' },
            h('div', { class: 'dl-option recommended' }, h('strong', {}, 'Complete deployment package (recommended)'), h('p', {}, `${PACKAGE_DIR}\\ plus the answer file, ready to extract to the root of a Windows 11 installation USB drive. Verifies itself; works after the USB drive is removed.`)),
            h('div', { class: 'dl-option' }, h('strong', {}, 'Answer file only'), h('p', {}, 'autounattend.xml by itself. It already embeds the Windows Update and application engines and the orchestrator, but it has no manual entry point, documentation or verification tools.')),
            h('div', { class: 'dl-option' }, h('strong', {}, 'Individual scripts'), h('p', {}, 'Single engine files for inspection or troubleshooting: ', h('a', { href: '#deployment-assets' }, 'Deployment assets'), ' on the Review page.')),
          ),
        ),
        card('contents-card', head('Package contents', 'list', 'Every file, its size and its role. The manifest lists the SHA-256 of each one; setup.ps1 and the orchestrator check them before running anything.'), contents),
        card(
          'usb-card',
          head('Preparing the USB drive', 'usb'),
          h(
            'ol',
            { class: 'howto' },
            h('li', {}, h('strong', {}, 'Create Windows 11 installation media. '), 'Use Microsoft\'s Media Creation Tool ("USB flash drive"). With Rufus and an official ISO, turn off every "Customize Windows installation" option: Rufus otherwise adds its own answer file.'),
            h('li', {}, h('strong', {}, 'Extract the ZIP to the root of the USB drive. '), 'In "Extract all", remove the suggested folder name and choose the drive itself. The answer file must sit next to setup.exe.'),
            h('li', {}, h('strong', {}, 'Boot the target computer from the USB drive. '), 'Setup stops at "Where do you want to install Windows?". Select the disk yourself: nothing chooses, cleans or formats a disk for you.'),
            h('li', {}, h('strong', {}, 'Sign in once. '), 'At the first sign-in the deployment starts by itself and opens a progress window. The computer restarts on its own when updates or applications need it.'),
            h('li', {}, h('strong', {}, 'Read the report. '), '"Deployment report" appears on the desktop when everything has finished. Remove the answer file from the USB drive afterwards.'),
          ),
          h('pre', { class: 'usb-layout', 'aria-label': 'USB drive layout' }, 'USB drive\\\n├── boot\\  efi\\  sources\\  setup.exe   (Microsoft media)\n├── ', usbAnswer, '\n└── WindowsDeployment\\\n    ├── setup.cmd  setup.ps1  deployment-manifest.json  README.txt\n    ├── scripts\\   bootstrap  orchestrator  windows-update  applications  finalization\n    ├── profiles\\  config\\  docs\\'),
          h(
            'p',
            { class: 'desc' },
            'How the files reach the installed system: Windows Setup copies the answer file to C:\\Windows\\Panther and, during the specialize pass, the answer file extracts its embedded scripts to C:\\Windows\\Setup\\Scripts (Administrators only). At the first sign-in the orchestrator verifies them against the manifest and copies them to ',
            h('code', {}, PACKAGE_ROOT),
            '. No drive letter is assumed and the USB drive is not needed after Setup.',
          ),
        ),
        card(
          'usb-prep-card',
          h(
            'div',
            { class: 'card-head', id: 'usb-prep' },
            h('div', { class: 'card-title' }, icon('usb'), h('h3', {}, 'Prepare Installation USB')),
            h('p', { class: 'card-desc' }, 'A small local tool for Windows prepares and checks the drive from the package you downloaded. Drives are handled on your computer only: this website never sees or changes a disk.'),
          ),
          h(
            'ol',
            { class: 'howto' },
            h('li', {}, h('strong', {}, 'Download the deployment package and the assistant. '), 'Extract the assistant and start ', h('code', {}, 'Prepare-InstallationUSB.cmd'), '.'),
            h(
              'li',
              {},
              h('strong', {}, 'Choose how to prepare the drive. '),
              h('span', { class: 'badge ok' }, 'Update'),
              ' adds this deployment to an existing Windows USB (Media Creation Tool): nothing is erased and the Windows files stay as they are; an older deployment on the drive is kept in WDB-previous. ',
              h('span', { class: 'badge warn' }, 'Create'),
              ' ERASES the USB flash drive you pick and builds it from a Windows 11 ISO (',
              h('a', { href: MICROSOFT_DOWNLOAD, target: '_blank', rel: 'noopener noreferrer' }, 'official Microsoft download'),
              '). ',
              h('span', { class: 'badge info' }, 'Inspect'),
              ' only reads a drive or ISO.',
            ),
            h('li', {}, h('strong', {}, 'Check the drive it shows. '), 'Every drive is listed with its number, model, serial, size, bus and volumes. The drive of the running Windows, internal and external hard disks and Ventoy drives are never erased; erasing needs the confirmation code of that exact drive and administrator rights.'),
            h('li', {}, h('strong', {}, 'Read the readiness report. '), '"Ready for installation" means files, Windows image, edition, boot files and every hash were verified. It does not mean the drive was booted on a computer.'),
          ),
          usbNeeds,
          usbBackup,
          usbDrivers,
          h('div', { class: 'action-stack' }, assistantBtn),
          h('pre', { class: 'mig-cmd usb-cmd', 'aria-label': 'Assistant commands' }, `.\\${ASSISTANT_SCRIPT} -Mode Discover
.\\${ASSISTANT_SCRIPT} -Mode Plan -Workflow Update -Package windows-deployment-package.zip -Target E:
.\\${ASSISTANT_SCRIPT} -Mode Apply -PlanPath <plan.json>
.\\${ASSISTANT_SCRIPT} -Mode Verify -Target E: -Package windows-deployment-package.zip`),
          h('p', { class: 'desc' }, `Windows release information in the assistant: Microsoft release-health data verified ${WINDOWS_RELEASES.verifiedUtc}; an image older than the latest update level is flagged, and Windows Update installs the rest after setup. Prefer extracting the ZIP by hand? The steps above still work.`),
        ),
      ),
      h(
        'aside',
        { class: 'review-side' },
        card('actions-card', head('Download', 'archive', 'Built in this browser from the current configuration.'), h('div', { class: 'action-stack' }, downloadBtn, xmlOnly)),
        card('stages-card', head('Stage order', 'layers', 'What runs after installation, in which context.'), stages),
        card(
          'recovery-card',
          head('Manual recovery', 'terminal', 'On the installed computer, in an elevated PowerShell window.'),
          h(
            'dl',
            { class: 'recovery' },
            h('dt', {}, 'Show progress'),
            h('dd', {}, h('code', {}, `powershell -ExecutionPolicy Bypass -File "${PACKAGE_ROOT}\\${STATUS_SCRIPT.replace(/\//g, '\\')}"`)),
            h('dt', {}, 'Resume after a problem'),
            h('dd', {}, h('code', {}, `powershell -ExecutionPolicy Bypass -File "${PACKAGE_ROOT}\\${RESUME_SCRIPT.replace(/\//g, '\\')}"`)),
            h('dt', {}, 'Restart one stage'),
            h('dd', {}, h('code', {}, '… Resume-Deployment.ps1 -RestartStage applications')),
            h('dt', {}, 'Run on another installation'),
            h('dd', {}, 'Right-click ', h('code', {}, `${PACKAGE_DIR}\\setup.cmd`), ' › Run as administrator'),
            h('dt', {}, 'Logs and report'),
            h('dd', {}, h('code', {}, `${DATA_ROOT}\\Deployment\\logs`), ' · ', h('code', {}, `${DATA_ROOT}\\reports`)),
          ),
        ),
      ),
    ),
  );

  return {
    el,
    update(p, result) {
      profileRef = p;
      resultRef = result;
      pkg = null;
      usbAnswer.textContent = `${p.output.answerFileName}          (this package)`;
      const need = mediaRequirements(p);
      usbNeeds.textContent = need.dismEditionId
        ? `This deployment needs media with ${need.editionName} (EditionId ${need.dismEditionId}) for ${need.architectures.join('/')}; the assistant refuses media without it and never installs another edition instead.`
        : `The edition is not fixed by a generic key (${need.editionMode}); the assistant checks the architecture (${need.architectures.join('/')}) and reports the editions on the media.`;
      usbBackup.textContent = settingsRestoreActive(p)
        ? `This deployment restores application settings: give the assistant the backup folder ${p.migration.backup!.folderName}. It is checked against the pinned SHA-256 and copied to WindowsDeployment\\backups\\${p.migration.backup!.folderName}. The drive then holds personal configuration data: keep it private.`
        : 'No settings backup is needed for this deployment.';
      const dm = driverMediaBlock(p);
      usbDrivers.textContent = dm
        ? `This deployment uses the offline driver bundle ${dm.bundle.folderName}: give the assistant that folder (-Drivers). It is checked against the pinned SHA-256 and copied to WindowsDeployment\\drivers\\${dm.bundle.folderName}${dm.setupCritical ? `; ${dm.setupCritical.packages.length} storage driver(s) go to $WinPEDriver$\\${dm.bundle.folderName} so Windows Setup can see the disk (required)` : ''}.`
        : 'No offline drivers are needed on the drive for this deployment.';
      const errors = result.issues.filter((i) => i.severity === 'error');
      clear(status);
      clear(contents);
      clear(stages);
      downloadBtn.disabled = !result.ok;
      xmlOnly.disabled = !result.ok;
      if (!result.ok) {
        status.className = 'status-card error';
        status.append(
          h('div', { class: 'status-icon' }, icon('x')),
          h('div', { class: 'status-body' }, h('div', { class: 'status-title' }, h('strong', {}, `Package blocked: ${errors.length} problem(s) to fix`)), h('p', {}, 'The package is built from a valid answer file only. See Review & download for the list.'), h('a', { href: '#section-review' }, 'Go to Review & download')),
        );
        sizeLabel.textContent = 'unavailable';
        contents.append(h('li', { class: 'empty' }, 'Available once the errors are fixed.'));
        return;
      }
      const x = ensure()!;
      const warnings = x.warnings;
      status.className = `status-card ${warnings.length ? 'warn' : 'ok'}`;
      status.append(
        h('div', { class: 'status-icon' }, icon('check')),
        h(
          'div',
          { class: 'status-body' },
          h('div', { class: 'status-title' }, h('strong', {}, `Ready: ${x.fileName}`), warnings.length ? h('span', { class: 'pill warn' }, icon('alert'), `${warnings.length} warning${warnings.length === 1 ? '' : 's'}`) : null),
          h('p', {}, `${x.entries.length} files, ${kb(x.zip.length)}. Package ${x.manifest.packageId}.`),
          warnings.length ? h('ul', { class: 'status-list' }, warnings.map((w) => h('li', { class: 'warning' }, icon('alert'), h('span', {}, w)))) : null,
        ),
      );
      sizeLabel.textContent = `${x.fileName} · ${kb(x.zip.length)}`;
      for (const e of x.entries) {
        const depth = e.path.split('/').length - 1;
        contents.append(
          h(
            'li',
            { 'data-file': e.path, style: `--depth:${depth}` },
            icon(e.path.endsWith('.ps1') || e.path.endsWith('.cmd') ? 'terminal' : e.path.endsWith('.json') ? 'code' : 'file'),
            h('code', {}, e.path),
            h('span', { class: `badge role-${e.role}` }, ROLE_LABELS[e.role] ?? e.role),
            h('span', { class: 'asset-size' }, kb(e.size)),
            h('span', { class: 'choice-desc' }, e.description),
          ),
        );
      }
      for (const s of [...x.manifest.stages].sort((a, b) => a.order - b.order)) {
        const state = !s.implemented ? ['Not implemented', 'muted'] : s.enabled ? ['On', 'ok'] : ['Off', 'muted'];
        const where = s.id === 'drivers' && s.enabled ? ' · offline drivers from the bundle; downloads only verified packages' : '';
        stages.append(
          h(
            'li',
            { 'data-stage': s.id },
            h('span', { class: 'step-num' }, String(s.order)),
            h(
              'div',
              {},
              h('strong', {}, s.name, ' ', h('span', { class: `pill ${state[1]}` }, state[0]!)),
              h('span', {}, `${s.context === 'SYSTEM' ? 'Runs as SYSTEM' : 'Runs as the signed-in user (elevated)'}${s.requiresInternet ? ' · needs Internet' : ' · works offline'}${where}`),
            ),
          ),
        );
      }
    },
  };
}
