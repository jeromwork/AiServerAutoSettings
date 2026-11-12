**Основная задержка — в организации первой настройки:** до рабочего транспорта выполняется цепочка отдельных SSH-подключений, загрузок и проверок; транспорт зависит от установки диска, а независимые разделы проходят последовательно. Параллельные проверки маршрутов и фоновые серверные установки уже реализованы, но этих ускорений недостаточно.

Разбор выполнен по исходникам ветки `app/windows`, HEAD `ec7c296`. Код не менял, ничего не коммитил, сеть и скрипты не запускал, `~/.ssh`, сервер и службы не трогал. Имеющиеся изменения рабочего дерева оставлены как были.

Все времена ниже — **оценки по коду, не результаты замеров**. Для расчёта:

- **H** — одно короткое SSH-подключение: примерно **1–3 с** напрямую, **3–20 с** через медленный обход. Последний диапазон согласуется с комментарием в [Wizard.Server.ps1:109](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Server.ps1:109).
- **U** — передача общего набора helpers: около **100 КиБ после Base64**, плюс команды оболочки. Исходники занимают примерно 78 КБ. При 10 КиБ/с только передача занимает около 10 с.
- Запуск нового Windows PowerShell с загрузкой библиотек — ориентировочно **0,3–2 с**, на загруженном компьютере больше.
- Таймаут — предел ожидания при проблеме, а не обязательная пауза.

**1. Последовательность от «Сервер» до «Итог»**

Фактический порядок:

`Сервер → Связь → Выход в интернет → Мост → Диск → Happier → Локальные сети → VPN → Итог`

Он жёстко задан в [SetupWizard.cs:28](/home/remoteagents/Disk/AiServerAutoSettings/app/launcher/SetupWizard.cs:28). При первой настройке последующие разделы закрыты до завершения или перевода предыдущих в ожидание: [WizardStep.cs:15](/home/remoteagents/Disk/AiServerAutoSettings/app/launcher/WizardStep.cs:15).

Каждый `Run(action)` создаёт новый **`powershell.exe`, фактически Windows PowerShell 5.1**, файл запроса, файл результата и progress-файл: [SetupWizard.cs:397](/home/remoteagents/Disk/AiServerAutoSettings/app/launcher/SetupWizard.cs:397). Это не обязательный запуск `pwsh` PowerShell 7.

До ввода настроек есть подготовка бандла: распаковка и самопроверка, которая разбирает все `.ps1`. Окно уже показано, но управление выключено до завершения подготовки: [TrayContext.cs:68](/home/remoteagents/Disk/AiServerAutoSettings/app/launcher/TrayContext.cs:68), [SetupWizard.cs:147](/home/remoteagents/Disk/AiServerAutoSettings/app/launcher/SetupWizard.cs:147), [selftest.ps1:27](/home/remoteagents/Disk/AiServerAutoSettings/build/selftest.ps1:27). Оценка — несколько секунд, зависит от диска и антивируса; бюджет самопроверки — 120 с. В текущем `build/components.json` список `binaries` пуст, поэтому обязательную загрузку бинарников на этой стадии приписывать текущему бандлу нельзя.

**«Сервер»**

| Действие | Источник | Нормально / медленный обход; ограничения |
|---|---|---|
| При повторном использовании профиля — отдельный SSH `true` | [Wizard.Server.ps1:168](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Server.ps1:168) | H; таймаут 10 с |
| Для нового профиля — создание локального ключа | [Wizard.Server.ps1:178](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Server.ps1:178) | Обычно <1–2 с, без сети |
| Если способов подключения несколько — отдельный SSH `true` на каждый маршрут | [Wizard.Server.ps1:60](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Server.ps1:60) | **Уже параллельно**. Первый доступный маршрут плюс до 3 с ожидания предпочтительного; общий предел 30 с, опрос каждые 100 мс |
| Ещё один SSH `true` ключом рабочего пользователя | [Wizard.Server.ps1:187](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Server.ps1:187) | H; бюджет 45 с, `ConnectTimeout=8` |
| При отказе — новый SSH исходным логином, передача `server-ssh-user.sh` и установка публичного ключа | [Wizard.Server.ps1:191](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Server.ps1:191) | H плюс создание пользователя/systemd: примерно 1–5 / 3–25 с; бюджет 45 с |
| При отказе — перебор выбранного, стандартных и профильных ключей, **каждый в новом SSH** | [Wizard.Server.ps1:152](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Server.ps1:152) | K×H; до 45 с на ключ. Для части ошибок дополнительно `ssh-keygen` с пределом 10 с |
| Затем, если нужно, — новый SSH по паролю и тот же bootstrap | [Wizard.Server.ps1:201](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Server.ps1:201) | H плюс bootstrap; отправка до 5 с, ожидание завершения до 30 с |
| После bootstrap — ещё один SSH `true` рабочего пользователя | [Wizard.Server.ps1:203](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Server.ps1:203) | H; бюджет 45 с |
| Инвентаризация: SSH `bash -s`, весь `server-wizard.sh` передаётся через stdin | [Wizard.Common.ps1:317](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Common.ps1:317) | Обычно 1–4 / 3–25 с; бюджет SSH 60 с |
| При `installMissing` — SSH с общим пакетом helpers | [Wizard.Common.ps1:320](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Common.ps1:320) | H+U: примерно 1–4 / 5–30+ с; бюджет 60 с |
| Следующий SSH — `server-wizard.sh repair …` | [Wizard.Common.ps1:324](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Common.ps1:324) | H плюс запуск фоновых процессов; обычно несколько секунд, при зависшем user systemd ещё до 10 с на операцию; бюджет SSH 120 с |
| Повторная полная инвентаризация отдельным SSH | [Wizard.Common.ps1:329](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Common.ps1:329) | Ещё 1–4 / 3–25 с |

Обычная первая настройка по паролю с `installMissing` — примерно **8+K последовательных SSH-сеансов**, дополнительно к параллельным пробам маршрутов. При H=15 с одни подключения дают около двух минут.

Инвентаризация тоже содержит ожидания: серверный REST Syncthing — до 4 с, проверка user systemd — до 5 с: [server-wizard.sh:88](/home/remoteagents/Disk/AiServerAutoSettings/build/server-wizard.sh:88).

**Отсоединённые установки уже есть.**

`repair` запускает disk и Happier через `setsid nohup`; процесс наследует отдельный `flock` операции. Проверка пригодности `systemd-run` ограничена 10 с: [server-wizard.sh:63](/home/remoteagents/Disk/AiServerAutoSettings/build/server-wizard.sh:63). Обе установки могут идти одновременно; общий предел каждой — 1800 с: [server-wizard.sh:127](/home/remoteagents/Disk/AiServerAutoSettings/build/server-wizard.sh:127).

- **Happier:** при необходимости Node.js, затем установщик Happier. Загрузка Node ограничена 180 с, скрипта установщика — 120 с, выполнение установщика — 900 с; внутренний bootstrap-lock ждёт до 120 с. Оценка холодной установки — десятки секунд или минуты, при ограниченных загрузках — несколько минут: [bootstrap.sh:7](/home/remoteagents/Disk/AiServerAutoSettings/accounts/bootstrap.sh:7).
- **Disk:** загрузка Syncthing, проверка хеша, генерация конфигурации и запуск. `ports.json` появляется **после загрузки бинарника**. REST имеет предел 3 с на запрос, запуск проверяется до 80 раз с паузой 100 мс: [server-disk.sh:168](/home/remoteagents/Disk/AiServerAutoSettings/disk/server-disk.sh:168). Это не строгие «8 секунд»: к паузам прибавляются REST-ожидания.
- Окно опрашивает операции раз в **12 с** отдельным PowerShell и SSH, серверный статус ограничен 30 с: [SetupWizard.cs:39](/home/remoteagents/Disk/AiServerAutoSettings/app/launcher/SetupWizard.cs:39), [Wizard.Common.ps1:66](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Common.ps1:66). Обнаружение завершения запаздывает на 0–12 с плюс стоимость запроса.
- Автопродолжение `ResumeAccount` и повтор «Связи» запускаются только когда `busy=false`: [SetupWizard.cs:478](/home/remoteagents/Disk/AiServerAutoSettings/app/launcher/SetupWizard.cs:478).

**«Связь»**

| Действие | Источник | Нормально / медленный обход; ограничения |
|---|---|---|
| UI впервые загружает каталог: новый PowerShell, SSH `python3 -`, передача исходника каталога | [SetupWizard.cs:504](/home/remoteagents/Disk/AiServerAutoSettings/app/launcher/SetupWizard.cs:504), [Wizard.Common.ps1:147](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Common.ps1:147) | H плюс небольшой payload; бюджет SSH 60 с |
| `Connection` заново получает тот же каталог отдельным SSH | [Wizard.Common.ps1:343](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Common.ps1:343) | Ещё H |
| Если включена публикация общего каталога — снова helpers, затем отдельный SSH `put` | [Wizard.Common.ps1:357](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Common.ps1:357) | H+U+H; по умолчанию публикация выключена |
| При отсутствии `channelPath` — опять helpers; затем SSH проверки `/etc/sing-box/config.json`; затем SSH экспорта канала или чтения `ports.json` | [Wizard.Server.ps1:236](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Server.ps1:236) | 3H+U: примерно 3–12 / 11–70+ с |
| При отсутствии sing-box — последовательная загрузка ZIP, SHA-256, распаковка | [Wizard.Server.ps1:256](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Server.ps1:256), [Disk.Binary.ps1:6](/home/remoteagents/Disk/AiServerAutoSettings/disk/Disk.Binary.ps1:6) | Ориентировочно 5–30 / 30–90+ с; загрузка ограничена 90 с, распаковка добавляется |
| Preflight: новый PowerShell-демон во временном Home | [Setup.Common.ps1:97](/home/remoteagents/Disk/AiServerAutoSettings/build/Setup.Common.ps1:97) | Примерно 5–15 / 15–45+ с до готовности |
| После готовности — ещё SSH `true` через временный локальный порт | [Setup.Common.ps1:128](/home/remoteagents/Disk/AiServerAutoSettings/build/Setup.Common.ps1:128) | 1–3 / 3–15 с; предел 15 с |
| Временный транспорт останавливается | [Setup.Common.ps1:134](/home/remoteagents/Disk/AiServerAutoSettings/build/Setup.Common.ps1:134) | Обычно <1–2 с; ожидание до 10 с |
| На чистой установке — сохранение настроек; рабочий демон запускается супервизором отдельно | [Wizard.Common.ps1:367](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Common.ps1:367), [TrayContext.cs:126](/home/remoteagents/Disk/AiServerAutoSettings/app/launcher/TrayContext.cs:126) | Ещё запуск и проверка пути, примерно 5–15 / 15–45+ с, часть времени перекрывается следующими разделами |
| Для уже управляемого подключения — после preflight ожидание proof рабочего демона | [Wizard.Common.ps1:280](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Common.ps1:280) | Обычно несколько секунд; цикл до 120 с, пауза 1 с, каждый дошедший до SSH proof — отдельный `true` до 15 с |

**Критическая зависимость:** связь требует порт диска даже при наличии VLESS.

Без VLESS код явно ждёт `ports.json` и переводит «Связь» в `pending=disk`. С VLESS экспорт канала также читает этот файл: [server-disk.sh:54](/home/remoteagents/Disk/AiServerAutoSettings/disk/server-disk.sh:54). Кроме того, генератор транспорта отвергает канал без `sync.override_port`: [Transport.Common.ps1:390](/home/remoteagents/Disk/AiServerAutoSettings/transport/Transport.Common.ps1:390). В VLESS-ветке отсутствие файла не преобразуется здесь в такое же аккуратное ожидание.

Внутри каждого запуска транспортного демона:

1. **До проб маршрутов** последовательно загружаются отсутствующие entry-конфиги: по SSH `cat /opt/rd-entry/client.json`, до 15 с на entry. Ошибка одного может оборвать инициализацию всего демона: [Transport.Daemon.ps1:115](/home/remoteagents/Disk/AiServerAutoSettings/transport/Transport.Daemon.ps1:115), [Transport.Common.ps1:847](/home/remoteagents/Disk/AiServerAutoSettings/transport/Transport.Common.ps1:847).
2. Строятся кандидаты; для SSH-hop вызывается локальный `ssh -G`. Это процесс SSH, **но не сетевой сеанс**.
3. Запускаются sing-box и постоянные OpenSSH `-D` для direct/hop/proxy: [Transport.Daemon.ps1:88](/home/remoteagents/Disk/AiServerAutoSettings/transport/Transport.Daemon.ps1:88).
4. По каждому кандидату открывается отдельный SSH с `head -c 65536 /dev/urandom`. **Живость проверяется параллельно; первый успешный путь активируется сразу.** Оценка 1–5 / 5–30 с; preflight задаёт 30 с на пробу, обычный демон по умолчанию 45 с: [Transport.Daemon.ps1:64](/home/remoteagents/Disk/AiServerAutoSettings/transport/Transport.Daemon.ps1:64).
5. Рейтинг идёт позже, по умолчанию по одному пути. Это обоснованно для измерения скорости; готовность не должна ждать окончания рейтинга: [Transport.Daemon.ps1:267](/home/remoteagents/Disk/AiServerAutoSettings/transport/Transport.Daemon.ps1:267).
6. Цикл демона — 300 мс, статус примерно раз в секунду; повтор запуска после ошибки — по умолчанию через 3 с.

Таким образом, без публикации каталога первая «Связь» делает **ещё пять управляющих SSH-сеансов**, затем SSH-пробы preflight, закрытие транспорта и повторный запуск рабочего экземпляра.

**Оставшиеся разделы**

| Раздел | Последовательность и источник | Оценка времени и ожидания |
|---|---|---|
| **Выход в интернет** | `AdminProbe`: отдельный PowerShell и root SSH `true`; затем `Proxy`: SSH с helpers и apply; затем **новый SSH confirm**. [SetupWizard.Network.cs:83](/home/remoteagents/Disk/AiServerAutoSettings/app/launcher/SetupWizard.Network.cs:83), [Wizard.Network.ps1:107](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Network.ps1:107) | Обычно 5–20 / 15–90+ с, без времени ввода пароля. Root-проба до 20 с, apply до 180 с, confirm до 120 с. Автооткат через 5 минут — защитный срок, его не ждут. При пропуске — только короткий PowerShell |
| **Мост** | Предварительный SSH proof; при необходимости установка отдельным PowerShell, запуск фонового процесса, SSH подготовки сервера с повторной передачей трёх bridge helpers, запуск executor PowerShell, постоянный reverse SSH, затем ещё SSH proof. [Wizard.Common.ps1:233](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Common.ps1:233), [Start-WindowsControl.ps1:140](/home/remoteagents/Disk/AiServerAutoSettings/Start-WindowsControl.ps1:140) | Уже рабочий мост: примерно H+proof. Новый: 5–15 / 15–60+ с. Установщик опрашивает лог до 45 раз с обязательной паузой 1 с; серверная подготовка до 60 с; executor ready до 20 с, remote ready до 25 с |
| **Повторы моста** | Внутренний reverse SSH повторяется бесконечно с задержкой `min(30,2+attempt)`; внешний цикл подготовки — пауза 15 с. [Start-CodexWindowsBridge.ps1:182](/home/remoteagents/Disk/AiServerAutoSettings/Start-CodexWindowsBridge.ps1:182), [Start-WindowsControl.ps1:200](/home/remoteagents/Disk/AiServerAutoSettings/Start-WindowsControl.ps1:200) | Это восстановление в фоне; при неработающем маршруте успешной установки не гарантирует |
| **Дерево диска** | На корень и каждую раскрываемую папку: новый PowerShell, **полный набор helpers**, отдельный SSH tree. [SetupWizard.cs:562](/home/remoteagents/Disk/AiServerAutoSettings/app/launcher/SetupWizard.cs:562), [Wizard.Common.ps1:399](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Common.ps1:399) | На уровень примерно 2–7 / 8–50+ с. Большие деревья ограничены 2000 элементами на уровень |
| **Установка диска** | Дочерний PowerShell; ещё SSH с тремя disk helpers и **синхронным bootstrap**; загрузка Windows SyncthingTray; запуск движка; ещё SSH add-device; ожидание SSH-баннера. [Install-RemoteDisk.ps1:31](/home/remoteagents/Disk/AiServerAutoSettings/disk/Install-RemoteDisk.ps1:31) | С готовыми бинарниками 5–15 / 15–60 с; холодная установка — десятки секунд или минуты. Загрузка до 90 с; SSH bootstrap по умолчанию 45 с; баннер до 30 с, повторы через 250 мс |
| **Применение выбора диска** | Ещё дочерний PowerShell, загрузка helpers, SSH tree; на новую локальную папку SSH list и attach; при сокращении выбора — SSH verify-selection; затем локальная синхронизация списка папок. [Select-Disk.ps1:11](/home/remoteagents/Disk/AiServerAutoSettings/disk/Select-Disk.ps1:11), [Add-RemoteDiskFolder.ps1:11](/home/remoteagents/Disk/AiServerAutoSettings/disk/Add-RemoteDiskFolder.ps1:11) | Примерно 2H на новую папку плюс общая работа; при обходе десятки секунд на папку. Локальный REST до 5 с на запрос. Пауза папки проверяется до 30 раз через 100 мс плюс REST-время |
| **Happier** | Общие helpers → SSH ensure. Если установка идёт — честный pending. Если готова — дочерний `Account.ps1`: снова загрузка двух helpers и проверка установки по SSH, затем отдельный SSH подключения аккаунта. [Wizard.Common.ps1:103](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Common.ps1:103), [Account.ps1:25](/home/remoteagents/Disk/AiServerAutoSettings/accounts/Account.ps1:25) | Pending: 2H+U. Готовый аккаунт: примерно 5–20 / 15–90+ с. SSH account до 180 с, серверный accounts-lock до 60 с |
| **Проверка аккаунта** | До четырёх `systemctl` по 30 с, затем до 20 запросов `/v1/machines` по 10 с с паузой 1 с. [server-account.mjs:148](/home/remoteagents/Disk/AiServerAutoSettings/accounts/server-account.mjs:148) | Обычно несколько секунд; внутренние пределы суммарно могут превышать внешний SSH-бюджет 180 с |
| **Локальные сети** | При добавлении: AdminProbe, SSH с OpenVPN-профилем/helpers и add, новый SSH test+confirm. При простом переходе с имеющимися сетями — SSH NetStatus. [Wizard.Network.ps1:136](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Network.ps1:136) | С установленным OpenVPN ориентировочно 10–40 / 30–120+ с. Add до 300 с, test+confirm до 120 с. Установка OpenVPN: apt update до 120 с, install до 180 с. Пустой раздел проходит локально |
| **VPN Windows** | Проверка конфликта → дочерний PowerShell → подготовка → UAC/broker → фоновый worker. [Wizard.Common.ps1:460](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Common.ps1:460), [Vpn.Tun.ps1:60](/home/remoteagents/Disk/AiServerAutoSettings/transport/Vpn.Tun.ps1:60) | Подготовка обычно несколько секунд, UAC зависит от человека. Worker ждёт адаптер до 40×250 мс; затем SSH-проба 64 КиБ до 40 с, DNS и HTTPS до 20 с. Повторные проверки каждые 30 с. Сам шаг возвращает «запрос передан», готовность ещё не подтверждена |
| **Итог: Activate** | Проверка свежести/revision транспорта → новый локальный SSH `true` → при включённом мосте отдельный SSH bridge proof → автозапуск и `wizard.configured=true`. [Wizard.Common.ps1:519](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Common.ps1:519) | Примерно 2–7 / 6–40+ с; `true` до 15 с, bridge SSH до 60 с. Activate сам не ждёт восстановления: может сразу отказать |
| **Inspect** | SSH server inventory → локальные REST диска → при сохранённом аккаунте SSH account inspect → локальный SSH transport proof → SSH bridge proof. Всё последовательно. [Wizard.Common.ps1:487](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Common.ps1:487) | Готовая система примерно 5–15 / 15–90+ с; внешний бюджет 300 с |

`Inspect` **не выполняется после каждого шага**: он используется при проверке запуска, открытии настроек и повторной проверке итога. На чистой первой настройке окно идёт через `Prepare`.

Дополнительные ожидания запуска:

- Перед `CheckOnLaunch` — 3 с; если не готова только связь — ещё 20 с и повторный `Inspect`: [TrayContext.cs:237](/home/remoteagents/Disk/AiServerAutoSettings/app/launcher/TrayContext.cs:237), [SetupWizard.cs:74](/home/remoteagents/Disk/AiServerAutoSettings/app/launcher/SetupWizard.cs:74).
- Супервизор после падения компонента откладывает повтор на **5, 10, 20, 40, 60 с**; сбрасывает задержку после 120 с здоровья: [Supervisor.cs:12](/home/remoteagents/Disk/AiServerAutoSettings/app/launcher/Supervisor.cs:12).
- Проверка здоровья 20×15 с у настроенного приложения — фоновое ожидание перед предупреждением, **не обязательная пятиминутная задержка установки**: [TrayContext.cs:251](/home/remoteagents/Disk/AiServerAutoSettings/app/launcher/TrayContext.cs:251).

Внешние бюджеты из [WizardStep.cs:37](/home/remoteagents/Disk/AiServerAutoSettings/app/launcher/WizardStep.cs:37):

| Action | Бюджет |
|---|---:|
| Server / Account / ResumeAccount | 420 с |
| Connection / Bridge | 900 с |
| Disk | 2100 с |
| Vpn | 600 с |
| Inspect / Skip | 300 с |
| Activate / DiskTree / AccountList | 180 с |
| Operation | 60 с |
| Proxy / Lan / LanRemove | 420 / 480 / 240 с |
| Прочие | 120 с |

Есть неоднозначность внутренних таймаутов: `Invoke-DiskProcess` сначала отдельно ждёт запись stdin, затем отдельно завершение процесса. Поэтому `TimeoutSeconds=60` для большого payload **не означает строгие 60 с общего времени**: [Disk.Common.ps1:24](/home/remoteagents/Disk/AiServerAutoSettings/disk/Disk.Common.ps1:24). Аналогично устроен административный askpass.

**2. Что повторяется зря**

- **Общие helpers загружаются целиком:** Server, инициализация Connection, публикация каталога, каждый DiskTree, AccountList, Account/ResumeAccount, retry установки. В пакете есть компоненты, не нужные конкретному запросу. Даже bridge-файлы, запись которых условная, всё равно передаются внутри скрипта: [Wizard.Common.ps1:26](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Common.ps1:26).
- После этого **Account и Disk ещё раз загружают свои helpers**, а мост передаёт три Python-файла при подготовке.
- **Каталог читается минимум дважды подряд:** UI `Catalog`, затем `Connection`. Для публикации повторная проверка актуальности нужна, но её можно совместить с CAS-записью. Сервер уже поддерживает CAS: [server-transport-catalog.py:43](/home/remoteagents/Disk/AiServerAutoSettings/transport/server-transport-catalog.py:43).
- Каждый управляющий вызов создаёт **новый SSH**, через hop — ещё и промежуточное SSH-подключение. Общего подключения для команд мастера нет; постоянные `-D` туннели транспорта его не заменяют.
- **Preflight подтверждает временный экземпляр и уничтожает его**, затем рабочий экземпляр повторяет запуск и liveness. Для изменения существующего подключения изоляция полезна; на чистой установке это повтор значительной части работы.
- Entry-кэш копируется **из рабочего Home в preflight**, но обратно не переносится. При холодном кэше временный и рабочий демон могут загрузить одинаковые entry-конфиги повторно.
- Установка Windows-диска снова вызывает серверный bootstrap. Если отсоединённая установка ещё выполняется, вызов может ждать её `bootstrap.lock`.
- Новый PowerShell создаётся не только на раздел, но и на загрузку каталога/дерева/списка аккаунтов/опрос установки; внутри разделов запускаются дополнительные процессы.
- Повторное доказательство рабочего пользователя после bootstrap полезно; перебор посторонних ключей **перед явно предоставленным паролем** способен добавить K×H без пользы.

При этом **новый SSH после изменения серверной сети убирать нельзя**: он доказывает, что новое подключение возможно. Продолжение старого соединения этого не подтверждает.

**3. Что можно выполнять параллельно и что мешает**

Сегодня параллельности мешают два уровня:

1. `Guard` выставляет общий `busy`, выключает страницы и навигацию на весь шаг: [SetupWizard.cs:388](/home/remoteagents/Disk/AiServerAutoSettings/app/launcher/SetupWizard.cs:388).
2. `Wizard.ps1` держит **`Invoke-WizardLock` вокруг всего action**, включая SSH, загрузки, дочерние установки и ожидания. Даже Catalog, DiskTree, NetStatus и Inspect входят в него. Исключение — Operation: [Wizard.ps1:19](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.ps1:19).

Замок ждёт всего 1 с и затем выдаёт ошибку; простое добавление `Task.WhenAll` приведёт к отказам «настройки уже применяются», а не к ускорению.

| Работа | Реальная зависимость | Возможность параллельного выполнения |
|---|---|---|
| **Связь** | SSH-профиль, канал, локальный binary | Должна иметь приоритет; каталог, диск, Happier и прокси не должны задерживать первый доступный путь |
| **Мост** | SSH-профиль, helpers, настройки shell | Не зависит от диска/Happier. Может запускаться сразу после SSH-доступа с корректным маршрутом |
| **Happier** | Серверный binary/Node, ключ, адрес API | Установка независима от диска/моста. Подключение аккаунта сейчас идёт через локальный transport SSH, поэтому требует связи либо отдельного bootstrap-маршрута |
| **Диск** | Серверный Syncthing и локальный движок; для синхронизации — транспорт | Серверная и локальная подготовка могут идти параллельно связи/Happier/мосту. Применение выбора — отдельная последовательная операция диска |
| **VPN Windows** | Свежий transport status, выбранный пригодный для TUN путь, UAC | Сбор сведений можно начать раньше; включать после подтверждения транспорта |
| **Серверный прокси и LAN** | Административный доступ, согласованное изменение сети | Подготовку/проверки можно перекрывать другой работой. Их сетевые транзакции между собой нужно сериализовать |
| **Inspect** | Снимок конфигурации | Сервер, аккаунт, диск и мост можно проверять независимо; итог принимать только для актуальной версии настроек |

Существующие конфликты, которые нужно сохранить или устранить адресно:

- `config.json` уже имеет отдельный короткий mutex чтения–изменения–записи: [Setup.Common.ps1:9](/home/remoteagents/Disk/AiServerAutoSettings/build/Setup.Common.ps1:9). Но параллельный rollback целого раздела способен затереть более новую настройку этого же раздела.
- Общие helpers пишутся в одни серверные пути. Большинство замен атомарные, однако одновременные разные версии всё равно дают гонку; `Install-RemoteDisk.ps1` использует и прямую перезапись.
- Preflight использует фиксированный `state/transport-probe` и диапазоны портов. Два preflight одновременно конфликтуют.
- `RemoteDisk/folders.lock` должен защищать выбор, attach и reconciliation одного диска.
- Серверные disk/happier уже имеют отдельные operation locks; disk bootstrap дополнительно имеет собственный блокирующий lock.
- **Прокси и LAN действительно разделяют один серверный `network.lock`**, sing-box и механизм pending/rollback: [proxy_out.py:357](/home/remoteagents/Disk/AiServerAutoSettings/server/proxy_out.py:357), [lan_vpn.py:1045](/home/remoteagents/Disk/AiServerAutoSettings/server/lan_vpn.py:1045). Их нельзя просто запускать одновременно.
- Параллельные установки делят пропускную способность. Их загрузки следует запускать после появления связи либо с меньшим приоритетом.

Отдельная проблема обходного SSH: **сохранённый маршрут применяется непоследовательно**.

`Invoke-WizardSsh` подхватывает его, но `Get-ControlSshArguments`, reverse SSH моста и rootkey/password команды административных действий строят подключения без этого overlay: [Start-WindowsControl.ps1:33](/home/remoteagents/Disk/AiServerAutoSettings/Start-WindowsControl.ps1:33), [Start-CodexWindowsBridge.ps1:140](/home/remoteagents/Disk/AiServerAutoSettings/Start-CodexWindowsBridge.ps1:140), [Wizard.Network.ps1:17](/home/remoteagents/Disk/AiServerAutoSettings/build/Wizard.Network.ps1:17). При блокировке прямого SSH это может давать таймауты и бесконечное восстановление моста вместо успешного завершения.

**4. Топ-5 изменений по выигрышу времени**

Оценки выигрыша пересекаются: складывать все числа нельзя.

| Приоритет | Что сделать и где | Ожидаемый выигрыш | Риски |
|---|---|---|---|
| **1** | **Убрать зависимость связи от Syncthing.** Поддержать SSH-only канал и необязательный sync inbound в `Initialize-WizardTransport`, `channel()`, `New-TransportConfig`. После первого proof показывать «Связь работает», остальные компоненты — отдельными статусами | Убирает с критического пути всю оставшуюся установку диска: **десятки секунд — несколько минут** | Нужно безопасно добавить sync inbound позже, сохранить соответствие серверу и корректный reload |
| **2** | **Сделать прямой путь импорта готового конфига с локальным sing-box.** Включить проверенный binary в поставку/кэш. Запускать предоставленный путь сразу; загрузку каталога и отсутствующих entry-конфигов перенести в фон. Места: `SetupWizard`, `Wizard.Server.ps1:256`, startup демона `:115` | **5–90+ с** загрузки binary, плюс **до 15 с на каждый отсутствующий entry**, плюс управляющие SSH | Размер EXE, обновление binary, проверка схемы и секретов; ошибка необязательного entry не должна ломать готовый основной путь |
| **3** | **Один управляющий сеанс на bootstrap, helpers по версии/хешу, один ответ inventory+catalog+channel.** Сохранить PowerShell worker на время окна; применять единый маршрут к мосту и admin SSH. Места: `Run`, `Invoke-WizardSsh`, `Send-WizardHelpers`, `Get-WizardCatalog`, Control/Admin adapters | Удаление 6–10 handshake: примерно **6–30 с напрямую, 18–200 с через обход**, плюс повторные передачи helpers. Исправление маршрута устраняет часть неуспешных сценариев | Переподключение, протокол worker, изоляция секретов. Для confirm после изменения сети всё равно нужен **новый** SSH |
| **4** | **Перейти от общего busy/замка к зависимостям компонентов.** После SSH одновременно готовить мост, Happier, диск и inventory; блокировать только конфликтующие изменения. Короткий config-lock оставить. Места: `Guard`, `order`, `Invoke-WizardLock`, действия `Invoke-WizardStep` | Полное завершение приближается к длительности самой долгой ветви вместо суммы. Для нескольких ветвей по 20–60 с — ориентировочно **40–120 с** выигрыша | Гонки rollback/config, одинаковые helpers, preflight-порты, folders.lock. Proxy/LAN оставить последовательными |
| **5** | **На чистой установке проверять сразу рабочий транспорт.** Не создавать и уничтожать preflight-копию; сохранить один daemon и его proof. Для редактирования уже рабочего подключения оставить изолированный preflight. Статусы получать событиями, не фиксированными паузами | Обычно **5–20 с**, на медленном пути **15–60+ с**; ещё 0–12 с на обнаружении завершения установки | Нельзя объявлять готовность по PID/порту: нужен свежий proof, правильный revision и закреплённый host key |

Для цели **«готовый конфиг → связь <60 с»** предлагаемый бюджет:

| Работа на критическом пути | Целевой бюджет |
|---|---:|
| Разбор конфига, локальная проверка | 1–3 с |
| Запуск одного рабочего транспорта | 1–5 с |
| Подключение предоставленным маршрутом и параллельные запасные пробы | 3–30 с |
| Аутентифицированный proof и публикация статуса | 1–10 с |
| **Всего** | **6–48 с** |

Это достижимая инженерная цель при готовом рабочем конфиге, доступном маршруте и локальном binary. Создание пользователя на пустом сервере, скачивание компонентов и ввод UAC следует учитывать отдельно.

Долгие серверные установки стоит развивать на уже существующей модели `running/finished/failed`, stage и elapsed. Для пользователя нужны независимые состояния: **«Связь работает», «Мост подключается», «Happier устанавливается», «Диск ожидает выбора»**. Сейчас значительная часть механизма уже есть; главная работа — убрать его зависимости от критического пути и общего последовательного мастера.