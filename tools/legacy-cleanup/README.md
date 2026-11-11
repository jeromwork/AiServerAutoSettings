# Удаление старой установки (временный, одноразовый инструмент)

Начисто убирает прежние установки RemoteAgents/RemoteDisk (SETUP.cmd, 04-disk.cmd, 05-control.cmd и ранние тестовые `RemoteAgents.exe`), чтобы новая `RemoteAgents.exe` встала с нуля.

1. Двойной щелчок по `Remove-OldInstall.cmd`: покажет найденное и спросит «Удалить? (да/нет)». До «да» ничего не меняется.
2. Затем запустите `release\RemoteAgents.exe`.
3. Если новая не заработала: закройте её (трей → Выход) и запустите `Restore-OldInstall.cmd`.

Что убирается: задачи `RemoteDiskChannel`, `RemoteDiskFolders`, `RemoteAgents*`; значения Run `RemoteDisk`, `RemoteAgents`, `RemoteAgentsControl`, `RemoteVPN`; меню `RemoteDisk_add`/`AiServerSync`; значок Disk в Проводнике (CLSID, NameSpace, HideDesktopIcons); все процессы из `%LOCALAPPDATA%\RemoteAgents` и `RemoteDisk` (кроме запущенных из папки Disk); папка `RemoteDisk` целиком и всё в `RemoteAgents`, кроме `ssh-profiles`.
Ничего не удаляется: всё переносится в `%LOCALAPPDATA%\RemoteAgents-old-backup-<время>\` (`manifest.json`, XML задач, `.reg`, `cleanup.log`).

Никогда не трогаются: `~\.ssh`, `RemoteAgents\ssh-profiles` (ключ этого ПК для сервера, вход по паролю выключен; новый мастер берёт ключ оттуда), файлы папки Disk, OpenVPN.

Ключи: `-Plan` только показать, `-Yes` без вопроса; `Restore-OldInstall.ps1 -Backup <папка>`. Коды выхода: 0 готово, 1 часть шагов не удалась (повтор безопасен), 2 отменено, 3 ошибка, 4 копии нет.
Smoke-тест: `timeout 60 pwsh -NoProfile -NonInteractive -File tests/smoke-plan.ps1 < /dev/null`.
