# Удаление старой установки (временный, одноразовый инструмент)

Начисто убирает прежние установки RemoteAgents/RemoteDisk (SETUP.cmd, 04-disk.cmd, 05-control.cmd и ранние тестовые `RemoteAgents.exe`), чтобы новая `RemoteAgents.exe` встала с нуля.

1. Двойной щелчок по `Remove-OldInstall.cmd`: покажет найденное и спросит «Удалить? (да/нет)». До «да» ничего не меняется.
2. Затем запустите `release\RemoteAgents.exe`.
3. Если новая не заработала: закройте её (трей → Выход) и запустите `Restore-OldInstall.cmd`.

Что убирается: задачи `RemoteDiskChannel`, `RemoteDiskFolders`, `RemoteAgents*`; значения Run `RemoteDisk`, `RemoteAgents`, `RemoteAgentsControl`, `RemoteVPN`; меню `RemoteDisk_add`/`AiServerSync`; значок Disk в Проводнике (CLSID, NameSpace, HideDesktopIcons); все процессы из `%LOCALAPPDATA%\RemoteAgents` и `RemoteDisk` (кроме запущенных из папки Disk); папка `RemoteDisk` целиком и всё в `RemoteAgents`, включая старые ключи `ssh-profiles` (в конце печатается путь ключа — его можно выбрать в новом мастере кнопкой «Файл ключа…»).
Ничего не удаляется: всё переносится в `%LOCALAPPDATA%\RemoteAgents-old-backup-<время>\` (`manifest.json`, XML задач, `.reg`, `cleanup.log`).

Никогда не трогаются: `~\.ssh`, файлы папки Disk, OpenVPN.

Ключи: `-Plan` только показать, `-Yes` без вопроса; `Restore-OldInstall.ps1 -Backup <папка>`. Коды выхода: 0 готово, 1 часть шагов не удалась (повтор безопасен), 2 отменено, 3 ошибка, 4 копии нет.
Smoke-тест: `timeout 60 pwsh -NoProfile -NonInteractive -File tests/smoke-plan.ps1 < /dev/null`.

## Что новая программа делает автоматически

Полный `Remove-OldInstall` по-прежнему запускается только вручную и действует как описано выше.
Программа его не вызывает. Перед стартом рабочего транспорта (в том числе из настройки связи)
`transport/Legacy.Conflicts.ps1` отключает только задачи `RemoteDiskChannel` и `RemoteDiskFolders`
(Stop + Disable, без Delete) и останавливает процессы из `%LOCALAPPDATA%\RemoteDisk\channel\`.

Старый `%LOCALAPPDATA%\RemoteDisk\tray\syncthingtray.exe` (и отдельный `syncthing.exe` из той же
папки) и значение Run `RemoteDisk` отключаются только если новая программа включает диск и
подтверждено совпадение состояния, слушающего порта либо пересечение папок Syncthing. Диск по
умолчанию переиспользует старые state и файлы. Новый движок того же exe распознаётся по цепочке
родителей с точным путём `Disk.Status.ps1`/`Install-RemoteDisk.ps1` текущего bundle и сохраняется.
При другой папке состояния без конфликта старый трей остаётся. Значение Run с чужой командой
не меняется. Мост `RemoteAgentsControl`, `%LOCALAPPDATA%\RemoteAgents\control`, новая EXE,
SSH-ключи, меню Проводника и каталоги не затрагиваются.

Перед изменениями создаётся отдельная `%LOCALAPPDATA%\RemoteAgents-old-backup-<время>\`:
`manifest.json` с `automatic: true`, XML задач, прежнее значение Run и команды остановленных
процессов. В копию также кладётся самостоятельный `Restore-OldInstall.ps1`. Каталог закрыт правами пользователя. Для отката закройте новую программу и выполните
`Restore-OldInstall.ps1 -Backup <папка>` (или выберите копию через `.cmd`). Восстанавливаются
XML и Run; ранее работавшие включённые задачи запускаются, оставшиеся отдельные процессы
возобновляются без дублирования уже живых. Восстановление прежних полных копий также работает.

Ошибки не роняют настройку: результат виден в `status/legacy-cleanup.json`, в статусах связи/диска
и в `logs/legacy-cleanup.log`. Повтор не создаёт новую копию при отсутствии изменений и сохраняет
путь предыдущей. Сухой план и отключение на подменённых вызовах:
`pwsh -NoProfile -File tools/legacy-cleanup/tests/test-conflicts.ps1`.
Работа ScheduledTasks/реестра/Win32_Process на настоящем Windows этим тестом не подтверждается.
