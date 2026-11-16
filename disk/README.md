# RemoteDisk

Действующие требования: [DISK-CONTRACT.md](../docs/DISK-CONTRACT.md).
[DISK-MATRIX.md](../docs/DISK-MATRIX.md) сохраняет исходный аудит; результаты этапа —
[DISK-STAGE1-REPORT.md](../docs/DISK-STAGE1-REPORT.md).

Сервер публикует только настоящие git top-level `~/Disk/<Имя>`. Git без origin разрешён,
но отмечается «без удалённого репозитория»; URL origin не попадает в журнал.
На ПК по умолчанию только прозрачные заглушки. Пользовательские действия выполняются
через локальный REST Syncthing; внешний/вложенный путь не поддерживается.

Новый Upload использует `rd-upload-v1-<32 lowercase hex>`, label равен имени без изменений.
Сервер принимает его только от знакомого устройства, при свободном имени и доступном непустом
корне. Сначала создаёт git с единственным пустым начальным коммитом, затем регистрацию.
Origin не придумывает. Legacy/ручные ID отвергаются; `(2)` и неявного merge нет.
Клиентский генератор этого ID и сообщения об отказах относятся к следующему этапу:
старые клиенты после этого серверного обновления больше не создают проекты через Upload.
Это намеренный запрет, а не совместимость старого протокола.

`bootstrap` обнаруживает и обслуживает проекты; `reconcile` — его старый псевдоним.
`add-device` принимает base64 JSON `{"deviceId":"...","deviceName":"..."}` (аргумент либо
`--stdin`), добавляет устройство и запускает тот же reconcile. `bootstrap` возвращает JSON
`deviceId`/`listen`. `install-auto` обслуживает таймер. `channel-config` готовит конфигурацию
канала из серверного sing-box, не меняя исходный конфиг. Пользовательская кнопка ПК SSH не вызывает.

Обязательные ignores из `stignore.txt` записываются в `.stignore-remoteagents`, include всегда
первый в `.stignore` (после BOM), до пользовательских `!`. Пользовательские строки сохраняются,
повторные managed include удаляются, права сохраняются. Точные прежние шаблоны заменяются
include; неизвестные правила не считаются разрешением передавать обязательные имена.
Правила работают по именам, содержимое на секреты не анализируется. SQL-дампы и файлы `*.sql`
локальны (включая db/schema.sql); исходники миграций другого расширения передаются.
Git exclude — только служебные файлы; внешний gitdir не изменяется.

Для новых и существующих managed папок: sendreceive, watcher=2 с, maxConflicts=-1,
staggered 30 дней (`maxAge=2592000`, cleanInterval=3600). Пользовательская пауза сохраняется.
Программа не коммитит последующие правки. Версии Syncthing не заменяют git.

`~/.local/share/remote-disk/missing-folders.json` — долговечное состояние: опубликованные ID/пути,
наблюдения отсутствия, вечные tombstones `removed`, миграция guard. Его нельзя удалять,
восстанавливать старой копией или чистить «для лечения». Повреждение этого файла блокирует
изменения папок; восстановить его следует из проверенного состояния с сохранением всех tombstones.
Первый запуск знает только текущий config и импорт guard, а не всю прошлую историю.

Физическое отсутствие проекта подтверждается непрерывными 30 с, монотонными часами и поколением
корня; перед DELETE повторно проверяются путь и доступность. Ручное удаление из config или смена
пути ранее опубликованного ID также создаёт tombstone. DELETE снимает только регистрацию,
не файлы ПК/сервера. Возврат каталога не снимает tombstone, старый ID никогда не принимается.
При пустом/недоступном/подменённом корне нет приёма, mkdir Disk/проектов или разрушительных
изменений; наблюдение сбрасывается. Для последнего удалённого проекта после проверки корня
нужно явное снятие регистрации: факт снятия запоминается и при пустом корне.

Журнал происхождения `project-journal.jsonl` содержит projectID, source, hostID (серверный device ID),
device предлагающего ПК, outcome и reason, без содержимого файлов/URL origin/ключей.
Неизменные решения подавляются по `project-journal-last.json`. stderr содержит краткие ошибки
отдельных папок; одна ошибка не мешает остальным. Отсутствие/ошибка git запрещает публикацию.

Таймер запускает bootstrap через 2 с после завершения предыдущего запуска, AccuracySec=1.
Это не SLA доставки за 2 с. Fallback cron — минута; bootstrap использует общий flock состояния.
Bootstrap обновляет/включает таймер сам. Для остановки обслуживания нужно остановить таймер
и убрать собственную cron-строку; одной остановки таймера недостаточно.
Лечение молчащего канала осталось прежним: ≥120 с без входящих байтов по всем соединениям,
свежая перепроверка, pause/resume, cooldown 60 с и повтор незавершённого resume. Оно не заменяет
подтверждение готовности проекта.

## Миграция временного сторожа и выкладка (здесь НЕ выполнялась)

Выполняет проверяющая/выкладочная сессия после интеграции и отдельного разрешения владельца.
Команды ниже — на сервере от владельца установки, из корня проверенного git checkout.
Они не создают тестовых проектов и не обращаются к Windows. Перед началом дождаться окончания
всех установщиков, которые могут заменить helper; запрет downgrade H21 остаётся клиентским этапом.

1. Найти точные systemd-юниты сторожа по ExecStart, остановить и отключить их; убедиться,
   что нет cron-запуска guard. Если сторож запускается иным способом, остановить тот механизм
   до следующего шага. Не удалять `vanish-guard.json`.

```bash
systemctl --user list-unit-files --type=service --no-legend | while read -r unit rest; do
  if systemctl --user show "$unit" -p ExecStart --value | rg -q 'disk-vanish-guard\.py'; then
    printf '%s\n' "$unit"
    systemctl --user disable --now "${unit%.service}.timer" "$unit"
  fi
done
crontab -l 2>/dev/null | rg 'disk-vanish-guard' || true
pgrep -af '[d]isk-vanish-guard.py' || true
```

Оставшийся cron/process — причина остановить выкладку до отключения запуска. Импортёр читает
`vanish-guard.json` (`paused` — список ID либо объект с ID-ключами); `missing` не является
подтверждением снятия. Каждый paused ID становится вечным tombstone, даже без регистрации.
Регистрация в Disk снимается при безопасном корне. Исходный файл остаётся; `guardImported=true`
означает завершённый импорт. Повторный запуск не создаёт новых проектов и не снимает tombstones.

2. Остановить основной таймер и cron fallback, дождаться действующего bootstrap под его lock,
   сохранить helper/правила/состояние для расследования, установить новую пару файлов.
   Резервная копия находится в служебной области, вне Disk и work.

```bash
state="$HOME/.local/share/remote-disk"
backup="$state/deploy-backup-$(date -u +%Y%m%dT%H%M%SZ)"
systemctl --user disable --now remote-disk-folders.timer
mkdir -m 700 "$backup"
crontab -l > "$backup/crontab" 2>/dev/null || true
python3 - "$backup/crontab" <<'PY' | crontab -
from pathlib import Path
import sys
for line in Path(sys.argv[1]).read_text().splitlines():
    if 'remote-disk/server-disk.sh' not in line:
        print(line)
PY
flock "$state/bootstrap.lock" bash -s -- "$state" "$backup" <<'SH'
set -euo pipefail
state=$1; backup=$2
for name in server-disk.sh stignore.txt missing-folders.json vanish-guard.json project-journal.jsonl project-journal-last.json; do
  if test -f "$state/$name"; then cp -p -- "$state/$name" "$backup/$name"; fi
done
install -m 700 disk/server-disk.sh "$state/server-disk.sh"
install -m 600 disk/stignore.txt "$state/stignore.txt"
SH
bash -n "$state/server-disk.sh"
bash "$state/server-disk.sh" bootstrap
```

Bootstrap сам включает основной таймер/cron fallback. При сомнении немедленно снова остановить
оба механизма приведёнными выше командами. При пустом корне не создавать sentinel/тестовый
проект ради обхода защиты: восстановить правильный том или явно снять ненужную регистрацию.

3. Проверить версию установленной пары файлов, результат импорта и журнал. Не печатать config.xml,
   API-key, ключи или origin URL. Сверить ожидаемые ID с реальным инвентарём владельца,
   а не создавать живую тестовую папку.

```bash
cmp disk/server-disk.sh "$state/server-disk.sh"
cmp disk/stignore.txt "$state/stignore.txt"
systemctl --user status remote-disk-folders.timer --no-pager
journalctl --user -u remote-disk-folders.service -n 30 --no-pager
python3 - "$state" <<'PY'
import json, sys
from pathlib import Path
state=Path(sys.argv[1])
x=json.loads((state/'missing-folders.json').read_text())
print('guardImported:', x.get('guardImported', False))
print('published:', sorted(x.get('published', {})))
print('tombstones:', sorted(x.get('removed', {})))
for line in (state/'project-journal.jsonl').read_text().splitlines()[-30:]:
    x=json.loads(line)
    print({k:x[k] for k in ('projectID','source','device','outcome','reason')})
PY
```

Проверить Syncthing REST только на loopback посредством локального скрипта, который читает ключ
в память и выводит только безопасные поля; не передавать ключ в argv/shell history:

```bash
python3 - "$state" <<'PY'
import json, sys, urllib.request, xml.etree.ElementTree as E
from pathlib import Path
s=Path(sys.argv[1]); root=E.parse(s/'config.xml').getroot()
port=json.loads((s/'ports.json').read_text())['gui']
r=urllib.request.Request(f'http://127.0.0.1:{port}/rest/config/folders', headers={'X-API-Key':root.findtext('gui/apikey')})
http=urllib.request.build_opener(urllib.request.ProxyHandler({}))
with http.open(r, timeout=3) as f:
    for x in json.load(f):
        print({k:x.get(k) for k in ('id','label','path','paused','type','versioning')})
PY
```

Ожидается: нет retired ID, у управляемых проектов staggered/maxAge=2592000,
нет non-git публикаций, label равен имени. Повтор bootstrap не меняет config и не добавляет дубли.
Первый запуск не может восстановить снятые до установки ID, отсутствующие и в guard/state:
их требуется занести в `removed` по проверенному инвентарю **до** включения обслуживания.

4. Откат: остановить основной таймер, убрать cron fallback как в шаге 2, дождаться bootstrap lock.
   Восстановить только два исполняемых файла; **не откатывать** missing-folders.json/журнал/guard
   и не восстанавливать старый Syncthing config. Старый helper не понимает вечные tombstones;
   после отката автоматизацию оставить выключенной до исправленной совместимой версии.

```bash
# state и backup — значения, сохранённые на шаге 2.
systemctl --user disable --now remote-disk-folders.timer
# Снова убрать cron fallback по шагу 2, затем:
flock "$state/bootstrap.lock" bash -s -- "$state" "$backup" <<'SH'
set -euo pipefail
state=$1; backup=$2
install -m 700 "$backup/server-disk.sh" "$state/server-disk.sh"
install -m 600 "$backup/stignore.txt" "$state/stignore.txt"
SH
```

Это откат поставки с остановленным обслуживанием; файлы проектов/ПК не удаляются.
Запуск старой версии «для проверки» запрещён: она может повторно принять retired ID.

## Изолированные проверки

Все fixtures — временные HOME под `/tmp`, настоящие Syncthing на loopback;
cron/systemd подменены. Живые `~/Disk`, state установки и Windows не используются.

```bash
flock /tmp/heavy-tests.lock python3 disk/test-disk.py -v
flock /tmp/heavy-tests.lock bash server/tests/run.sh
bash -n disk/server-disk.sh
# Клиентский этап (также только под общей блокировкой):
flock /tmp/heavy-tests.lock bash app/launcher/tests/run.sh
```

Для offline Syncthing можно задать `SYNCTHING_ARCHIVE` (архив Linux amd64 v2.1.7).
Linux-тесты не подтверждают Windows Shell, Корзину, cross-volume move и WinPS 5.1.
Клиентские незакрытые проверки перечислены по каждой клетке контракта.
