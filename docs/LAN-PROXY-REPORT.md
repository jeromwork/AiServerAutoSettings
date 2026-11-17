# LAN-прокси: завершение 17.11.2026

Работа продолжена с `ff0fb87` и `5d74307` в `app/lan-proxy`, без пересоздания.
WIP оставлен в истории. Push, merge, установка и применение на живых системах
не выполнялись; `~/Disk/AiServerAutoSettings` не менялся. Отличия новой `main`
в других функциях в эту ветку не переносились.

## Сделано

- Схема `lan[].share`, совместимость без секции, перенос через ConfigBundle /
  ConfigApply и существующий серверный export. Файлы: `ConfigBundle.cs`,
  `LanAccess.cs`, обе схемы launcher, пример paste, transport schema и пример
  server-apply. Секреты OpenVPN остаются ссылками.
- ПК: `Transport.Common.ps1` создаёт loopback `lan-proxy` и `lan-fwd-*` через
  `active`, отклоняет остальные назначения mixed, выбирает свободные порты и
  сохраняет их в `transport-ports.json`. `Transport.Daemon.ps1` публикует `lan`
  в `status/transport.json`. Исправлены необязательные массивы и учёт переноса
  портов пробросов. PowerShell-файлы сохраняют BOM/CRLF, синтаксис — PS 5.1.
- `LanProxy.cs`: TcpListener PAC без администратора, сохранение чужого PAC/прокси,
  восстановление своего AutoConfigURL при выходе/удалении/старте после аварии.
  PAC не вызывает DNS Windows. Исправлено чтение всего HTTP-заголовка перед ответом.
  Карточка и трей (`StatusView`, `MainScreenModel`, `MainWindow.Cards`,
  `TrayContext`, `Uninstall`) используют свежую CONNECT-пробу первого разрешённого
  хоста через mixed. Недоступный хост не выдаётся за доказанно отключённую ЛВС.
- Сервер: `lan_share.py` добавляет точные разрешения к известным завершениям
  sing-box и Xray, сохраняя остальную политику. Подсети/приватные адреса доменов
  ЛВС идут в direct-out, публичные адреса доменов sing-box — в прежний final;
  Xray использует штатный freedom. Маршруты в `tun-lan-<имя>` и TCP хоста
  проверяет существующий менеджер LAN; для share проверяются фактические подсети.
  Никаких новых nft/маршрутов LAN-прокси не создаёт.
- Изменения входят в `server_apply`, доставку `Wizard.ServerApply.ps1` и bundle.
  Есть проверка кандидата, общий lock, pending, подтверждение новым SSH,
  автоматический откат через 5 минут/при ошибке и boot recovery.
  Учёт правил независим от изменяемого результата генерации. Исправлена структура
  логических правил sing-box; base/LAN/recovery учитывают pending share.
- Добавлены тесты `server/tests/test_lan_share.py`, `LanProxyTests.cs`,
  `test-lan-proxy-pac.cjs`, `transport/test-lan-proxy-config.ps1` и отдельный
  fail-fast runner `transport/test-lan-proxy-fast.sh` с внешним лимитом 10 секунд
  (C# компилируется заранее). Подключены к существующим полным runner, которые
  в этой работе не запускались. Обновлены LAN, CONFIG, TRANSPORT и SERVER-APPLY.

## Проверки этого продолжения

Во время правок — только компиляция/синтаксис. .NET 4.8 launcher и отдельная сборка
`PortableTests.csproj -p:LanTests=true`: успешно, 0 предупреждений/ошибок.
Python `py_compile`, PowerShell parser и `sing-box check` кандидата — успешно.
Первый syntax check выявил недопустимый верхний `inbound` логического правила;
после исправления кандидат принят.

В конце выполнен только затронутый набор, каждая команда под `timeout 420`:

- `flock /tmp/heavy-tests.lock bash transport/test-lan-proxy-fast.sh`:
  fail-fast остановился на неточном тестовом сценарии: хост оставался в прежней
  подсети и раньше срабатывала проверка разрешённых назначений. Сценарий исправлен.
- Продолжены только упавшие/ещё не выполненные Python-тесты, без повтора успешно
  пройденных: в сумме все 6 прошли. Проверены схема/старый конфиг/CRLF/export,
  область правил, идемпотентность/удаление, sing-box check, Xray-генерация,
  plan без записей/команд, apply/confirm, откат и границы маршрутов. Тест изменения
  правила обнаружил общие ссылки результата и записи владения; исправлено через
  независимую копию, соответствующий тест повторён успешно.
- `pwsh -NoProfile -NonInteractive -File transport/test-lan-proxy-config.ps1`:
  успешно; CRLF/BOM, старый и forwards-only конфиги, конфликты портов,
  сохранённые порты, loopback, назначение проброса, active/reject и sing-box check.
- `flock /tmp/heavy-tests.lock dotnet …/lan-tests/net10.0/PortableTests.dll <repo>`:
  успешно; схема/миграция/store/export, 10 исполняемых PAC-сценариев через Node,
  отсутствие локального DNS, HTTP PAC, чужие настройки, снятие/аварийное
  восстановление PAC, успешный и неуспешный CONNECT через loopback-фикстуру.

Прогоны заняли секунды, бюджет 5–7 минут не исчерпан. Полные `server/tests/run.sh`
и `app/launcher/tests/run.sh` не запускались. Единый runner целиком после исправлений
повторно не запускался: результаты выше получены продолжением отдельных частей.

Для следующего отдельного прогона: заранее собрать
`dotnet build app/launcher/tests/PortableTests.csproj -p:LanTests=true`, затем
`timeout 420 flock /tmp/heavy-tests.lock bash transport/test-lan-proxy-fast.sh`.

## Не проверено и живой приёмочный шаг

Не проверены Windows PowerShell 5.1, WinForms/трей, настоящий HKCU/WinINet и
браузер, реальный канал с переключением active, OpenVPN/ЛВС, DNS сервера,
маршрутизация/SSH/root/systemd rollback на живом сервере и запуск Xray-бинарного
check. Службы, сеть Windows, сервер и клиника не менялись. Linux/.NET 10 и моки
этого не подтверждают. Клиентский TUN/полный VPN и сторонние VPN не изменялись.

После обычной настройки и запуска EXE один безопасный шаг на ПК:

```powershell
powershell -NoProfile -File transport/Test-LanProxy.ps1 -TransportHome "$env:LOCALAPPDATA\RemoteAgents"
```

Это только curl через уже запущенный mixed и TCP к локальным пробросам: никаких
изменений настроек Windows. JSON и код 0 подтверждают эти пробы. `localTcp` означает
только наличие слушателя, `remoteConnect` — достижимость цели через mixed;
работа SSH/RDP/БД непосредственно через проброс и реальное применение PAC браузером
требуют отдельной проверки приложения. Границы функции — прокси и TCP-пробросы,
не полный VPN.
