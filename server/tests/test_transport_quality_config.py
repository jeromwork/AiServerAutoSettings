"""Q micro-tests: fake export boundaries, pure policy and stable sync revision."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('q_config', Path(__file__).resolve().parents[1] / 'remoteagents_config.py')
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class TransportQualityConfigTests(unittest.TestCase):
    def test_policy_defaults_and_partial_override(self):
        defaults = config.transport_policy({})['switch']
        self.assertEqual(defaults, config.TRANSPORT_SWITCH_DEFAULTS)
        defaults['blipMs']['default'] = 1
        self.assertEqual(config.TRANSPORT_SWITCH_DEFAULTS['blipMs']['default'], 10000)
        changed = config.transport_policy({'transport': {'switch': {'classK': {'wifi': 0.9}}}})['switch']
        self.assertEqual((changed['classK']['wifi'], changed['classK']['mobile']), (0.9, 1.5))

    def test_invalid_policy(self):
        for bad in ({'unknown': 1}, {'classK': {'wifi': True}}, {'stageMs': [3000, 1000]},
                    {'stageMs': [1000]}, {'blipMs': {'min': 20000}},
                    {'probeBudgetKiBPer10m': {'mobile': 0}}, {'tspuMemoryHours': '24'},
                    {'flapWindowMs': 1800001}):
            with self.subTest(bad=bad), self.assertRaises(config.Error):
                config.transport_policy({'transport': {'switch': bad}})

    def export(self, settings):
        args = SimpleNamespace(name='test', happier='new:test', folders=None, vpn='off',
                               output=None, agent_sudo='full')
        out = io.StringIO()
        # Every side effect and clock boundary is replaced; no keys/services/files are accessed.
        with contextlib.ExitStack() as stack:
            stubs = dict(folders_list=None, master_password=None, common_sections=({'host': 'example.invalid'}, None),
                         server_sections={}, computer_sections={}, computer_lans={},
                         keypair=('fixture-private', 'ssh-ed25519 fixture'), fingerprint='fixture',
                         save_record=None, append_worker=None, publish_sync=None, event=None,
                         now='2026-01-01T00:00:00Z')
            for name, value in stubs.items():
                stack.enter_context(mock.patch.object(config, name, return_value=value))
            stack.enter_context(mock.patch.object(config, 'locked', side_effect=lambda _: contextlib.nullcontext()))
            stack.enter_context(mock.patch.object(config.secrets, 'token_hex', return_value='0123456789abcdef'))
            stack.enter_context(mock.patch.object(config.time, 'time_ns', return_value=0))
            config.export({'workerAuthorizedKeys': 'fixture', **settings}, args, out, io.StringIO())
        return json.loads(out.getvalue())

    def test_export_legacy_omits_transport(self):
        self.assertNotIn('transport', self.export({}))

    def test_export_explicit_policy_is_normalized_and_validated(self):
        self.assertEqual(self.export({'transport': {'switch': {'classK': {'wifi': 0.9}}}})['transport']['switch']['classK']['wifi'], 0.9)
        with self.assertRaises(config.Error):
            self.export({'transport': {'switch': {'stageMs': [3000, 1000]}}})

    def test_sync_keeps_legacy_revision_even_with_explicit_policy(self):
        old_config = {'kind': config.CONFIG_KIND, 'schema': 1, 'server': {'host': 'example.invalid'}, 'secrets': {}}
        revision = hashlib.sha256(json.dumps(old_config, ensure_ascii=False, sort_keys=True).encode()).hexdigest()
        old_raw = json.dumps({'config': old_config, 'revision': revision, 'generatedUtc': 'old'})
        for settings in ({}, {'transport': {'switch': {}}}):
            with self.subTest(settings=settings), contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(config, 'common_sections', return_value=({'host': 'example.invalid'}, None)))
                stack.enter_context(mock.patch.object(config, 'now', return_value='fake-now'))
                stack.enter_context(mock.patch.object(config, 'locked', side_effect=lambda _: contextlib.nullcontext()))
                stack.enter_context(mock.patch.object(config, 'event'))
                replace = stack.enter_context(mock.patch.object(config, 'replace_worker'))
                self.assertEqual(config.sync_document(settings)['config'], old_config)
                config.publish_sync({'syncFile': 'fixture', **settings})
                update = replace.call_args.args[2]
                self.assertEqual(update(old_raw), old_raw)
                self.assertEqual(json.loads(update(''))['revision'], revision)


if __name__ == '__main__':
    unittest.main(verbosity=2)
