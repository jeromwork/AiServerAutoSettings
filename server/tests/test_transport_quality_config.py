"""Q micro-tests: pure normalization only; no services, files or wall-clock waits."""
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location('q_config', Path(__file__).resolve().parents[1] / 'remoteagents_config.py')
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


def main():
    defaults = config.transport_policy({})['switch']
    assert defaults == config.TRANSPORT_SWITCH_DEFAULTS
    defaults['blipMs']['default'] = 1
    assert config.TRANSPORT_SWITCH_DEFAULTS['blipMs']['default'] == 10000
    changed = config.transport_policy({'transport': {'switch': {'classK': {'wifi': 0.9}}}})['switch']
    assert changed['classK']['wifi'] == 0.9 and changed['classK']['mobile'] == 1.5
    for bad in ({'unknown': 1}, {'classK': {'wifi': True}}, {'stageMs': [3000, 1000]}, {'stageMs': [1000]}, {'blipMs': {'min': 20000}}, {'probeBudgetKiBPer10m': {'mobile': 0}}, {'tspuMemoryHours': '24'}):
        try:
            config.transport_policy({'transport': {'switch': bad}})
        except config.Error:
            pass
        else:
            raise AssertionError('invalid policy accepted: ' + repr(bad))
    print('PASS: Q exporter config (defaults, partial policy, invalid fields; no I/O)')


if __name__ == '__main__':
    main()
