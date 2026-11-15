#!/usr/bin/python3
"""Local access-key administration; Python stdlib only."""

import argparse
from contextlib import contextmanager
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import ssl
import sys
import tempfile


BASE = Path(__file__).resolve().parent
NAME = re.compile(r"[a-z0-9][a-z0-9._-]{0,39}", re.ASCII)


class KeyErrorMessage(Exception):
    pass


def read_keys(path):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"version": 1, "keys": {}}
    return validate_keys(data)


def validate_keys(data):
    if (not isinstance(data, dict) or type(data.get("version")) is not int
            or data["version"] != 1 or not isinstance(data.get("keys"), dict)):
        raise ValueError()
    hashes = set()
    for name, record in data["keys"].items():
        if (not NAME.fullmatch(name) or not isinstance(record, dict)
                or not isinstance(record.get("sha256"), str)
                or not re.fullmatch(r"[a-fA-F0-9]{64}", record["sha256"])
                or not isinstance(record.get("created"), str)):
            raise ValueError()
        datetime.datetime.fromisoformat(record["created"])
        digest = record["sha256"].lower()
        if digest in hashes:
            raise ValueError()
        hashes.add(digest)
    return data


@contextmanager
def locked_keys(path):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    # Lock a separate inode: keys.json itself is replaced on every write.
    fd = os.open(path.parent / ".keys.lock", os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(fd, "a") as lock:
        os.fchmod(lock.fileno(), 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield read_keys(path)


def write_keys(path, data):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8",
                                         dir=path.parent, prefix=".keys-",
                                         delete=False) as output:
            temporary = output.name
            os.fchmod(output.fileno(), 0o600)
            json.dump(data, output, ensure_ascii=True, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if temporary is not None and os.path.exists(temporary):
            os.unlink(temporary)


def certificate():
    pem = Path(os.environ.get("TG_GW_CERT", str(BASE / "tls/cert.pem"))).read_text(
        encoding="ascii"
    ).strip() + "\n"
    der = ssl.PEM_cert_to_DER_cert(pem)
    digest = hashlib.sha256(der).hexdigest().upper()
    fingerprint = ":".join(digest[i:i + 2] for i in range(0, len(digest), 2))
    return pem, fingerprint


def connection_data(key, pem, fingerprint, machine=False):
    # The installer owns host/port selection; caller environment cannot override it.
    settings_path = Path(os.environ.get("TG_GW_KEYS", str(BASE / "state/keys.json"))).parent / "settings.json"
    settings = json.loads(settings_path.read_text(encoding="utf-8"))
    port = settings["port"]
    host = settings["public_host"]
    if (type(port) is not int or not 1 <= port <= 65535 or not isinstance(host, str)
            or not re.fullmatch(r"[A-Za-z0-9.:-]+", host)):
        raise ValueError()
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    base = f"https://{host}:{port}/{key}"
    if machine:
        return json.dumps({"base_url": base, "ca_pem": pem, "sha256": fingerprint}) + "\n"
    return f'''Данные подключения (сохраните сейчас: ключ повторно не показывается)
Базовый адрес: {base}

Сертификат: сохраните весь PEM ниже в gw.pem и передайте клиенту.
{pem}SHA-256 отпечаток: {fingerprint}

Проверка:
curl --cacert gw.pem '{base}/bot<ТОКЕН>/getMe'

python-telegram-bot:
Bot(token=TOKEN, base_url="{base}/bot", base_file_url="{base}/file/bot")

aiogram 3:
AiohttpSession(api=TelegramAPIServer.from_base("{base}"))
# Передайте эту сессию в Bot(token=TOKEN, session=session).

node-telegram-bot-api (классический API):
new TelegramBot(TOKEN, {{baseApiUrl: "{base}"}})

Telegraf:
new Telegraf(TOKEN, {{telegram: {{apiRoot: "{base}/"}}}})

Доверие сертификату (путь к gw.pem должен быть абсолютным):
Python: SSL_CERT_FILE=/путь/gw.pem (ssl/httpx), REQUESTS_CA_BUNDLE=/путь/gw.pem (requests).
Библиотека может использовать собственные корни; лучше передать её HTTP-клиенту
свой SSL-контекст: ssl.create_default_context(cafile="/путь/gw.pem").
Для python-telegram-bot: HTTPXRequest(httpx_kwargs={{"verify": ssl_context}}),
передайте отдельные request и get_updates_request в Bot для обычных запросов и polling.
Для aiogram настройте SSL-контекст в используемом aiohttp-коннекторе.
Node: NODE_EXTRA_CA_CERTS=/путь/gw.pem перед запуском процесса.
Проверку TLS оставьте включённой. Храните базовый адрес как секрет.
'''


def main():
    parser = argparse.ArgumentParser(description="Ключи доступа шлюза Telegram Bot API")
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("add", "revoke"):
        sub = commands.add_parser(command)
        sub.add_argument("name")
        if command == "add":
            sub.add_argument("--json", action="store_true", help="Данные подключения в JSON")
    commands.add_parser("list")
    commands.add_parser("show-cert")
    args = parser.parse_args()
    if args.command in ("add", "revoke") and not NAME.fullmatch(args.name):
        parser.error("Имя: 1–40 символов a-z, 0-9, '.', '_', '-'; начало — буква или цифра")
    path = Path(os.environ.get("TG_GW_KEYS", str(BASE / "state/keys.json")))
    try:
        if args.command == "show-cert":
            pem, fingerprint = certificate()
            print(pem + "SHA-256 отпечаток: " + fingerprint)
        elif args.command == "list":
            for name, record in sorted(read_keys(path)["keys"].items()):
                print(name, record["created"])
        else:
            with locked_keys(path) as data:
                if args.command == "add":
                    if args.name in data["keys"]:
                        raise KeyErrorMessage("Имя уже существует")
                    pem, fingerprint = certificate()
                    key = secrets.token_urlsafe(32)
                    # Validate settings and prepare output before changing the file.
                    details = connection_data(key, pem, fingerprint, args.json)
                    data["keys"][args.name] = {
                        "sha256": hashlib.sha256(key.encode("ascii")).hexdigest(),
                        "created": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    }
                else:
                    if args.name not in data["keys"]:
                        raise KeyErrorMessage("Имя не найдено")
                    del data["keys"][args.name]
                write_keys(path, data)
            if args.command == "add":
                print(details, end="")
            else:
                print("Ключ отозван")
    except KeyErrorMessage as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, TypeError, RecursionError):
        print("Ошибка: проверьте файл ключей, сертификат, настройки и права доступа", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
