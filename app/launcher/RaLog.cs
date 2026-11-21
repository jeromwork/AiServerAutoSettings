using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace RemoteAgents.Launcher
{
    internal enum LogLevel { Debug, Info, Warn, Error }

    // Единый формат журнала (docs/LOGS.md). Одна строка — одно событие:
    //   <UTC ISO мс Z> <локальное HH:mm:ss.fff+ZZ:ZZ> <УРОВЕНЬ,5> <компонент,9> <событие,14> s=<сессия> k=v ...
    // Запись никогда не выбрасывает исключения наружу.
    internal static class RaLog
    {
        public static readonly string[] Components = { "launcher", "vpn", "helper", "core", "transport", "net", "conflict", "ship", "happier", "config", "disk", "update", "bridge" };
        internal const int MaxLine = 4096;
        // Параметры можно менять в тестах.
        internal static long MaxBytes = 2L * 1024 * 1024;
        internal static int MaxArchives = 5;
        // Отдельные потоки могут хранить меньше архивов (helper-events: 3 по 2 МБ).
        internal static readonly Dictionary<string, int> ArchivesByStream = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        static int ArchivesFor(string stream) { int n; lock (ArchivesByStream) return ArchivesByStream.TryGetValue(stream, out n) ? n : MaxArchives; }
        internal static long TotalLimit = 60L * 1024 * 1024;
        internal static Func<DateTimeOffset> Clock = () => DateTimeOffset.Now;
        // Дедупликация и частота только launcher-шума ниже Warn; VPN/сеть/помощник/ядро/конфиг без ограничений.
        internal static LogLimits Limits = new LogLimits();
        internal static readonly string Session = NewSession();
        static string defaultDir;
        internal static string DefaultDir => defaultDir;
        static readonly Dictionary<string, object> gates = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        static readonly Dictionary<string, int> failures = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        static readonly Random random = new Random(Guid.NewGuid().GetHashCode());
        static readonly Regex EventName = new Regex("^[a-z0-9.-]+$");

        static string NewSession() { return Guid.NewGuid().ToString("N").Substring(0, 4); }

        internal static void Configure(string logsDir) { defaultDir = logsDir; }
        // Известные значения секретов (DiagnosticReport.KnownSecrets) прячутся в каждой записи; задаёт лаунчер.
        internal static Func<IEnumerable<string>> Secrets;
        // Вызывается после записи строки уровня ERROR (лаунчер ускоряет отправку на сервер).
        internal static Action OnError;
        static IEnumerable<string> KnownSecrets() { try { var f = Secrets; return f == null ? null : f().ToArray(); } catch { return null; } }

        // ---- формат (чистая функция) -------------------------------------------------------
        internal static string Format(DateTimeOffset now, LogLevel level, string comp, string evt, IList<KeyValuePair<string, string>> fields, string session)
        {
            var secrets = KnownSecrets();
            var line = new StringBuilder(160);
            line.Append(now.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture)).Append(' ');
            line.Append(now.ToString("HH:mm:ss.fffzzz", CultureInfo.InvariantCulture)).Append(' ');
            line.Append(level.ToString().ToUpperInvariant().PadRight(5)).Append(' ');
            line.Append(SafeName(comp, "launcher").PadRight(9)).Append(' ');
            line.Append(SafeEvent(evt).PadRight(14));
            line.Append(" s=").Append(session);
            if (fields != null)
                foreach (var f in fields) {
                    string key = Regex.Replace(f.Key ?? "", "[^A-Za-z0-9_.-]", "_");
                    if (key.Length == 0 || key == "s") continue;
                    string value = LogMask.IsSecretKey(key) ? "***" : LogMask.Clean(f.Value ?? "", secrets);
                    line.Append(' ').Append(key).Append('=').Append(QuoteValue(value));
                }
            string text = line.ToString();
            if (text.Length > MaxLine) text = text.Substring(0, MaxLine) + "…[cut]";
            return text;
        }

        internal static string SafeEvent(string evt)
        {
            string e = (evt ?? "").ToLowerInvariant();
            e = Regex.Replace(e, "[^a-z0-9.-]", "-");
            return e.Length == 0 ? "event" : e;
        }
        static string SafeName(string value, string fallback)
        {
            string c = Regex.Replace((value ?? "").ToLowerInvariant(), "[^a-z0-9._-]", "-");
            return c.Length == 0 ? fallback : c;
        }

        internal static string QuoteValue(string value)
        {
            bool quote = value.Length == 0 || value.IndexOfAny(new[] { ' ', '"', '=', '\n', '\r', '\t' }) >= 0;
            if (!quote) return value;
            var s = new StringBuilder("\"");
            for (int i = 0; i < value.Length; i++) {
                char c = value[i];
                if (c == '\r') { if (i + 1 < value.Length && value[i + 1] == '\n') continue; s.Append("\\n"); }
                else if (c == '\n') s.Append("\\n");
                else if (c == '\t') s.Append(' ');
                else if (c == '\\') s.Append("\\\\");
                else if (c == '"') s.Append("\\\"");
                else s.Append(c);
            }
            return s.Append('"').ToString();
        }

        internal static List<KeyValuePair<string, string>> Pairs(string[] kv)
        {
            var list = new List<KeyValuePair<string, string>>();
            if (kv == null) return list;
            for (int i = 0; i + 1 < kv.Length; i += 2) list.Add(new KeyValuePair<string, string>(kv[i], kv[i + 1]));
            if (kv.Length % 2 == 1) list.Add(new KeyValuePair<string, string>("msg", kv[kv.Length - 1]));
            return list;
        }

        // ---- запись ---------------------------------------------------------------------------
        internal static void Write(string stream, LogLevel level, string comp, string evt, params string[] kv)
        { WriteTo(defaultDir, stream, level, comp, evt, Pairs(kv)); }

        internal static void Write(string stream, LogLevel level, string comp, string evt, IDictionary<string, string> fields)
        { WriteTo(defaultDir, stream, level, comp, evt, fields == null ? null : fields.ToList()); }

        internal static void WriteTo(string dir, string stream, LogLevel level, string comp, string evt, IList<KeyValuePair<string, string>> fields)
        {
            try {
                if (string.IsNullOrEmpty(dir)) return;
                if (level == LogLevel.Debug && comp == "ship") return; // Отправщик не создаёт себе новые данные.
                var now = Clock(); var repeats = new List<LogLimits.Summary>();
                bool write = Limits.Allow(dir, stream, level, comp, evt, fields, now, repeats);
                WriteRepeats(now, repeats);
                if (write) AppendLine(dir, stream, Format(now, level, comp, evt, fields, Session));
            } catch { /* Журнал не должен ронять работу. */ }
        }

        // При штатном выходе: счётчики всех каталогов, включая явно переданные в WriteTo, до отправки журналов.
        internal static void FlushLimits()
        {
            try { WriteRepeats(Clock(), Limits.Drain()); } catch { /* Журнал не должен ронять завершение. */ }
        }

        static void WriteRepeats(DateTimeOffset now, IEnumerable<LogLimits.Summary> repeats)
        {
            foreach (var r in repeats)
                AppendLine(r.Dir, r.Stream, Format(now, LogLevel.Info, r.Component, "repeat", LogLimits.SummaryFields(r), Session));
        }

        // Строка уже в формате (зеркало журнала помощника, ядра).
        internal static void AppendLine(string dir, string stream, string line)
        {
            string path = Path.Combine(dir, stream + ".log");
            object gate;
            bool firstUse = false;
            lock (gates) { if (!gates.TryGetValue(path, out gate)) { gate = new object(); gates[path] = gate; firstUse = true; } }
            if (firstUse) LogLimits.PurgeArchives(dir, Clock()); // старые архивы чистятся при первой записи потока, а не по таймеру
            lock (gate) {
                Mutex mutex = null; bool held = false;
                try {
                    try { mutex = new Mutex(false, "Local\\RemoteAgents-log-" + stream); held = mutex.WaitOne(200); }
                    catch (AbandonedMutexException) { held = true; }
                    catch { mutex = null; }
                    string pending = "";
                    int failed;
                    if (failures.TryGetValue(path, out failed) && failed > 0)
                        pending = Format(Clock(), LogLevel.Warn, "launcher", "log.write-failed", new[] { new KeyValuePair<string, string>("n", failed.ToString(CultureInfo.InvariantCulture)) }, Session) + "\n";
                    try {
                        System.IO.Directory.CreateDirectory(dir);
                        byte[] body = LineBytes(line);
                        byte[] marker = pending.Length == 0 ? new byte[0] : LineBytes(pending);
                        byte[] bytes = new byte[marker.Length + body.Length];
                        Buffer.BlockCopy(marker, 0, bytes, 0, marker.Length);
                        Buffer.BlockCopy(body, 0, bytes, marker.Length, body.Length);
                        if (bytes.Length + 3 > MaxBytes) bytes = body;
                        // Резервируем BOM до ротации: каждый из шести файлов строго <= MaxBytes.
                        // Если ротация недоступна, рост запрещён; следующая успешная запись сообщит log.write-failed.
                        Rotate(path, bytes.Length + 3);
                        bool fresh = !File.Exists(path) || new FileInfo(path).Length == 0;
                        using (var f = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete)) {
                            if (fresh) f.Write(new byte[] { 0xEF, 0xBB, 0xBF }, 0, 3);
                            f.Write(bytes, 0, bytes.Length);
                        }
                        failures[path] = 0;
                        if (OnError != null && line.IndexOf(" ERROR ", StringComparison.Ordinal) is int e && e > 0 && e < 60) try { OnError(); } catch { }
                    } catch { failures[path] = failures.TryGetValue(path, out failed) ? failed + 1 : 1; }
                } finally {
                    if (mutex != null) { try { if (held) mutex.ReleaseMutex(); } catch { } mutex.Dispose(); }
                }
            }
        }

        static byte[] LineBytes(string line)
        {
            // Внешние журналы тоже ограничены; сравнение повторов происходит до этого обрезания.
            string safe = Regex.Replace(line ?? "", @"[\x00-\x1F\x7F]", "");
            int budget = (int)Math.Min(8192, MaxBytes - 3);
            byte[] suffix = Encoding.UTF8.GetBytes("…[cut]");
            if (budget <= suffix.Length + 1) throw new IOException("Log size limit is too small");
            // Не выделяем массив пропорционально произвольно длинной внешней строке.
            if (safe.Length > budget) safe = safe.Substring(0, budget);
            byte[] bytes = Encoding.UTF8.GetBytes(safe + "\n");
            if (bytes.Length <= budget) return bytes;
            int end = budget - suffix.Length - 1;
            while (end > 0 && (bytes[end] & 0xC0) == 0x80) end--;
            var result = new byte[end + suffix.Length + 1];
            Buffer.BlockCopy(bytes, 0, result, 0, end);
            Buffer.BlockCopy(suffix, 0, result, end, suffix.Length);
            result[result.Length - 1] = 10;
            return result;
        }

        static void Rotate(string path, int incoming)
        {
            if (!File.Exists(path) || new FileInfo(path).Length + incoming <= MaxBytes) return;
            int archives = ArchivesFor(Path.GetFileNameWithoutExtension(path));
            string oldest = path + "." + archives.ToString(CultureInfo.InvariantCulture);
            if (File.Exists(oldest)) File.Delete(oldest);
            for (int i = archives - 1; i >= 1; i--) {
                string from = path + "." + i.ToString(CultureInfo.InvariantCulture), to = path + "." + (i + 1).ToString(CultureInfo.InvariantCulture);
                if (File.Exists(from)) File.Move(from, to);
            }
            File.Move(path, path + ".1");
            LogLimits.PurgeArchives(Path.GetDirectoryName(path), Clock());
            EnforceTotal(Path.GetDirectoryName(path));
        }

        static void EnforceTotal(string dir)
        {
            try {
                var files = new DirectoryInfo(dir).GetFiles("*.log*").ToList();
                long total = files.Sum(f => f.Length);
                if (total <= TotalLimit) return;
                // Сначала самые старые архивы: .5, потом .4 ...
                foreach (var f in files.Select(x => new { x, n = ArchiveNumber(x.Name) }).Where(x => x.n > 0).OrderByDescending(x => x.n).ThenBy(x => x.x.LastWriteTimeUtc)) {
                    if (total <= TotalLimit) break;
                    try { total -= f.x.Length; f.x.Delete(); } catch { }
                }
            } catch { }
        }
        static int ArchiveNumber(string name)
        {
            var m = Regex.Match(name, @"\.log\.(\d+)$");
            return m.Success ? int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture) : 0;
        }

        // Для тестов и читателей: имена файлов потока от самого старого к самому новому.
        internal static string[] StreamFiles(string dir, string stream)
        {
            var list = new List<string>();
            string path = Path.Combine(dir, stream + ".log");
            for (int i = ArchivesFor(stream); i >= 1; i--) { string a = path + "." + i.ToString(CultureInfo.InvariantCulture); if (File.Exists(a)) list.Add(a); }
            if (File.Exists(path)) list.Add(path);
            return list.ToArray();
        }

        internal static bool ValidEvent(string evt) { return evt != null && EventName.IsMatch(evt); }

        // Идентификатор попытки: on-HHmmss-xx.
        internal static class Attempt
        {
            internal static string New(string prefix)
            {
                int n; lock (random) n = random.Next(256);
                return (prefix ?? "a") + "-" + Clock().UtcDateTime.ToString("HHmmss", CultureInfo.InvariantCulture) + "-" + n.ToString("x2", CultureInfo.InvariantCulture);
            }
        }
    }
}
