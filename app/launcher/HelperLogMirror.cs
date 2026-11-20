using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;

namespace RemoteAgents.Launcher
{
    // Забирает новые строки журнала помощника (команда log.read) и дописывает их в logs\helper.log и logs\core.log.
    // Помощник v9 команды не знает и при неверном запросе закрывает канал: версия проверяется ДО вызова.
    internal sealed class HelperLogMirror
    {
        internal const int MinHelperVersion = 10, Iterations = 10, MaxBytes = 40000;
        readonly string logsDir, cursorFile;
        readonly Func<bool> ready;
        readonly Func<string> helperVersion;
        readonly Func<ulong, int, Dictionary<string, object>> read;
        readonly Action<LogLevel, string, string[]> log;
        readonly object gate = new object();
        string lastState = "";
        internal HelperLogMirror(string logsDir, string stateDir, Func<bool> ready, Func<string> helperVersion,
            Func<ulong, int, Dictionary<string, object>> read, Action<LogLevel, string, string[]> log)
        {
            this.logsDir = logsDir; cursorFile = Path.Combine(stateDir, "helper-log-cursor.json");
            this.ready = ready; this.helperVersion = helperVersion; this.read = read; this.log = log;
        }

        ulong LoadCursor() { try { ulong n; return ulong.TryParse(Json.Str(Json.Read(cursorFile), "after"), NumberStyles.None, CultureInfo.InvariantCulture, out n) ? n : 0; } catch { return 0; } }
        void SaveCursor(ulong after) { try { Json.Write(cursorFile, new Dictionary<string, object> { { "after", after.ToString(CultureInfo.InvariantCulture) } }); } catch { } }
        void State(string state, params string[] kv)
        {
            if (state == lastState) return;
            lastState = state; if (state != "ok") log(LogLevel.Warn, "helper.unreachable", new[] { "state", state }.Concat(kv).ToArray());
        }
        static string Component(string line)
        {
            // <UTC> <локальное> <УРОВЕНЬ> <компонент> <событие> ...
            var parts = line.Split(new[] { ' ' }, 6, StringSplitOptions.RemoveEmptyEntries);
            return parts.Length > 3 ? parts[3] : "";
        }
        // Возвращает число перенесённых строк; -1 — помощник недоступен.
        internal int Pull()
        {
            lock (gate) {
                int version; if (!int.TryParse(helperVersion() ?? "", out version) || version < MinHelperVersion) { State("old-helper", "version", helperVersion() ?? ""); return -1; }
                if (!ready()) { State("not-connected"); return -1; }
                int total = 0;
                try {
                    ulong after = LoadCursor();
                    for (int i = 0; i < Iterations; i++) {
                        var reply = read(after, MaxBytes);
                        ulong next; ulong.TryParse(Json.Str(reply, "next"), NumberStyles.None, CultureInfo.InvariantCulture, out next);
                        ulong lost; ulong.TryParse(Json.Str(reply, "lost"), NumberStyles.None, CultureInfo.InvariantCulture, out lost);
                        if (Json.Bool(reply, "reset")) { log(LogLevel.Warn, "helper.log-reset", new[] { "was", after.ToString(CultureInfo.InvariantCulture), "now", next.ToString(CultureInfo.InvariantCulture) }); after = next; SaveCursor(after); break; }
                        if (lost > 0) log(LogLevel.Warn, "helper.log-lost", new[] { "lines", lost.ToString(CultureInfo.InvariantCulture) });
                        var lines = Json.Strings(Json.Get(reply, "lines"));
                        foreach (string line in lines) { RaLog.AppendLine(logsDir, Component(line) == "core" ? "core" : "helper", line); total++; }
                        if (next > after) { after = next; SaveCursor(after); }
                        if (lines.Length == 0) break;
                    }
                    State("ok");
                } catch (Exception e) { State("error", "err", e.GetType().Name); return total == 0 ? -1 : total; }
                return total;
            }
        }
    }
}
