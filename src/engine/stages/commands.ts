/**
 * Command-line builders. Adapted from upstream `CommandBuilder` (Main.cs, MIT).
 * These return raw strings; XML escaping happens only in the serializer.
 */

export class CommandError extends Error {}

export class CommandBuilder {
  constructor(private readonly hidePowerShellWindows: boolean) {}

  private get windowStyle(): string {
    return this.hidePowerShellWindows ? 'Hidden' : 'Normal';
  }

  shell(command: string): string {
    return `cmd.exe /c "${command}"`;
  }

  registry(args: string): string {
    return `reg.exe ${args}`;
  }

  /**
   * Inline PowerShell for a single XML command line. The command must not contain double quotes
   * (which would end the -Command argument) and must end with `;` or `}`.
   */
  powerShell(command: string): string {
    if (command.includes('"')) throw new CommandError(`PowerShell command must not contain '"': ${command}`);
    if (!command.endsWith(';') && !command.endsWith('}')) throw new CommandError(`PowerShell command must end with ';' or '}': ${command}`);
    return `powershell.exe -WindowStyle "${this.windowStyle}" -NoProfile -Command "${command}"`;
  }

  /** `-ExecutionPolicy Unrestricted` applies to this process only; it is not the machine policy. */
  powerShellFile(path: string): string {
    return `powershell.exe -WindowStyle "${this.windowStyle}" -ExecutionPolicy "Unrestricted" -NoProfile -File "${path}"`;
  }

  vbScript(path: string): string {
    return `cscript.exe //E:vbscript "${path}"`;
  }
}

/** Quotes a value as a single-quoted PowerShell string literal. */
export function psQuote(value: string): string {
  return `'${value.replace(/'/g, "''").replace(/[‘’‚‛]/g, (m) => m + m)}'`;
}
