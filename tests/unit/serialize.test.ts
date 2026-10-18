import { describe, expect, it } from 'vitest';
import { XmlCharacterError, escapeAttr, escapeText, findInvalidXmlChar, serialize, serializeFragment } from '../../src/engine/xml/serialize';
import { parseXml } from '../../src/engine/xml/parse';
import { NS, el, leaf, text, textContent, elements } from '../../src/engine/xml/tree';

describe('XML escaping', () => {
  it('escapes markup characters in text', () => {
    expect(escapeText('a & b < c > d "e" \'f\'')).toBe('a &amp; b &lt; c &gt; d "e" \'f\'');
  });

  it('escapes quotes and whitespace in attributes', () => {
    expect(escapeAttr('say "hi" & <go>\t\n')).toBe('say &quot;hi&quot; &amp; &lt;go&gt;&#x9;&#xA;');
  });

  it('writes non-ASCII as character references so output is pure ASCII', () => {
    expect(escapeText('Zoë 😀 Ñ')).toBe('Zo&#xEB; &#x1F600; &#xD1;');
    const xml = serialize(el('unattend', NS.unattend, [leaf('Name', 'Zoë Ålund')]));
    expect(/^[\t\n\r\x20-\x7e]*$/.test(xml)).toBe(true);
  });

  it('rejects characters XML 1.0 cannot represent', () => {
    expect(() => escapeText('bell\u0007')).toThrow(XmlCharacterError);
    expect(() => escapeText('lone\uD800surrogate')).toThrow(XmlCharacterError);
    expect(findInvalidXmlChar('ok\ttab\nline')).toBeUndefined();
    expect(findInvalidXmlChar('nul\u0000')).toBe(0);
  });

  it('round-trips hostile strings through a real parser', () => {
    const hostile = `"'&<>]]><!-- --><?pi?>&amp;${'\\'}Ω`;
    const xml = serialize(el('unattend', NS.unattend, [el('X', NS.unattend, [text(hostile)], [{ name: 'a', value: hostile }])]));
    const parsed = parseXml(xml);
    expect(parsed.errors).toEqual([]);
    const x = elements(parsed.root!)[0]!;
    expect(textContent(x)).toBe(hostile);
    expect(x.attrs[0]!.value).toBe(hostile);
  });
});

describe('serializer layout and namespaces', () => {
  it('uses CRLF, tabs, an XML declaration and declares prefixes once', () => {
    const root = el('unattend', NS.unattend, [el('A', NS.unattend, [], [{ name: 'action', value: 'add', ns: NS.wcm, prefix: 'wcm' }])]);
    root.declare = [{ prefix: 'wcm', uri: NS.wcm }];
    const xml = serialize(root);
    expect(xml).toBe(
      '<?xml version="1.0" encoding="utf-8"?>\r\n<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">\r\n\t<A wcm:action="add" />\r\n</unattend>\r\n',
    );
  });

  it('switches the default namespace for foreign elements', () => {
    const xml = serializeFragment(el('root', 'urn:a', [el('child', 'urn:b', [leaf('leaf', 'v', 'urn:b')])]));
    expect(xml).toContain('<child xmlns="urn:b">');
    expect(xml).toContain('<leaf>v</leaf>');
    expect(parseXml(xml).errors).toEqual([]);
  });
});
