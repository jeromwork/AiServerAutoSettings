# Удаление старой установки (временный, одноразовый инструмент)

Начисто убирает прежние установки RemoteAgents/RemoteDisk (SETUP.cmd, 04-disk.cmd, 05-control.cmd и ранние тестовые `RemoteAgents.exe`), чтобы новая `RemoteAgents.exe` встала с нуля.

1. Двойной щелчок по `Remove-OldInstall.cmd`: покажет найденное и спросит «Удалить? (да/нет)». До «да» ничего не меняется.
2. Затем запустите `release\RemoteAgents.exe`.
3. Если новая не заработала: закройте её (трей → Выход) и запустите `Restore-OldInstall.cmd`.

Действующее описание сети: [Локальные сети и VPN](../../docs/VPN-LAN.md).

Никогда не трогаются: `~\.ssh`, файлы папки Disk, OpenVPN.

Ключи: `-Plan` только показать, `-Yes` без вопроса; `Restore-OldInstall.ps1 -Backup <папка>`. Коды выхода: 0 готово, 1 часть шагов не удалась (повтор безопасен), 2 отменено, 3 ошибка, 4 копии нет.
Smoke-тест: `timeout 60 pwsh -NoProfile -NonInteractive -File tests/smoke-plan.ps1 < /dev/null`.
