#!/usr/bin/env python3
"""Static .NET Framework reference guard; requires only Python, no Windows/pwsh.

Core's automatic references cannot validate the explicit PS 5.1 assembly list.
This checks XML/serialization dependencies, including serializer overload types;
it does not replace compiling the helpers with Windows PowerShell 5.1 (C# 5).
Run: python3 transport/test-transport-events-references.py
"""
from pathlib import Path
import re
import unittest


EVENTS = Path(__file__).with_name('Transport.Events.ps1')


def required_assemblies(csharp):
    required = set()
    if re.search(r'\b(?:System\.Runtime\.Serialization|DataContractJsonSerializer|'
                 r'DataContractSerializer|XmlObjectSerializer|XmlDictionaryReader|XmlDictionaryWriter|'
                 r'DataContract(?:Attribute)?|DataMember(?:Attribute)?)\b', csharp):
        required.add('System.Runtime.Serialization.dll')
    # Both serializers expose XmlReader/XmlWriter overloads on .NET Framework.
    # csc needs System.Xml even when the chosen overload takes a Stream.
    if re.search(r'\b(?:System\.Xml|XmlReader|XmlWriter|XmlDictionaryReader|'
                 r'XmlDictionaryWriter|XmlDocument|DataContractJsonSerializer|'
                 r'DataContractSerializer|XmlObjectSerializer)\b', csharp):
        required.add('System.Xml.dll')
    return required


def check_desktop_references(script):
    source = re.search(r"\$source\s*=\s*@'\r?\n(.*?)\r?\n'@", script, re.S)
    if not source:
        raise AssertionError('Cannot locate the Transport.Events C# source')
    # Inspect only the non-Core branch compiling this source, never references
    # mentioned in comments, the C# source, or the Core Add-Type invocation.
    suffix = re.sub(r'(?m)#.*$', '', script[source.end():])
    branch = re.search(
        r"if\s*\(\s*\$PSVersionTable\.PSEdition\s+-eq\s+'Core'\s*\)"
        r'\s*\{[^{}]*\}\s*else\s*\{([^{}]*)\}', suffix)
    if not branch or not re.search(r'Add-Type\s+-TypeDefinition\s+\$source\b', branch[1]):
        raise AssertionError('Cannot locate the explicit PS 5.1 Add-Type branch')
    references = re.search(r'-ReferencedAssemblies\s+([^;\r\n}]+)', branch[1])
    assemblies = set(re.findall(r'\b[\w.]+\.dll\b', references[1])) if references else set()
    missing = required_assemblies(source[1]) - assemblies
    if missing:
        raise AssertionError('PS 5.1 Add-Type missing references: ' + ', '.join(sorted(missing)))


class DesktopReferencesTests(unittest.TestCase):
    def test_events_desktop_references(self):
        check_desktop_references(EVENTS.read_text(encoding='utf-8-sig'))

    def test_serializers_require_xml_without_an_explicit_xml_type(self):
        for serializer in ('DataContractJsonSerializer', 'DataContractSerializer', 'XmlObjectSerializer'):
            with self.subTest(serializer=serializer):
                self.assertEqual(required_assemblies(serializer), {
                    'System.Runtime.Serialization.dll', 'System.Xml.dll'})

    def test_xml_and_serialization_types(self):
        for source in ('XmlReader reader;', 'System.Xml.XmlWriter writer;'):
            with self.subTest(source=source):
                self.assertEqual(required_assemblies(source), {'System.Xml.dll'})
        self.assertEqual(required_assemblies('[DataContract] class Row { [DataMember] int Value; }'),
                         {'System.Runtime.Serialization.dll'})
        self.assertEqual(required_assemblies('XmlDictionaryReader reader;'), {
            'System.Runtime.Serialization.dll', 'System.Xml.dll'})
        self.assertEqual(required_assemblies('using System.Runtime.Serialization.Json;'),
                         {'System.Runtime.Serialization.dll'})
        self.assertEqual(required_assemblies('using System.IO; class Row {}'), set())

    def test_missing_reference_is_not_satisfied_by_core_or_comments(self):
        script = EVENTS.read_text(encoding='utf-8-sig')
        for assembly in ('System.Xml.dll', 'System.Runtime.Serialization.dll'):
            with self.subTest(assembly=assembly):
                mutated = script.replace(',' + assembly, '')
                mutated = mutated.replace(
                    "-eq 'Core') { Add-Type -TypeDefinition $source",
                    "-eq 'Core') { Add-Type -TypeDefinition $source -ReferencedAssemblies " + assembly)
                mutated += '\n# -ReferencedAssemblies ' + assembly + '\n'
                with self.assertRaisesRegex(AssertionError, re.escape(assembly)):
                    check_desktop_references(mutated)


if __name__ == '__main__':
    unittest.main(verbosity=2)
