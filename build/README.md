# Сборка лаунчера (этапы 2–3)

`./build/build-exe.sh` — собрать на Linux пару `release/RemoteAgents.exe`, `release/RemoteVPN.exe` и `release/Start.cmd` для первого запуска и ручного обновления поверх.
`build/out/` — промежуточные файлы; у вариантов независимые встроенные бандлы и runtime-состояние обновления.
`./build/publish.sh` — опционально опубликовать EXE/архив в dist текущего пользователя на сервере; клиенты сами не проверяют обновления.
Нужны Python 3, bash, git и `~/.dotnet/dotnet` (SDK 10). Коммиты и push скрипты не делают.

`./build/build-exe.sh` оставляет в `build/out/`:

- `RemoteAgents.exe`, `RemoteVPN.exe` — два варианта одного проекта .NET Framework 4.8;
- `<Product>/<version>.zip`, `<Product>/publish/` — встроенный бандл и результат publish каждого варианта;
- `initial-bundle.zip` — совместимый путь к бандлу RemoteAgents;
- `<версия>.zip` и `bundle.zip` — OTA-архив с модулями и новым EXE для самообновления.

`./build/make-bundle.sh <версия> <каталог> [--launcher <exe>]` собирает только архив.
`python3 build/make-app-icon.py` рисует `app/launcher/app.ico` — значок программы (зелёный круг трея). Он встраивается в оба EXE (`ApplicationIcon`)
и выгружается для пунктов меню Проводника; результат в Git, `app/launcher/tests/test_app_icon.py` проверяет файл и значок собранного EXE.
`python3 build/make-state-icons.py` рисует значки состояний папок Диска в `app/launcher/icons/` (папка с бейджем: галочка, стрелки, облако, крест...);
они встраиваются в оба EXE и выгружаются в `%LOCALAPPDATA%\RemoteDisk\explorer-icons`, проверка — `test_state_icons.py`. Общая кисть — `build/icon_art.py`.
`./build/publish.sh <zip> [<dist>] [--min-launcher 1.0.0] [--launcher <exe>]` публикует готовый архив;
`--launcher` дополнительно публикует отдельный EXE для скачивания установщиком. Для самообновления EXE должен находиться **в ZIP**.
`REMOTEAGENTS_BUNDLE_VERSION` задаёт фиксированный номер бандла вместо UTC-даты с git hash.
`REMOTEAGENTS_DIST` задаёт dist для команды без аргументов. Публикация одной версии с другими байтами запрещена.

Состав задаёт `bundle-files.txt`: явные файлы, разрешённые шаблоны; `?` означает необязательный шаблон.
Тексты нормализуются в LF, PowerShell получает UTF-8 BOM для Windows PowerShell 5.1.
Syncthing/sing-box и личные профили не упаковываются. Загрузку их закреплённых версий выполняют мастер и Install-RemoteDisk.ps1 (SHA256);
формат `binaries` поддерживает будущую загрузку отдельных файлов по HTTPS с SHA256 и кэшем.

Подробности и проверки Windows: [docs/LAUNCHER.md](../docs/LAUNCHER.md).
