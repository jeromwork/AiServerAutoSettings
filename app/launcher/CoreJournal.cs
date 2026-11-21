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
        readonly Action<string> sink;
        string lastKey;
        int repeats, noise;
        LogLevel lastLevel;
        internal CoreJournal(Action<string> sink) { this.sink = sink; }

        internal void Write(string line)
        {
            string clean = Ansi.Replace(line ?? "", "");
            var record = Record.Match(clean);
            if (!record.Success || record.Groups[2].Value != "core.line") {
                Flush(); lastKey = null; sink(clean); return;
            }
            var field = TextField.Match(record.Groups[4].Value);
            if (!field.Success) { Flush(); lastKey = null; sink(clean); return; }
            string text = field.Groups[1].Value;
            // RaLog использует JSON-совместимые кавычки и экранирование.
            if (text.StartsWith("\"", StringComparison.Ordinal)) {
                try { text = Json.Parse(text) as string ?? text; }
                catch { Flush(); lastKey = null; sink(clean); return; }
            }
            var embedded = Preamble.Match(text);
            string level = embedded.Success ? embedded.Groups[1].Value.ToUpperInvariant() : record.Groups[1].Value;
            LogLevel severity = level == "ERROR" || level == "FATAL" || level == "PANIC" ? LogLevel.Error :
                level == "WARN" || level == "WARNING" ? LogLevel.Warn : level == "DEBUG" ? LogLevel.Debug : LogLevel.Info;
            LogLevel outer; if (Enum.TryParse(record.Groups[1].Value, true, out outer) && outer > severity) severity = outer;
            // Главный фактический источник: INFO router: found process path. Ошибки не фильтруются.
            if (embedded.Success && severity <= LogLevel.Info && text.IndexOf("router: found process", StringComparison.OrdinalIgnoreCase) >= 0) {
                if (++noise == NoiseThreshold) FlushNoise();
                return;
            }
            string body = embedded.Success ? text.Substring(embedded.Length) : text;
            string key;
            using (var sha = SHA256.Create())
                key = Convert.ToBase64String(sha.ComputeHash(Encoding.UTF8.GetBytes(record.Groups[3].Value + "\0" + severity + "\0" + body)));
            if (key == lastKey) {
                if (++repeats == CollapseThreshold) FlushRepeats();
                return;
            }
            Flush(); lastKey = key; lastLevel = severity;
            // Исправляем внешний уровень старого помощника, не меняя UTC, seq и исходный текст.
            int offset = record.Groups[1].Index;
            clean = clean.Substring(0, offset) + severity.ToString().ToUpperInvariant().PadRight(record.Groups[1].Length) + clean.Substring(offset + record.Groups[1].Length);
            sink(clean);
        }
        void Summary(LogLevel level, string evt, params string[] fields)
        { sink(RaLog.Format(RaLog.Clock(), level, "core", evt, RaLog.Pairs(fields), RaLog.Session)); }
        void FlushRepeats()
        {
            if (repeats == 0) return;
            Summary(lastLevel, "repeat", "of", "core.line", "count", repeats.ToString(CultureInfo.InvariantCulture));
            repeats = 0;
        }
        void FlushNoise()
        {
            if (noise == 0) return;
            Summary(LogLevel.Info, "core.noise-summary", "of", "router.found-process", "suppressed", noise.ToString(CultureInfo.InvariantCulture));
            noise = 0;
        }
        // Конец полученной пачки/смена сообщения закрывают счётчики; новых периодических задач нет.
        internal void Flush() { FlushRepeats(); FlushNoise(); }
    }
}
