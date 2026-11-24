"""Переключатель «Управление компьютером»: <home>\\state\\control.json {"enabled": bool}; по умолчанию разрешено."""
import json, os

CTRL_TEXT = 'Управление компьютером запрещено на этом ПК'


def _path(home):
    return os.path.join(home, 'state', 'control.json')


def enabled(home):
    try:
        with open(_path(home), encoding='utf-8') as f:
            return bool(json.load(f).get('enabled', True))
    except (OSError, ValueError, AttributeError):
        return True


def set(home, on):
    p = _path(home)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump({'enabled': bool(on)}, f)
    os.replace(tmp, p)
