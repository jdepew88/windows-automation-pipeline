import type { Pass, Profile } from './schema/profile';
import { CommandBuilder } from './stages/commands';
import { PowerShellSequence, type SequenceKind } from './stages/sequences';
import { NS, append, child, el, elements, getAttr, leaf, setAttr, text, type XElement } from './xml/tree';
import type { Issue } from './validation/issues';
import type { Identity } from './naming';

export const SCRIPTS_DIR = 'C:\\Windows\\Setup\\Scripts';
export const PUBLIC_KEY_TOKEN = '31bf3856ad364e35';
export const PASSES: Pass[] = ['offlineServicing', 'windowsPE', 'generalize', 'specialize', 'auditSystem', 'auditUser', 'oobeSystem'];

export type CommandStage = 'windowsPE' | 'specialize' | 'firstLogon';

export interface EmbeddedFile {
  path: string;
  content: string;
}

/**
 * Mutable state shared by the feature modifiers while one answer file is generated.
 * Modifiers only touch the document through these helpers, which keeps component placement,
 * namespaces and command containers consistent.
 */
export class GenContext {
  readonly root: XElement;
  readonly cmd: CommandBuilder;
  readonly seq: Record<SequenceKind, PowerShellSequence>;
  readonly files: EmbeddedFile[] = [];
  readonly issues: Issue[] = [];
  private extractorAdded = false;

  constructor(
    readonly profile: Profile,
    readonly identity: Identity,
  ) {
    this.cmd = new CommandBuilder(profile.setup.hidePowerShellWindows);
    this.seq = {
      specialize: new PowerShellSequence('specialize'),
      defaultUser: new PowerShellSequence('defaultUser'),
      userOnce: new PowerShellSequence('userOnce'),
      firstLogon: new PowerShellSequence('firstLogon'),
    };
    this.root = createBaseDocument();
  }

  settings(pass: Pass): XElement {
    const s = elements(this.root).find((e) => e.name === 'settings' && getAttr(e, 'pass') === pass);
    if (!s) throw new Error(`settings pass="${pass}" missing from base document`);
    return s;
  }

  findComponent(pass: Pass, name: string): XElement | undefined {
    return elements(this.settings(pass)).find((e) => e.name === 'component' && getAttr(e, 'name') === name);
  }

  component(pass: Pass, name: string): XElement {
    return this.findComponent(pass, name) ?? append(this.settings(pass), newComponent(name));
  }

  /** Gets or creates a direct child element of a component. */
  componentChild(pass: Pass, component: string, element: string): XElement {
    const comp = this.component(pass, component);
    return child(comp, element) ?? append(comp, el(element));
  }

  setValue(pass: Pass, component: string, element: string, value: string): void {
    const comp = this.component(pass, component);
    const existing = child(comp, element);
    if (existing) existing.children = [text(value)];
    else append(comp, leaf(element, value));
  }

  appendCommand(stage: CommandStage, commandLine: string): void {
    const [pass, component, container, item, field]: [Pass, string, string, string, string] =
      stage === 'windowsPE'
        ? ['windowsPE', 'Microsoft-Windows-Setup', 'RunSynchronous', 'RunSynchronousCommand', 'Path']
        : stage === 'specialize'
          ? ['specialize', 'Microsoft-Windows-Deployment', 'RunSynchronous', 'RunSynchronousCommand', 'Path']
          : ['oobeSystem', 'Microsoft-Windows-Shell-Setup', 'FirstLogonCommands', 'SynchronousCommand', 'CommandLine'];
    const c = this.componentChild(pass, component, container);
    append(c, el(item, NS.unattend, [leaf(field, commandLine)]));
  }

  /**
   * Embeds a file in the answer file's extension block and returns its target path. The first call
   * also registers the specialize command that extracts all embedded files to disk.
   */
  embedFile(name: string, content: string): string {
    const path = name.includes('\\') ? name : `${SCRIPTS_DIR}\\${name}`;
    if (this.files.some((f) => f.path.toLowerCase() === path.toLowerCase())) {
      throw new Error(`Embedded file ${path} registered twice`);
    }
    const ext = this.extensions();
    if (!this.extractorAdded) {
      this.extractorAdded = true;
      append(ext, el('ExtractScript', NS.ext, [text(EXTRACT_SCRIPT)]));
      this.appendCommand(
        'specialize',
        this.cmd.powerShell(
          "$xml = [xml]::new(); $xml.Load('C:\\Windows\\Panther\\unattend.xml'); $sb = [scriptblock]::Create( $xml.unattend.Extensions.ExtractScript ); Invoke-Command -ScriptBlock $sb -ArgumentList $xml;",
        ),
      );
    }
    append(ext, el('File', NS.ext, [text(content)], [{ name: 'path', value: path }]));
    this.files.push({ path, content });
    return path;
  }

  private extensions(): XElement {
    // May have been pruned while still empty; it always belongs after the settings elements.
    return child(this.root, 'Extensions', NS.ext) ?? append(this.root, el('Extensions', NS.ext));
  }

  error(path: string, message: string): void {
    this.issues.push({ severity: 'error', path, message });
  }

  warn(path: string, message: string): void {
    this.issues.push({ severity: 'warning', path, message });
  }
}

/**
 * Reads embedded files from the copy of the answer file that Windows Setup keeps at
 * C:\Windows\Panther\unattend.xml. Adapted from upstream `resource/ExtractScripts.ps1` (MIT).
 */
export const EXTRACT_SCRIPT = `param(
    [xml] $Document
);

foreach( $file in $Document.unattend.Extensions.File ) {
    $path = [System.Environment]::ExpandEnvironmentVariables( $file.GetAttribute( 'path' ) );
    mkdir -Path( $path | Split-Path -Parent ) -ErrorAction 'SilentlyContinue';
    $encoding = switch( [System.IO.Path]::GetExtension( $path ) ) {
        { $_ -in '.ps1', '.xml' } { [System.Text.Encoding]::UTF8; }
        { $_ -in '.reg', '.vbs', '.js' } { [System.Text.UnicodeEncoding]::new( $false, $true ); }
        default { [System.Text.Encoding]::Default; }
    };
    $bytes = $encoding.GetPreamble() + $encoding.GetBytes( $file.InnerText.Trim() );
    [System.IO.File]::WriteAllBytes( $path, $bytes );
}`;

export function newComponent(name: string): XElement {
  const c = el('component');
  setAttr(c, 'name', name);
  setAttr(c, 'processorArchitecture', 'amd64');
  setAttr(c, 'publicKeyToken', PUBLIC_KEY_TOKEN);
  setAttr(c, 'language', 'neutral');
  setAttr(c, 'versionScope', 'nonSxS');
  return c;
}

/** Base document, mirroring upstream `resource/autounattend.xml`. */
function createBaseDocument(): XElement {
  const settings = (pass: Pass, ...components: XElement[]) => el('settings', NS.unattend, components, [{ name: 'pass', value: pass }]);
  const withChildren = (c: XElement, ...kids: XElement[]) => {
    c.children.push(...kids);
    return c;
  };
  const root = el('unattend');
  root.children.push(
    settings('offlineServicing'),
    settings(
      'windowsPE',
      withChildren(newComponent('Microsoft-Windows-International-Core-WinPE'), leaf('UILanguage', 'en-US')),
      withChildren(
        newComponent('Microsoft-Windows-Setup'),
        el('UserData', NS.unattend, [el('ProductKey', NS.unattend, [el('Key'), el('WillShowUI')]), leaf('AcceptEula', 'true')]),
        leaf('UseConfigurationSet', 'false'),
      ),
    ),
    settings('generalize'),
    settings('specialize'),
    settings('auditSystem'),
    settings('auditUser'),
    settings(
      'oobeSystem',
      withChildren(
        newComponent('Microsoft-Windows-International-Core'),
        leaf('InputLocale', 'en-US'),
        leaf('SystemLocale', 'en-US'),
        leaf('UILanguage', 'en-US'),
        leaf('UserLocale', 'en-US'),
      ),
      withChildren(
        newComponent('Microsoft-Windows-Shell-Setup'),
        el('UserAccounts'),
        el('AutoLogon'),
        el('OOBE', NS.unattend, [
          leaf('ProtectYourPC', '3'),
          leaf('HideEULAPage', 'true'),
          leaf('HideWirelessSetupInOOBE', 'true'),
          leaf('HideOnlineAccountScreens', 'false'),
        ]),
      ),
    ),
    el('Extensions', NS.ext),
  );
  // wcm namespace declared on the root, as in WSIM-authored files.
  root.declare = [{ prefix: 'wcm', uri: NS.wcm }];
  return root;
}
