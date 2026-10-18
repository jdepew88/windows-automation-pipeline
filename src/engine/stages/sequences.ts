/**
 * Ordered PowerShell command sequences for the four script stages. Each one becomes a single .ps1
 * file that logs every step. Adapted from upstream `PowerShellSequence` (Main.cs, MIT).
 */

export type SequenceKind = 'specialize' | 'defaultUser' | 'userOnce' | 'firstLogon';

const META: Record<SequenceKind, { activity: string; logFile: string; fileName: string }> = {
  specialize: {
    activity: 'Running scripts to customize your Windows installation.',
    logFile: 'C:\\Windows\\Setup\\Scripts\\Specialize.log',
    fileName: 'Specialize.ps1',
  },
  defaultUser: {
    activity: "Running scripts to modify the default user's registry hive.",
    logFile: 'C:\\Windows\\Setup\\Scripts\\DefaultUser.log',
    fileName: 'DefaultUser.ps1',
  },
  userOnce: {
    activity: 'Running scripts to configure this user account.',
    logFile: '$env:TEMP\\UserOnce.log',
    fileName: 'UserOnce.ps1',
  },
  firstLogon: {
    activity: 'Running scripts to finalize your Windows installation.',
    logFile: 'C:\\Windows\\Setup\\Scripts\\FirstLogon.log',
    fileName: 'FirstLogon.ps1',
  },
};

const RESTART_EXPLORER = `Get-Process -Name 'explorer' -ErrorAction 'SilentlyContinue' | Where-Object -FilterScript {
	$_.SessionId -eq ( Get-Process -Id $PID ).SessionId;
} | Stop-Process -Force;`;

export class PowerShellSequence {
  private readonly commands: string[] = [];
  private restartExplorer = false;

  constructor(readonly kind: SequenceKind) {}

  get fileName(): string {
    return META[this.kind].fileName;
  }

  append(command: string): void {
    this.commands.push(command.trim());
  }

  invokeFile(path: string): void {
    this.append(`& '${path.replace(/'/g, "''")}';`);
  }

  requestExplorerRestart(): void {
    this.restartExplorer = true;
  }

  get isEmpty(): boolean {
    return this.commands.length === 0;
  }

  get length(): number {
    return this.commands.length;
  }

  getScript(): string {
    const { activity, logFile } = META[this.kind];
    const blocks = [...this.commands, ...(this.restartExplorer ? [RESTART_EXPLORER] : [])];
    const lines: string[] = ['$scripts = @('];
    for (const command of blocks) {
      lines.push('\t{');
      for (const line of command.split(/\r?\n/)) lines.push(`\t\t${line}`);
      lines.push('\t};');
    }
    lines.push(');', '');
    lines.push(`& {
  [float] $complete = 0;
  [float] $increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity '${activity.replace(/'/g, "''")} Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command «{0}».' -f $(
      $script.ToString().Trim() -replace '\\s+', ' ' -replace '^(.{99})(.+)$', '$1…';
    );
    $start = [datetime]::Now;
    & $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "\`r\`n" * 3;
    $complete += $increment;
  }
} *>&1 | Out-String -Width 1KB -Stream >> "${logFile}";`);
    return lines.join('\r\n');
  }
}
