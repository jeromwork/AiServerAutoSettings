# Проверка двустороннего runtime на Syncthing v2.1.7

Тест: `test-two-way-sync.py`, Linux amd64, два настоящих процесса из одного проверенного официального архива. Запуск без скачиваний:

```sh
python3 test-two-way-sync.py --archive /path/to/syncthing-linux-amd64-v2.1.7.tar.gz
```

SHA256 архива: `2edc416e7ed136b7c858ed5f3f02a3b8316589605e54c380228ceea7acbf0142`. Значение совпадает с закреплённым установщиком и ранее сохранённым официальным checksum-файлом; GPG-подпись в этом запуске не проверялась. Бинарник извлекается заново в приватный временный каталог после проверки SHA256; непроверенный бинарник из кеша не используется.

Обе стороны настроены через `server-sync-runtime.py configure --mode bidirectional`, каждая со своим manifest, рабочим каталогом и состоянием. Используется одна продуктовая политика исключений. Тест не подменяет `.stignore`, тип папки или версионирование. GUI и TCP привязаны только к 127.0.0.1, порты случайные; relay, discovery, NAT, reporting и upgrades выключены. Генерация нового двустороннего состояния выполняется без пробного открытия стандартных портов. Внешняя сеть и действующие привязки не используются. Очистка останавливает только Popen-процессы данного теста.

## Найденные ошибки

1. Черновик обращался к API немедленно после Popen. Теперь готовность API ожидается до 60 секунд с проверкой выхода собственного процесса. На реальном v2.1.7 API доступен после запуска; отдельная несовместимость REST API с v2 не выявлена. Это объяснение исходного падения, но сам прошлый запуск не воспроизводился по его старым журналам.
2. Исходный `staggered` прореживает быстрые последовательные версии: после успешной правки и удаления в `.stversions` оставался исходный текст, а последний удалённый текст отсутствовал. Строгий К2 воспроизвёл это. Для новых двусторонних подключений включён `simple`, `cleanoutDays=30`, `keep=2147483647`, очистка раз в час. Практического ограничения по числу версий в небольшом дереве нет; формальный предел указан явно. Старые состояния автоматически не мигрируются.
3. `health` без `--peer` искал соединение с ключом None и сообщал `connected=false` при живом соединении. Теперь использует peer из собственного `configured.json`, если аргумент не передан. К7 обязательно проверяет true до остановки, false после неё, true и доставку файлов после перезапуска.
4. Проверки черновика были некорректны: К4 создавал секреты сразу на обоих узлах, затем требовал отсутствия; К3 искал конфликт по неверной маске и не сравнивал тексты; К2 принимал любой элемент `.stversions`. Тест переписан: отдельные функции К1–К7, уникальные пути каждого направления, точные тексты, конфликтные копии на обоих узлах, положительный барьер передачи перед отрицательными проверками. К6 держит отрицательное окно 12 секунд; пауза проверяется в обе стороны. К1, возобновление К6 и восстановление К7 обходятся без ручного scan.

Режим sendonly и его белый список не менялись. Изменение health исправляет чтение статуса; явно заданный peer по-прежнему поддерживается.

## Границы проверки

Проверены только два Linux-процесса и маленькие синтетические деревья. Windows, приложение в app/, SSH-туннель, сон/перезагрузка ОС, VPS, большие деревья, длительное хранение/очистка через 30 дней, сбой диска, ACL, symlinks, коллизии регистра и несколько версий одного файла внутри одной секунды не проверены. У Syncthing имена архивов имеют секундную точность; тест разделяет правку и удаление паузой 1.1 секунды. Это не гарантия сохранения всех локальных промежуточных записей. Удалённый текст проверяется чтением точного содержимого архива, полноценный UI восстановления не проверяется.

Дополнительно прошли `test-server-sync-deletion.py server-sync.py`, 17 тестов `test-server-sync-git.py`, компиляция Python и проверка whitespace изменённых файлов. Старый `test-multi-sync-loopback.py` прочитан, но не запускался: его установщик скачивает бинарник, внешняя сеть в этом задании запрещена.

## Диагностика до исправления

Исходный staggered и исходный health дали следующие строки (это не зачётные прогоны):

```text
FAIL K2 edits, deletions and exact archived contents both directions: timeout: deleted content archived
FAIL K7 disconnected status and automatic recovery: timeout: connected before stop
```

## Два последовательных зачётных прогона

Окончательный код не менялся между прогонами. В каждом семь PASS, строк FAIL нет.

### Прогон 1

```text
SHA256 OK Syncthing v2.1.7 archive 2edc416e7ed136b7c858ed5f3f02a3b8316589605e54c380228ceea7acbf0142
PASS K5 first connection merges existing contents without deletion
PASS K1 new files A->B and B->A
PASS K2 edits, deletions and exact archived contents both directions
PASS K3 concurrent edits preserve both versions on both peers
PASS K4 .env, .pem, secret names and .git excluded both directions
PASS K6 pause blocks transfer, resume catches up
PASS K7 disconnected status and automatic recovery
```

### Прогон 2

```text
SHA256 OK Syncthing v2.1.7 archive 2edc416e7ed136b7c858ed5f3f02a3b8316589605e54c380228ceea7acbf0142
PASS K5 first connection merges existing contents without deletion
PASS K1 new files A->B and B->A
PASS K2 edits, deletions and exact archived contents both directions
PASS K3 concurrent edits preserve both versions on both peers
PASS K4 .env, .pem, secret names and .git excluded both directions
PASS K6 pause blocks transfer, resume catches up
PASS K7 disconnected status and automatic recovery
```
