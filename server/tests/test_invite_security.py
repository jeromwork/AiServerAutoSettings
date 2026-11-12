"""Privilege-boundary regressions: metadata/OS mutations are mocked, no sudo/root."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('invite_security_subject', Path(__file__).parents[1] / 'invite.py')
invite = importlib.util.module_from_spec(spec)
spec.loader.exec_module(invite)


class TrustedPathTests(unittest.TestCase):
    def metadata(self, unsafe):
        def stat(path, *args, **kwargs):
            return type('Stat', (), dict(st_uid=0, st_mode=0o40777 if path == unsafe else 0o40755))()
        return stat

    def test_sudo_helper_rejects_writable_ancestor_before_any_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'helper-dir').mkdir()
            (root / 'service/.ssh').mkdir(parents=True)
            (root / 'service/.ssh/authorized_keys').write_text('')
            c = dict(sandbox=False, enrollHelper=str(root / 'helper-dir/enroll'), enrollUser='ra-enroll',
                     enrollHome=str(root / 'service'), enrollAuthorizedKeys=str(root / 'service/.ssh/authorized_keys'),
                     sudoersFile=str(root / 'sudoers'), _file=str(root / 'config.json'))
            account = type('Account', (), dict(pw_dir=c['enrollHome'], pw_shell='/bin/sh', pw_uid=900))()
            with patch.object(invite.Path, 'stat', self.metadata(root)), \
                    patch.object(invite, 'run', return_value=b'ra-enroll L'), \
                    patch.object(invite.pwd, 'getpwnam', return_value=account), \
                    patch.object(invite.os, 'chown'), patch.object(invite.os, 'chmod'), \
                    patch.object(invite, 'save') as save:
                with self.assertRaises(invite.Error):
                    invite.provision(c)
                save.assert_not_called()

    def test_config_rejects_symlink_in_writable_lexical_parent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            trusted, unsafe = root / 'trusted', root / 'untrusted'
            trusted.mkdir()
            unsafe.mkdir()
            data = json.loads((Path(__file__).parents[1] / 'invite-config.example.json').read_text())
            data['hostKeys'] = ['ssh-ed25519 Zml4dHVyZQ==']
            config = trusted / 'config.json'
            config.write_text(json.dumps(data))
            link = unsafe / 'config.json'
            link.symlink_to(config)
            with patch.object(invite.Path, 'stat', self.metadata(unsafe)), patch.object(invite.os, 'geteuid', return_value=0):
                with self.assertRaises(invite.Error):
                    invite.config(link)
