# CHANNEL-CLEAN — поток B

Дата: 2026-11-12. Worktree `wt-channel-clean`, ветка `app/channel-clean`, база `f12980b`.

## Изменения

- `build/Wizard.Bootstrap.ps1`: transport собирается заново из текущего `profile.server` и `profile.vpn.bootstrap`. Старые `transport.serverRoute`, `wizard.serverRoute`, списки entries/hops/relays/cdn, disabledTags, channelPath, cacheRoot и флаги bootstrap/channelFirst не копируются. Персональный hop-overlay не восстанавливается из прежнего wizard. Новый SSH-профиль использует сервер и материализованный ключ вставленного конфига.
- Каждый подготовленный Bootstrap получает отдельный `state/bootstrap-cache-<guid>`. В него попадают только entries из текущего materialized.json; одноимённые кэши прежнего сервера и прежний staged cache не используются. Для объявленного секрета без материализации подготовка честно завершается ошибкой. Каталог без готового entry может получить его обычным Sync-TransportEntryCache; ошибка одного такого получения больше не блокирует relay.
- Повторный Bootstrap пропускается только для подготовленного здесь снимка без сохранённых маршрутов, с совпадающим сервером/портом/логином/путём ключа и текущей configRevision, свежим успешным статусом и доступным SOCKS-портом. Старый живой канал сам по себе не даёт пропустить подготовку.
- `transport/Transport.Common.ps1`: построение singbox-ssh-direct, relay, SSH-hop, OpenSSH-hop, proxy, entry и CDN изолировано по кандидату. Неудачные пути остаются в AllCandidates с buildFailed и New-TransportDiagnostic; в строки статуса они переходят как fail, с пустой скоростью. В журнал пишется process-failed. Причина и пояснение берутся из фиксированного списка, без текста стороннего исключения, адресов, путей и секретов; код завершения сохраняется, если известен.
- Ошибки отдельных настроек узла проверяются при его построении. Проверки уникальности имён и общей структуры остаются общими; строгая проверка редактора сохранена. При отсутствии пригодных включённых кандидатов возникает общая ошибка «Нет доступных кандидатов транспорта».
- Пропущенные пути не получают probe-порт, outbound, detour или tunnel в рабочей конфигурации. Отбор selector и рейтинг используют только Candidates. Старое remembered/ok с высокой скоростью не может вернуть путь с ошибкой построения; лимитный рейтинг не тратит на него места. Повреждённый entry-кэш не обрушает сбор контекста диагностики.
- Overlay-hop без known_hosts-hop получает `hop-host-key-missing` / «Нет ключа хоста промежуточного сервера»; оба его варианта исключаются. Явный knownHostsPath выбранного hop сохраняется.
- Invoke-TransportText различает невозможность найти программу/файл запуска, таймаут и ненулевой код. Get-TransportHostKeys проверяет наличие файла до запуска ssh-keygen; код 1 у `ssh-keygen -F` допускается как результат поиска без совпадения и превращается в понятную ошибку отсутствующего закреплённого ключа.

## Что переносится из старого transport

Явный список: `singBoxPath`; порты `sshPort`, `channelSocksPort`, `syncPort`, `probePortBase`, `socksPortBase`, `apiPort`; `bindPhysical`, `metered`; `activeProbeBytes`, `rankProbeBytes`, `activeIntervalSec`, `meteredActiveIntervalSec`, `rankIntervalSec`, `rankConcurrency`, `topOnMetered`, `stallSeconds`, `probeTimeoutSec`, `restartDelaySec`.

`openSsh` по-прежнему возвращается к значению по умолчанию при Bootstrap. Отключения отдельных тегов принадлежат прежнему набору путей и сбрасываются. Только для прежней runtime-only формы без `profile.server` сохранена совместимость: используется существующий profilePath; вставленный переносимый конфиг с server всегда создаёт свой профиль.

Save-WizardRoute не менялся: шаг «Сервер» сохраняет проверенный маршрут в wizard.serverRoute и ssh.conf/SSH-профиль. Read-TransportSettings переносит его в runtime transport overlay, Initialize-WizardTransport — в transport этапа «Связь». Проверены unit-путь через Read-TransportSettings и настоящий путь Server → Connection в channel e2e; собственный SOCKS канала не превращается в маршрут демона через самого себя.

## Проверки

Все PowerShell-проверки выполнены через `/home/remoteagents/.cache/pwsh-test/pwsh -NoProfile -NonInteractive -File … < /dev/null`, каждая под `timeout 60`, с отдельным `LOCALAPPDATA=/tmp/cc-channel-clean-…` и таким же TestHome там, где параметр предусмотрен.

| Проверка | Результат |
| --- | --- |
| app/launcher/tests/test-config-bootstrap.ps1 | PASS, 65 assertions |
| app/launcher/tests/test-config-engine.ps1 | PASS, 39 checks; five-way overlap 913 мс |
| app/launcher/tests/test-config-routes.ps1 | PASS, 46 checks |
| transport/test-transport-config.ps1 | PASS, 287 checks |
| app/launcher/tests/test-wizard.ps1 | PASS, 88 checks |
| app/launcher/tests/test-refresh.ps1 | PASS, 27 checks |
| Итого PowerShell | 6 файлов, 552 проверки, exit 0 |
| timeout 120 python3 app/launcher/tests/test_config_e2e.py --scenario channel | PASS, один прогон, exit 0 |
| git diff --check | PASS |
| BOM/переводы строк | Все 4 изменённых ps1: UTF-8 BOM, только CRLF |

Регрессии: прежняя установка с hop одновременно в transport и wizard, старым профилем/каталогом/cacheRoot и свежим статусом; новый профиль без known_hosts-hop; relay остаётся в настоящем Get-TransportCandidates. Отдельно проверены отсутствующий overlay host pin, SSH pin, ошибочные relay/hop/entry, недоступный proxy helper, ошибка загрузки кэша, сохранённый успех из памяти, selector/ранжирование/непрерывные probe-порты, отсутствие утечки в журнале и полный отказ при нуле кандидатов. Входные config.json и SSH -G включают CRLF. Тест bootstrap дополнительно повторён после усиления проверки повторного использования канала: PASS, 65 assertions.

E2E использовал настоящий loopback sshd/OpenSSH/sing-box и `config export --vpn channel`, без fallback экспортера. Bootstrap выбрал `vless-relay-relay` за **8332 мс**; до Server ok — **14241 мс**, Server — **5897 мс**, Connection — **17135 мс**, контрольный SSH-вход выданным ключом — **386 мс**. Весь сценарий — **41,5 с**; relay принял **11** соединений / **545552** байта, прямой SSH был заглушён стендом. Bridge/Account на стенде заменены заглушками, VPN выключен. Финальное усиление условия reuse проверено unit-тестом; чистый путь e2e с отсутствующим channelFirst этим условием не затрагивается, повторный сквозной прогон не выполнялся.

## Границы и непроверенное

Изменены два production-файла, два unit-теста и этот отчёт. Wait-WizardChannel, Start-WizardWorkingTransport, Transport.Daemon.ps1 и Get-TransportRevision не менялись. Кодировка журналов (п. 4), изменения test_config_e2e.py и upgrade e2e оставлены потоку C. Существующий channel-сценарий не редактировался.

Windows/PowerShell 5.1/.NET Framework 4.8 реально не запускались: подтверждены переносимый синтаксис и тесты PowerShell 7, но это не заменяет Windows-проверку. Живой сервер, ~/.ssh, службы, рабочий мост и Windows не изменялись; сетевые действия e2e ограничены тестовым loopback-стендом.

`build/build-exe.sh` не запускался по границе потока B; новый RemoteAgents.exe не собран, SHA-256 новой сборки отсутствует. Сборка и проверка после слияния остаются владельцу. Push/merge не выполнялись.
