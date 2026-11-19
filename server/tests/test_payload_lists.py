"""Keep launcher staging and bundle contents aligned with the server payload."""
import re
import unittest

from test_server_apply import app, SOURCE


class PayloadListsTests(unittest.TestCase):
    def test_launcher_names_cover_installed_code(self):
        script = (SOURCE.parent / 'build/Wizard.ServerApply.ps1').read_text(encoding='utf-8-sig')
        names = re.search(r"\$names\s*=\s*@\((.*?)\)", script, re.S)
        self.assertIsNotNone(names)
        staged = set(re.findall(r"'([^']+)'", names[1]))
        self.assertFalse(set(app.CODE_FILES) - staged)

    def test_bundle_covers_installed_code(self):
        bundled = set((SOURCE.parent / 'build/bundle-files.txt').read_text().splitlines())
        self.assertFalse({'server/' + name for name in app.CODE_FILES} - bundled)

    def test_installed_code_exists(self):
        for name in app.CODE_FILES:
            with self.subTest(name=name):
                self.assertTrue((SOURCE / name).is_file())
