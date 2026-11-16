# Диск без возвратов — этап 3: быстрые тесты

16.11.2026, `app/disk-solid`, worktree `~/work/wt-disk-solid`.
Push, merge, выкладка и обращения к Windows не выполнялись.

## Сделано

- Параметризованы серверные REST/process/download/startup/grace/stale/cooldown/poll интервалы,
  systemd и резервный cron; клиентские C#/PowerShell REST, Keep, missing, locks, startup,
  transport/banner, installer retry, watcher и reconnect. Исходные продуктовые defaults сохранены.
  Полный перечень переменных и единиц — в `disk/README.md`.
- Сервер принимает положительные конечные секунды; C#/PowerShell — миллисекунды.
  Некорректные значения отклоняются. Native API с целыми секундами мокается в быстрых тестах.
  Смена cron-интервала заменяет только собственное расписание и сохраняет посторонние строки.
- `disk/test-fast.sh`: внешний `timeout 15`, контроль общего бюджета 10 с, fail-fast на всех
  слоях. Launcher `tests/run.sh` без аргументов запускает только этот набор;
  `--live` — интеграцию, `--full` — весь launcher, с ограниченным live вместо старых массовых Disk-прогонов.
- Fast использует временные HOME/LOCALAPPDATA/USERPROFILE и FS в `/dev/shm`, настоящий git,
  production helpers/команды/журнал, fake REST и часы. `fsync`/`Flush(true)` не отключены.
  Настоящие Syncthing/cron/systemd не запускаются. C# собирается SDK Roslyn без NuGet/MSBuild;
  список файлов берётся из отдельного csproj, повторный запуск сверяет хеш всех входов.
- `disk/test-live.sh`: внешний `timeout 60`, fail-fast, два настоящих Syncthing в disposable
  HOME на loopback, короткие ожидания. Проверяет Upload/git-admission/передачу, effective ignores
  с положительным scan-sentinel, Keep/download, снятие ID и сохранность локальных данных.
- В старых серверном grace и клиентском watch-missing fixtures убраны реальные 30/34 с:
  время передаётся явно. Старые engine/safety fixtures сохранены для адресной диагностики;
  массово при правке не запускаются. Installer-child fixture использует миллисекундный offer timeout.
- Правило ≤10 с / fail-fast / инъекция часов / live перед выкладкой записано в Конституцию.
  В контракт добавлено соответствие быстрых проверок ранее проверенным клеткам.

## Что проверяется по матрице

Это замена способа проверки уже реализованных переходов, а не новые исправления всех дыр аудита.

| Дыры / клетки | Быстрый эквивалент |
|---|---|
| H01/H02/H10/H11/H26; 1a–c, 5a/d/e, 8c, серверная часть 9c, policy 12a | `ContractTests`, discovery/registration/lost PUT/reservation в `TransitionTests`; excludes/versioning/admission/idempotence. |
| H03/H07; 6a/c, 7a–e | `DiskExplorerTests.MissingFolders/Lifecycle`: fake monotonic clock, реальное перемещение/удаление disposable путей, возврат, недоступная база, оформление, повтор. |
| 2a/c/d/e, 8a/b | Tombstones/manual unshare/path change/guard/re-offer в `ContractTests`, continuous absence/root generation в `TransitionTests`, confirmed/unconfirmed withdrawal в C#. |
| 3a/b, 11b | `Commands/LocalCopies`: только явный download/merge, тот же ID, сохранение локальных данных, unlimited conflicts/versioning. BEP-конфликт не имитируется копированием файлов. |
| H09; 4a–e, 12b | `Commands/FastSafety/Lifecycle/RecyclePolicy`: scan/sequence/counters, полный список ignored, поздняя запись, conflict, timeout, отказ Корзины и rollback. |
| 5b/c/f/g/h | Path admission/коллизия/UUID/retry и явное RO→sendreceive без смены серверного ID. |
| 6b | `FastSafety`: удаление содержимого при существующем корне оставляет регистрацию для обычной BEP-синхронизации. Доставку удаления проверяет сохранённый engine fixture. |
| H08; прерывание операций | `Recovery`: before/after POST, detach, partial recycle, recycle, placeholder; новый объект журнала, два повтора, сохранность байтов, восстановление partial как paused. |
| 10c/d, 11a | PowerShell accept/policy/readiness с виртуальным временем, поздним предложением и без fallback-create. |
| Watchdog/ошибки одной папки | Чистые `StaleConnectionTests`/`ServerHardeningTests` с fake REST/clock, без настоящего туннельного ожидания. |

## Прогоны и вывод

Все сборки, общий fast и live запускались через `flock --close /tmp/heavy-tests.lock`.
Время ожидания чужой блокировки в приведённые времена не входит.

| Проверка | Результат |
|---|---|
| Новый timing regression до исправления | FAIL: `invalid duration accepted` (0,107 с); затем PASS. |
| Новый cron override/replacement regression до исправления | FAIL (0,007 с); затем все три timing-теста PASS (0,028 с). |
| Быстрый набор с пересборкой C# после последней правки C#-fixture | PASS, **9,253 с**; 49 Python-тестов на тот момент, 213 C# checks, 24 PS acceptance checks. |
| Итоговый `flock --close /tmp/heavy-tests.lock bash app/launcher/tests/run.sh` | PASS, **7,069 с**; **50 Python-тестов**, **213 C# checks**, **24 PS acceptance checks**, плюс PS timing/readiness/parser/INI checks. Python 3,12 с, C# 0,81 с, PS 2,97 с. |
| `flock --close /tmp/heavy-tests.lock bash disk/test-live.sh` — один прогон | PASS, **15,629 с**; все три группы live PASS, собственные движки удалены cleanup. |
| Синтаксис shell/Python, PowerShell parser, `git diff --check` | PASS. |

При разработке старый способ сборки/fixtures превышал бюджет: срабатывал внешний лимит 15 с
(код 124), а один завершённый набор занял 10,730 с и корректно вернул код 1, хотя assertions
прошли. Лимиты не увеличивались; внутри runner повторов нет. Убраны MSBuild/restore startup,
дисковые fixtures и многократные виртуальные PS polling-итерации. На загруженном сервере
превышение бюджета по-прежнему означает FAIL, а не скрытое продление ожидания.

## Что осталось

H12/H14–H22 не полировались. Клетки, помеченные в контракте как план, не объявлены закрытыми.
Fast доказывает решения приложения; настоящий BEP, Shell/Корзина Windows, cross-volume,
WinPS 5.1, три клиента одновременно и остальные интеграционные границы не заменяются моками.
В этом этапе live проверяет указанную цепочку, а не весь исторический многоминутный набор.
Полный launcher/server-набор не запускался: этапом предписаны быстрый и один live-прогон.

Наработки `a0c081c/a175d75/4d89432` уже перенесены в этап 2 (`8fffbc9`); повторного cherry-pick нет.
Изменений в `TrayContext.cs`, `TrayMenuModel.cs`, `ConfigWindow.Main.cs`, `ConfigBundle.cs`,
`HappierWebResolver.cs`, `transport/*` и перечисленных серверных файлах соседней сессии нет.
`TrayMenuModel.cs` только включён в отдельную тестовую сборку для существующего DiskTraySession.
Живые Disk/state/Syncthing, серверные службы и компьютеры не изменялись.
