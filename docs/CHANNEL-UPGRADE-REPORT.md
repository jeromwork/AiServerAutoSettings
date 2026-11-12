# Канал первым поверх прежней установки — отчёт

12.11.2026. Ветка `app/channel-upgrade` (от f12980b).

## Что сделано
Добавлен сценарий `--scenario channel-upgrade` в `app/launcher/tests/test_config_e2e.py`. Он идёт тем же путём, что `channel`: тот же стенд, выдача, вставка и «Запустить». Отличие одно: до вставки конфига в `<LOCALAPPDATA>/RemoteAgents/` создаётся прежняя установка, как на Windows владельца. `ConfigE2E.cs` не менялся.

Как устроена прежняя установка (`write_old_installation`):
- **Старый профиль** `ssh-profiles/<id1>/project-connections/control/`. В нём `ssh-transport.json`, `id_ed25519`, `ssh.conf`, `known_hosts` и `known_hosts-hop`.
- **`config.json`**:
  - `wizard.configured=true`;
  - `wizard.serverRoute` и `transport.serverRoute` = `{used:'hop', hop:{name, ssh:'user@127.0.0.1:P', keyFile, hostKey}}`, в том виде, как их сохраняет `Save-WizardRoute`;
  - `transport.profilePath` указывает на старый профиль;
  - `transport.channelPath` = `state/wizard-channel-….json`;
  - `transport.hops=[]`;
  - ручки стенда те же, что в `channel`.

После «Запустить» сценарий ждёт того же, что `channel`: Bootstrap `ok`, канал `vless-relay-relay`, Server `ok` через proxy `127.0.0.1:channelSocksPort`, вход ключом. Сверх этого он проверяет:
- в `logs/transport.log` нет `fatal`;
- `transport.serverRoute` не `hop`;
- `transport.profilePath` указывает не на старый профиль.

Время Bootstrap выводится в итоговом JSON (`bootstrapMs`, `startToServerOkMs`).

Быстрый отказ (`run_engine_watched`, только в `channel-upgrade`). Если Bootstrap закончился, а в `transport.log` есть `fatal`, прогон останавливается сразу. Без этого Server ещё около 45 с ждал бы глушилку, и прогон не уложился бы в `timeout 120`. В сообщении об ошибке выводятся строка журнала, `status/transport.json` и строки `[Bootstrap]`.

## Как сценарий падает на текущем коде (f12980b)
`timeout 120 python3 app/launcher/tests/test_config_e2e.py --scenario channel-upgrade`: rc=1 за 58 с.
```
AssertionError: transport daemon fatal; Bootstrap ended after 50.0 s without a channel
logs/transport.log:
  2026-11-12T08:12:24.5602981Z fatal SSH не выполнен @Transport.Common.ps1:106
status/transport.json: configRevision='' candidates=[] active=None
[Bootstrap] · канал не поднят за 45 с
[Bootstrap] timing Bootstrap 46310
```
Полный `transport.log`: `start` → `fatal SSH не выполнен @Transport.Common.ps1:106` → `process-failed candidate=transport reason=initialization-failed` → `stop`. В `setup.log` есть `bootstrap.channel.unavailable`. Новый профиль `…/pc-…/` создан без `known_hosts-hop`. Всё совпадает с журналом с Windows.

Цепочка подтверждена отдельным вызовом `Read-TransportSettings` + `Get-TransportCandidates` на сохранённом каталоге стенда:
`Invoke-TransportText :106` ← `Get-TransportHostKeys :221` ← `Get-TransportCandidates :301` (ветка `hop.knownHostsPath` оверлея `wizard-server-route`).

Для сравнения: `--scenario channel` на том же коде без прежней установки проходит. До правки теста: PASS, 99,7 с, Bootstrap 50,6 с. После правки теста (регрессия): PASS, 40,1 с, Bootstrap 7,2 с. Разброс времени Bootstrap между прогонами большой.

## Кракозябры в `transport.log`: не менял
Явного правила «журналы в UTF-8 с BOM» нет: ни в `docs/CONSTITUTION.md` (§5а), ни в других документах. Все журналы программы пишутся одинаково, в UTF-8 без BOM:
- `Write-SetupLog` (`build/Setup.Common.ps1:12`);
- `Write-DiskLog` (`install.log`);
- `disk.log`;
- журнал состояний в `Transport.Common.ps1:802`;
- `launcher.log` и `config-window.log` (`Files.Utf8 = UTF8Encoding(false)`).

BOM только в `transport.log` сделал бы журналы разнородными. Поэтому код не менялся, `test-transport-config.ps1` не прогонялся.

Варианты на решение:
1. **Общее правило для всех журналов**: BOM при создании файла и после ротации (`.1`/`.old`), дописывание без BOM. Это 6 мест в PS и `Journal` в C#. Ни Блокнот (Windows 10 1903+ сам распознаёт UTF-8), ни программа от этого ничего не теряют. Минус: у файлов, которые уже есть, BOM появится только после ротации.
2. **Только `transport.log`**, как предлагалось в задаче. Это минимальная правка `Write-TransportLog`: если файла нет, писать с `UTF8Encoding($true)`. Минус: журналы перестают быть одинаковыми.
3. **Не менять файлы**, а в инструкциях поддержки и агентам писать `Get-Content -Encoding UTF8 logs\transport.log`. Кракозябры видны только в Windows PowerShell 5.1 без `-Encoding`. В PS 7 и Блокноте текст читается правильно.

## Что не проверено
- Зелёный `channel-upgrade`: нужен код потока B. Bootstrap не должен наследовать прежний маршрут, а сбой одного кандидата не должен ронять демон. Цифры времени Bootstrap после исправления снять, когда B будет слит.
- Вариант, когда у прежнего hop задан пароль (`routePasswordFile`), не воспроизводился. В стенде есть только hop с ключом.
- Прежний демон, который ещё работает при вставке (`Stop-WizardOldTransport`), в этом сценарии не запускается.
- Windows: проверка идёт только на Linux-стенде.

## Файлы
- `app/launcher/tests/test_config_e2e.py`
- `docs/CHANNEL-UPGRADE-REPORT.md`

## Как запускать
```
timeout 120 python3 app/launcher/tests/test_config_e2e.py --scenario channel-upgrade
timeout 120 python3 app/launcher/tests/test_config_e2e.py --scenario channel
```
