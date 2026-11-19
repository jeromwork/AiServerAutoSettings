"""Keep launcher staging and bundle contents aligned with the server payload."""
import re
import unittest

from test_server_apply import app, SOURCE


class PayloadListsTests(unittest.TestCase):
    def launcher_foreach_lists(self):
        script = (SOURCE.parent / 'build/Wizard.ServerApply.ps1').read_text(encoding='utf-8-sig')
        lists = re.findall(r"foreach\s*\(\s*\$name\s+in\s+@\((.*?)\)\s*\)", script, re.S)
        self.assertEqual(len(lists), 2, 'Expected schema/gateway and assets foreach lists')
        return [set(re.findall(r"'([^']+)'", items)) for items in lists]

    def test_launcher_names_cover_installed_code(self):
        script = (SOURCE.parent / 'build/Wizard.ServerApply.ps1').read_text(encoding='utf-8-sig')
        names = re.search(r"\$names\s*=\s*@\((.*?)\)", script, re.S)
        self.assertIsNotNone(names)
        staged = set(re.findall(r"'([^']+)'", names[1]))
        missing = set(app.CODE_FILES) - staged
        self.assertFalse(missing, 'Launcher is missing code files: ' + ', '.join(sorted(missing)))

    def test_launcher_foreach_lists_cover_installed_payload(self):
        staged, assets = self.launcher_foreach_lists()
        required = {'config.paste.schema.json'} | {'tg-gateway/' + name for name in app.TG_GATEWAY_FILES}
        missing = required - staged
        self.assertFalse(missing, 'Launcher is missing schema/gateway files: ' + ', '.join(sorted(missing)))
        self.assertSetEqual(set(app.components.ASSETS), assets)

    def test_bundle_covers_installed_code(self):
        lines = (SOURCE.parent / 'build/bundle-files.txt').read_text().splitlines()
        # Bundle entries may rename a source, notably the launcher schema.
        bundled = {line.split('=>')[-1].strip() for line in lines
                   if line.strip() and not line.lstrip().startswith('#')}
        required = ({'server/' + name for name in app.CODE_FILES}
                    | {'server/config.paste.schema.json'}
                    | {'server/tg-gateway/' + name for name in app.TG_GATEWAY_FILES}
                    | set(app.components.ASSETS))
        missing = required - bundled
        self.assertFalse(missing, 'Bundle is missing payload files: ' + ', '.join(sorted(missing)))

    def test_installed_code_exists(self):
        for name in app.CODE_FILES:
            with self.subTest(name=name):
                self.assertTrue((SOURCE / name).is_file())
