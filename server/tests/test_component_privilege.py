"""Run privileged installer validation in a hostile caller's working directory."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]


class InstallerPrivilegeTests(unittest.TestCase):
    def test_codex_package_check_cannot_import_callers_json(self):
        script = (REPO / 'server-codex-v1.sh').read_text()
        function = re.search(r'(?ms)^check_package\(\) \{.*?^\}', script)[0]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'json.py').write_text('from pathlib import Path\nPath("EXECUTED").touch()\nraise RuntimeError("untrusted code")\n')
            # Use the real installer function, without running its apt/user setup.
            result = subprocess.run(['bash', '-c', 'version=0.166.0; target=fixture\n' + function + '\ncheck_package "$1"',
                                     'test', str(root / 'missing-package')], cwd=root,
                                    env=dict(os.environ, PYTHONPATH=temp), capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertFalse((root / 'EXECUTED').exists(), 'root installer imported caller-owned json.py')


if __name__ == '__main__':
    unittest.main()
