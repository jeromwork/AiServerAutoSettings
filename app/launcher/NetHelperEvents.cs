using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

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
        // helper-events целиком обходит LogLimits: выделенный seq не теряется из-за дедупа/частоты.
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
            internal bool Reset; // курсор больше последнего seq: журнал пересоздан
        }
        // Строки с seq > after, не больше max байт (с запасом на экранирование JSON).
        internal Page Read(ulong after, int max)
        {
            if (max <= 0 || max > MaxRead) max = MaxRead;
            var page = new Page { Next = after };
            lock (gate) { if (after > seq) { page.Next = seq; page.Reset = true; return page; } }
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
            return sb.Append("],\"next\":").Append(page.Next.ToString(CultureInfo.InvariantCulture)).Append(",\"lost\":").Append(page.Lost.ToString(CultureInfo.InvariantCulture)).Append(",\"reset\":").Append(page.Reset ? "true" : "false").Append('}').ToString();
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

    // Доступ службы к шине событий. Шина помощника (B3) при создании ставит сюда свой EventBus;
    // пока она не подключена, Bus == null и публикации молча пропускаются (журнал helper-events пишется как раньше).
    internal static class HelperBus
    {
        internal static volatile EventBus Bus;
        internal static void Publish(string topic, params string[] kv)
        {
            try { var bus = Bus; if (bus != null) bus.Publish(topic, BusTopics.Sources.VpnCore, kv); } catch { }
        }
    }

    // Читает вывод ядра из pipe в отдельной нити: ReadFile блокируется до появления данных, опроса нет.
    // Нить только читает, дописывает vpn-core.log, режет строки и публикует события; любая ошибка разбора
    // не останавливает чтение (иначе ядро зависнет на записи в полный pipe).
    internal sealed class CoreOutputReader
    {
        internal const int QueueLimit = 2000, RingLines = 40, MaxLineChars = 1000;
        internal const long RotateBytes = 5L * 1024 * 1024;
        readonly long rotateBytes;
        bool rotateFailed, writesStopped;
        readonly Stream input;
        readonly string filePath, core;
        readonly Action<string, string[]> publish;
        readonly ConcurrentQueue<string> queue = new ConcurrentQueue<string>();
        readonly Queue<string> ring = new Queue<string>();
        readonly object ringGate = new object();
        readonly ManualResetEvent ready = new ManualResetEvent(false), eof = new ManualResetEvent(false);
        long lines, sent, dropped, queued;
        int statsWritten;
        volatile string readyLine = "", lastFatal = "";
        FileStream file;
        Thread thread;

        internal CoreOutputReader(Stream input, string filePath, string core, Action<string, string[]> publish, long rotateBytes = RotateBytes)
        {
            this.rotateBytes = rotateBytes;
            this.input = input; this.filePath = filePath; this.core = core ?? "vpn"; this.publish = publish ?? ((t, kv) => { });
        }
        internal WaitHandle Ready { get { return ready; } }
        internal WaitHandle Eof { get { return eof; } }
        internal string ReadyLine { get { return readyLine; } }
        internal string LastFatal { get { return lastFatal; } }
        internal long Lines { get { return Interlocked.Read(ref lines); } }
        internal long Sent { get { return Interlocked.Read(ref sent); } }
        internal long Dropped { get { return Interlocked.Read(ref dropped); } }

        internal void Start()
        {
            thread = new Thread(Run) { IsBackground = true, Name = "core-output" };
            thread.Start();
        }
        // Для тестов: дождаться конца потока.
        internal bool Join(int ms) { var t = thread; return t == null || t.Join(ms); }

        void Run()
        {
            var buffer = new byte[16 * 1024];
            var pending = new MemoryStream();
            try {
                while (true) {
                    int read;
                    try { read = input.Read(buffer, 0, buffer.Length); } catch { break; }
                    if (read <= 0) break;
                    try {
                        AppendFile(buffer, read);
                        for (int i = 0; i < read; i++) {
                            if (buffer[i] != 10) { pending.WriteByte(buffer[i]); if (pending.Length > 64 * 1024) { Line(pending); } continue; }
                            Line(pending);
                        }
                    } catch { pending.SetLength(0); }
                }
                try { if (pending.Length > 0) Line(pending); } catch { }
            } finally {
                try { if (file != null) file.Dispose(); } catch { }
                try { input.Dispose(); } catch { }
                eof.Set();
            }
        }
        void AppendFile(byte[] data, int count)
        {
            if (writesStopped) return;
            try {
                if (file != null && file.Length > rotateBytes) {
                    file.Dispose(); file = null;
                    if (!rotateFailed) {
                        try { if (File.Exists(filePath + ".1")) File.Delete(filePath + ".1"); File.Move(filePath, filePath + ".1"); }
                        catch {
                            // Один раз: запись в шину; дальше при переполнении файл просто усекается, без повторных Move.
                            rotateFailed = true;
                            try { publish(BusTopics.SingboxLine, new[] { "core", core, "line", "WARN vpn-core.log: rotation failed, file will be truncated at the limit" }); } catch { }
                        }
                    }
                    if (rotateFailed) {
                        // Усечение; если и оно не удалось, ниже file == null и запись пропускается (рост ограничен).
                        try { using (new FileStream(filePath, FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete)) { } }
                        catch { writesStopped = true; return; }
                    }
                }
                if (file == null && filePath != null) file = new FileStream(filePath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
                if (file != null) { file.Write(data, 0, count); file.Flush(); }
            } catch { try { if (file != null) file.Dispose(); } catch { } file = null; }
        }
        void Line(MemoryStream pending)
        {
            string text = Encoding.UTF8.GetString(pending.GetBuffer(), 0, (int)pending.Length).TrimEnd('\r');
            pending.SetLength(0);
            if (text.Trim().Length == 0) return;
            Interlocked.Increment(ref lines);
            string clean = LogMask.Clean(text);
            if (clean.Length > MaxLineChars) clean = clean.Substring(0, MaxLineChars);
            lock (ringGate) { ring.Enqueue(clean); while (ring.Count > RingLines) ring.Dequeue(); }
            if (text.IndexOf("sing-box started (", StringComparison.Ordinal) >= 0) {
                bool first = !ready.WaitOne(0);
                readyLine = clean; ready.Set();
                if (first) publish(BusTopics.SingboxStarted, new[] { "core", core, "line", clean });
            }
            if (Regex.IsMatch(text, @"\b(FATAL|PANIC)\b")) {
                lastFatal = clean.Length > 500 ? clean.Substring(0, 500) : clean;
                publish(BusTopics.SingboxFatal, new[] { "core", core, "line", clean });
            }
            if (!ShouldSend(text)) return;
            if (Interlocked.Read(ref queued) >= QueueLimit) { Interlocked.Increment(ref dropped); return; }
            queue.Enqueue(clean); Interlocked.Increment(ref queued); Interlocked.Increment(ref sent);
        }
        // WARN/ERROR/FATAL/PANIC — всегда; INFO — только служебные строки. Остальное остаётся лишь в vpn-core.log.
        internal static bool ShouldSend(string line)
        {
            var level = CoreLogPump.LevelOf(line);
            if (level != LogLevel.Info) return true;
            foreach (var noisy in new[] { "inbound connection", "outbound connection", "connection to", "dns:" })
                if (line.IndexOf(noisy, StringComparison.Ordinal) >= 0) return false;
            foreach (var keep in new[] { "sing-box started", "started at", "updated default interface", "updated available networks", "restful api", "network:", "router:" })
                if (line.IndexOf(keep, StringComparison.Ordinal) >= 0) return true;
            return false;
        }
        // Из цикла monitor: переносит накопленные строки в helper-events (core.line) и шину (singbox.line).
        internal int Drain(HelperEventLog events, int max = 500)
        {
            int count = 0; string line;
            while (count < max && queue.TryDequeue(out line)) {
                Interlocked.Decrement(ref queued); count++;
                try { if (events != null) events.Write(CoreLogPump.LevelOf(line), "core", "core.line", "text", line); } catch { }
                publish(BusTopics.SingboxLine, new[] { "core", core, "line", line });
            }
            return count;
        }
        // Один раз за запуск ядра: итоговый счётчик строк.
        internal void WriteStats(HelperEventLog events)
        {
            if (Interlocked.Exchange(ref statsWritten, 1) != 0) return;
            long total = Lines, s = Sent, d = Dropped;
            try { if (events != null) events.Write(LogLevel.Info, "core", "core.stats", "lines", total.ToString(CultureInfo.InvariantCulture), "sent", s.ToString(CultureInfo.InvariantCulture), "dropped", d.ToString(CultureInfo.InvariantCulture), "filtered", Math.Max(0, total - s - d).ToString(CultureInfo.InvariantCulture)); } catch { }
        }
        internal string Tail(int count)
        {
            lock (ringGate) { var all = ring.ToArray(); return string.Join("\n", all.Skip(Math.Max(0, all.Length - count))); }
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
        // Шина службы (шаг B3): каждая строка ядра VPN уходит как singbox.line {core=vpn, level, line}.
        internal EventBus Bus;
        internal CoreLogPump(string directory, HelperEventLog events)
        {
            dir = directory; this.events = events;
            try { string path = Path.Combine(dir, FileName); offset = File.Exists(path) ? new FileInfo(path).Length : 0; } catch { }
        }
        internal string FilePath { get { return Path.Combine(dir, FileName); } }
        // Читатель вывода текущего ядра VPN (событийный путь). Пока он задан, файл построчно не перечитывается: Pump() — только для тестов.
        internal volatile CoreOutputReader Reader;
        internal void Flush() { var reader = Reader; if (reader != null) reader.Drain(events); }

        // Перед (пере)запуском ядра: файл больше 5 МБ уходит в .1, прежний .1 заменяется.
        internal void RotateIfLarge(long limit = 5L * 1024 * 1024)
        {
            lock (gate) {
                try {
                    string path = FilePath;
                    if (File.Exists(path) && new FileInfo(path).Length > limit) {
                        if (Reader == null) Pump();
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
                            if (line.Trim().Length > 0) {
                                var level = Level(line);
                                events.Write(level, "core", "core.line", "text", line); count++;
                                var bus = Bus; if (bus != null) bus.Publish(BusTopics.SingboxLine, BusTopics.Sources.VpnCore, "core", "vpn", "level", level.ToString().ToLowerInvariant(), "line", line);
                            }
                        }
                        if (start == 0 && read == buffer.Length && read > 0) start = read; // строка без конца длиннее буфера
                        offset += start; // неполная последняя строка дочитывается в следующий раз
                    }
                } catch { }
                return count;
            }
        }
        internal static LogLevel LevelOf(string line) { return Level(line); }
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
