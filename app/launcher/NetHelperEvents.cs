using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace RemoteAgents.Launcher
{
    // Журнал помощника в едином формате (helper-events.log) со сквозным номером seq и выдача
    // его по команде log.read. Каталог ProgramData недоступен пользователю, поэтому строки
    // уходят через pipe уже замаскированными. Чистый код: тестируется без службы.
    internal sealed class HelperEventLog
    {
        internal const string Stream = "helper-events";
        internal const int MaxRead = 40000;
        static readonly Regex SeqField = new Regex(@"\sseq=(\d+)(?:\s|$)");
        readonly string dir;
        readonly object gate = new object();
        ulong seq;

        internal HelperEventLog(string directory)
        {
            dir = directory;
            lock (RaLog.ArchivesByStream) RaLog.ArchivesByStream[Stream] = 3;
            seq = RecoverLast();
        }
        internal ulong Last { get { lock (gate) return seq; } }

        ulong RecoverLast()
        {
            foreach (string file in RaLog.StreamFiles(dir, Stream).Reverse()) {
                ulong last = 0;
                try { foreach (string line in ReadTail(file, 64 * 1024)) { ulong n = SeqOf(line); if (n > last) last = n; } } catch { }
                if (last > 0) return last;
            }
            return 0;
        }
        static IEnumerable<string> ReadTail(string file, int bytes)
        {
            using (var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                if (stream.Length > bytes) stream.Seek(-bytes, SeekOrigin.End);
                using (var reader = new StreamReader(stream, new UTF8Encoding(false), true)) {
                    var lines = new List<string>(); string line;
                    while ((line = reader.ReadLine()) != null) lines.Add(line);
                    return lines;
                }
            }
        }
        internal static ulong SeqOf(string line)
        {
            var m = SeqField.Match(line ?? "");
            ulong n;
            return m.Success && ulong.TryParse(m.Groups[1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out n) ? n : 0;
        }

        // seq стоит первым среди полей: так его находит разбор даже при длинных значениях.
        internal ulong Write(LogLevel level, string comp, string evt, params string[] kv)
        {
            lock (gate) {
                seq++;
                var fields = new List<KeyValuePair<string, string>> { new KeyValuePair<string, string>("seq", seq.ToString(CultureInfo.InvariantCulture)) };
                fields.AddRange(RaLog.Pairs(kv));
                RaLog.WriteTo(dir, Stream, level, comp, evt, fields);
                return seq;
            }
        }

        internal sealed class Page
        {
            internal readonly List<string> Lines = new List<string>();
            internal ulong Next, Lost;
        }
        // Строки с seq > after, не больше max байт (с запасом на экранирование JSON).
        internal Page Read(ulong after, int max)
        {
            if (max <= 0 || max > MaxRead) max = MaxRead;
            var page = new Page { Next = after };
            var found = new List<KeyValuePair<ulong, string>>();
            string[] files = RaLog.StreamFiles(dir, Stream);
            lock (gate) {
                for (int i = files.Length - 1; i >= 0; i--) {
                    ulong min = ulong.MaxValue; var chunk = new List<KeyValuePair<ulong, string>>();
                    try {
                        using (var stream = new FileStream(files[i], FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                        using (var reader = new StreamReader(stream, new UTF8Encoding(false), true)) {
                            string line;
                            while ((line = reader.ReadLine()) != null) {
                                ulong n = SeqOf(line); if (n == 0) continue;
                                if (n < min) min = n;
                                if (n > after) chunk.Add(new KeyValuePair<ulong, string>(n, line));
                            }
                        }
                    } catch { }
                    found.InsertRange(0, chunk);
                    if (min <= after + 1) break; // граница курсора внутри этого файла
                }
            }
            found.Sort((a, b) => a.Key.CompareTo(b.Key));
            if (found.Count > 0 && found[0].Key > after + 1) page.Lost = found[0].Key - after - 1;
            int budget = 0;
            foreach (var item in found) {
                int cost = Encoding.UTF8.GetByteCount(item.Value) + 5 * item.Value.Count(c => c == '"' || c == '\\' || c == '<' || c == '>' || c == '\'' || c == '&') + 4;
                if (page.Lines.Count > 0 && budget + cost > max) break;
                page.Lines.Add(item.Value); budget += cost; page.Next = item.Key;
            }
            if (page.Lines.Count == 0 && found.Count == 0) page.Next = after;
            return page;
        }

        internal static string Reply(Page page, string helperVersion)
        {
            var sb = new StringBuilder("{\"ok\":true,\"state\":\"ready\",\"helperVersion\":\"" + helperVersion + "\",\"lines\":[");
            for (int i = 0; i < page.Lines.Count; i++) { if (i > 0) sb.Append(','); sb.Append(JsonString(page.Lines[i])); }
            return sb.Append("],\"next\":").Append(page.Next.ToString(CultureInfo.InvariantCulture)).Append(",\"lost\":").Append(page.Lost.ToString(CultureInfo.InvariantCulture)).Append('}').ToString();
        }
        static string JsonString(string text)
        {
            var sb = new StringBuilder("\"");
            foreach (char c in text) {
                if (c == '"') sb.Append("\\\""); else if (c == '\\') sb.Append("\\\\");
                else if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                else sb.Append(c);
            }
            return sb.Append('"').ToString();
        }
    }

    // Строки vpn-core.log (вывод sing-box) переносятся в helper-events как core.line со своим seq.
    internal sealed class CoreLogPump
    {
        internal const string FileName = "vpn-core.log";
        readonly string dir;
        readonly HelperEventLog events;
        readonly object gate = new object();
        long offset;
        internal CoreLogPump(string directory, HelperEventLog events)
        {
            dir = directory; this.events = events;
            try { string path = Path.Combine(dir, FileName); offset = File.Exists(path) ? new FileInfo(path).Length : 0; } catch { }
        }
        internal string FilePath { get { return Path.Combine(dir, FileName); } }

        // Перед (пере)запуском ядра: файл больше 5 МБ уходит в .1, прежний .1 заменяется.
        internal void RotateIfLarge(long limit = 5L * 1024 * 1024)
        {
            lock (gate) {
                try {
                    string path = FilePath;
                    if (File.Exists(path) && new FileInfo(path).Length > limit) {
                        Pump();
                        if (File.Exists(path + ".1")) File.Delete(path + ".1");
                        File.Move(path, path + ".1"); offset = 0;
                    }
                } catch { }
            }
        }
        // Читает новые строки (до 200 за вызов). Возвращает число перенесённых строк.
        internal int Pump()
        {
            lock (gate) {
                int count = 0;
                try {
                    string path = FilePath;
                    if (!File.Exists(path)) return 0;
                    using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                        if (stream.Length < offset) offset = 0; // файл заменён или усечён
                        stream.Seek(offset, SeekOrigin.Begin);
                        var buffer = new byte[Math.Min(stream.Length - offset, 256 * 1024)];
                        int read = stream.Read(buffer, 0, buffer.Length);
                        int start = 0;
                        for (int i = 0; i < read && count < 200; i++) {
                            if (buffer[i] != 10) continue;
                            string line = Encoding.UTF8.GetString(buffer, start, i - start).TrimEnd('\r');
                            start = i + 1;
                            if (line.Trim().Length > 0) { events.Write(Level(line), "core", "core.line", "text", line); count++; }
                        }
                        if (start == 0 && read == buffer.Length && read > 0) start = read; // строка без конца длиннее буфера
                        offset += start; // неполная последняя строка дочитывается в следующий раз
                    }
                } catch { }
                return count;
            }
        }
        static LogLevel Level(string line)
        {
            return Regex.IsMatch(line, @"\b(FATAL|PANIC)\b") ? LogLevel.Error : Regex.IsMatch(line, @"\bERROR\b") ? LogLevel.Error : Regex.IsMatch(line, @"\bWARN\b") ? LogLevel.Warn : LogLevel.Info;
        }
        // Последние строки файла (уже замаскированные) для core.exit.
        internal string Tail(int lines)
        {
            try {
                string path = FilePath;
                if (!File.Exists(path)) return "";
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                    if (stream.Length > 16 * 1024) stream.Seek(-16 * 1024, SeekOrigin.End);
                    using (var reader = new StreamReader(stream, new UTF8Encoding(false), true)) {
                        var all = reader.ReadToEnd().Replace("\r", "").Split('\n').Where(l => l.Trim().Length > 0).ToArray();
                        return LogMask.Clean(string.Join("\n", all.Skip(Math.Max(0, all.Length - lines))));
                    }
                }
            } catch { return ""; }
        }
    }
}
