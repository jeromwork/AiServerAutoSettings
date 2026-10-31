#!/usr/bin/env python3
"""Dependency-free MCP stdio adapter; no credentials in configuration or stdout."""
import argparse
import json
import os
import socket
import sys

MAX = 262144


def schema(properties=None, required=None):
    return {"type": "object", "properties": properties or {}, "required": required or [], "additionalProperties": False}


STR = {"type": "string"}
TOOLS = [
    ("windows_status", "Current Windows device, selected workspace and installed capability paths. Does not contact devices or servers.", schema(), True),
    ("windows_list", "List immediate entries under the selected workspace; secret and reparse paths are denied.", schema({"path": STR}), True),
    ("windows_read", "Read UTF-8 text under the selected workspace (max 64 KiB). Secret/reparse paths are denied.", schema({"path": STR}, ["path"]), True),
    ("windows_write", "Write UTF-8 text under the selected workspace (max 64 KiB). Secret/reparse paths are denied.", schema({"path": STR, "content": STR}, ["path", "content"]), False),
    ("windows_command", "Run an explicitly requested PowerShell command on Windows as the signed-in user. Shell must be enabled by owner; full user access, SSH/VPN/ADB available if installed. Never read secrets. Maximum 60 seconds.", schema({"command": STR, "cwd": STR, "timeout_seconds": {"type": "integer", "minimum": 1, "maximum": 60}}, ["command"]), False),
    ("windows_process_start", "Start an explicitly requested development command on Windows, tracked until this bridge stops. Full user shell permission required. Returns a process id for poll/stop.", schema({"command": STR, "cwd": STR}, ["command"]), False),
    ("windows_process_poll", "Read bounded output and state of a development process started by this bridge.", schema({"id": STR}, ["id"]), True),
    ("windows_process_stop", "Stop a development process and its child processes started by this bridge.", schema({"id": STR}, ["id"]), False),
]


def exchange(path, op, args):
    with socket.socket(socket.AF_UNIX) as conn:
        conn.settimeout(100)
        conn.connect(os.path.expanduser(path))
        payload = json.dumps({"op": op, "args": args}, separators=(",", ":")).encode() + b"\n"
        if len(payload) > MAX:
            raise ValueError("request too large")
        conn.sendall(payload)
        raw = conn.makefile("rb").readline(MAX + 1)
        if len(raw) > MAX or not raw.endswith(b"\n"):
            raise ValueError("invalid response")
        return json.loads(raw)


def dispatch(message, path):
    method = message.get("method")
    params = message.get("params", {})
    if method == "initialize":
        version = params.get("protocolVersion")
        if version not in {"2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"}:
            version = "2025-11-25"
        return {"protocolVersion": version, "capabilities": {"tools": {}}, "serverInfo": {"name": "windows-bridge", "version": "1.0.0"}, "instructions": "Only execute Windows shell when explicitly requested by the owner. Windows VPN/SSH keys stay on Windows. File tools are workspace-limited; shell runs as the Windows user."}
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": [{"name": name, "description": description, "inputSchema": inputs, "annotations": {"readOnlyHint": readonly, "openWorldHint": not readonly}} for name, description, inputs, readonly in TOOLS]}
    if method == "tools/call":
        tool = next((tool for tool in TOOLS if tool[0] == params.get("name")), None)
        if not tool:
            raise ValueError("unknown tool")
        values = params.get("arguments", {})
        spec = tool[2]
        if not isinstance(values, dict) or set(values) - set(spec["properties"]) or any(key not in values for key in spec["required"]):
            raise ValueError("invalid tool arguments")
        for key, value in values.items():
            kind = spec["properties"][key]["type"]
            if kind == "string" and not isinstance(value, str):
                raise ValueError("invalid argument type")
            if kind == "integer" and (type(value) is not int or not 1 <= value <= 60):
                raise ValueError("invalid timeout")
        try:
            result = exchange(path, tool[0].removeprefix("windows_"), values)
        except Exception:
            result = {"ok": False, "error": "Windows bridge disconnected; start or reconnect the Windows bridge."}
        return {"content": [{"type": "text", "text": json.dumps(result, ensure_ascii=False)}], "isError": not result.get("ok", False)}
    raise LookupError("method not found")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    args = parser.parse_args()
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
            response = {"jsonrpc": "2.0", "id": message["id"], "result": dispatch(message, args.socket)}
        except LookupError:
            response = {"jsonrpc": "2.0", "id": message.get("id"), "error": {"code": -32601, "message": "Method not found"}}
        except Exception:
            response = {"jsonrpc": "2.0", "id": message.get("id") if isinstance(message, dict) else None, "error": {"code": -32602, "message": "Invalid request or parameters"}}
        print(json.dumps(response, ensure_ascii=False, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    sys.exit(main())
