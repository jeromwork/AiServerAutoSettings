#!/usr/bin/env python3
"""Dependency-free MCP stdio adapter; no credentials in configuration or stdout."""
import argparse
import json
import os
import socket
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
# Resolve the bundled sibling even when the client starts Python with -I.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import server_node_catalog as catalog_api

MAX = 262144


def schema(properties=None, required=None):
    return {"type": "object", "properties": properties or {}, "required": required or [], "additionalProperties": False}


STR = {"type": "string"}
TOOLS = [
    ("windows_status", "Current Windows device, selected workspace and installed capability paths. Does not contact devices or servers.", schema(), True),
    ("windows_list", "List immediate entries under the selected workspace; secret and reparse paths are denied.", schema({"path": STR}), True),
    ("windows_read", "Read UTF-8 text under the selected workspace (max 64 KiB). Secret/reparse paths are denied.", schema({"path": STR}, ["path"]), True),
    ("windows_write", "Write UTF-8 text under the selected workspace (max 64 KiB). Secret/reparse paths are denied.", schema({"path": STR, "content": STR}, ["path", "content"]), False),
    ("windows_command", "Run an explicitly requested PowerShell command on Windows as the signed-in user. Shell must be enabled by owner; full user access, SSH/VPN/ADB available if installed. Never read secrets. Maximum 60 seconds. Tasks run concurrently. Set exclusive=true for installation, environment transitions, network/service changes or reboot; refuses immediately if another task is active.", schema({"command": STR, "cwd": STR, "exclusive": {"type": "boolean"}, "timeout_seconds": {"type": "integer", "minimum": 1, "maximum": 60}}, ["command"]), False),
    ("windows_process_start", "Start an explicitly requested development command on Windows, tracked until this bridge stops. Tasks run concurrently; set exclusive=true for installation, environment transitions, network/service changes or reboot. Exclusive refuses immediately if another task is active. Full user shell permission required. Returns a process id for poll/stop.", schema({"command": STR, "cwd": STR, "exclusive": {"type": "boolean"}}, ["command"]), False),
    ("windows_process_poll", "Read bounded output and state of this task's process. Completed output is consumed on first read, expires after 300 seconds, and may be evicted after 64 retained results.", schema({"id": STR}, ["id"]), True),
    ("windows_process_stop", "Stop a development process and its child processes started by this bridge.", schema({"id": STR}, ["id"]), False),
]
TASK_TOOLS={'windows_command','windows_process_start','windows_process_poll','windows_process_stop'}
TOOLS=[(name, description, schema(dict(inputs['properties'],taskId=STR), inputs['required']) if name in TASK_TOOLS else inputs, readonly) for name,description,inputs,readonly in TOOLS]


def exchange(path, op, args, binding=None, timeout=100):
    with socket.socket(socket.AF_UNIX) as conn:
        conn.settimeout(timeout)
        conn.connect(os.path.expanduser(path))
        request = {"op": op, "args": args}
        if binding is not None:
            request['binding'] = {key: binding[key] for key in ('projectId', 'hostId', 'deviceLabel', 'windowsReplica')}
        payload = json.dumps(request, separators=(",", ":")).encode() + b"\n"
        if len(payload) > MAX:
            raise ValueError("request too large")
        conn.sendall(payload)
        with conn.makefile("rb") as stream:
            raw = stream.readline(MAX + 1)
        if len(raw) > MAX or not raw.endswith(b"\n"):
            raise ValueError("invalid response")
        return json.loads(raw)


def dispatch(message, path, catalog=None):
    method = message.get("method")
    params = message.get("params", {})
    if method == "initialize":
        version = params.get("protocolVersion")
        if version not in {"2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"}:
            version = "2025-11-25"
        return {"protocolVersion": version, "capabilities": {"tools": {}}, "serverInfo": {"name": "windows-bridge", "version": "1.1.0"}, "instructions": "Only execute Windows shell when explicitly requested by the owner. Windows VPN/SSH keys stay on Windows. File tools are workspace-limited; shell runs as the Windows user."}
    if method == "ping":
        return {}
    if method == "tools/list":
        tools = []
        for name, description, inputs, readonly in TOOLS:
            if catalog:
                inputs = schema(dict(inputs['properties'], projectId=STR, hostId=STR), inputs['required']+['projectId','hostId']+(['taskId'] if name in TASK_TOOLS else []))
                description += ' Requires exact projectId and hostId from windows_devices; never falls back to another node.'
            tools.append({"name": name, "description": description, "inputSchema": inputs, "annotations": {"readOnlyHint": readonly, "openWorldHint": not readonly}})
        if catalog:
            tools.append({'name':'windows_devices','description':'List registered Windows bindings, names, live availability and discovered capabilities. Sleeping/disconnected devices are unavailable; executable discovery does not prove SDK/VPN functionality.', 'inputSchema':schema({'projectId':STR}), 'annotations':{'readOnlyHint':True}})
        return {"tools":tools}
    if method == "tools/call":
        if catalog and params.get('name') == 'windows_devices':
            values = params.get('arguments', {})
            if not isinstance(values, dict) or set(values)-{'projectId'} or ('projectId' in values and not catalog_api.IDENT.fullmatch(values['projectId'])):
                raise ValueError('Invalid project filter')
            devices = []
            for record in catalog_api.records(catalog, Path.home()):
                if values.get('projectId') and record['projectId'] != values['projectId']:
                    continue
                row = {key:record[key] for key in ('projectId','hostId','deviceName','serverWorkspace','windowsReplica')}
                row['projectName']=record.get('projectName',record['projectId'])
                row.update(available=False, capabilities={}, shell_enabled=False)
                try:
                    status = exchange(record['socketPath'], 'status', {}, record, timeout=3)
                    if catalog_api.matches(record, status):
                        row.update(available=True, capabilities=status.get('capabilities',{}), shell_enabled=status.get('shell_enabled',False))
                    else:
                        row['offlineReason'] = 'Мост ответил, но это другой компьютер или другая привязка'
                except (FileNotFoundError, ConnectionRefusedError):
                    row['offlineReason'] = 'Мост на компьютере не запущен или нет связи с сервером'
                except socket.timeout:
                    row['offlineReason'] = 'Мост не ответил за 3 секунды'
                except Exception as error:
                    row['offlineReason'] = 'Ошибка связи с мостом: ' + type(error).__name__
                devices.append(row)
            return {'content':[{'type':'text','text':json.dumps({'ok':True,'devices':devices},ensure_ascii=False)}]}
        tool = next((tool for tool in TOOLS if tool[0] == params.get("name")), None)
        if not tool:
            raise ValueError("unknown tool")
        values = params.get("arguments", {})
        binding = None
        if catalog:
            if not isinstance(values, dict) or any(not isinstance(values.get(key), str) or not catalog_api.IDENT.fullmatch(values[key]) for key in ('projectId','hostId')):
                raise ValueError('Explicit projectId and hostId required')
            candidates = [r for r in catalog_api.records(catalog, Path.home()) if r['projectId']==values['projectId'] and r['hostId']==values['hostId']]
            if len(candidates)!=1:
                return {'content':[{'type':'text','text':'{"ok":false,"error":"Exact target is not registered; no fallback"}'}], 'isError':True}
            binding = candidates[0]
            path = binding['socketPath']
            values = {key:value for key,value in values.items() if key not in ('projectId','hostId')}
        spec = tool[2]
        if catalog and tool[0] in TASK_TOOLS and not catalog_api.IDENT.fullmatch(values.get('taskId','')):
            raise ValueError('Explicit taskId required')
        if not isinstance(values, dict) or set(values) - set(spec["properties"]) or any(key not in values for key in spec["required"]):
            raise ValueError("invalid tool arguments")
        for key, value in values.items():
            kind = spec["properties"][key]["type"]
            if kind == "string" and not isinstance(value, str):
                raise ValueError("invalid argument type")
            if kind == "boolean" and type(value) is not bool:
                raise ValueError("invalid exclusive flag")
            if kind == "integer" and (type(value) is not int or not 1 <= value <= 60):
                raise ValueError("invalid timeout")
        try:
            status = None
            if binding or values.get('exclusive') is True:
                status = exchange(path, 'status', {}, binding, timeout=3)
            if binding and not catalog_api.matches(binding, status):
                raise ValueError('Target binding mismatch')
            if values.get('exclusive') is True and status.get('coordination', {}).get('exclusive') is not True:
                result = {"ok": False, "error": "Executor does not advertise exclusive support; update/restart the Windows bridge before requesting exclusive."}
                return {"content": [{"type": "text", "text": json.dumps(result)}], "isError": True}
            result = exchange(path, tool[0].removeprefix("windows_"), values, binding)
            if binding:
                result['target'] = {'projectId':binding['projectId'],'hostId':binding['hostId']}
        except Exception:
            result = {"ok": False, "error": "Windows bridge disconnected; start or reconnect the Windows bridge."}
        return {"content": [{"type": "text", "text": json.dumps(result, ensure_ascii=False)}], "isError": not result.get("ok", False)}
    raise LookupError("method not found")


def main():
    parser = argparse.ArgumentParser()
    group=parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--socket")
    group.add_argument("--catalog")
    args = parser.parse_args()
    output_lock = threading.Lock()
    slots = threading.BoundedSemaphore(64)

    def respond(message, release_slot=False):
        try:
            response = {"jsonrpc": "2.0", "id": message["id"], "result": dispatch(message, args.socket, args.catalog)}
        except LookupError:
            response = {"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": "Method not found"}}
        except Exception:
            response = {"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32602, "message": "Invalid request or parameters"}}
        finally:
            if release_slot:
                slots.release()
        emit(response)

    def emit(response):
        with output_lock:
            print(json.dumps(response, ensure_ascii=False, separators=(",", ":")), flush=True)

    with ThreadPoolExecutor(max_workers=64) as workers:
        while True:
            raw = sys.stdin.buffer.readline(MAX + 1)
            if not raw:
                return 0
            message = None
            try:
                if len(raw) > MAX or not raw.endswith(b"\n"):
                    return 1
                message = json.loads(raw)
                if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
                    raise ValueError("invalid request")
                if "id" not in message:
                    continue
                # Keep protocol setup synchronous; only tool calls may complete out of order.
                if message.get('method') != 'tools/call':
                    respond(message)
                elif slots.acquire(blocking=False):
                    workers.submit(respond, message, True)
                else:
                    emit({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32000, "message": "Too many concurrent bridge requests (64)"}})
            except Exception:
                emit({"jsonrpc": "2.0", "id": message.get("id") if isinstance(message, dict) else None, "error": {"code": -32602, "message": "Invalid request or parameters"}})


if __name__ == "__main__":
    sys.exit(main())
