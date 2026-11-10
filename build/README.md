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
`./build/publish.sh <zip> [<dist>] [--min-launcher 1.0.0] [--launcher <exe>]` публикует готовый архив;
`--launcher` дополнительно публикует отдельный EXE для скачивания установщиком. Для самообновления EXE должен находиться **в ZIP**.
`REMOTEAGENTS_BUNDLE_VERSION` задаёт фиксированный номер бандла вместо UTC-даты с git hash.
`REMOTEAGENTS_DIST` задаёт dist для команды без аргументов. Публикация одной версии с другими байтами запрещена.

Состав задаёт `bundle-files.txt`: явные файлы, разрешённые шаблоны; `?` означает необязательный шаблон.
Тексты нормализуются в LF, PowerShell получает UTF-8 BOM для Windows PowerShell 5.1.
Syncthing/sing-box и личные профили не упаковываются. Загрузку их закреплённых версий пока выполняет прежний установщик;
формат `binaries` поддерживает будущую загрузку отдельных файлов по HTTPS с SHA256 и кэшем.

**Связка этапа 3 реализована, Windows-приёмка ожидается.** `Migrate.ps1`, `Migrate.Common.ps1` и
`Rollback.ps1` включаются в build/ внутри бандла. EXE --install запускает импорт и переход с независимой
задачей отката; --uninstall вызывает тот же Rollback без ожидания. Исходные control/ и профили сохраняются.
Disk.Status и Control.Status наблюдают сервисы; трей Syncthing создаётся через CIM и переживает лаунчер.
До перехода disk/control выключены; VPN автоматически не включается. Watchdog ставится до захвата
RemoteDiskChannel; при отказе или неполной проверке здоровья прежняя схема восстанавливается.

Подробности и проверки Windows: [docs/LAUNCHER.md](../docs/LAUNCHER.md).
