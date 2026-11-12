# CONFIG — отчёт потока C

Ветка `app/config-c`, worktree `/home/remoteagents/work/wt-config-c`. Push/merge не выполнялись. Живые Windows, мосты, серверные службы и пользовательские authorized_keys не менялись. Все SSH-проверки — отдельный rootless sshd на loopback, ключи и writable HOME во временной папке.

## Сделано

- Общий Invoke-WizardLock заменён ресурсными mutex. Connection/Bridge/Account/Disk/Vpn перекрываются в отдельных процессах; Proxy/Lan используют общий server-network lock. Короткие config/log/progress lock защищают R/M/W и append.
- Один управляющий SSH worker на поколение профиля/pins/маршрута; отдельные процессы делят его, команды на сервере перекрываются. Секретные payload/ответы — в атомарной приватной очереди с очисткой. Автоповтора изменяющих команд нет. Confirm сетевых транзакций сохраняет новый SSH.
- Helpers передаются только при несовпадении SHA-256 нормализованного содержимого. Выбранный маршрут записывается также в SSH config, который читают control/reverse SSH.
- Connection работает без серверного Syncthing и sync inbound. При первой настройке проверяет сразу рабочий daemon; при изменении установленной связи сохраняет preflight и независимый откат. Disk отдельно добавляет настоящий sync inbound, проверяет конфигурацию и reload/SSH, не блокируя первый Connection.
- `timing <Action> <мс>` записывается в `text` строки ProgressFile, в том числе при исключении. Формат JSONL совместим с прежним читателем.
- Bootstrap использует `profile.vpn.bootstrap` и материализованные секреты до первого SSH; проверяет чужой VPN, HTTPS и свежий TUN. Переиспользует binary из Home/bundle либо прежнюю загрузку с SHA-256. Установленная сеть при повторном Bootstrap сохраняется.
- Выданный config key используется без создания другого authorized key: это сохраняет смысл revoke. Первый импорт без hostKeys использует прежний TOFU OpenSSH с последующим pin; доверенный sync без pins отвергается.
- Новые компьютеры получают устойчивый локальный hostId; разные компьютеры не делят `control`. Bridge принимает deviceName и передаёт его повторной регистрацией того же binding, с проверкой серверного реестра.
- ConfigSync обновляет адреса, pins, routes, caches и VPN своим прежним ключом; preflight, независимый watchdog, живой proof и rollback сохранены. На Windows регистрируется ограниченная задача каждые 5 минут и при входе, с runtime вне удаляемого bundle.
- Enrollment PowerShell удалён вместе с Wizard.Invite.ps1. Полезные тесты переименованы в test-config-*; test-refresh переписан на key-only sync. Пароли hop обслуживает отдельный Route.Proxy.ps1, без зависимости от удаляемого C# InviteHop.

Файлы: `build/Wizard*.ps1`, `build/Setup.Common.ps1`, `transport/Transport.Common.ps1`, `transport/Route.Proxy.ps1`, `transport/Vpn.Tun.ps1`, `transport/Test-Transports.ps1`, `disk/server-disk.sh`, `disk/Install-RemoteDisk.ps1`, соответствующие PS/loopback-тесты и строки `app/launcher/tests/run.sh`. Полные интерфейсы — [CONFIG-ENGINE.md](CONFIG-ENGINE.md).

## Проверки

Все отдельные вызовы ограничены timeout 60, максимум 120 секунд. Полный `app/launcher/tests/run.sh` **не запускался**.

| Проверка | Результат |
|---|---|
| test-config-engine.ps1 | 37 проверок. Пять настоящих PowerShell-процессов: общее перекрытие критических секций **1331 мс** в последнем прогоне (в предыдущем — 408 мс); в секции пауза 900 мс и реальные файловые изменения; Proxy/Lan не перекрываются. ConfigSync с несколькими ресурсами вызывает тело один раз. Параллельный Vpn не отключает bootstrap до proof Connection. Есть rollback неуспешного первого proof с сохранением чужих настроек. Работа внутри разделов в этом тесте имитируется. |
| test-config-bootstrap.ps1 | 24 утверждения: порядок VPN-first, off/foreign/error, CRLF; ОС/TUN заменены адаптерами. |
| test-config-routes.ps1 | 33 проверки: разные пароли двух hop, приватные файлы, новая форма host/user/port, неизменный ключ конфига и отказ при его отсутствии. SSH/probes заменены адаптерами; дополнительно настоящий ssh -G проверяет, что hop не наследует ProxyCommand целевого профиля. |
| test-config-account.ps1 | 9 проверок, без настоящих аккаунтов. |
| test-refresh.ps1 | 20 проверок: настоящий keygen, сохранение ключа, недоверенный ввод, staged pins, idempotency, watchdog и rollback; сеть/TUN/scheduler имитируются. |
| test-config-device.ps1 | Устойчивый отдельный ID, русское имя через Bridge попадает в **настоящий код серверного реестра**, права/binding сохраняются, управляющие символы отвергаются. SSH и здоровье Windows-моста заменены адаптерами. |
| test-config-scheduler.ps1 | 7 проверок: 300 секунд, logon, Limited/Interactive, IgnoreNew, лимит 4 минуты, runtime переживает pruning, повторное применение. Настоящий Windows Task Scheduler не использовался. |
| test-wizard.ps1 / test-wizard-onboarding.ps1 / test-network.ps1 | 88 / 90 / 34 проверки. Первоначальные таймауты onboarding выявили старую заглушку preflight, ожидавшую настоящий новый proof; заглушка обновлена, тест прошёл. |
| transport/test-transport-config.ps1 | 263 проверки без внешней сети, включая SSH-only канал, последующее добавление sync и BOM/кодировки. |
| transport/test-transport-liveness.py | Рабочий путь выбран за 3,2 с при молчащем пути с таймаутом 10 с; liveness параллелен, ranking позже. Внешние SSH/sing-box в этом тесте имитируются. |
| transport/test-server-catalog.py / disk/test-tree.py | 8 / 9 тестов. |
| app/launcher/tests/test_wizard_boundary.py | 5 тестов, в том числе настоящая запись atomic helpers в изолированный HOME. |
| статические проверки | bash -n run.sh, git diff --check, разбор 53 PowerShell-файлов; нет invite/ra-enroll/.rainvite ссылок в PowerShell движка и PS-тестах. Файлы PS сохранены UTF-8 BOM + CRLF; cross-system payload тестируется с CRLF. |

### Loopback и время

`transport/test-engine-loopback.py` использует **настоящие OpenSSH, rootless sshd и sing-box 1.14.4**. Подменён только systemctl внутри изолированного server HOME, чтобы inventory не обращался к службам хоста. Syncthing и Windows TUN не запускаются. Источник канала явно вынесен в fixture, системный `/etc/sing-box` не используется в контрольных прогонах.

Исходная версия взята через `git archive c746b86^`. Для неё внутри временной копии только стендовые порты SSH и preflight адаптированы к unprivileged loopback (вместо :22 и диапазонов Linux ephemeral ports). Исходники переданного repo тест не изменяет.

Контрольный последовательный прогон до изменений: **Server 1,589 с; возврат Connection 13,974 с**. До изменений успешный Connection подтверждал временную preflight-копию; новая версия возвращает успех после proof оставленного рабочего daemon. Другой прогон baseline дал 14,532 с. Дополнительный baseline с отдельным измерением именно рабочего proof: **Connection вернулся за 12,316 с, рабочая связь подтверждена за 19,860 с**. После изменений в таком же последовательном сценарии с метаданными порта диска: **Server 4,100 с; возврат Connection с рабочим proof 16,429 с**. Возврат старого действия и новой версии имеет разную гарантию; прямого ускорения на loopback по этим двум числам не заявляется.

После изменений без диска получены **12,255 / 22,884 / 41,276 с** от начала Server до успешного Connection. Разброс включает прогоны с параллельно запущенными тяжёлыми тестами; переносить его на скорость Windows/сети нельзя. Финальный прогон без диска: **Server 4,660 с; Connection = рабочий proof 16,998 с**. Во всех этих прогонах настоящий рабочий SSH проверен. Прежняя версия без порта диска не могла завершить эту ветвь; теперь отсутствие Syncthing не является ожиданием Connection.

Loopback дополнительно проверяет: два отдельных PowerShell-процесса имеют одинаковый SSH_CONNECTION и **перекрывающиеся интервалы удалённых команд**, helper не перезаписывается при том же хеше, sync inbound добавляется после первого Connection с новым живым SSH proof. После остановки/restart управляющего worker старый изменяющий запрос удаляется и не выполняется повторно.

## Стыки и безопасные ограничения

1. **Координатор / Start-WindowsControl.ps1:43 (вне файлов C):** при каждой регистрации брать `profile.device.name`, fallback COMPUTERNAME. Здесь Bridge немедленно передаёт имя, ConfigSync повторно его регистрирует; пока чужой файл не изменён, очередной reconnect старого control может временно вернуть системное имя. Эта проблема не скрывается успешной проверкой имени сразу после Bridge.
2. **B:** нужен `remoteagents config sync` с аутентифицированным JSON `type=settings`; точная форма описана в CONFIG-ENGINE.md. Серверные тесты приглашений, вызывавшие удалённый test-invite.ps1 или старые параметры test-refresh.ps1, принадлежат B и требуют замены. Сам C не менял server/**.
3. **A:** согласовать материализованные пути: существующий transport.profilePath с исходным ключом, либо profile.server.keyFile/keyPath, резерв secrets/server-key; channel/entry caches; hop keyFile/routePasswordFile. PS не читает vault и не превращает secret-ref в строковый пароль. Для Bootstrap binary должен быть в Home/bundle либо доступен прежний проверяемый download.
4. **D:** использовать новые Bootstrap/ConfigSync, передавать deviceName, учитывать result.ok/pending и повторять только соответствующий раздел; удалить старые ссылки на приглашения. Оставшиеся Python/C# UI-тесты старого InviteWindow относятся к его миграции. Сборка единого EXE и полный run.sh — координатор после соединения потоков; промежуточный EXE со старым UI не собирался, SHA-256 ему не приписывается.
5. На настоящей Windows PowerShell 5.1, Task Scheduler, DPAPI, UAC, реальном VPN и Windows-мосте проверки **не выполнялись**. Требуется приёмка в Windows на стенде; тесты Linux этого не заменяют.

## Приёмка после соединения потоков

Вставить конфиг со своим materialized key и именем устройства; проверить Bootstrap → Server → параллельные разделы, Connection при ещё устанавливаемом диске, повтор только Disk. Проверить имя после перезапуска моста. На стенде изменить адрес/pins через config sync, дождаться задачи 5 минут, проверить живой SSH; сломанный снимок должен откатиться. Revoke должен закрыть **новый** вход ключом конфига (уже открытые SSH-сессии остаются по контракту).

## Коммиты кода

- `c746b86` — ресурсные замки и timing.
- `8379e9c` — общий управляющий SSH, helpers по хешу, SSH-only и рабочий proof.
- `a0a5f6b` — перенос Bootstrap/sync, удаление enrollment, deviceName и поздний inbound диска.
- `38f2704` — защита начального VPN при параллельном применении, recovery без replay, формы materialized routes, bundled binary и регрессии.

Документация и этот отчёт сохранены отдельным завершающим коммитом. Во всех сообщениях коммитов последняя строка `Stream: C`.
