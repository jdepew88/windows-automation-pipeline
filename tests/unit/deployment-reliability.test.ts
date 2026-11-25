import { describe, expect, it } from 'vitest';
import initializeSource from '../../src/engine/deployment/scripts/Initialize-Deployment.ps1?raw';
import showSource from '../../src/engine/deployment/scripts/Show-DeploymentStatus.ps1?raw';
import serverSource from '../../src/engine/deployment/scripts/DeploymentStatusServer.ps1?raw';
import orchestratorSource from '../../src/engine/deployment/scripts/DeploymentOrchestrator.ps1?raw';
import completeSource from '../../src/engine/deployment/scripts/Complete-Deployment.ps1?raw';
import wuEngineSource from '../../src/engine/windows-update/scripts/WindowsUpdateEngine.ps1?raw';
import { buildManifest, MONITOR_FINAL_REPORT_HOURS, ORCHESTRATOR_LIMITS, packageFiles, PROGRESS_REFRESH_SECONDS, STATUS_SERVER_SCRIPT } from '../../src/engine/deployment';
import { engineConfig } from '../../src/engine/windows-update';
import { ownerDefaults } from '../../src/engine/profiles';
import { migrate } from '../../src/engine/profiles/migrations';
import { validateProfile } from '../../src/engine/validation/validate';
import { generateOk, profile } from './helpers';

/**
 * Deployment reliability (orchestrator 1.2.0, Windows Update engine 1.2.0, application engine
 * 1.4.0): what the generated package declares and static guarantees of the shipped scripts. The
 * behaviour itself is tested in tests/powershell (Engine, Applications, Deployment, Monitor).
 */

const fnBody = (src: string, name: string) => {
  const t = src.replace(/\r\n/g, '\n');
  const start = t.indexOf(`function ${name} {`);
  expect(start, name).toBeGreaterThanOrEqual(0);
  const next = t.indexOf('\nfunction ', start + 10);
  return t.slice(start, next < 0 ? undefined : next);
};

describe('owner defaults', () => {
  it('Windows Update installs recommended and optional updates, optional drivers included, three attempts each', () => {
    const p = ownerDefaults();
    expect(p.windowsUpdate.optionalUpdates).toBe('install');
    expect(p.windowsUpdate.maxAttemptsPerUpdate).toBe(3);
    expect(p.windowsUpdate.featureUpdates).toBe('skip');
    const c = engineConfig(p);
    expect(c).toMatchObject({ optionalUpdates: 'install', drivers: 'include', featureUpdates: 'skip', maxAttemptsPerUpdate: 3, retryDelaySeconds: 120 });
  });

  it('the deployment monitor is on, bound to the computer itself (LAN access off), port 8765', () => {
    expect(ownerDefaults().monitoring).toEqual({ enabled: true, lanAccess: false, port: 8765 });
  });

  it('applications keep three attempts per package', () => {
    expect(ownerDefaults().applications.maxAttemptsPerPackage).toBe(3);
  });
});

describe('manifest and package', () => {
  it('declares the progress window (7 s) and the monitor; ships and embeds the status server', () => {
    const p = profile();
    const m = buildManifest(p).manifest;
    expect(m.progress).toEqual({ task: '\\WindowsDeploymentBuilder\\Progress', refreshSeconds: 7, opensAtSignIn: true });
    expect(m.monitor).toEqual({
      enabled: true,
      port: 8765,
      lanAccess: false,
      refreshSeconds: PROGRESS_REFRESH_SECONDS,
      finalReportHours: MONITOR_FINAL_REPORT_HOURS,
      script: STATUS_SERVER_SCRIPT,
      task: '\\WindowsDeploymentBuilder\\StatusServer',
      readOnly: true,
      firewall: null,
    });
    const f = packageFiles(p).find((x) => x.path === STATUS_SERVER_SCRIPT);
    expect(f?.embedded).toBe('Deployment\\scripts\\monitor\\DeploymentStatusServer.ps1');
    // Embedded files that are not .ps1 must be ASCII; the server is .ps1 but stays ASCII anyway.
    expect([...f!.content].every((c) => c.charCodeAt(0) < 128)).toBe(true);
    expect(generateOk(p).xml).toContain('DeploymentStatusServer.ps1');
  });

  it('LAN access adds a Private/local-subnet firewall rule declaration; off means no server at all', () => {
    const lan = buildManifest(profile((p) => (p.monitoring.lanAccess = true))).manifest;
    expect(lan.monitor).toMatchObject({ lanAccess: true, firewall: { profile: 'Private', remoteAddress: 'LocalSubnet', protocol: 'TCP' } });
    const off = profile((p) => (p.monitoring.enabled = false));
    expect(buildManifest(off).manifest.monitor).toEqual({ enabled: false });
    expect(packageFiles(off).some((x) => x.path === STATUS_SERVER_SCRIPT)).toBe(false);
  });

  it('orchestrator limits: monitor every 5 minutes, bounded automatic recovery, longer limit for Windows Update', () => {
    expect(ORCHESTRATOR_LIMITS).toMatchObject({ monitorIntervalMinutes: 5, autoRecoveries: 2, stalledAfterMinutes: 120, longOperationMinutes: 240 });
    expect(buildManifest(profile()).manifest.failureHandling.orchestrator).toMatchObject({ monitorIntervalMinutes: 5, autoRecoveries: 2, longOperationMinutes: 240 });
  });

  it('the README and installation guide explain the progress window and how to reach the monitor', () => {
    const files = packageFiles(profile((p) => (p.monitoring.lanAccess = true)));
    const readme = files.find((x) => x.path === 'README.txt')!.content;
    const install = files.find((x) => x.path === 'docs/INSTALLATION.txt')!.content;
    expect(readme).toMatch(/opens by itself at every\s+sign-in/);
    expect(readme).toContain('http://192.168.1.100:8765/#t=<access token>');
    expect(install).toMatch(/opens again after every restart and sign-in/);
    expect(install).toContain('Private networks, local subnet');
  });
});

describe('profiles and validation', () => {
  it('an older (schema 7) profile gets no monitor and keeps generating the same kind of package', () => {
    const v7 = { ...JSON.parse(JSON.stringify(ownerDefaults())), schemaVersion: 7 } as Record<string, unknown>;
    delete v7.monitoring;
    const r = migrate(v7);
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.value.monitoring).toEqual({ enabled: false, lanAccess: false });
      expect(r.notes.join(' ')).toMatch(/deployment monitor .*turned off/);
    }
  });

  it('rejects a monitor port outside 1024-65535', () => {
    for (const port of [80, 70000, 1.5]) {
      const { issues } = validateProfile(profile((p) => (p.monitoring.port = port)));
      expect(issues.some((i) => i.path === 'monitoring.port' && i.severity === 'error'), String(port)).toBe(true);
    }
    expect(validateProfile(profile()).issues.some((i) => i.path === 'monitoring.port')).toBe(false);
  });
});

describe('shipped scripts: static guarantees', () => {
  it('the progress window opens at sign-in as the user without elevation, once per session, every 7 seconds', () => {
    const reg = fnBody(initializeSource, 'Register-WddProgressTask');
    expect(reg).toMatch(/New-ScheduledTaskTrigger -AtLogOn -User \$User/);
    expect(reg).toMatch(/-LogonType Interactive -RunLevel Limited/);
    expect(reg).toMatch(/-MultipleInstances IgnoreNew/);
    expect(reg).toMatch(/\[int\] \$IntervalSeconds = 7/);
    expect(showSource).toMatch(/\[int\] \$IntervalSeconds = 7/);
    expect(showSource).not.toMatch(/IntervalSeconds = 15/);
    expect(showSource).toMatch(/Local\\WindowsDeploymentBuilder-Progress/);
    expect(completeSource).toContain("Unregister-WddTask '\\WindowsDeploymentBuilder\\' 'Progress'");
  });

  it('the status server is read-only: GET/HEAD only, no command execution, no restart, no file serving', () => {
    expect(serverSource).toMatch(/if \(\$Method -notin 'GET', 'HEAD'\)/);
    for (const bad of [/Invoke-Expression/i, /\biex\b/i, /Start-Process/i, /Restart-Computer/i, /Stop-Computer/i, /shutdown\.exe/i, /Get-Content\s+-Path\s+\$/i, /Access-Control-Allow-Origin/i]) {
      expect(serverSource, String(bad)).not.toMatch(bad);
    }
    // Only these routes exist.
    const routes = [...serverSource.matchAll(/^\s{8}'(\/[a-z./]*)' \{/gm)].map((m) => m[1]).sort();
    expect(routes).toEqual(['/api/status', '/app.css', '/app.js', '/favicon.ico']);
  });

  it('the firewall rule is limited to Private networks and the local subnet; no port forwarding or UPnP', () => {
    const fw = fnBody(serverSource, 'Set-WddMonitorFirewall');
    expect(fw).toMatch(/-Direction Inbound -Action Allow -Protocol TCP -LocalPort \$Port -Profile Private -RemoteAddress LocalSubnet/);
    expect(serverSource).not.toMatch(/portproxy|UPnP|NATUPnP|-Profile Any|-Profile Public/i);
  });

  it('the LAN prefix is used only when LAN access is enabled; otherwise 127.0.0.1/localhost', () => {
    const start = fnBody(serverSource, 'Start-WddStatusServer');
    expect(start).toMatch(/if \(\$Settings\.lanAccess\) \{ @\("http:\/\/\+:\$\(\$Settings\.port\)\/"\) \} else \{ @\("http:\/\/127\.0\.0\.1:\$\(\$Settings\.port\)\/", "http:\/\/localhost:\$\(\$Settings\.port\)\/"\) \}/);
  });

  it('the watchdog never starts the WinGet (user) stage from SYSTEM and is bounded', () => {
    const wd = fnBody(orchestratorSource, 'Invoke-WddWatchdog');
    expect(wd).toMatch(/if \(\$stage\.context -eq 'user'\)/);
    expect(wd).toMatch(/if \(\$used -ge \$max\)/);
  });

  it('Windows Update: "can request user input" alone is no reason to skip; feature updates and Insider builds never install by default', () => {
    const skip = fnBody(wuEngineSource, 'Get-WduSkipReason');
    expect(skip).not.toMatch(/NeedsUserInput/);
    expect(skip).toMatch(/Insider Preview build \(never installed\)/);
    expect(wuEngineSource).toMatch(/try \{ \$inst\.ForceQuiet = \$true \} catch \{ \}/);
  });
});
