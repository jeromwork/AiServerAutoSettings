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
        internal static long TotalLimit = 60L * 1024 * 1024;
        internal static Func<DateTimeOffset> Clock = () => DateTimeOffset.Now;
        internal static readonly string Session = NewSession();
        static string defaultDir;
        static readonly Dictionary<string, object> gates = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        static readonly Dictionary<string, int> failures = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        static readonly Random random = new Random(Guid.NewGuid().GetHashCode());
        static readonly Regex EventName = new Regex("^[a-z0-9.-]+$");

        static string NewSession() { return Guid.NewGuid().ToString("N").Substring(0, 4); }

        internal static void Configure(string logsDir) { defaultDir = logsDir; }

        // ---- формат (чистая функция) -------------------------------------------------------
        internal static string Format(DateTimeOffset now, LogLevel level, string comp, string evt, IList<KeyValuePair<string, string>> fields, string session)
        {
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
                    string value = LogMask.IsSecretKey(key) ? "***" : LogMask.Clean(f.Value ?? "");
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
                AppendLine(dir, stream, Format(Clock(), level, comp, evt, fields, Session));
            } catch { /* Журнал не должен ронять работу. */ }
        }

        // Строка уже в формате (зеркало журнала помощника, ядра).
        internal static void AppendLine(string dir, string stream, string line)
        {
            string path = Path.Combine(dir, stream + ".log");
            object gate;
            lock (gates) { if (!gates.TryGetValue(path, out gate)) { gate = new object(); gates[path] = gate; } }
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
                        string text = pending + line + "\n";
                        byte[] bytes = new UTF8Encoding(false).GetBytes(text);
                        Rotate(path, bytes.Length);
                        bool fresh = !File.Exists(path) || new FileInfo(path).Length == 0;
                        using (var f = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete)) {
                            if (fresh) f.Write(new byte[] { 0xEF, 0xBB, 0xBF }, 0, 3);
                            f.Write(bytes, 0, bytes.Length);
                        }
                        failures[path] = 0;
                    } catch { failures[path] = failures.TryGetValue(path, out failed) ? failed + 1 : 1; }
                } finally {
                    if (mutex != null) { try { if (held) mutex.ReleaseMutex(); } catch { } mutex.Dispose(); }
                }
            }
        }

        static void Rotate(string path, int incoming)
        {
            if (!File.Exists(path) || new FileInfo(path).Length + incoming <= MaxBytes) return;
            string oldest = path + "." + MaxArchives.ToString(CultureInfo.InvariantCulture);
            if (File.Exists(oldest)) File.Delete(oldest);
            for (int i = MaxArchives - 1; i >= 1; i--) {
                string from = path + "." + i.ToString(CultureInfo.InvariantCulture), to = path + "." + (i + 1).ToString(CultureInfo.InvariantCulture);
                if (File.Exists(from)) File.Move(from, to);
            }
            File.Move(path, path + ".1");
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
            for (int i = MaxArchives; i >= 1; i--) { string a = path + "." + i.ToString(CultureInfo.InvariantCulture); if (File.Exists(a)) list.Add(a); }
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
