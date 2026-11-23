# Лаборатория RemoteAgents

Ветка `lab` (orphan): сторож-EXE (`lab/exe/`) + Python-часть (`lab/ralab/`) + серверная команда `ra-lab` (`lab/server/`).
EXE распаковывает переносной Python и код, запускает `run_lab.py` и перезапускает его. Вся логика связи - в Python:
читает настоящий конфиг установленной RemoteAgents (только чтение), запускает свой sing-box (входы direct на 127.0.0.1,
Clash API с secret), одновременно измеряет все пути к серверу (64 КиБ туда и обратно), первый успешный становится каналом
ассистента, остальные попадают в рейтинг. Системная сеть ПК не меняется.

## Сборка
`bash lab/build.sh` -> `lab/out/RemoteAgents-Lab.exe` и `lab/out/RemoteAgents-Lab СТОП.cmd` (см. build.sh).

## Сервер
`bash lab/server/install.sh` -> `~/.local/bin/ra-lab`. Без root, sshd и `authorized_keys` не трогает.

## Команды ra-lab
`wait-up [--deadline 90]`, `status`, `log [-n N]`, `rank`, `exec "<cmd>" [--shell powershell|cmd] [--max-time S] [--cwd D]`,
`kill <id>`, `read <путь> [локальный]`, `write <путь> <локальный|->`, `restart`, `switch <путь>`, `push [--wait]`
(`--pc ИМЯ` ставится перед командой, по умолчанию - последний подключавшийся ПК). `push` пакует `lab/run_lab.py` и `lab/ralab/**/*.py`
текущего git-каталога, агент проверяет код, Python перезапускается с кодом 3; если новая версия не подняла канал - EXE откатывает.

## Аварийно
`RemoteAgents-Lab СТОП.cmd` на рабочем столе: гасит процессы, откатывает системные изменения, сохраняет журнал, удаляет папку лаборатории.

## Журнал
`%LOCALAPPDATA%\RemoteAgents-lab\logs\lab-N.jsonl` (5 МБ x 4), рейтинг путей - `state\ranking.json`, `ra-lab log` / `ra-lab rank`.

## Таймеры
В Python один таймер - конец раунда измерений `round.end` (60 с, `bus.guard`); замёрзший путь не сообщает о заморозке. Детекторы заморозки
канала - чужие: ssh `ServerAliveInterval=15` x 2, TCP keepalive sing-box (`tcp_keep_alive 15s / 5s`), QUIC idle у hy2/tuic.

## TODO
TODO(владелец 23.11): переключение на более быстрый путь при работающем канале - решить позже (канал рвётся на секунды).
Сейчас путь меняется только при обрыве канала или командой `ra-lab switch`; рейтинг задаёт порядок проб в следующем раунде.

## Выпуск версии
Правка -> номер в `lab/STAGE` (`V<N>`) -> коммит в ветку `lab` -> ревью -> `bash lab/release.sh`.
Скрипт собирает EXE, ставит тег `lab-v<N>`, кладёт `RemoteAgents-Lab-V<N>.exe` в GitHub-релиз `lab-latest` (там копятся все версии для отката)
и проверяет скачиванием sha256. Номер версии виден в подсказке значка (`V<N> ·`) и в окне «Состояние».
