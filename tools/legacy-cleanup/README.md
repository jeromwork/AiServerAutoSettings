# Удаление старой установки (временный, одноразовый инструмент)

Убирает старую установку RemoteAgents/RemoteDisk (SETUP.cmd, 04-disk.cmd, 05-control.cmd), чтобы новая `RemoteAgents.exe` встала начисто.

1. Двойной щелчок по `Remove-OldInstall.cmd`: покажет найденное и спросит «Удалить? (да/нет)». До «да» ничего не меняется.
2. Затем запустите `release\RemoteAgents.exe`.
3. Если новая не заработала: закройте её (трей → Выход) и запустите `Restore-OldInstall.cmd`.

Что убирается: задачи `RemoteDiskChannel`, `RemoteDiskFolders`, `RemoteAgents rollback`, `RemoteAgents-Recovery-*`; автозапуск `RemoteDisk` и старый `RemoteAgentsControl`; меню `RemoteDisk_add`/`AiServerSync`; старые трей, Syncthing, sing-box и мост; папки `%LOCALAPPDATA%\RemoteDisk` и `RemoteAgents\control` (если новая EXE уже стоит, переносится только `control\app`).
Ничего не удаляется: всё переносится в `%LOCALAPPDATA%\RemoteAgents-old-backup-<время>\` (`manifest.json`, XML задач, `.reg`, `cleanup.log`).

Никогда не трогаются: `~\.ssh` (единственный ключ входа на сервер), `RemoteAgents\ssh-profiles`, файлы папки Disk, файлы новой EXE, OpenVPN.

Ключи: `-Plan` только показать, `-Yes` без вопроса; `Restore-OldInstall.ps1 -Backup <папка>`. Коды выхода: 0 готово, 1 часть шагов не удалась (повтор безопасен), 2 отменено, 3 ошибка, 4 копии нет.
Smoke-тест: `timeout 60 pwsh -NoProfile -NonInteractive -File tests/smoke-plan.ps1 < /dev/null`.
