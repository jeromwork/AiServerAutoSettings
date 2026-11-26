# Проверка обновления и отката v3 (без боевого выпуска)

Идея: тестовые сборки подписаны ТЕСТОВЫМ ключом, а `--release-base` ведёт на локальный «GitHub» (`dev update serve`).
Боевой ключ, GitHub и боевой home не затрагиваются. Всё ниже работает и на Linux (проверено), и на Windows (`--target windows/amd64`).

## 1. Ключ и сборки
```
T=$(mktemp -d)
ssh-keygen -q -t ed25519 -N '' -f $T/key
echo "ra3 $(cut -d' ' -f1,2 $T/key.pub)" > $T/signers          # один тестовый ключ
export SIGNERS_FILE=$T/signers
cd go
VERSION=3.0.101 ./build.sh --target windows/amd64 && cp dist/remoteagents-windows-amd64.exe $T/v101.exe
VERSION=3.0.102 ./build.sh --target windows/amd64 && cp dist/remoteagents-windows-amd64.exe $T/v102.exe
# кандидаты с поломкой (поле testFault, только для тестовых сборок):
VERSION=3.0.103 EXTRA_LDFLAGS="-X main.testFault=crash"         ./build.sh --target windows/amd64   # ядро падает сразу
VERSION=3.0.104 EXTRA_LDFLAGS="-X main.testFault=hang"          ./build.sh --target windows/amd64   # жив, но good не шлёт (откат через 120 с)
VERSION=3.0.105 EXTRA_LDFLAGS="-X main.testFault=reject-config" ./build.sh --target windows/amd64   # `config check --current` отказывает
```
Версия обязана быть `3.0.<число>`; обновление идёт на большее число. Для другой ОС: `--target linux/amd64`, имя файла `remoteagents-linux-amd64`.

## 2. «Релиз-сервер»
```
mkdir $T/serve; cp <нужная сборка> $T/serve/remoteagents-windows-amd64.exe; echo 3.0.102 > $T/serve/version.txt
REPO=<owner/repo из git remote origin, например jeromwork/AiServerAutoSettings>
v101 dev update serve --dir $T/serve --key $T/key --repo $REPO --listen 127.0.0.1:18791 --os windows --arch amd64
```
Файлы читаются на каждый запрос: чтобы «выпустить» другую версию, подмените файл и `version.txt` в `$T/serve`.
На ПК: серверный порт пробросить на ПК (`devports open`) либо запускать `serve` на самом ПК.

## 3. Запуск тестируемой программы (боевой home не трогать)
```
v101.exe supervise --home <ТЕСТОВЫЙ_HOME> --safe --no-channel --no-singbox --release-base http://127.0.0.1:18791
```
Адрес страницы: `<HOME>\\state\\webui.url`. Без `--no-channel` нужен конфиг и сервер, как в бою.

## 4. Сценарии (всё видно на странице в блоке «Обновить»: проверяю → скачиваю → проверяю кандидата → запускаю → готово / откат)
| Что | Как | Ожидание |
|---|---|---|
| Обновление | `serve` отдаёт v102, кнопка «Обновить» | `Версия 3.0.102 работает`; `versions\\state.json`: current=3.0.102, prevGood=3.0.101 |
| Нет обновлений | то же при актуальной версии | `Обновлений нет` |
| Ручной откат | кнопка «Вернуть прежнюю версию» или `remoteagents rollback --home H` | current=3.0.101, bad=3.0.102; без запущенного ядра CLI правит состояние сам |
| Кандидат падает | отдать 3.0.103 (crash) | событие `Откат`, current остаётся прежней, причина `crashed, exit code 1` |
| Нет good | 3.0.104 (hang) | откат через 120 с (`silenceTimeout`; со сторожем `--fast` — 3 с) |
| Кандидат отвергает конфиг | 3.0.105 | ошибка `candidate rejected current config` на стадии проверки, слот не создаётся |
| Неверная подпись / хеш | подменить файл в `serve` после выпуска `checksums` либо другой ключ | `signature: invalid` / `checksum mismatch`, слота нет |
| Откат с конфигом | после обновления применить конфиг, потом откат | конфиг возвращается на поколение, которое читает старая версия; `config apply` и вставка конфига работают |

## 5. Автотесты (затронутые пакеты)
`go test ./internal/update ./internal/supervise ./internal/config ./cmd/remoteagents` — Stage/подпись/хеш/отказ конфига, откат версии
при падении / тишине / запросе отката / непринятом конфиге, сетевая ошибка не откатывает версию, схема конфига и совместимый откат поколения.

## 6. Совместимость (кратко)
* `config/gen-N/meta.json` `{schema}`; `config.SchemaVersion` — формат, который читает сборка. Версия, меняющая формат gen-N,
  увеличивает число. Старая сборка не читает более новое поколение (`config: newer-schema`, страница показывает причину
  и подсказку `remoteagents config revert`).
* `remoteagents version --json` содержит `schema`; при откате версии сторож спрашивает схему версии-цели и, если current
  записан более новой схемой, переносит current на lastgood/последнее good-поколение с подходящей схемой и снимает switch.json.
* `versions/state.json` имеет `schema`; поля только добавляются. `bad` — версия, с которой откатились: автообновление её
  повторно не ставит, ручное «Обновить» ставит (слот остаётся на диске, тот же файл переиспользуется).
* Хранятся Current + LastGood + PrevGood (до `MaxSlots` = 5 каталогов): минимум две предыдущие версии.
