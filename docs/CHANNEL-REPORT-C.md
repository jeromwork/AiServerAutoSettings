# CHANNEL — отчёт потока C (сквозной тест «канал первым» на стенде)

12.11.2026. Ветка `app/channel-c`. Задача: `docs/TASK-CHANNEL.md`, раздел «Поток C».

## Что сделано
Новый сценарий рядом с существующим, на loopback, без root. Существующий сценарий не изменился по поведению.

- `python3 app/launcher/tests/test_config_e2e.py`: как раньше, сценарий `config`.
- `--scenario channel` (или `RA_E2E_SCENARIO=channel`): полный сценарий «канал первым». Пройдёт только после слияния A и B.
- `--scenario channel-parts`: его части по отдельности. От A/B не зависит и проходит уже сейчас.

### Стенд «канал первым» (`ChannelStand`)
- **sshd** слушает `127.0.0.1:P`. Ключ хоста задаётся в настройках выдачи (`hostKeys`).
- **«Глушилка»** на `127.0.0.2:P` (Python). На каждое подключение она открывает соединение с `127.0.0.1:P`, передаёт клиенту настоящий баннер sshd и замолкает навсегда: данные клиента читает и выбрасывает. В конфиге `server.address=127.0.0.2`, `port=P`.
- **sing-box VLESS-Reality** слушает только `127.0.0.1:V`:
  - ключи `sing-box generate reality-keypair`, uuid4, `short_id` (4 байта hex);
  - сайт-приманка для handshake: TLS-вход sing-box `127.0.0.1:H` с сертификатом от `sing-box generate tls-keypair stand.test`, его трафик отклоняется.
  - В `transport/test-*.py` настоящего Reality-сервера нет, там поддельный sing-box. Поэтому параметры генерируются самим sing-box, а формат клиента повторяет `disk/test-disk.py` и `Get-TransportCandidates`.
- **Секрет `vpn-channel`**: `{outbounds:[{type:'vless', server:'127.0.0.2', server_port:V, uuid, flow:'xtls-rprx-vision', tls:{server_name, utls chrome, reality{public_key, short_id}}}]}`. Прямой адрес канала `127.0.0.2:V` закрыт, поэтому `vless-direct` не работает. Работает только relay.
- **Тупой TCP-ретранслятор** (Python, как sparfum): `127.0.0.1:R → 127.0.0.1:V`. Считает подключения и байты.
- **Каталог** `relays:[{name:'relay',host:'127.0.0.1',port:R}]` передаётся через `catalogFile` настроек выдачи.
- **Настройки выдачи** `vpnBootstrap = {channelFile, vpn:{checkUrl:'https://stand.test/generate_204', dnsServer:'127.0.0.1'}}`.
- **Подставной `RemoteAgents.exe`** в `<LOCALAPPDATA>/RemoteAgents/`: sh-обёртка над тестовой сборкой (`--proxy-connect`, тот же `ProxyRelay.cs`, что в EXE). Маршрут `proxy` строит `ProxyCommand` именно через неё.

### Ход сценария `channel`
1. **Выдача конфига** командой `remoteagents config export --vpn channel --master-password-stdin`. Проверяются:
   - `vpn.enabled=false`, есть `checkUrl` и `dnsServer`;
   - `bootstrap.channel={secret:'vpn-channel'}`;
   - `catalog.relays` — ровно relay стенда, `entries={}`, `hops={}`;
   - `vpn-channel` выдан как `enc1:`.
2. **Ручки стенда** в `config.json`:
   - те же, что в старом сценарии;
   - плюс `transport.channelSocksPort` — свободный порт, а не 2223, чтобы не задевать живые службы.
3. **Вставка** (`--apply`): Parse, Unlock, Store, Materialize.
4. **«Запустить»** (`--run`, ConfigEngine). Ожидается:
   - **план:** начинается с `['bootstrap','server','connection']`;
   - **итог Bootstrap:** `ok=true`, `vpn='channel'`, `channel='vless-relay-relay'`, summary начинается с `Канал до сервера поднят: vless-relay-relay`;
   - **журнал:** есть строки трассировки `[Bootstrap] · `;
   - **разделы:** Server и Connection `ok`, все разделы `ok`;
   - **маршрут:** `config.wizard.serverRoute = {used:'proxy', proxy:{type:'socks', host:'127.0.0.1', port:channelSocksPort}}`;
   - **признаки:** `transport.channelFirst=true`, `channelSocksPort` сохранён после «Связи»;
   - **профиль:** в `routeProxyCommand` есть `--proxy-connect socks 127.0.0.1 <channelSocksPort>`;
   - **демон:** `status/transport.json.active='vless-relay-relay'`, через relay прошли подключения;
   - **TUN и UAC не вызывались:** нет `state/vpn-session.json`, `state/vpn-sing-box.json`, `state/bootstrap-internet-check.json`, `state/vpn-owner.json`; `vpn.enabled` не true; нет `vpn.bootstrapTag`.
5. **Живой SSH-вход** выданным ключом с аргументами сохранённого профиля, то есть через канал.
6. **Цифры:**
   - `startToServerOkMs` — «Запустить → Сервер ✅», считается от старта движка с учётом Bootstrap;
   - `bootstrapMs`, `serverMs`, время каждого раздела;
   - счётчики relay и глушилки;
   - `loginMs`, `totalSeconds`.

### Изменения в `ConfigE2E.cs`
- **Раздел `Bootstrap`** стал настоящим действием `Invoke("Bootstrap", {})`, с тем же пустым запросом, что в `RunSection` окна. Раньше он попадал в заглушку `default`. В старом сценарии Bootstrap нет в плане, это проверяется.
- **`askpassExecutable`** запроса Server = `<home>/RemoteAgents.exe`, только если такой файл есть. Его создаёт только сценарий channel, как `Program.Exe` в окне.
- **`--proxy-connect`** передаётся в `ProxyRelay.Run`.
- **В итоговом JSON** новые поля `startToServerOkMs` и `bootstrap {ok, vpn, channel, summary}`. Старый сценарий их не читает.

### Изменения в `test_config_e2e.py` для старого сценария
Только вынесены помощники `write_sshd_conf` и `wait_port`, содержимое не менялось. Добавлен разбор `--scenario`, по умолчанию `config`.

## Проверки с цифрами
| Проверка | Результат |
|---|---|
| `--scenario config` (старый, регрессия) | PASS, 81,1 с; server 5,9 с, server→connection ok 21,1 с |
| `--scenario channel-parts` | PASS, 19–23 с (два прогона) |
| — стенд: sshd поднят (sshd + глушилка + Reality + relay) | 0,7–0,9 с |
| — вход ключом прямо на `127.0.0.1:P` | 0,28–0,39 с |
| — глушилка `127.0.0.2:P` | баннер `SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.20`, затем тишина; `ssh -v` дошёл до `Remote protocol version`, повис и снят через 8,0 с |
| — `vless-direct` (`127.0.0.2:V`) | соединение отклонено |
| — ssh через временный sing-box-клиент (mixed `channel-socks` + `route-options override_address/override_port` + VLESS через relay) и `--proxy-connect` | 3 входа: 521 / 463 / 446 мс (первый прогон: 573 / 609 / 881 мс) |
| — curl `--socks5-hostname` через тот же вход к `127.0.0.2:P` | пришёл баннер настоящего sshd, а не глушилки (время ограничено `--max-time 3`) |
| — relay | 4 подключения, ~36 КБ |
| `--scenario channel` до слияния A/B | падает, как и ожидалось (60 с); подробности ниже |

Проверка `route-options` выполнялась на sing-box 1.14.4. Правило `{inbound:['channel-socks'], action:'route-options', override_address:'127.0.0.1', override_port:<порт sshd>}`, за ним `{inbound:['channel-socks'], outbound:…}`:
- проходит `sing-box check`;
- на деле переадресует назначение `127.0.0.2:P` на `127.0.0.1:P` на стороне сервера канала: вход прошёл, хотя по адресу 127.0.0.2 стоит глушилка.

Значит, контрактный вариант для потока A в sing-box 1.14 доступен.

### Что показал `--scenario channel` до слияния
- **Выдача:** у экспортёра ещё нет `--vpn channel`. Сработал запасной путь `--vpn on` + `vpn.enabled=false` (те же секреты, контрактная форма раздела). В выводе он помечен `issuedBy: "FALLBACK: …"`. После слияния B запасной путь не используется: выдача идёт честно через экспортёр.
- **Bootstrap:** нынешний движок вернул `vpn='conflict'` («Работает другой VPN»). На этой машине есть `tun0`. Это ровно то, что поток A убирает: проверка чужого VPN в режиме канала не нужна.
- **Server:** маршрут «напрямую» на `127.0.0.2:P` повис после `SSH2_MSG_KEXINIT sent` и через 45 с упал с «Таймаут команды». Диагностика: `TCP 127.0.0.2:P: соединение 10 мс, баннер «SSH-2.0-OpenSSH_9.6p1…»`. Стенд воспроизводит журнал с «Компа».
- Relay не использовался (0 подключений), глушилка приняла 2 подключения.

## Отступления и решения
- **`channelSocksPort`** на стенде — свободный порт, а не 2223: живой сервер и чужие стенды не задеваются. Сценарий проверяет, что «Связь» сохраняет это значение.
- **Запасная выдача** до слияния B — по разрешению задания. Она помечена в выводе и не скрывает отсутствие B.
- **Глушилка** пропускает только баннер, как сказано в задании. У «Компа» проходит и обмен ключами, но итог для клиента одинаковый: зависание после рукопожатия.
- **Порты демона** `probePortBase` и `socksPortBase` оставлены по умолчанию, как в старом сценарии. Параллельные прогоны других стендов могут столкнуться на 26000+/28000+.
- **Уборка:** после прогона процессы, в командной строке или окружении которых есть каталог стенда, снимаются по PID через `/proc`. Без `pkill -f`.

## Что не проверено
- Полный `--scenario channel` в зелёном состоянии: нужны движок A и выдача B (`--vpn channel`).
- Уложится ли полный сценарий в `timeout 120`: Bootstrap до 45 с, Server, Connection ~15 с плюс сборка. Цифру `startToServerOkMs` нужно снять после слияния.
- Повтор SSH при перезапуске демона в «Связи» (A, п. 5) на стенде отдельно не провоцируется.
- Windows, UAC и настоящий Happ: на Linux «не вызывались» проверяется только по отсутствию файлов TUN-пути и флагов в `config.json`.

## Файлы
- `app/launcher/tests/test_config_e2e.py`
- `app/launcher/tests/ConfigE2E.cs`
- `docs/CHANNEL-REPORT-C.md`

## Как запускать
```
cd ~/work/wt-channel-c
timeout 120 python3 app/launcher/tests/test_config_e2e.py --scenario channel-parts
timeout 120 python3 app/launcher/tests/test_config_e2e.py --scenario channel   # после слияния A+B
timeout 120 python3 app/launcher/tests/test_config_e2e.py                      # старый сценарий
```
