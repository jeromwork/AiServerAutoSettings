using System;
using System.Collections.Generic;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace RemoteAgents.Launcher
{
    // Ограничение зеркала core.log, в том числе для уже установленного помощника v15.
    // Одно последнее сообщение (SHA-256), счётчики до 1000/100; нет часов, таймеров и словаря строк.
    internal sealed class CoreJournal
    {
        internal const int CollapseThreshold = 100, NoiseThreshold = 1000;
        static readonly Regex Ansi = new Regex(@"(?:\x1b)?\[[0-9;]*m");
        static readonly Regex Record = new Regex(@"^\S+\s+\S+\s+(DEBUG|INFO|WARN|ERROR)\s+core\s+(\S+)\s+s=(\S+)(.*)$");
        static readonly Regex TextField = new Regex(@"(?:^| )text=(""(?:\\.|[^""\\])*""|[^ ]*)");
        // Внутренние часы sing-box не входят в тождество сообщения. ID соединения сохраняется.
        static readonly Regex Preamble = new Regex(@"^(?:[+-]\d{4}\s+)?(?:\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?\s+)?(DEBUG|INFO|WARN|WARNING|ERROR|FATAL|PANIC)\s+", RegexOptions.IgnoreCase);
        readonly Func<string, bool> sink;
        string lastKey;
        int repeats, noise;
        LogLevel lastLevel;
        internal CoreJournal(Func<string, bool> sink) { this.sink = sink; }

        internal bool Write(string line)
        {
            string clean = Ansi.Replace(line ?? "", "");
            var record = Record.Match(clean);
            if (!record.Success || record.Groups[2].Value != "core.line") {
                if (!Flush()) return false; lastKey = null; return sink(clean);
            }
            var field = TextField.Match(record.Groups[4].Value);
            if (!field.Success) { if (!Flush()) return false; lastKey = null; return sink(clean); }
            string text = field.Groups[1].Value;
            // RaLog использует JSON-совместимые кавычки и экранирование.
            if (text.StartsWith("\"", StringComparison.Ordinal)) {
                try { text = Json.Parse(text) as string ?? text; }
                catch { if (!Flush()) return false; lastKey = null; return sink(clean); }
            }
            var embedded = Preamble.Match(text);
            string level = embedded.Success ? embedded.Groups[1].Value.ToUpperInvariant() : record.Groups[1].Value;
            LogLevel severity = level == "ERROR" || level == "FATAL" || level == "PANIC" ? LogLevel.Error :
                level == "WARN" || level == "WARNING" ? LogLevel.Warn : level == "DEBUG" ? LogLevel.Debug : LogLevel.Info;
            LogLevel outer; if (Enum.TryParse(record.Groups[1].Value, true, out outer) && outer > severity) severity = outer;
            // Главный фактический источник: INFO router: found process path. Ошибки не фильтруются.
            if (embedded.Success && severity <= LogLevel.Info && text.IndexOf("router: found process", StringComparison.OrdinalIgnoreCase) >= 0) {
                if (noise >= NoiseThreshold && !FlushNoise()) return false;
                if (++noise == NoiseThreshold) FlushNoise();
                return true;
            }
            string body = embedded.Success ? text.Substring(embedded.Length) : text;
            string key;
            using (var sha = SHA256.Create())
                key = Convert.ToBase64String(sha.ComputeHash(Encoding.UTF8.GetBytes(record.Groups[3].Value + "\0" + severity + "\0" + body)));
            if (key == lastKey) {
                if (repeats >= CollapseThreshold && !FlushRepeats()) return false;
                if (++repeats == CollapseThreshold) FlushRepeats();
                return true;
            }
            if (!Flush()) return false;
            lastKey = null;
            // Исправляем внешний уровень старого помощника, не меняя UTC, seq и исходный текст.
            int offset = record.Groups[1].Index;
            clean = clean.Substring(0, offset) + severity.ToString().ToUpperInvariant().PadRight(record.Groups[1].Length) + clean.Substring(offset + record.Groups[1].Length);
            if (!sink(clean)) return false;
            lastKey = key; lastLevel = severity;
            return true;
        }
        bool Summary(LogLevel level, string evt, params string[] fields)
        { return sink(RaLog.Format(RaLog.Clock(), level, "core", evt, RaLog.Pairs(fields), RaLog.Session)); }
        bool FlushRepeats()
        {
            if (repeats == 0) return true;
            if (!Summary(lastLevel, "repeat", "of", "core.line", "count", repeats.ToString(CultureInfo.InvariantCulture))) return false;
            repeats = 0; return true;
        }
        bool FlushNoise()
        {
            if (noise == 0) return true;
            if (!Summary(LogLevel.Info, "core.noise-summary", "of", "router.found-process", "suppressed", noise.ToString(CultureInfo.InvariantCulture))) return false;
            noise = 0; return true;
        }
        // Конец полученной пачки/смена сообщения закрывают счётчики; новых периодических задач нет.
        internal bool Flush() { return FlushRepeats() && FlushNoise(); }
        // После ограниченного числа отказов зеркало учитывает незаписанные сводки как lost.
        internal int DiscardPending()
        { int lost = repeats + noise; repeats = noise = 0; lastKey = null; return lost; }
    }
}
