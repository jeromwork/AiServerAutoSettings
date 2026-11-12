# «Тот же аккаунт Happier» при установке Happier вручную

Ветка `app/config`. Проблема: Happier, установленный на сервер обычным способом (`~/.happier`, своя служба
`happier-daemon.*`), программа не видела. `{"action":"list"}` возвращал `accounts:[]`, шаг «Аккаунт» конфига
с `happier.mode: "same"` падал, а `remoteagents config export` выдавал такой конфиг без проверки.

## Что сделано

1. **`accounts/server-account.mjs`**
   - `nativeAccount(home)`: обычная установка считается аккаунтом, если есть вход. Читаются файлы
     `~/.happier/settings.json` (`activeServerId`, `servers.<id>.serverUrl/webappUrl`) и
     `servers/<id>/access.key` (или старый `~/.happier/access.key`), из них берётся `token`.
   - Id публичный и устойчивый, формат как у программных: `sha256("happier-home\n" + origin API + "\n" + sub)`,
     где `sub` — id аккаунта из токена. Id не меняется при обновлении токена, а при входе в другой аккаунт он
     другой. Токена, ключей и `sub` в ответе нет. С программными id не пересекается.
   - `listAccounts` ставит такой аккаунт первым, подпись «Happier сервера».
   - `inspectAccount(id, home, request)`: для обычной установки берётся `pid` и `machineId` из
     `servers/<id>/daemon.state.json`. Процесс должен быть жив, и в его `cmdline` должно быть `daemon`. Затем
     `GET /v1/machines` с токеном этого аккаунта: машина должна быть `active:true`. Только чтение. Программный
     путь не изменился, общая проверка API вынесена в `machineActive`.
   - Почему свой разбор, а не `readCredentials` из vendor-пакета (§2). При импорте vendor-пакета с
     `HAPPIER_HOME_DIR=~/.happier` его логгер чистит `~/.happier/logs` и создаёт там файл, а `Configuration`
     меняет права (`chmod`) на файлы и каталоги. Это изменило бы живой Happier. Разбираются только поля
     vendor-формата, причина записана в комментарии.
2. **Сверка проверок id.** Формат остался `^[a-f0-9]{64}$`, поэтому `Connect-WizardProfileAccount`
   (`build/Wizard.Bootstrap.ps1`), `Inspect` (`build/Wizard.Common.ps1`), `Account.ps1` и регулярное выражение в
   mjs менять не пришлось. `Connect-WizardProfileAccount` уже выбирал аккаунт по `Request.account`, но C#
   это поле не передавал, а схема конфига его отвергала («Неизвестное поле»). Исправлено:
   - `app/launcher/ConfigBundle.cs`: в схему добавлено `happier.account` (ровно 64 hex), и оно учитывается в
     конфликте «другой аккаунт»;
   - `app/launcher/ConfigApply.cs` (`ConfigRequests.Account`): для `same` передаёт `account` в шаг движка;
   - `app/launcher/config.paste.schema.json`, `docs/CONFIG.md`: то же поле.
3. **`server/remoteagents_config.py export`**
   - `happier_accounts(c)`: список берётся тем же `accounts/server-account.mjs` (`listAccounts`), код подаётся
     в `node` через stdin. Под root помощник запускается правами рабочего пользователя. Если проверить не
     удалось, конфиг не выдаётся, вывод помощника не печатается.
   - `happier_same(c, wanted)` проверяет до мастер-пароля и до создания ключа:
     - нет ни одного аккаунта → отказ: «войдите в Happier на сервере или выдайте с `--happier new:…`»;
     - аккаунт один → как раньше, `{"mode":"same"}` без id;
     - аккаунтов несколько → id пишется в `happier.account`, только если выбор однозначен:
       `--happier same:<подпись или id>` (новый вариант существующего флага, нового флага нет) или подпись
       `happier.account` из настроек выдачи. Иначе отказ со списком «подпись id» и подсказкой.
   - Новое необязательное поле настроек `happier.home`: где искать аккаунты (по умолчанию HOME `workerUser`).
     Нужно стенду, чтобы тесты не читали настоящий HOME. Описано в `server/config-export.schema.json` и
     `docs/CONFIG-SERVER.md`.

## Файлы

`accounts/server-account.mjs`, `accounts/test-accounts.mjs`, `server/remoteagents_config.py`,
`server/config-export.schema.json`, `server/tests/test_config_export.py`, `app/launcher/ConfigBundle.cs`,
`app/launcher/ConfigApply.cs`, `app/launcher/config.paste.schema.json`, `app/launcher/tests/ConfigBundleTests.cs`,
`app/launcher/tests/ConfigApplyTests.cs`, `app/launcher/tests/test_config_e2e.py`, `docs/CONFIG.md`,
`docs/CONFIG-SERVER.md`, этот отчёт. Файлы `build/Wizard.Server.ps1`, `build/Wizard.Engine.ps1` и `transport/*`
не тронуты, EXE не собирался.

## Проверки (каждый набор запущен один раз)

| Набор | Итог |
|---|---|
| `node accounts/test-accounts.mjs` | OK, 40 проверок (было 26). Новые: только обычная установка (id 64 hex, без секретов, устойчив к обновлению токена, другой `sub` даёт другой id, без `access.key` аккаунта нет, старый `access.key`), обычная установка вместе с двумя программными (3 разных id), `inspect` (живой daemon + `active:true` → ok; `active:false`, ответ 401, чужой pid, остановленный daemon → не ok; файлы `~/.happier` не меняются) |
| `bash server/tests/run.sh` | 75 тестов, все прошли (было 72). Новые: только обычная установка → `{"mode":"same"}`; нет аккаунтов → отказ, ключ не создан, `new:` выдаётся; обычная + программная → отказ без выбора, `same:Подпись`, `same:<id>`, подпись из настроек → `happier.account`, неизвестная и неоднозначная подпись → отказ |
| `dotnet run … -p:ConfigTests=true` | PASS: CONFIG, 130 проверок (новые: `happier.account` принимается; `A…`, 63 знака, перевод строки, подпись отвергаются) |
| `dotnet run … -- <dir>` (TestEntry) | OK, 95 проверок движка конфига (новые: без id запрос без `account`, с id `account` доходит до шага); self-test обновлений 93/93 |
| `test-config-account.ps1` (pwsh 7, без изменений PS) | OK, 9 проверок |
| `test_wizard_boundary.py` | OK, 5 тестов |
| `test_config_e2e.py` (config) и `--scenario channel` | оба PASS; выдача в стенде видит поддельную обычную установку (`happier.home`) |
| Живой сервер, только чтение | `list` → 1 аккаунт «Happier сервера» (`https://api.happier.dev`), `inspect` → `{"ok":true}`, `happier_same` → однозначно, id не нужен. Неизвестный id → отказ (код 1). В `~/.happier` ничего не записано, служба не трогалась |

## Что не проверено

- Настоящий Windows и PowerShell 5.1 (§6в): код PowerShell не менялся, тест запускался на pwsh 7.
- Полный шаг «Аккаунт» с компьютера на живом сервере. Установленная копия
  `~/.local/share/remoteagents-accounts/server-account.mjs` старая, мастер заменит её при следующей отправке помощников.
- Запуск `export` от root: путь со сменой пользователя (`user=`/`group=` в `subprocess.run`) тестом не покрыт.
- Обычная установка со схемой `settings.json` без `servers.<id>.serverUrl` (старые версии Happier) в список не
  попадает: адрес по умолчанию не подставляется.

## Открытые вопросы

- Если тот же аккаунт Happier подключить ещё и программой (ввести ключ), в списке будет две строки с разными
  id: у обычной установки нет ключа подписи, поэтому id программы для неё не вычислить. Склеивать их по `sub` или нет?
- В старом мастере (`SetupWizard.cs`) строка «Happier сервера» показывается как «другой аккаунт». Ввод ключа
  для неё вернёт `account-key-mismatch`. Помечать такие строки в списке (`kind`) или скрывать их там?
- Когда на сервере один аккаунт, id в конфиг не пишется (так в задаче). Если потом появится второй аккаунт,
  ранее выданный конфиг потребует выбора. Писать id всегда?
