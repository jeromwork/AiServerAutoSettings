# Соглашение для параллельной работы над задачей CONFIG

Общее задание — `docs/TASK-CONFIG.md`. Работа поделена на 4 потока, каждый в своём worktree и своей ветке от `app/config`.
Поток трогает ТОЛЬКО свои файлы. Нужно чужое — опиши в своём отчёте, что требуется, и сделай заглушку у себя.
Слияние делает координатор. Правила: `docs/CONSTITUTION.md`.

| Поток | Ветка / worktree | Исполнитель | Свои файлы |
|---|---|---|---|
| A. Формат и секреты | `app/config-a` / `~/work/wt-config-a` | Codex | новые `app/launcher/ConfigBundle.cs`, `SecretVault.cs`, `SecretCommand.cs`, `SecretPrompt.cs`; `app/launcher/config.paste.schema.json`, `config.paste.example.json`; `docs/CONFIG.md`; тесты `app/launcher/tests/ConfigBundleTests.cs` (+ строки в `PortableTests.csproj`) |
| B. Сервер | `app/config-b` / `~/work/wt-config-b` | Opus | `server/**` (кроме `server/lan*`, `server/proxy*` — не трогать), `server_node_catalog.py`, `codex-windows-bridge.py` (только имя компьютера), `server/tests/**` |
| C. Движок и скорость | `app/config-c` / `~/work/wt-config-c` | Codex | `build/*.ps1`, `transport/**`, `disk/**`, их тесты, `app/launcher/tests/*.ps1`, `app/launcher/tests/run.sh` |
| D. Окно и оркестратор | `app/config-d` / `~/work/wt-config-d` | Opus | остальные `app/launcher/*.cs` (Program, TrayContext, SetupWizard*, FirstInstall, новые `ConfigWindow.cs`, `ConfigApply.cs`), удаление `Invitation*.cs`, `InviteHop`, их C#-тестов |

## 1. Формат конфига (человек вставляет / сохраняет)

Обычный читаемый JSON. Секреты — в разделе `secrets`; значение либо открытый текст, либо `enc1:…`, либо пусто (спросить).

```json
{
  "kind": "remoteagents-config", "schema": 1,
  "device": { "name": "Ноутбук сына" },
  "server": {
    "address": "203.0.113.10", "port": 22, "login": "remoteagents",
    "hostKeys": ["ssh-ed25519 AAAA…"],
    "key": { "secret": "server-key" },
    "rootPassword": { "secret": "server-root-password", "hint": "из письма хостинга" },
    "routes": [ { "kind": "direct" }, { "kind": "proxy", "proxy": {"type": "socks", "server": "127.0.0.1", "port": 10808} },
                { "kind": "hop", "hop": {"host": "…", "port": 22, "user": "…", "hostKey": "…", "key": {"secret": "hop-key"}, "password": {"secret": "hop-password"}} } ]
  },
  "vpn":     { "enabled": false, "checkUrl": "…", "dnsServer": "…", "bootstrap": { "channel": {"secret": "vpn-channel"}, "entries": {"имя": {"secret": "vpn-entry-имя"}} } },
  "happier": { "mode": "same | new", "label": "Мой аккаунт", "serverUrl": "…", "webappUrl": "…", "key": {"secret": "happier-key"} },
  "bridge":  { "enabled": true, "allowShell": false },
  "disk":    { "base": "C:\\Users\\user\\Disk", "folders": ["Проекты/Сайт", "Документы"] },
  "proxyOut":{ "type": "socks", "server": "…", "port": 1080, "login": "…", "password": {"secret": "proxy-out-password"} },
  "lan":     [ { "name": "Офис", "kind": "openvpn", "ovpn": {"secret": "lan-Офис-ovpn"}, "password": {"secret": "lan-Офис-password"} } ],
  "secrets": {
    "protected": "master-password",
    "kdf": { "name": "pbkdf2-sha256", "iterations": 200000, "salt": "base64" },
    "check": "enc1:…",
    "server-key": "enc1:…",
    "hop-password": ""
  }
}
```

- Отсутствующий раздел = «не трогать». Неизвестные поля — отказ с понятной причиной (кроме `hint`).
- Ссылка на секрет: `{"secret": "<имя>", "hint": "<необязательная подсказка>"}`. Имя: `^[a-z0-9][a-z0-9._-]{0,63}$` (кириллица в именах `lan-…`/`vpn-entry-…` — допустить буквы Unicode).
- `secrets.protected` есть → все непустые значения `enc1:`; программа один раз спрашивает мастер-пароль. Нет → значения открытым текстом.
- `enc1:` = base64( iv[16] ‖ AES-256-CBC(PKCS7) ‖ HMAC-SHA256[32] над iv‖ciphertext ), ключи 64 байта = PBKDF2-SHA256(мастер, salt, iterations): первые 32 — AES, вторые 32 — HMAC.
  `check` — зашифрованная строка `remoteagents` для проверки пароля. Неверный пароль / подмена → отказ, ничего не применяется.
- Экспорт «для ИИ» — тот же JSON, где у каждого секрета значение `"<есть, скрыт>"` или `""`.

## 2. Хранение на компьютере

- `config.json` (существующий) получает раздел `profile` = желаемое состояние без `secrets` (то, что вставили/правят).
- Секреты — хранилище `secrets/vault.json`: имя → значение, зашифровано DPAPI CurrentUser (на Linux-тестах — открыто, с пометкой).
- `SecretVault.Materialize(home)` раскладывает секреты в существующие файлы, которые ждут действия PowerShell
  (ключ SSH → путь из `profile`, `secrets/channel.json`, `secrets/entries/*`, `secrets/proxy-out.json`, hop-ключи и т. п.).
  Таблица соответствия — в `docs/CONFIG.md`.

## 3. C#-интерфейс потока A (поток D пользуется им; до слияния — заглушки с теми же сигнатурами)

```csharp
internal sealed class ParsedConfig { public Dictionary<string,object> Profile; public Dictionary<string,string> Secrets; public bool Locked;
                                     public string[] Missing; public Dictionary<string,string> Hints; }
internal static class ConfigBundle {
  ParsedConfig Parse(string text);                      // InvalidDataException с причиной по-русски; CRLF допустим
  ParsedConfig Unlock(ParsedConfig p, string master);   // InvalidDataException «Неверный мастер-пароль»
  string[] Conflicts(string home, ParsedConfig p);      // «сейчас X / в конфиге Y» для сервера, аккаунта Happier, корня диска, убранных папок
  void Store(string home, ParsedConfig p, IEnumerable<string> acceptSections); // profile в config.json + секреты в vault
  string Export(string home, string master);            // полный, master==null → открытый текст
  string ExportForAi(string home);
}
internal static class SecretVault { void Set(string home,string name,string value); bool Has(string home,string name);
                                    string[] Names(string home); void Materialize(string home); }
internal static class SecretPrompt { string Ask(IWin32Window owner, string name, string why); } // скрытый ввод, null = отмена
internal static class SecretCommand { int Run(string home, string[] args); } // secret set|status|import, вывод без значений
```

## 4. Движок (C ↔ D)

- D запускает существующие действия `build/Wizard.ps1 -Action <X> -RequestFile …` как сейчас (`SetupWizard.Run`), но **параллельно**:
  сначала `Bootstrap` (VPN первым, если в profile есть `vpn.bootstrap`), затем `Server`; после успеха одновременно
  `Connection`, `Bridge`, `Account`, `Disk`, `Vpn`; `Proxy` и `Lan` — последовательно между собой, после `Server`.
- C обеспечивает, что эти действия можно запускать одновременно (узкие замки вместо общего `Invoke-WizardLock`), пишут прогресс
  в `ProgressFile` и время этапа строкой `timing <этап> <мс>`. Формы запросов прежние; новые поля — в `docs/CONFIG-ENGINE.md` (пишет C):
  `Bootstrap {}` (берёт данные из profile/materialized secrets), `Bridge {…, deviceName}`, `Server {…}` без изменений.
- «Связь работает» = успешный `Connection` с живой проверкой; не ждёт Syncthing/диск.
- Автообновление адресов/ключей/VPN своим ключом раз в 5 минут (бывший invite sync) — C (клиент) + B (сервер), формат ответа сервера
  описывает B в `docs/CONFIG-SERVER.md`.

## 5. Сервер (B)

- `remoteagents config export --name "<название>" [--master-password-stdin]` → полный конфиг: новая пара ed25519 на выдачу,
  открытая часть рабочему пользователю в authorized_keys с меткой `ra-config:<id> <название>`, закрытая — `secrets.server-key`;
  адрес/порт/ключи хоста/маршруты/VPN bootstrap — из существующих настроек сервера (те же источники, что invite).
- `config list` (id, название, создан, последний вход если известен), `config revoke <id>`; список компьютеров с названиями.
- Имя компьютера: `deviceName` из запроса моста попадает в реестр (`server_node_catalog.py`) и в `windows_devices`.
- Убрать: `ra-enroll`, одноразовый пропуск, `invite create/list/revoke/refresh`, sudo-скрипт регистрации, `install-invite.sh`,
  `invite_overlay.py`, `invite-config.*` — после переноса полезного (sync адресов, devices).

## Общее

- Commit в свою ветку можно, push/merge — нет. Живой сервер, `~/.ssh`, службы, мост и Windows-компьютеры не трогать.
- Тесты: `timeout 60` (максимум 120) на файл. PowerShell на Linux: `~/.cache/pwsh-test/pwsh -NoProfile -NonInteractive … < /dev/null`,
  `LOCALAPPDATA=/tmp/<своё>`. .NET: `~/.dotnet/dotnet`. Код — для Windows PowerShell 5.1 и .NET 4.8. Тесты подают CRLF.
- Прогресс: одной строкой «k/n: что делаю» в `/tmp/agent-config-<a|b|c|d>-status.txt` после каждого шага.
- В конце: отчёт `docs/CONFIG-REPORT-<A|B|C|D>.md` — что сделано, файлы, проверки с цифрами, что нужно от других потоков, что не проверено.
