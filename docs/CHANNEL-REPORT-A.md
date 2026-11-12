# Отчёт CHANNEL, поток A — движок PowerShell

12.11.2026, ветка `app/channel-a`. Задача: `docs/TASK-CHANNEL.md`, раздел «Поток A» и PowerShell-часть «Контракта».

## Что сделано
1. **`Start-WizardBootstrap`** (`build/Wizard.Bootstrap.ps1`).
   - Подготовка `config.transport` прежняя: profilePath, группы каталога, entries, channelPath, `Set-WizardBootstrapHops`, `Ensure-WizardTransportBinary`.
   - Ставятся `channelFirst=true` и `bootstrap=true`; `openSsh` удаляется, поэтому действует значение по умолчанию (`true`).
   - Убраны проверка чужого VPN, `Select-WizardBootstrapInternetPath`, `Set-VpnEnabled` и запуск TUN.
   - Демон запускается через `Start-WizardWorkingTransport`.
   - `Wait-WizardChannel` ждёт до 45 с с шагом 1 с. Условия: `status/transport.json` текущей ревизии конфига свежий, `ok`, есть `active`, и открыт TCP `127.0.0.1:<channelSocksPort>`.
   - Итог по контракту: `vpn='channel'`, `channel=<tag>`, `summary='Канал до сервера поднят: <tag>'`. При неуспехе: `vpn='channel-failed'`, `summary='Канал до сервера не поднят: <причина>. Доступны обычные маршруты'`.
   - Строки трассировки: `· кандидаты канала: …`, `· выбран кандидат канала: …`, `· канал поднят за N мс` или `· канал не поднят за 45 с`.
   - Ранний выход `Test-WizardNetworkManaged` оставлен.
   - Удалены неиспользуемые функции TUN-bootstrap: `Get-WizardBootstrapVpnConflict`, `Start-WizardBootstrapTun`, `Wait-WizardBootstrapTun`, `Select-WizardBootstrapInternetPath`, `Test-WizardBootstrapInternetPath`. Их вызывали только Bootstrap и заглушки старого теста (§2).
   - Не тронуты: `Vpn.Tun.ps1`, `Test-VpnConflict.ps1` (их использует шаг «VPN») и `Set-VpnEnabled`.
2. **Вход SOCKS** (`transport/Transport.Common.ps1`, `New-TransportConfig`).
   - Вход: `{type:'mixed', tag:'channel-socks', listen:'127.0.0.1', listen_port:channelSocksPort}`.
   - Правила первыми в `route.rules`: `route-options` с `override_address='127.0.0.1'` и `override_port=Get-TransportServerPort`, затем `route` → `active`.
   - Порт входит в общую проверку пересечений.
   - `channelSocksPort`: по умолчанию 2223, в `$defaults` у `Read-TransportSettings`, диапазон проверяется так же, как у других портов.
   - `override_*` в `route-options` в sing-box 1.14.4 есть, эквивалент не понадобился.
3. **`Get-TransportCandidates`**: туннель `openssh-proxy` не создаётся, если прокси сохранённого маршрута — `127.0.0.1`/`localhost:<channelSocksPort>`.
4. **`Connect-WizardSnapshot`**.
   - Когда `config.transport.channelFirst` и порт отвечает, первым в списке идёт маршрут `{kind:'proxy', proxy:{type:'socks', host:'127.0.0.1', port}}` с заголовком «через канал».
   - Нумерация маршрутов конфига (файлы hop-N) не сдвигается.
   - Дальше работает существующее: `Select-WizardRoute`, `Save-WizardRoute` (в `ssh.conf` пишется `ProxyCommand`), `routeProxyCommand`.
5. **Раздел «Связь» при первой установке.**
   - `Set-WizardInitialNetwork` переносит `channelFirst` и `channelSocksPort` из прежнего `config.transport`, если в новом их нет. `relays` переносятся, если в новом каталоге их нет; непустой список нового каталога не трогается.
   - **Перечитывает ли демон config — да.** Раз в 1 с он сравнивает `Get-TransportRevision`: хеш содержимого `config.transport`, профиля, канала и маршрута. Новый конфиг проверяется в фоне (`sing-box check`). Затем перезапускается только sing-box; неизменённые туннели OpenSSH остаются.
   - Второй процесс от `Start-WizardWorkingTransport` сразу завершается: мьютекс на Home занят.
   - **Выбрано:** отдельного перезапуска нет. Порт SOCKS пропадает только на время перезапуска sing-box. Selector сразу встаёт на запомненный путь, `interrupt_exist_connections=false`.
   - Повтор в `Invoke-WizardSsh`: один раз через 3 с, только при `transport.channelFirst` и только при сбое соединения SSH. Это код выхода ssh 255, а для общего управляющего сеанса — «Управляющий SSH-сеанс не запущен/прерван» (см. отступления).
6. **Честная причина SSH** (`disk/Disk.Common.ps1`, `Invoke-DiskProcess`).
   - Условие: код 255, в stderr есть `Remote protocol version` и `timed out` или `Connection reset`.
   - Результат: «Сервер ответил, но сеть глушит SSH после рукопожатия — нужен обход (канал через промежуточный сервер)».
   - Флаг `WizardNoBanner` не ставится: `Invoke-WizardLogin` ставит его только по тексту «SSH-баннера».
7. **Тесты.**
   - `test-config-bootstrap.ps1` переписан, 47 проверок. Проверяется:
     - TUN, UAC-дочерний процесс и `Set-VpnEnabled` не вызываются;
     - чужой VPN (`Test-VpnConflict.ps1` бандла сообщает о конфликте) не вызывается и не мешает;
     - `channelFirst` и `bootstrap` пишутся, `openSsh` по умолчанию;
     - итог и трассировка соответствуют контракту; неуспех и таймаут ожидания проверены;
     - hop каталога работает;
     - вход `channel-socks` и правила корректны, `sing-box check` настоящим sing-box 1.14.4 проходит;
     - без `channelFirst` входа нет, конфликт портов отвергается, петли `openssh-proxy` нет;
     - маршрут «через канал» первый и сохраняется как proxy с `ProxyCommand`, при молчащем порту его нет;
     - честная причина п. 6 проверяется поддельным `ssh`, `WizardNoBanner` при этом не ставится;
     - повтор 255 работает: один раз, ≥3 с, не для других кодов и не без `channelFirst`.
   - `test-config-engine.ps1`: +2 проверки, что `Set-WizardInitialNetwork` сохраняет `channelFirst`, порт и relays.

## Файлы
- `build/Wizard.Bootstrap.ps1`, `build/Wizard.Common.ps1`, `build/Wizard.Engine.ps1`
- `transport/Transport.Common.ps1`, `disk/Disk.Common.ps1`
- `app/launcher/tests/test-config-bootstrap.ps1`, `app/launcher/tests/test-config-engine.ps1`
- Все .ps1 сохранены в UTF-8 с BOM и CRLF; парсер PowerShell ошибок не нашёл ни в одном из 5 изменённых файлов кода.

## Проверки (pwsh на Linux, `timeout 60` на файл)
| Тест | Итог |
|---|---|
| test-config-bootstrap.ps1 | PASS, 47 проверок, ~13 с |
| test-config-engine.ps1 | OK, 39 |
| test-config-routes.ps1 | PASS, 46 |
| test-config-account / device / scheduler | OK (9 / — / 7) |
| test-wizard.ps1 | OK, 88 |
| test-refresh.ps1 | OK, 27 |
| test-network / first-install / wizard-account | OK (34 / 16 / 42) |
| transport/test-transport-config.ps1 | OK, 263 |
| test-wizard-onboarding.ps1 | FAIL «hop key contents and route options are not logged or saved» — **падает так же на исходном HEAD** (`git archive HEAD`), к потоку A не относится |
| transport/test-engine-loopback.py --without-disk (`timeout 120`, настоящий sing-box) | PASS |
| transport/test-transport-liveness.py, test-transport-daemon.py (с hot reload) | OK |

Мутационная проверка: с исходным `Disk.Common.ps1` новый тест падает.

Ручная проверка sing-box 1.14.4: вход `mixed` с `route-options override_address/override_port`, запрос через SOCKS на `example.invalid:80` пришёл на локальный 127.0.0.1:38224 (HTTP 200).

## Отступления и решения
- **Вход `channel-socks` добавляется только при `transport.channelFirst`.** В контракте условия нет. Без него каждый демон занимал бы порт 2223, а `Invoke-TransportPreflight` (`build/Setup.Common.ps1`, не мой файл) поднимал бы второй демон на том же порту. Кроме того, `transport/test-transport-config.ps1` (не мой файл) ожидает, что все входы — `direct`. Для конфигураций без `channelFirst` вывод не изменился.
- **`Test-WizardNetworkManaged`** (`Wizard.Common.ps1`) возвращает `false`, если `channelFirst` и `bootstrap` установлены, а `wizard.configured` нет. Без этого свежий статус демона, поднятого в Bootstrap, направил бы первую «Связь» в `Set-WizardNetwork` (preflight и задача отката), а не в `Set-WizardInitialNetwork`, как предполагает п. 5. «Связь» снимает `bootstrap`, дальше действуют прежние правила.
- **`bootstrap=true` оставлен** вместе с `channelFirst`. Так `singbox-ssh-direct` не строится без закреплённого ключа хоста (TOFU), а «Связь» снимает признак как раньше.
- **`Set-WizardNetwork`:** при `channelFirst` изолированный preflight получает копию transport со свободным loopback-портом `channelSocksPort`. Иначе он столкнулся бы с рабочим демоном. Рабочий конфиг не меняется.
- **Повтор в `Invoke-WizardSsh` и управляющий сеанс.** Bridge, Account и Disk ходят через общий управляющий сеанс (`REMOTEAGENTS_WIZARD_SESSION=1`), где кода 255 нет. Его аналог — «Управляющий SSH-сеанс не запущен/прерван», он тоже повторяется один раз. Повтор после «прерван» может повторить уже отправленную команду. Тот же риск есть у 255, план его допускает.
- **Схема `transport/config.schema.json`** (не мой файл) не дополнена полями `channelFirst` и `channelSocksPort`. Во время работы схема не проверяется, но в документации её стоит дополнить.

## Что не проверено
- Ничего не проверено на Windows и PowerShell 5.1: настоящий Bootstrap с демоном, sing-box.exe и relay, длительность пропадания порта при перезапуске sing-box, повтор SSH у параллельных разделов. Это проверит сквозной тест потока C после слияния A+B, затем нужна проверка на «Компе».
- Возможная петля **`openssh-direct`**. Этот туннель строится с `-UseRoute`, то есть с `ProxyCommand` сохранённого маршрута. После шага «Сервер» это маршрут через `127.0.0.1:channelSocksPort`, то есть через сам демон. Пока активен другой кандидат (relay), туннель работает. Если активным станет сам `openssh-direct`, новые подключения туннеля пойдут по кругу. План (п. 3) исключает только `openssh-proxy`, поэтому я не менял это поведение и оставляю риск на решение.
