# «Диск без возвратов»: этап 1

Работа в `app/disk-solid`, worktree `~/work/wt-disk-solid`.
Push, merge, выкладка, живой Syncthing, `~/Disk` владельца и Windows не затрагивались.
Файлы соседней сессии Happier не менялись.

## Объём

Контракт: `DISK-CONTRACT.md`, все 69 клеток исходного аудита, решения Q1–Q10,
путь восстановления и имя существующего/планируемого теста в каждой строке.
Планируемые клиентские тесты явно помечены, прохождение им не приписывается.
Исторические PLAN-DISK/SPEC-SYNC/EXPLORER-*/FOLDERS-STATUS-REPORT перенаправлены на контракт.
Конституция §6г и disk/README приведены к принятым решениям.

Серверная часть:

| Дыра / клетки | Изменение | Регрессионные тесты в disk/test-disk.py |
|---|---|---|
| H01, 1a–c | Настоящий git top-level/валидный gitdir; non-git не публикуется; отсутствие origin отмечается | ContractTests.test_git_top_level_and_valid_gitdir_are_required; test_existing_nongit_registration_is_retired_without_deleting_data |
| Сервер H02, Q1, 5a/5e/8c/10d | Только Upload-ID; init и один пустой первый коммит, без выдуманного origin | ContractTests.test_only_upload_ids_are_admitted_and_git_is_initialized_once; IncomingFolderTests.test_upload_is_accepted_bidirectionally_and_offered_to_a_third_device |
| Q2, 5c–d | Отказ занятых имён/пересечений, без суффиксов/merge | ContractTests.test_name_collision_and_invalid_labels_are_refused_without_sanitizing; IncomingFolderTests.test_colliding_labels_never_merge_existing_contents_or_registered_paths |
| Сервер H12, 1c/5d | NFC, общий строгий набор символов/длин/Windows reserved, без санитизации, casefold коллизии | ContractTests.test_name_collision_and_invalid_labels_are_refused_without_sanitizing; test_case_colliding_server_names_are_both_refused |
| Сервер H17/Q6, 2a/2d–e/8a–c | Долговечные published/removed, ручное снятие/смена пути, невосстанавливаемый ID | ContractTests.test_manual_unshare_tombstones_even_existing_path_and_never_returns; test_removed_upload_and_renamed_marker_never_reuse_tombstone; MissingFolderTests |
| H05, 2c | Недоступный/пустой корень — без mkdir/приёма/DELETE; сброс наблюдения | ContractTests.test_empty_missing_or_unreadable_root_has_no_mutations_or_mkdir; MissingFolderTests.test_unavailable_empty_or_replaced_disk_resets_continuous_absence |
| Сервер H11/Q8, 13a–d | Обязательный include первым, расширение списка, сохранение пользовательских правил | ContractTests.test_mandatory_ignores_precede_negations_and_cover_q8; ServerTests.test_foreign_ignores_survive_updates_and_rules_work_in_real_engine |
| H24 | JSONL происхождения, стабильные поля, подавление повторов, без содержимого/URL origin | ContractTests.test_origin_status_never_logs_url_or_file_contents; test_only_upload_ids_are_admitted_and_git_is_initialized_once |
| Сервер H26/Q9, 11a/12a | Staggered 30 дней для новых/существующих, дальнейших коммитов нет | ContractTests.test_versioning_is_migrated_for_existing_folders; test_only_upload_ids_are_admitted_and_git_is_initialized_once |
| H23 | Импорт paused guard-ID до discovery, вечные tombstones, сохранение исходника | ContractTests.test_guard_paused_ids_are_imported_before_any_discovery; test_failed_guard_delete_and_missing_root_preserve_imported_tombstones |
| Долговечность защиты | Битые tombstones не превращаются в пустой список; каталог состояния fsync до REST DELETE | ContractTests.test_broken_durable_tombstones_fail_closed; test_tombstone_directory_is_synced_before_rest_delete |
| Первый коммит после сбоя | Пустой init-коммит сохраняет ранее staged локальные данные в индексе, не коммитит их | ContractTests.test_initial_commit_is_empty_even_after_interrupted_init_with_staged_data |
| Отказы/журнал | Недоступный журнал блокирует новую публикацию; ID с CRLF не подделывает строки stderr | ContractTests.test_journal_failure_blocks_new_publication; test_legacy_refusal_stderr_is_single_line_and_deduplicated |

Существующие успешные fixtures публикации переведены на настоящие git-репозитории.
Прежние ожидания `(2)`, санитизации label и восстановления retired ID заменены на отказ.
Изолированные Upload fixtures используют версионированный ID, политику до первого scan и локальную базу Disk.
Проверки с настоящими движками остаются во временных HOME, systemd/cron имитируются.

Для обязательного `server/tests/run.sh` исправлен только test fixture в
`server/tests/test_config_export.py`: `Env` создаёт свой пустой `serverConfig`, а проверка
временных путей включает его. Первый прогон обнаружил, что без этого поля старый fixture
обращался к стандартному `/var/lib/remoteagents-status/server-config.json` машины и падал
на несовпадении схемы. Рабочий файл не менялся, его содержимое/секреты не выводились.
Код выдачи, `server/server_components.py`, `server/server_apply.py` и файлы Happier не изменены.

## Проверки

Все исполнения `disk/test-disk.py` и `server/tests/run.sh` выполнены через
`flock /tmp/heavy-tests.lock`; реальные Syncthing запускались только с временными HOME,
server fixtures — во временных каталогах. Использован проверенный локальный архив Syncthing
2.1.7 (SHA-256 `2edc416e7ed136b7c858ed5f3f02a3b8316589605e54c380228ceea7acbf0142`).
Для ограничения ресурсов: GOMAXPROCS=2, DOTNET_PROCESSOR_COUNT=2;
для финального общего прогона также MSBUILDDISABLENODEREUSE=1 и UseSharedCompilation=false.

| Проверка | До исправления | Финальный результат |
|---|---|---|
| Первые 20 новых ContractTests | FAILED: failures=15, errors=9 (субтесты считаются отдельно) на исходном серверном коде | Вошли в зелёные 26 ContractTests |
| Ещё 4: журнал недоступен, CRLF/повторы, существующий linked gitdir, неизвестный guard path | Все 4 упали на первом исправлении | Все прошли |
| Ещё 2: staged данные после прерванного init, fsync каталога до DELETE | Оба упали до соответствующей правки | Оба прошли |
| Все новые ContractTests | Всего добавлено 26 | `Ran 26 tests in 4.169s — OK` |
| Полный disk/test-disk.py | Первый широкий прогон: 72 теста, failures=2/errors=1; ошибка проверки недоступного пути в тесте и два устаревших fixture (non-git / legacy ID), исправлены | `Ran 78 tests in 350.584s — OK` |
| server/tests/run.sh | Падение старого fixture на стандартном serverConfig машины; изоляция исправлена, focused concurrent-export прошёл | `server/tests: 204 тестов, все прошли`; gateway `Ran 34 tests — OK`; installer `Ran 11 tests — OK`; exit 0 |
| Синтаксис/документы | — | `bash -n`; компиляция встроенного Python; синтаксис всех bash-блоков README; 69/69 клеток и ссылки на реализованные test methods; `git diff --check` — PASS |

Повторить из корня checkout (по отдельности; либо обе команды последовательно под одним flock):

```bash
flock /tmp/heavy-tests.lock env SYNCTHING_ARCHIVE=/home/remoteagents/.cache/remoteagents-vpn-test/syncthing-linux-amd64-v2.1.7.tar.gz GOMAXPROCS=2 python3 disk/test-disk.py -v
flock /tmp/heavy-tests.lock env DOTNET_PROCESSOR_COUNT=2 MSBUILDDISABLENODEREUSE=1 UseSharedCompilation=false bash server/tests/run.sh
```

Полный launcher suite не запускался: C# не менялся, клиентские переходы не объявлены готовыми.
Во время ожидания общего lock обнаружен оставшийся VBCSCompiler завершившегося чужого прогона:
он унаследовал descriptor блокировки. После проверки отсутствия build/run/publish процессов
завершён только этот compiler (SIGTERM), рабочие службы не останавливались.

## Осталось

Клиентский этап: новый Upload-ID в C#, запрет внешних/вложенных путей во всех entry points,
сообщения об отказе сервера, явный merge после reinstall, локальный delete/move/rename/detach,
очистка ложного ini, stale pending и подтверждение снятия, Keep с ignored/поздними правками,
журнал операции/восстановление после crash, конфликты/честные статусы, политики/версии ПК,
installer без fallback-create, identity rotation, единый custom home, запрет downgrade helper,
два Windows/WinPS 5.1/реальная Корзина и cross-volume move. Контракт содержит имена необходимых тестов.

Разобраны a0c081c/a175d75/4d89432; полное cherry-pick не делалось. Полезные части для следующего
этапа: monotonic local detach + защитные проверки времени, отдельный явный merge/LocalCopy.
Нужно исключить внешние пути, добавить проверку привязки оформления и новые ignores/версии.
Серверный этап не объявляет эти клиентские дыры закрытыми.

Ограничения наблюдения: ручное удаление и возврат регистрации целиком между двумя снимками
невидимы; снятие до первого запуска без старого state/guard нельзя восстановить догадками.
Upload-ID — маркер протокола, не подпись действия доверенного устройства.
Пустой корень намеренно не вызывает автоснятие последнего проекта: требуется явное снятие config.
Процедура выкладки/проверки/безопасного отката находится в disk/README.md; здесь она не исполнялась.
