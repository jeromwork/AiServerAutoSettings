# CONFIG — отчёт интегратора

Ветка `app/config`, worktree `~/work/wt-config`, поверх слияния потоков A/B/C/D (5003368). Push/merge не выполнялись.
Живой сервер, `~/.ssh`, authorized_keys пользователя `remoteagents`, службы, мост и Windows-компьютеры не трогались:
все проверки — во временных HOME и на своём sshd на loopback без root.

## Что состыковано (по пунктам задания)

1. **D↔C, имена действий и поля.** Трей вызывает `ConfigSync` (было `Sync`), бюджет 300 с. Окно читает ответ по
   `docs/CONFIG-ENGINE.md`: `ok:false` без `pending` — ❌ (раньше любое `ok:false` становилось ⏳ и даже пропускало «Сервер»
   дальше), `pending:"disk"|"happier"` — ⏳ со слежением, `pending:"connection"` у Vpn — Vpn повторяется один раз сразу
   после успешного Connection, неподтверждённый TUN — ⏳. Повторяется только свой раздел. `Server.port`/`hostKeys`/
   `hop.hostKey` и `Bridge.deviceName` доходят до PowerShell; на пути «чистый VPS по паролю root» порт и ключи хоста
   раньше игнорировались — исправлено. `--invite-hop` не осталось; пароль hop целиком идёт через `Route.Proxy.ps1`
   (askpass EXE, в аргументах SSH только путь); неиспользуемый C# `HopRelay`/`--hop-relay` удалён. Без ключа Happier
   («тот же аккаунт», как выдаёт сервер) запрос Account теперь несёт `mode:"same"`.
2. **A↔D.** Конфликты A (`server|happier|disk: сейчас X / в конфиге Y`) D разбирает; `"<есть, скрыт>"` = оставить
   сохранённое (A, проверено). Пути файлов-секретов D берёт **только** из `secrets/materialized.json` (вместо придуманного
   `secrets/config/<имя>`). `proxyOut.checkUrl`/`lan[].checkUrl` (термин схемы A) вместо `ipCheckUrl`; `lan[].host/port/login`
   в схеме уже были. Пароли при повторном открытии настроек берутся и из vault. `secret set/status/import` подключены к EXE.
   Чистый VPS: после «Сервера» по паролю root ключ, которым программа входит, кладётся в vault как `server-key`,
   `rootPassword` убирается — «Сохранить конфиг в файл» восстанавливает доступ без пароля хостинга.
3. **A↔B.** Схема принимает вывод `remoteagents config export`: добавлен `vpn.bootstrap.catalog`; остальное (hops с key,
   disk без base, happier без key, server без rootPassword, имена `hop-*-key/password`, `vpn-entry-*`, `vpn-hop-*`,
   JSON-текст канала/узлов) подтверждено тестом и сквозным прогоном. Тестовый вектор enc1 из `docs/CONFIG-SERVER.md`
   добавлен в C#-тесты (расшифровка + неверный пароль). `Materialize` больше не падает целиком из-за одной пустой ссылки
   (ключ **или** пароль root, ключ нового Happier создаёт сам шаг): пустая ссылка не даёт файла, перечислена в `missing`,
   старый файл вместо неё не используется.
4. **A↔C, материализация.** PowerShell читает `secrets/materialized.json`: ключ сервера (`serverKeyFile`), ключи и пароли
   hop по индексу маршрута, канал/кэши узлов, ключи SSH-переходов «VPN первым» (для них пишется частный ssh config под
   публичным псевдонимом каталога с ключами хоста из каталога). «VPN первым» запускается только при наличии `channel`.
5. **B↔C, автообновление.** Один протокол: сервер публикует `~/.config/remoteagents/config-sync.json`, клиент читает его
   своим ключом (`cat …`), `ConvertFrom-WizardConfigSync` переводит снимок во внутренний формат движка. Описано в обоих
   документах. Найдено и исправлено: через местный транспорт команды шли с `ssh -n`, живой каталог приходил пустым —
   каждый sync падал, пока работала связь.
6. **sing-box для «VPN первым».** `build/bundle-binaries.json` закрепляет архив sing-box 1.14.4 для Windows и сам
   `sing-box.exe` (обе SHA-256). `build-exe.sh` скачивает его один раз в кэш сборки (`bundle.py fetch`), встраивает в
   начальный бандл EXE; отдельным файлом в архив обновления по SSH он не попадает (но EXE внутри обновления его содержит). При первом применении копируется в `transport-bin` с проверкой
   хеша. Нет ни встроенного, ни доступа к GitHub — понятная причина в строке раздела, а не тихий провал.
   EXE из-за этого вырос примерно на 28 МБ.
   Попутно: в allowlist бандла не было `Wizard.Engine/Session/SessionHost/Bootstrap.ps1` и был удалённый
   `Wizard.Invite.ps1` — после слияния бандл не собирался вовсе; добавлен тест, что все модули мастера и ConfigSync в бандле.
7. **Имя компьютера.** `Start-WindowsControl.ps1` при каждой регистрации берёт `-DeviceName`, иначе `profile.device.name`,
   иначе `COMPUTERNAME` (тест в `test-windows-control.py`). Смена названия в настройках повторяет `Bridge` (было у D).
8. **`build/server-ssh-user.sh`**: дописывает в authorized_keys под тем же `flock`, что `config export/revoke`, и только в
   текущий файл (revoke заменяет его через rename). Тест с параллельными revoke: без исправления воспроизводится потеря строки.
9. **Устаревшее удалено:** `docs/INVITE.md`, `INVITE-REPORT.md`, `INVITE-UPDATE-REPORT.md`, `TASK-INVITE.md`;
   `wizard.inviteVpn*`, `transport.inviteBootstrap` (→ `bootstrap`, поле, которое реально пишет движок), имена тестовых
   каталогов. Оставшиеся совпадения `grep -ri invite` — история в отчётах/задании и список удалённого в CONFIG-SERVER.md;
   `overlay` в транспорте — это локальный слой каталога, к приглашениям не относится.
10. **run.sh**: ConfigTests для RemoteAgents и RemoteVPN (собственный каталог сборки — иначе `StartupObject` переиспользовал
    чужую сборку и запускалась не та точка входа) и сквозной тест.
11. **`app/launcher/config-ai-prompt.md`**: случаи «сервер уже есть» (проще — `config export` у администратора) и «чистый VPS»
    (адрес, `root`, подсказка к паролю), только JSON по схеме, секреты — пустые ссылки, пароли не спрашивать и останавливать
    человека, если пишет их в чат. Пример в нём проходит схему.

## Сквозной тест

`app/launcher/tests/test_config_e2e.py` (+ `ConfigE2E.cs`, те же исходники на net10). Настоящие OpenSSH, rootless sshd,
sing-box 1.14.4, PowerShell 7 на Linux:

`remoteagents config export --master-password-stdin` → текст (CRLF) → `Parse` / неверный мастер-пароль отвергнут / `Unlock` /
`Store` / `Materialize` → `ConfigPlan` + `ConfigEngine` (D) запускают настоящие `Wizard.ps1 Server`, затем одновременно
`Connection`, `Vpn` (настоящие) и `Bridge`/`Account`/`Disk` (стендовые) → вход ключом из конфига новым ssh-процессом →
`ConfigSync` по снимку сервера, затем новый ключ хоста на сервере + `config sync` → клиент его закрепил, повтор ничего не
меняет → `config revoke` → новый вход: `Permission denied`.

Проверяется также: использован именно выданный ключ (лишних ключей в authorized_keys и профилях нет), экспорт «для ИИ» без
значения ключа, полный экспорт → разбор → тот же ключ, мастер-пароль нигде не сохранён.

**Время «Server начат → Connection успешен»: **18,0 с** в прогоне внутри полного run.sh; 20,5 с в отдельном прогоне** (Server 5,0 с, Connection 13,0 с; перекрытие
параллельных разделов 0,65 с). Цель ≤ 60 с выполнена на стенде; это loopback, на реальном канале будет другое.

Сквозной тест нашёл три ошибки, невидимые в тестах потоков: NullReference в `ConfigRequests.Server` для конфига только с
маршрутом `direct` (это вывод `config export` по умолчанию — раздел «Сервер» падал всегда), пустой каталог при ConfigSync
через местный транспорт, отсутствие модулей движка в бандле.

## Итоги прогонов

- `timeout 1500 bash app/launcher/tests/run.sh` — **код 0, 5 мин 16 с**. В нём: PowerShell-тесты (setup 16, selective 46,
  account 25, wizard 88, onboarding 92, wizard-account 42, navpane, network 34, config-account 9, config-bootstrap 32,
  transport-config 263, config-routes 46, config-engine 37 — пять процессов перекрылись на 819 мс, config-device,
  config-scheduler 7, refresh 27); Python (liveness, first_run 9, disk tree 9, engine loopback, server catalog 8,
  accounts 26, build 12, bridge health, wizard boundary 5, server operations 5); вложенный `server/tests/run.sh` — 70 тестов;
  PortableTests RemoteAgents и RemoteVPN — config engine 86, disk tree 25, proxy relay, самотесты 93/93 каждый;
  ConfigTests RemoteAgents и RemoteVPN — 125 проверок каждый; сквозной тест — PASS; сборка/публикация net48 — PASS.
- `timeout 300 bash server/tests/run.sh` отдельно — **70 тестов, все прошли, 36,6 с**.
- `python3 test-windows-control.py` (корневой, не входит в run.sh) — 12 тестов OK.
- Ни один тест не обходился. Изменены по решению владельца/контракту: `test-refresh.ps1` (подаёт снимок в формате сервера),
  `test-config-bootstrap.ps1` (VPN первым требует `channel`), проверка materialize в `ConfigBundleTests.cs`
  (`missing` вместо отказа целиком), ожидания путей в `ConfigApplyTests` (манифест вместо `secrets/config`).

## Сборка

`build/build-exe.sh` — код 0 (бандл `20261112.045742-466ece8`, коммит 466ece8):

| Файл | SHA-256 | Размер |
|---|---|---|
| `release/RemoteAgents.exe` | `ab199dc2844ab3c11c2f984243e50300b09021fa6ea4c046c78134ce1651250a` | 28 421 632 |
| `release/RemoteVPN.exe` | `033edb98b33bae63f6c9d01f087c67a25973564655d11cc857f5966bd7f6c87b` | 28 421 120 |

Начальные бандлы обоих продуктов содержат `transport/sing-box.exe` и все модули движка. EXE в git **не закоммичены**
(28 МБ каждый; прежде release-EXE коммитили, но это решение по объёму репозитория — за координатором/владельцем); они лежат
в worktree `release/` и `build/out/`. Честно: архив обновления по SSH (`build/out/bundle.zip`) не содержит sing-box
отдельно, но содержит сам EXE, а в нём — начальный бандл с sing-box, поэтому обновление тоже ≈ 28 МБ.

## Что НЕ проверено

- **Windows**: WinForms-окна, DPAPI, скрытый ввод, планировщик задач (ConfigSync каждые 5 минут, откат), PowerShell 5.1,
  настоящий запуск `RemoteAgents.exe secret …` в консоли, копирование `sing-box.exe` из бандла на Windows.
- **Живой сервер**: `config export` от root с настройками в `/etc`, journalctl для `config list`.
- **Реальный VPN**: «VPN первым» (TUN, HTTPS-проверка, SSH-переходы каталога) проверен только адаптерами; ConfigSync на
  стенде работал без VPN. Маршрут через прокси с паролем (`routes[].proxy.password`) материализуется, но транспорт его
  пока не использует.
- Мост (`Bridge`), Happier (`Account`) и диск (`Disk`) в сквозном тесте — стендовые заглушки; их действия покрыты
  отдельными тестами потоков C/D.

## Приёмка владельцем на Windows

1. На сервере (администратор): `remoteagents config export --name "Ноутбук" --master-password-stdin --output ~/laptop.json`
   (пароль одной строкой в stdin). Передать файл одним путём, мастер-пароль — другим.
2. На Windows-компьютере без установленной программы запустить новый `RemoteAgents.exe`. Должно открыться окно поверх всех
   с «Вставить конфиг». Вставить текст файла (или перетащить файл), «Запустить», ввести мастер-пароль один раз.
3. Смотреть строки разделов: «Сервер» ✅, затем одновременно «Связь», «Мост», «Happier», «Диск», «VPN». Записать время из
   журнала окна от начала «Сервер» до ✅ «Связь» (цель ≤ 60 с). Неверный мастер-пароль должен давать отказ без изменений.
4. В `windows_devices` компьютер должен называться «Ноутбук», а не `WIN-…`; перезагрузить компьютер или выключить/включить
   сеть — название должно остаться. Сменить название в «Настройки» → «Сменить» — новое имя появляется в списке.
5. «Настройки» → «Конфиг»: «Скопировать» — в тексте секреты только `"<есть, скрыт>"`. «Сохранить конфиг в файл» с паролем
   → удалить программу → вставить этот файл → всё восстанавливается без вопросов.
6. Через 5–10 минут в Планировщике заданий есть задача `RemoteAgents config sync …`, в журнале программы —
   `config.sync.current`/`updated`.
7. `RemoteAgents.exe secret status` в консоли — только имена и «есть/нет», без значений.
8. На сервере `remoteagents config list` показывает выдачу; `remoteagents config revoke <id>` — после перезапуска
   программы (новое SSH-соединение) вход не проходит; открытая сессия может продолжать работать до разрыва — так задумано.
9. Отдельно на «чистом VPS» (по желанию): кнопка «Собрать конфиг с ИИ» → ответ ИИ вставить → программа спрашивает пароль
   root в своём окне → после «Сервер» ✅ «Сохранить конфиг в файл» содержит `server-key`, а не пароль root.
