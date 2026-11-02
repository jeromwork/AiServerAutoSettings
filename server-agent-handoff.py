#!/usr/bin/env python3
"""Public project handoff. No model calls, credential access or GUI database access."""
import argparse
import base64
import html
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import uuid
import server_node_catalog as node_catalog


IDENT = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")
LABEL = re.compile(r"win-[a-f0-9]{28}\Z")
USER_HOME = Path("/home/remoteagents")


def owned(path, directory=False):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise ValueError("untrusted handoff path")
    if directory and not stat.S_ISDIR(info.st_mode):
        raise ValueError("directory required")


def mkdir_private(path):
    # Check the full managed chain. Never follow an existing symlink into another tree.
    path = Path(path)
    if path == USER_HOME:
        owned(path, True)
        return
    mkdir_private(path.parent)
    if not path.exists() and not path.is_symlink():
        path.mkdir(mode=0o700)
    owned(path, True)


def write_owned(path, value, mode=0o600):
    if path.exists() or path.is_symlink():
        owned(path)
        if not path.is_file():
            raise ValueError("regular file required")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode)
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
        stream.write(value)
    path.chmod(mode)


def validate(data):
    if data.get("schema") != 1:
        raise ValueError("unsupported handoff schema")
    for name in ("projectId", "hostId"):
        if not isinstance(data.get(name), str) or not IDENT.fullmatch(data[name]):
            raise ValueError("invalid binding")
    if not LABEL.fullmatch(data.get("deviceLabel", "")):
        raise ValueError("invalid device")
    expected = USER_HOME / "work/projects" / data["projectId"]
    if data.get("serverWorkspace") != str(expected):
        raise ValueError("workspace binding mismatch")
    if data.get("socketPath") != str(USER_HOME / ".local/state/codex-remote" / (data["deviceLabel"] + ".sock")):
        raise ValueError("socket binding mismatch")
    if data.get("agents") not in ("1", "2", "3") or type(data.get("allowShell")) is not bool:
        raise ValueError("invalid agent selection")
    if not isinstance(data.get("windowsReplica"), str) or not re.match(r"^[A-Za-z]:\\", data["windowsReplica"]):
        raise ValueError("absolute Windows replica required")
    return data


def handoff_directory(data):
    return USER_HOME / ".local/share/remote-agent-handoff" / data["projectId"] / data["hostId"]


def prompt(data, directory):
    return f"""Ты работаешь на VPS под обычным пользователем remoteagents. Помоги владельцу выполнить его текущую задачу; не начинай произвольную установку или публикацию без запроса. Все необходимые мосты уже устанавливает BAT; не создавай transport заново и не рассчитывай на Codex, Claude или Python в Windows. На компьютере достаточно запущенного BAT, подготовившего PowerShell/OpenSSH и служебные компоненты.
Выбранный проект: {data['serverWorkspace']}
Прочитай обязательные правила проекта и только нужные инструкции установки. Следуй предусмотренным ими согласованиям. Пиши исходники только в выбранном серверном проекте; сервер — единственный автор, Windows — отдельная receive-only рабочая копия. Не добавляй и не доверяй другие папки автоматически.
Одна зарегистрированная привязка (не цель по умолчанию): projectId={data['projectId']}; hostId={data['hostId']}; MCP=windows-{data['deviceLabel']}; Windows replica={data['windowsReplica']}.
Начни с windows_devices(projectId=выбранный ID), покажи владельцу имена, hostId и доступность. Цель для каждой задачи согласуется явно; регистрация ниже не назначает её автоматически. Во все Windows-инструменты передавай точные projectId и hostId. Затем вызови MCP windows_status для выбранной пары и проверь точное совпадение workspace, sync_guard.project_id и sync_guard.host_id. Доступны windows_list, windows_read, windows_command, windows_process_start/poll/stop. windows_write заблокирован. Перед каждой windows_command и windows_process_start исполнитель сам требует НОВЫЙ sync_barrier: ready=true, fresh=true и совпадающую привязку; старого результата недостаточно. При конфликте/отключении останови выполнение и сообщи причину.
Прочитай {directory}/smoke-result.json. transport_smoke=true означает только детерминированную проверку transport, НЕ запуск модели. Для собственной приёмки вызови windows_status, выполни безопасный windows_command Write-Output 'remote-agent-model-smoke' (если shell_enabled=true), проверь результат и только тогда сообщи, что именно твоя сессия использовала Windows. shell разрешён владельцем: {str(data['allowShell']).lower()}.
Команды Windows выполняются с правами вошедшего пользователя, а не в изолированной песочнице. Используй их только для текущей задачи, разрешённой владельцем. Не читай .env/.env.*, auth.json, credentials, токены, приватные ключи, браузерные профили и буфер. Не обходи согласования; не делай push/PR без отдельного разрешения. Вход в аккаунт выполняет человек в официальном окне входа.
Место запуска проекта выбирается для текущей задачи: сервер, этот компьютер либо отдельные компоненты на разных сторонах. Не закрепляй Node/PHP/Metro за конкретным устройством навсегда. Для серверного localhost используй SSH-проброс только на loopback компьютера; если локальный порт занят, предложи свободный и покажи точную ссылку. Публичный тестовый доступ — отдельное разрешение с аутентификацией, ограничением срока и доступов; не публикуй БД и административные порты автоматически.
Доступ к другим серверам: сначала уточни целевую среду и допустимые действия. Если production или внутренняя сеть доступны только с компьютера владельца, запускай разрешённый SSH/клиент через windows_command/windows_process_start: VPS → Windows-мост → локальная сеть/VPN → целевой сервер. Не предполагай, что VPN ноутбука доступен самому VPS. SSH-ключи остаются в Windows и используются штатным клиентом/ssh-agent; не копируй их на VPS и не проси отправлять пароль в чат. Для пароля используй штатный интерактивный вход на компьютере владельца; при отсутствии такого ввода остановись и помоги открыть его, не встраивай пароль в команду. Сначала проверь соединение без изменений. Установку VPN, программ, доступ к USB и production выполняй только по соответствующему запросу владельца, с необходимыми согласованиями. BAT не устанавливает частные VPN-профили и не содержит production-адресов или секретов.
Эта инструкция описывает одну конкретную привязку компьютера. Несколько компьютеров могут оставаться подключёнными одновременно и выполнять разные явно назначенные задачи: например, VPS запускает веб-приложение, домашний ПК — эмулятор, ноутбук — браузер. Не требуй отключать другой компьютер только ради выбора цели. Перед каждой операцией проверяй windows_status именно целевого MCP и совпадение его workspace/projectId/hostId с соответствующим handoff.json. Для другого компьютера нужна его отдельная подтверждённая привязка; не подменяй идентификаторы и не выбирай цель по активности мыши или наличию RDP. Если нужный компьютер не зарегистрирован/недоступен, сообщи это и не переноси задачу на другое устройство молча. Общий каталог windows_devices проверяет каждый узел живым запросом через его защищённый мост; старые записи остаются недоступными. На втором ПК присоединяются к существующему projectId через меню BAT без seed. Цель переназначается следующими вызовами с другой явно выбранной парой projectId/hostId; общего переключателя active PC нет. Для command/process_start/poll/stop обязательно передавай taskId текущей задачи. Среда Windows резервируется для этой задачи: dev-сервер и сопутствующие команды допустимы с тем же taskId, чужая задача получает busy. После завершения/остановки процессов среда освобождается. Не подставляй чужой taskId для обхода блокировки. Разные компьютеры могут работать одновременно. Серверные исходники меняй последовательно и замораживай записи на время проверки/запуска; snapshot не является транзакцией распределённой файловой системы.
VPN-шлюз выбирается отдельно от компьютера для эмулятора и от места запуска проекта. Если администратор VPN ограничил одновременные подключения, не пытайся обходить это изменением профиля. Для двух VPN-сессий попроси владельца получить у администратора отдельные профили/сертификаты и разрешение одновременного входа. Для разрешённой задачи можно выполнить SSH или другой клиент на одном компьютере с уже действующим VPN; это не создаёт VPN-сессию на втором устройстве и не должно превращаться в общий сетевой шлюз без отдельного согласования.
Определи недостающие компоненты для задачи, составь короткий план и выполни разрешённую настройку; команды установки с повышением прав согласуй. При shell_enabled=false объясни, как владелец может включить команды через BAT, а не обходи запрет. Готовность подтверждай проверкой; отдельно укажи, что не удалось проверить. Отвечай владельцу по-русски, коротко и простыми словами.
"""


def install_instruction_pointer(path, instructions):
    """Append/refresh only our block, preserving the project's existing rules."""
    begin = "<!-- RemoteAgents handoff begin -->"
    end = "<!-- RemoteAgents handoff end -->"
    content = ""
    if path.exists() or path.is_symlink():
        owned(path)
        if not path.is_file():
            raise ValueError("regular instruction file required")
        content = path.read_text(encoding="utf-8")
    block = (begin + "\n## Подключение Windows через установщик\n"
             "Перед работой с компьютером владельца прочитай инструкции: " + str(instructions) + "\n"
             "Они описывают выбранный компьютер, MCP-мост и разрешения. Проверяй актуальную привязку перед командами.\n" + end)
    if begin in content or end in content:
        if content.count(begin) != 1 or content.count(end) != 1 or content.index(begin) > content.index(end):
            raise ValueError("ambiguous managed instruction block")
        start = content.index(begin)
        finish = content.index(end) + len(end)
        updated = content[:start] + block + content[finish:]
    else:
        updated = content + ("\n\n" if content else "") + block + "\n"
    # Replace atomically, with no truncation of existing project rules on failure.
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(updated)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def prepare(data):
    data = validate(data)
    label=USER_HOME/'work/.remote-agents-projects'/data['projectId']/'label.json'
    if label.exists():
        owned(label)
        data['projectName']=str(json.loads(label.read_text('utf-8')).get('name',data['projectId']))[:120]
    directory = handoff_directory(data)
    mkdir_private(directory)
    workspace = Path(data["serverWorkspace"])
    for path in (USER_HOME / "work", USER_HOME / "work/projects", workspace):
        owned(path, True)
    write_owned(directory / "handoff.json", json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    write_owned(directory / "first-message.txt", prompt(data, directory))
    write_owned(directory / "instructions.md", prompt(data, directory))
    catalog=USER_HOME / '.local/share/remote-agents-nodes'
    mkdir_private(catalog)
    node_catalog.register(catalog, data, USER_HOME)
    shared=directory.parent/'instructions.md'
    write_owned(shared, f'''Проект на VPS: {workspace}. Сервер — единственный автор исходников. Windows получает отдельную receive-only копию, исходная папка служит только seed. Секреты, зависимости, SDK, БД и .git не переносятся.
Перед задачей выбери среду явно: VPS либо конкретные projectId + hostId из windows_devices(projectId="{data['projectId']}"). Покажи владельцу имя/ID и доступность выбранного узла. Регистрация, RDP и активность мыши не выбирают цель. Разные задачи могут использовать разные компьютеры одновременно; закрывать BAT другого компьютера не нужно.
Во все windows_* передавай точные projectId и hostId, для command/process_start/poll/stop также один taskId текущей задачи (нижний регистр, цифры, _ или -, до 64 символов). В рамках задачи можно запустить dev-сервер, затем сборку/ADB и проверки с тем же taskId. Другая задача не получает среду, пока есть работающие процессы предыдущей. Не переиспользуй taskId чужой задачи ради обхода отказа. Для переназначения poll/stop процессы старой задачи, затем явно выбери другой hostId. Не перенаправляй команды молча при недоступности. tools/status показывают только обнаруженные executables, а не проверенную работу VPN, SDK или USB.
Начни с windows_status выбранной пары и проверь workspace, sync_guard.project_id/host_id. Для команд нужен новый fresh sync barrier; серверные записи замораживаются на время проверки и запуска. Серверные изменения выполняй последовательно; snapshot не является распределённой транзакцией. Не редактируй принимающую Windows-копию. Если команда возвращает conflict/busy/offline/stale — остановись и сообщи причину.
Прочитай только инструкции выбранной привязки в {directory.parent}/<hostId>/instructions.md и её smoke-result.json. Детерминированный transport_smoke не означает модельную приёмку. В своей сессии проверь windows_status и разрешённый безопасный windows_command Write-Output 'remote-agent-model-smoke', оцени результат и сообщи отдельно непроверенное.
Управление Windows разрешает владелец в BAT, shell действует с его правами. Не читай .env, токены, ключи, личные аккаунтные файлы и буфер. Вход, MFA и доверие выполняет человек в официальном UI. Не обходи UAC, SSH/TLS или согласования; push/production требуют отдельного запроса. Для закрытой сети можно выполнить разрешённый штатный SSH/клиент на выбранном Windows с действующим VPN; ключи остаются там, пароль только в штатном интерактивном окне. Не делай из ПК общий сетевой шлюз.
Место запуска Node/PHP/эмулятора выбирается для задачи, не закреплено навсегда. Серверный localhost доступен через loopback SSH-проброс в меню BAT, занятый локальный порт заменяется свободным и показывается ссылка. Не публикуй сервисы автоматически. Дополнительные SDK, VPN, production и другие серверы настраивай только по запросу. Отвечай по-русски и подтверждай готовность фактическими проверками.
''')
    # Per-project context, rather than RDP origin or the last attached host,
    # selects the devices. A single matching connected device needs no boilerplate.
    with shared.open('a',encoding='utf-8') as stream:
        stream.write('\nНе требуй служебного первого сообщения. Для единственного доступного Windows-узла этого проекта используй MCP автоматически. При нескольких узлах уточни только целевой компьютер задачи. В начале работы и при смене цели показывай владельцу коротко: «Проект: имя → Windows: имя компьютера». Закрепляй выбор в контексте этой задачи/чата, а не глобально для всех пользователей. Переподключение RDP и появление другого компьютера не меняют цель текущей задачи. Разные проекты веди в отдельных чатах/контекстах; не подключай проект другого человека по совпадению имени и не перенаправляй задачу на его компьютер. Общие приложения не означают общий выбранный проект.\n')
    install_instruction_pointer(workspace / "AGENTS.md", shared)
    install_instruction_pointer(workspace / "CLAUDE.md", shared)
    global_instructions=directory.parent.parent/'instructions.md'
    write_owned(global_instructions,'''Установщик подключает Windows-компьютеры через MCP. Не требуй от владельца служебного первого сообщения. При начале задачи вызови windows_devices, сопоставь текущую папку проекта (разрешив символьные ссылки) с serverWorkspace и прочитай её AGENTS.md/CLAUDE.md. Для единственного подключённого узла этого проекта автоматически проверь windows_status и используй его projectId/hostId; если цель неоднозначна, уточни проект/компьютер, не выбирай последний подключённый. Для задач управления Windows используй windows_* MCP, а не Linux shell. Исходники редактируются на VPS, Windows получает отдельную копию; команды запуска, настройки и сборки для подключённой Windows выполняй через её MCP с одним taskId задачи. Отсутствие/недоступность MCP сообщай явно, не имитируй выполнение. Подтверждения действий соблюдай согласно политике самого агента.\n''')
    for parent,filename in ((USER_HOME,'AGENTS.md'),(USER_HOME,'CLAUDE.md'),(USER_HOME/'.codex','AGENTS.md'),(USER_HOME/'.claude','CLAUDE.md')):
        mkdir_private(parent)
        install_instruction_pointer(parent/filename,global_instructions)
    name = "windows-" + data["deviceLabel"]
    config = {"mcpServers": {name: {"type": "stdio", "command": "/usr/bin/python3", "args": [str(USER_HOME / ".local/share/codex-remote/codex-windows-bridge.py"), "--catalog", str(catalog)]}}}
    write_owned(directory / "claude-mcp.json", json.dumps(config) + "\n")
    write_owned(directory / "smoke-result.json", json.dumps({"transport_smoke": False, "model_acceptance": False, "reason": "Smoke not run yet"}) + "\n")
    render_page(data, directory)
    desktop = USER_HOME / "Desktop"
    mkdir_private(desktop)
    shortcut = desktop / ("RemoteAgents-Start-" + data["projectId"] + "-" + data["hostId"] + ".desktop")
    write_owned(shortcut, "[Desktop Entry]\nType=Application\nName=Начать настройку проекта\nComment=Готовое первое сообщение для Codex или Claude Code\nExec=xdg-open " + str(directory / "start.html") + "\nIcon=applications-development\nTerminal=false\nCategories=Development;\n", 0o700)
    return directory


def render_page(data, directory):
    message = html.escape(prompt(data, directory))
    project = html.escape(data["serverWorkspace"])
    available = "Codex" if data["agents"] == "1" else "Claude — вкладка Code" if data["agents"] == "2" else "Codex или Claude — вкладка Code"
    page = """<!doctype html><html lang="ru"><meta charset="utf-8"><title>Начать настройку проекта</title>
<style>body{font:18px/1.5 system-ui;max-width:900px;margin:48px auto;padding:0 24px;background:#f6f7fb;color:#172336}button{font:inherit;background:#2359d1;color:white;border:0;border-radius:10px;padding:14px 22px;cursor:pointer}textarea,input{box-sizing:border-box;width:100%;font:15px/1.4 monospace;padding:14px;border:1px solid #bdc8d8;border-radius:8px}textarea{height:230px}section{background:white;border-radius:16px;padding:24px;margin:20px 0}.muted{color:#536379}</style>
<h1>Передайте настройку серверному агенту</h1><p>Windows уже подключается этой программой. Оставьте BAT открытым, пока агент работает.</p>
<section><h2>1. Откройте приложение</h2><p>__APP__. Войдите в свой аккаунт в серверном браузере. Создайте локальный проект/чат и выберите эту папку. Не включайте отдельный worktree: мост привязан к указанной папке.</p><input id="project" readonly value="__PROJECT__"><p class="muted">Для Codex перезапустите MCP в настройках. В Claude используйте Code, а не обычный Chat. При первом открытии подтвердите доверие только выбранной папке и подключению Windows.</p></section>
<section><h2>2. Начните задачу в выбранном проекте</h2><p>Инструкции подключения добавлены в AGENTS.md и CLAUDE.md этой серверной папки. Напишите агенту свою задачу; для проверки можно попросить проверить соединение с этим компьютером. Если текущая сессия была открыта до настройки, создайте новую сессию проекта. Ниже — запасное первое сообщение, если инструкции не подхватились.</p><button onclick="copyPrompt()">Скопировать запасное первое сообщение</button><p id="copied" aria-live="polite"></p><textarea id="prompt" readonly>__PROMPT__</textarea></section>
<p class="muted">Кнопка копирует только видимый текст и не читает буфер. Установщик не отправляет сообщения в личный чат и не входит в аккаунт. Агент сам проверит инструменты; проверка транспорта не означает, что модель уже работала.</p>
<script>function copyPrompt(){let t=document.getElementById('prompt');t.select();let ok=document.execCommand('copy');document.getElementById('copied').textContent=ok?'Текст скопирован. Вставьте его в чат.':'Выделенный текст можно скопировать Ctrl+C.'}</script></html>
"""
    write_owned(directory / "start.html", page.replace("__APP__", available).replace("__PROJECT__", project).replace("__PROMPT__", message))


def rpc(data, calls):
    adapter = USER_HOME / ".local/share/codex-remote/codex-windows-bridge.py"
    messages = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}}, {"jsonrpc": "2.0", "method": "notifications/initialized"}, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}]
    for index, (name, arguments) in enumerate(calls, 2):
        arguments=dict(arguments,projectId=data['projectId'],hostId=data['hostId'])
        if name in ('windows_command','windows_process_start','windows_process_poll','windows_process_stop'):
            arguments['taskId']='transport-smoke-'+data['hostId'][:40]
        messages.append({"jsonrpc": "2.0", "id": index, "method": "tools/call", "params": {"name": name, "arguments": arguments}})
    completed = subprocess.run(["/usr/bin/python3", str(adapter), "--catalog", str(USER_HOME/'.local/share/remote-agents-nodes')], input="".join(json.dumps(m) + "\n" for m in messages), text=True, capture_output=True, timeout=110 * max(1, len(calls)))
    if completed.returncode:
        raise ValueError("MCP adapter did not complete")
    replies = [json.loads(line) for line in completed.stdout.splitlines()]
    if [reply.get("id") for reply in replies] != [0, 1] + list(range(2, len(calls) + 2)):
        raise ValueError("incomplete MCP exchange")
    names = {tool["name"] for tool in replies[1]["result"]["tools"]}
    if not {"windows_status", "windows_read", "windows_command"} <= names:
        raise ValueError("missing Windows tools")
    values = []
    for reply in replies[2:]:
        result = json.loads(reply["result"]["content"][0]["text"])
        if reply["result"].get("isError") or not result.get("ok"):
            raise ValueError("Windows smoke tool rejected")
        values.append(result)
    return values


def smoke(data, directory):
    result = {"transport_smoke": False, "model_acceptance": False, "projectId": data["projectId"], "hostId": data["hostId"]}
    marker = Path(data["serverWorkspace"]) / ("ra-smoke-" + uuid.uuid4().hex[:16] + ".txt")
    created = False
    try:
        status = rpc(data, [("windows_status", {})])[0]
        guard = status.get("sync_guard", {})
        if status.get("workspace", "").casefold().rstrip("\\") != data["windowsReplica"].casefold().rstrip("\\") or guard.get("project_id") != data["projectId"] or guard.get("host_id") != data["hostId"] or not guard.get("required") or status.get("file_mutations_enabled"):
            raise ValueError("Windows binding mismatch")
        result["status_smoke"] = True
        if not data["allowShell"] or not status.get("shell_enabled"):
            result["reason"] = "Status passed; shell smoke requires explicit owner permission"
            return result
        fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write("remote-agent-smoke-v1")
        created = True
        for content in ("remote-agent-smoke-v1", "remote-agent-smoke-v2"):
            marker.write_text(content, encoding="utf-8")
            command = "Get-Content -LiteralPath '" + marker.name + "' -Raw"
            checked = rpc(data, [("windows_command", {"command": command, "timeout_seconds": 10}), ("windows_read", {"path": marker.name})])
            if checked[0].get("exit_code") != 0 or checked[0].get("output", "").strip() != content or checked[1].get("content") != content:
                raise ValueError("server edit did not reach Windows through fresh barrier")
        result.update(transport_smoke=True, server_edit_to_windows=True, fresh_barrier_command=True, reason="Adapter/broker/Windows status, file read and two server edits passed")
    except Exception:
        # Do not print exception details: upstream output may contain private transport data.
        result["reason"] = "Windows transport smoke did not pass; reconnect the selected project and retry"
    finally:
        if created:
            marker.unlink(missing_ok=True)
            try:
                deleted = rpc(data, [("windows_command", {"command": "Test-Path -LiteralPath '" + marker.name + "'", "timeout_seconds": 10})])[0]
                result["fixture_cleanup_synced"] = deleted.get("exit_code") == 0 and deleted.get("output", "").strip() == "False"
            except Exception:
                result["fixture_cleanup_synced"] = False
        write_owned(directory / "smoke-result.json", json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    return result


def launch(data, directory, agent):
    workspace = Path(data["serverWorkspace"])
    owned(workspace, True)
    os.chdir(workspace)
    message = prompt(data, directory)
    if agent == "codex":
        binary = "/opt/remote-agents/codex/0.166.0/bin/codex"
        name = "windows-" + data["deviceLabel"]
        options = []
        for marker in Path("/var/lib/remote-agents/windows-mcp").glob("windows-win-*"):
            if re.fullmatch(r"windows-win-[a-f0-9]{28}", marker.name):
                options += ["-c", "mcp_servers." + marker.name + ".enabled=false"]
        options += ["-c", "mcp_servers." + name + ".enabled=true", "-c", "mcp_servers." + name + '.default_tools_approval_mode="prompt"', "-c", "mcp_servers." + name + ".required=true", "-c", "mcp_servers." + name + ".tool_timeout_sec=100"]
        os.execv(binary, [binary, "--cd", str(workspace), "--sandbox", "workspace-write", "--ask-for-approval", "on-request"] + options + [message])
    binary = str(USER_HOME / ".local/bin/claude")
    os.execv(binary, [binary, "--permission-mode", "default", "--strict-mcp-config", "--mcp-config", str(directory / "claude-mcp.json"), message])


def main():
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--prepare-b64")
    group.add_argument("--handoff", type=Path)
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--agent", choices=("codex", "claude"))
    args = parser.parse_args()
    if os.getuid() == 0 or Path.home() != USER_HOME:
        raise ValueError("Handoff must run as remoteagents with its own HOME")
    if args.prepare_b64:
        data = validate(json.loads(base64.b64decode(args.prepare_b64, validate=True)))
        directory = prepare(data)
    else:
        owned(args.handoff)
        data = validate(json.loads(args.handoff.read_text(encoding="utf-8")))
        directory = handoff_directory(data)
        if args.handoff != directory / "handoff.json":
            raise ValueError("handoff path mismatch")
    if args.smoke:
        result = smoke(data, directory)
        print(json.dumps(result, ensure_ascii=False))
        return 0 if result.get("transport_smoke") or not data["allowShell"] and result.get("status_smoke") else 1
    if args.agent:
        if args.agent == "codex" and data["agents"] == "2" or args.agent == "claude" and data["agents"] == "1":
            raise ValueError("agent not selected")
        launch(data, directory, args.agent)
    print(json.dumps({"handoff_ready": True, "directory": str(directory), "gui_first_message_sent": False, "model_acceptance": False}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        print("Project handoff could not complete; no model acceptance claimed.", file=sys.stderr)
        sys.exit(1)
