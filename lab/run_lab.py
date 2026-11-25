"""Точка входа Лаборатории. Embed-Python (python312._pth) не добавляет папку скрипта в sys.path - делаем это сами."""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ralab import app  # noqa: E402

if __name__ == '__main__':
    code = app.main(sys.argv[1:])
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(code)  # потоки-демоны и блокирующие читатели не должны задерживать выход
