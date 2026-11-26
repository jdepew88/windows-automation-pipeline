import type { Profile } from './schema/profile';
import type { DeploymentAsset } from './windows-update';
import { COMPLETION_MARKER, DATA_ROOT, RESULT_FILE, TASK_NAME, TASK_PATH } from './windows-update';
import { APP_MARKER, APP_RESULT_FILE, APP_TASK_NAME, applicationsActive } from './applications';
import { FINAL_STATUSES, MARKER_STATUSES } from './applications/results';
import { DRIVER_FINAL_STATUSES, DRIVER_MARKER_STATUSES, DRIVER_STAGE } from './drivers/contract';
import { DRIVER_TASK_NAME, driversActive } from './drivers';
import { OFFICE_FINAL_STATUSES, OFFICE_STAGE, OFFICE_TASK_NAME, officeActive } from './office';

/**
 * The orchestration contract (orchestration.json): which stages exist, in which order, who runs
 * them, how they coordinate and where each one reports. The future deployment ZIP / setup.ps1
 * orchestrator reads this instead of hard-coding paths.
 */

export const STATE_DIR = `${DATA_ROOT}\\state`;
export const INSTALL_LOCK = `${STATE_DIR}\\install.lock`;
export const RESTART_MARKER = `${STATE_DIR}\\restart-pending.json`;

export function orchestrationContract(p: Profile) {
  return {
    schemaVersion: 1,
    dataRoot: DATA_ROOT,
    coordination: {
      policy: p.applications.coordination,
      description:
        'updatesFirst: preparation (network, WinGet check, package availability) may run while Windows Update works; application installation starts only after the Windows Update stage is final. Installing anything and scheduling a restart both require the install lock.',
      installLock: INSTALL_LOCK,
      restartMarker: RESTART_MARKER,
      lockSemantics: 'Exclusive file handle; released by Windows when the holder exits. restart-pending.json is valid only in the boot it was written in (and for 30 minutes).',
    },
    stages: [
      {
        id: 'windowsUpdate',
        order: 1,
        enabled: p.windowsUpdate.enabled,
        implemented: true,
        runsAs: 'SYSTEM',
        task: `${TASK_PATH}${TASK_NAME}`,
        result: RESULT_FILE,
        marker: COMPLETION_MARKER,
        finalStatuses: ['Succeeded', 'CompletedWithFailures', 'Failed', 'Offline'],
        markerStatuses: ['Succeeded', 'CompletedWithFailures'],
        waitsFor: [],
      },
      {
        id: 'applications',
        order: 2,
        enabled: applicationsActive(p),
        implemented: true,
        runsAs: 'Signed-in user, elevated (WinGet is not supported as SYSTEM)',
        task: `${TASK_PATH}${APP_TASK_NAME}`,
        result: APP_RESULT_FILE,
        marker: APP_MARKER,
        finalStatuses: [...FINAL_STATUSES],
        markerStatuses: [...MARKER_STATUSES],
        waitsFor: [...(p.windowsUpdate.enabled ? ['windowsUpdate'] : []), ...(driversActive(p) ? ['drivers'] : [])],
        includes: ['winget packages', 'additionalSoftware'],
      },
      {
        id: DRIVER_STAGE.id,
        order: 3,
        enabled: driversActive(p),
        implemented: true,
        phase: DRIVER_STAGE.phase,
        runsAs: DRIVER_STAGE.runsAs,
        task: `${TASK_PATH}${DRIVER_TASK_NAME}`,
        inventory: [...DRIVER_STAGE.inventoryFiles],
        result: DRIVER_STAGE.resultFile,
        report: DRIVER_STAGE.reportFile,
        marker: DRIVER_STAGE.marker,
        finalStatuses: [...DRIVER_FINAL_STATUSES],
        markerStatuses: [...DRIVER_MARKER_STATUSES],
        waitsFor: p.windowsUpdate.enabled && p.drivers.useWindowsUpdate ? [...DRIVER_STAGE.waitsFor] : [],
        note: driversActive(p)
          ? 'Inspection before Windows Update (and network bootstrap from verified offline packages), resolution only after the Windows Update stage is final and restarted. Installing a driver and scheduling a restart both require the install lock.'
          : 'Off for this deployment: no driver is installed or changed.',
      },
      // Schema 9: only when Office is selected, so other contracts keep their shape.
      ...(officeActive(p)
        ? [
            {
              id: OFFICE_STAGE.id,
              order: 4,
              enabled: true,
              implemented: true,
              runsAs: 'SYSTEM',
              task: `${TASK_PATH}${OFFICE_TASK_NAME}`,
              result: OFFICE_STAGE.resultFile,
              marker: OFFICE_STAGE.marker,
              finalStatuses: [...OFFICE_FINAL_STATUSES],
              waitsFor: [...(p.windowsUpdate.enabled ? ['windowsUpdate'] : []), ...(applicationsActive(p) ? ['applications'] : [])],
              note: 'Installs Office LTSC under the install lock after the applications, then verifies it. Never activates it.',
            },
          ]
        : []),
    ],
  };
}

/** The orchestration.json deployment asset (also included in the deployment package). */
export function orchestrationAsset(p: Profile): DeploymentAsset {
  return {
    name: 'orchestration.json',
    content: (JSON.stringify(orchestrationContract(p), null, 2) + '\n').replace(/\r?\n/g, '\r\n'),
    mime: 'application/json',
    description: 'Stages, order, coordination locks and result files for the deployment orchestrator',
    group: 'orchestration',
  };
}
