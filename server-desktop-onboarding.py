#!/usr/bin/env python3
"""Open an installed agent in the managed X session; never handle login secrets."""
import argparse
import os
from pathlib import Path
import shutil
import stat
import subprocess


GUIDE = """<!doctype html><html lang="ru"><meta charset="utf-8">
<title>Начать работу на сервере</title><style>body{font:18px/1.6 sans-serif;max-width:850px;margin:40px auto;padding:0 24px;color:#182536}h1{font-size:30px}li{margin:16px 0}</style>
<h1>Ваш рабочий стол сервера</h1>
<ol><li>Выбранное приложение открывается автоматически. Если оно уже предлагает чат, повторный вход не нужен. Иначе выберите вход и завершите его в официальном браузере сервера. Пароль и код подтверждения вводите только в официальном окне входа.</li>
<li>Откройте нужный проект. Если подключали Windows, используйте ярлык «Начать настройку проекта»: там указана точная серверная папка. В ней установщик подготовил AGENTS.md и CLAUDE.md с инструкциями подключения. Создайте новую сессию и напишите агенту свою задачу. Запасное первое сообщение доступно в том же ярлыке. Для Claude используйте вкладку Code.</li>
<li>Оставьте установщик Windows открытым: он держит SSH-соединение. Можно переключаться между рабочим столом и меню установщика, не закрывая RDP.</li></ol>
<p>Установка приложения, вход в аккаунт и готовность проекта — отдельные этапы. Наличие окна не подтверждает вход или выполнение команд.</p>
<p>VPN необязателен. Он настраивается отдельно из меню установщика.</p></html>
"""


def write_file(path, text, mode=0o600):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(text)
    os.chmod(path, mode)


def prepare(home):
    desktop = home / "Desktop"
    if not desktop.exists():
        desktop.mkdir(mode=0o700)
    info = desktop.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise ValueError("Unsafe desktop directory")
    page = desktop / "RemoteAgents-Start.html"
    write_file(page, GUIDE)
    write_file(desktop / "RemoteAgents-Help.desktop", "[Desktop Entry]\nType=Application\nName=Начать здесь — вход и проект\nExec=xdg-open " + str(page) + "\nIcon=help-browser\nTerminal=false\n", 0o700)


def launch(agents, home, runner=subprocess.Popen):
    prepare(home)
    # Launch one GUI at a time. If both are installed, Codex is the first entry.
    command = "claude-desktop" if agents == "2" else "chatgpt"
    executable = shutil.which(command)
    if not executable:
        raise ValueError("Selected app is not installed")
    env = os.environ.copy()
    env.update(HOME=str(home), DISPLAY=":98", XAUTHORITY="/run/remoteagents-desktop-x/Xauthority",
               XDG_CURRENT_DESKTOP="XFCE", XDG_SESSION_DESKTOP="xfce", XDG_SESSION_TYPE="x11",
               PULSE_SERVER="unix:/run/remoteagents-desktop-audio/pulse/native")
    runner([executable], cwd=home / "work", env=env, stdin=subprocess.DEVNULL,
           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("agents", choices=("1", "2", "3"))
    args = parser.parse_args()
    home = Path.home()
    if os.getuid() == 0 or home != Path("/home/remoteagents"):
        raise SystemExit("Launch as the managed non-root user")
    launch(args.agents, home)
    print("AGENT_WINDOW_REQUESTED=1")


if __name__ == "__main__":
    main()
