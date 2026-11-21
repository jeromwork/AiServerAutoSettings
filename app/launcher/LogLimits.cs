using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace RemoteAgents.Launcher
{
    // Ограничения launcher-шума (конституция 4б): повторы схлопываются в счётчик, источник режется по частоте.
    // VPN/сеть/помощник/ядро/конфиг, другие потоки и Warn+ пишутся целиком; архивы чистятся по сроку.
    // Без таймеров: время приходит параметром (RaLog.Clock),
    // «просроченные» счётчики сбрасываются при следующей записи, а не по таймеру.
    internal sealed class LogLimits
    {
        // Только launcher ниже Warn, кроме vpn/net/helper/core/config: одинаковая строка пишется не чаще раза в окно.
        // Warn и ERROR не схлопываются по дедупу и не режутся по EventBurstLines (шум на Warn гасится в источнике:
        // disk.explorer.unavailable пишется только при переходе, см. ExplorerOutage). Остальные повторы считаются и
        // выводятся одной строкой «repeat count=N»; 60 с: повтор раз в 5 с даёт ~12 строк/мин -> 1.
        internal static TimeSpan RepeatWindow = TimeSpan.FromSeconds(60);
        // Не больше стольких строк одного события (поток+компонент+событие) за окно, даже если поля разные. 20/мин
        // на событие держит launcher.log далеко ниже ~1 МБ за 2 минуты; исключения те же, что у RepeatWindow.
        internal static int EventBurstLines = 20;
        // Верхняя граница числа отслеживаемых ключей: при переполнении счётчики сбрасываются (память ограничена).
        internal static int MaxTrackedKeys = 256;
        // Ротированные файлы (*.log.N) старше этого срока удаляются.
        internal static TimeSpan ArchiveMaxAge = TimeSpan.FromDays(14);

        internal struct Summary { internal string Dir, Stream, Component, Event, Reason; internal int Count; }

        sealed class Seen { internal string Dir, Stream, Component, Event; internal DateTimeOffset LastWritten, LastSeen; internal int Suppressed; }
        sealed class Burst { internal string Dir, Stream, Component, Event; internal DateTimeOffset Start; internal int Written, Suppressed; }

        static readonly HashSet<string> UnlimitedComponents = new HashSet<string>(new[] { "vpn", "net", "helper", "core", "config" }, StringComparer.OrdinalIgnoreCase);
        readonly object gate = new object();
        readonly Dictionary<string, Seen> seen = new Dictionary<string, Seen>(StringComparer.Ordinal);
        readonly Dictionary<string, Burst> bursts = new Dictionary<string, Burst>(StringComparer.Ordinal);
        DateTimeOffset lastSweep = DateTimeOffset.MinValue;

        internal static string Key(string dir, string stream, LogLevel level, string comp, string evt, IList<KeyValuePair<string, string>> fields)
        {
            return string.Join("\u0001", new[] { dir ?? "", stream ?? "", level.ToString(), comp ?? "", evt ?? "", fields == null ? "" : string.Join("\u0002", fields.Select(f => f.Key + "\u0003" + f.Value)) });
        }

        // true — строку писать; summaries — счётчики повторов, которые нужно записать перед ней.
        internal bool Allow(string dir, string stream, LogLevel level, string comp, string evt, IList<KeyValuePair<string, string>> fields, DateTimeOffset now, List<Summary> summaries)
        {
            // Никакого дедупа/предела частоты для диагностических потоков и важных событий.
            if (!string.Equals(stream, "launcher", StringComparison.OrdinalIgnoreCase) || level >= LogLevel.Warn ||
                UnlimitedComponents.Contains(comp)) return true;
            lock (gate) {
                Sweep(now, summaries);
                string key = Key(dir, stream, level, comp, evt, fields);
                Seen s;
                if (seen.TryGetValue(key, out s)) {
                    s.LastSeen = now;
                    if (now - s.LastWritten < RepeatWindow && now >= s.LastWritten) { s.Suppressed++; return false; }
                    if (s.Suppressed > 0) { summaries.Add(new Summary { Dir = dir, Stream = stream, Component = comp, Event = evt, Count = s.Suppressed, Reason = "same" }); s.Suppressed = 0; }
                } else {
                    if (seen.Count >= MaxTrackedKeys) FlushAll(summaries);
                    s = new Seen { Dir = dir, Stream = stream, Component = comp, Event = evt, LastSeen = now };
                    seen[key] = s;
                }
                string bkey = (dir ?? "") + "\u0001" + (stream ?? "") + "\u0001" + (comp ?? "") + "\u0001" + (evt ?? "");
                Burst b;
                if (!bursts.TryGetValue(bkey, out b)) { b = new Burst { Dir = dir, Stream = stream, Component = comp, Event = evt, Start = now }; bursts[bkey] = b; }
                if (now - b.Start >= RepeatWindow || now < b.Start) {
                    if (b.Suppressed > 0) summaries.Add(new Summary { Dir = dir, Stream = stream, Component = comp, Event = evt, Count = b.Suppressed, Reason = "rate" });
                    b.Start = now; b.Written = 0; b.Suppressed = 0;
                }
                if (b.Written >= EventBurstLines) { b.Suppressed++; s.LastWritten = now; return false; }
                b.Written++; s.LastWritten = now;
                return true;
            }
        }

        // Просроченные ключи закрываются: счётчик выводится, запись удаляется (не чаще раза в окно).
        void Sweep(DateTimeOffset now, List<Summary> summaries)
        {
            if (now - lastSweep < RepeatWindow && now >= lastSweep) return;
            lastSweep = now;
            foreach (string k in seen.Where(p => now - p.Value.LastSeen >= RepeatWindow || now < p.Value.LastSeen).Select(p => p.Key).ToList()) {
                Seen s = seen[k];
                if (s.Suppressed > 0) summaries.Add(new Summary { Dir = s.Dir, Stream = s.Stream, Component = s.Component, Event = s.Event, Count = s.Suppressed, Reason = "same" });
                seen.Remove(k);
            }
            foreach (string k in bursts.Where(p => now - p.Value.Start >= RepeatWindow || now < p.Value.Start).Select(p => p.Key).ToList()) {
                Burst b = bursts[k];
                if (b.Suppressed > 0) summaries.Add(new Summary { Dir = b.Dir, Stream = b.Stream, Component = b.Component, Event = b.Event, Count = b.Suppressed, Reason = "rate" });
                bursts.Remove(k);
            }
        }

        void FlushAll(List<Summary> summaries)
        {
            foreach (Seen s in seen.Values) if (s.Suppressed > 0) summaries.Add(new Summary { Dir = s.Dir, Stream = s.Stream, Component = s.Component, Event = s.Event, Count = s.Suppressed, Reason = "same" });
            foreach (Burst b in bursts.Values) if (b.Suppressed > 0) summaries.Add(new Summary { Dir = b.Dir, Stream = b.Stream, Component = b.Component, Event = b.Event, Count = b.Suppressed, Reason = "rate" });
            seen.Clear(); bursts.Clear();
        }

        // Для выхода из программы: вывести накопленные счётчики.
        internal List<Summary> Drain() { var list = new List<Summary>(); lock (gate) FlushAll(list); return list; }
        internal int Tracked { get { lock (gate) return seen.Count + bursts.Count; } }

        internal static List<KeyValuePair<string, string>> SummaryFields(Summary s)
        {
            var fields = new List<KeyValuePair<string, string>> {
                new KeyValuePair<string, string>("count", s.Count.ToString(CultureInfo.InvariantCulture)),
                new KeyValuePair<string, string>("of", s.Event ?? ""),
            };
            if (s.Reason == "rate") fields.Add(new KeyValuePair<string, string>("reason", "rate"));
            return fields;
        }

        // Чистка ротированных файлов (*.log.N) только по сроку. Общий размер держит RaLog.EnforceTotal (60 МиБ).
        internal static int PurgeArchives(string dir, DateTimeOffset now)
        {
            int removed = 0;
            try {
                if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return 0;
                var files = new DirectoryInfo(dir).GetFiles("*.log.*").Where(f => Regex.IsMatch(f.Name, @"\.log\.\d+$")).ToList();
                foreach (var f in files)
                    if (now.UtcDateTime - f.LastWriteTimeUtc > ArchiveMaxAge) { try { f.Delete(); removed++; } catch { } }
            } catch { }
            return removed;
        }
    }
}
