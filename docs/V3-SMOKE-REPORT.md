# smoke: повторная проверка по ревью, 25.11.2026

## ИТОГ

Замечание smoke.notes выполнено: живой Linux/amd64 запуск прошёл все пункты цели.
Проверен `go/dist/linux-amd64/RemoteAgents` из текущего worktree, ветка `v3/s-smoke`,
база `162768d`. Изменений Go не потребовалось, API и таймеры не менялись.

## ЧТО ИСПРАВЛЕНО

Закрыт пробел предыдущей проверки: выполнен настоящий запуск с настоящим каналом
и отдельным ключом `v3-smoke`, а не только сборка.

Конфиг выдан `server/remoteagents_config.py export --name v3-smoke --vpn channel
--happier new:v3-smoke --folders none --agent-sudo none`. Экспорт использовал
временную копию пользовательских настроек: `lanPcAccess` указывал на пустой список,
`syncFile` — внутрь временного дома. Это обошло недоступный без root файл ЛВС,
не меняя общие настройки. Ключ зарегистрирован штатным экспортом.

По `lab/CONFIG.md` собран формат `remoteagents-2`: SSH-поля и ключ из экспорта,
`paths.channel` из секрета bootstrap, `control: true`. VPN, LAN, TUN, disk,
автообновление, Happier и автозапуск не включались. Конфиг запечатан штатным
`python3 -m ralab.v2config seal`; случайный пароль хранился только во временном доме.

Запуск: `setsid … run --home /tmp/v3-smoke-home --config … --password-file …
--pc v3-smoke --safe --no-tun`, stdin — FIFO для команды выхода. Первый открытый
конфиг штатно отвергнут («Конфиг не защищён паролем»), после seal запуск успешен.
Команду exec передавали без `--shell sh`: серверный CLI принимает только Windows
названия shell, а агент на Linux сам использует `/bin/sh`.

## ПРОВЕРКИ

Все пункты цели — да:

- Канал: журнал 22:50:06.923 `channel.up`, `path: vless-direct`, `rport: 13340`.
- Компьютер в управлении: `ra-lab --pc v3-smoke status` вернул
  `computer: v3-smoke`, `control: true`, `channel.state: up`;
  журнал 22:50:24.456 — `GET /status`, код 200.
- Команда: `ra-lab --pc v3-smoke exec 'printf v3-smoke-ok' --max-time 10`
  вернула `v3-smoke-ok`; журнал 22:50:35.988 — `POST /exec`, код 200,
  22:50:35.989 — `proc.exited`, `exec:1`, код 0.
- Webui: HTTP GET страницы и `/state` вернули 200; HTML содержит RemoteAgents,
  состояние — конфиг v3-smoke, control=true, channel.up. Подтверждение события
  в журнале — `channel.up` выше. Проверка HTTP, без ручного открытия браузера.
- «Выход»: в FIFO передано `{"t":"exit","final":true}`; журнал
  22:50:49.546 — `app.stop`, «команда exit от EXE»;
  22:50:49.637 — выход `ssh:1:chan`, 22:50:49.894 — выход `singbox`.

Процессы запуска отсутствуют; порты UI 36063, агента 37483, SOCKS 36821
и обратного канала 13340 закрыты. Файлов `v3-smoke*` в состоянии ra-lab нет:
регистрацию убрал штатный обработчик завершения SSH-сессии.
`config revoke e57b0c7383af42e6` удалил ключ из authorized_keys; остаётся штатная
аудитная запись об отзыве. `devports close v3-smoke` выполнен.
Временный дом с конфигами, паролем и журналами удалён после сохранения отчёта.
Активных остатков на сервере нет.

Ограничения: это проверка ядра `run` с safe/no-tun, без трея и supervisor.
`devports list` выполнен, `devports free` зарезервировал 8205 и 8206,
но внутренних адресов приложение явно не принимает: оно выбрало свободные
loopback-порты через ОС. Это отклонение от требования выбирать каждый порт
через devports; алгоритм приложения не менялся. Inbound sing-box — только
`direct` на 127.0.0.1 (45579, 38061, 40207), без TUN. Системные сетевые
настройки, службы и sudo не использовались. Фоновые запросы `/exposed`
получали ожидаемый 503: forwards выключены в этом конфиге.

Обязательные проверки, каждая под `timeout 420`, завершились кодом 0:

- `go build ./...` для Linux, `GOOS=windows`, `GOOS=darwin`.
- `go vet` для тех же ОС: `./cmd/remoteagents ./internal/core ./internal/channel
  ./internal/agent ./internal/singbox ./internal/webui`.
- `gofmt -l .`: вывод пуст.
- Поиск `Ticker|time.Sleep|time.After|time.Tick` в этих пакетах:
  `cmd/remoteagents/dev_procs.go:44` — существующая пауза 100 мс демонстрационной
  dev-команды; `internal/channel/uplink.go:661` — существующий разовый таймаут
  SSH-пробы 60 секунд. Новых таймеров нет.

Тесты не добавлялись и не запускались. Не заработавших пунктов цели нет.
