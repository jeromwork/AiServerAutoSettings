"""Full export selects only matching deployment secrets; real root IO is in Docker."""
import copy
import unittest
from test_config_export import rc


class FullExportTests(unittest.TestCase):
    def setUp(self):
        self.public = dict(proxyOut=dict(type='http', server='proxy.invalid', port=80,
                                        password={'secret': 'proxy-secret'}, ipv6='block'))
        self.backup = dict(schema=1, config=copy.deepcopy(self.public),
                           secrets={'proxy-secret': 'PRIVATE_SENTINEL', 'unused': 'UNUSED_SENTINEL'})

    def test_new_invitation_key_is_in_clone_bridge_identity(self):
        import json
        deployment = {'serverComponents': {'bridge': {'identity': {'secret': 'bridge-id'}}}}
        values = {'bridge-id': json.dumps({'.ssh/authorized_keys': 'OLD KEY\n'})}
        rc.bridge_invitation(deployment, values, 'NEW KEY ra-config:0123456789abcdef Test')
        self.assertEqual(json.loads(values['bridge-id'])['.ssh/authorized_keys'], 'OLD KEY\nNEW KEY ra-config:0123456789abcdef Test\n')

    def test_missing_optional_agent_auth_preserves_waiting_state(self):
        self.public['agents'] = {'claude': {'enabled': True, 'auth': {'secret': 'login-needed'}}}
        self.backup['config'] = copy.deepcopy(self.public)
        self.backup['secrets']['login-needed'] = ''
        self.assertEqual(rc.server_secret_values(self.backup, self.public)['login-needed'], '')

    def test_only_referenced_values_are_selected(self):
        self.assertEqual(rc.server_secret_values(self.backup, self.public), {'proxy-secret': 'PRIVATE_SENTINEL'})

    def test_changed_public_snapshot_is_refused_without_values(self):
        self.public['proxyOut']['port'] = 81
        with self.assertRaises(rc.Error) as caught:
            rc.server_secret_values(self.backup, self.public)
        self.assertNotIn('SENTINEL', str(caught.exception))

    def test_missing_hidden_or_nontext_value_is_refused(self):
        for value in (None, '', '<есть, скрыт>', 123):
            with self.subTest(value=value):
                self.backup['secrets']['proxy-secret'] = value
                with self.assertRaises(rc.Error):
                    rc.server_secret_values(self.backup, self.public)


if __name__ == '__main__':
    unittest.main()
