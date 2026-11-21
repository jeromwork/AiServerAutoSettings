using System;
using System.Collections.Generic;
using System.Linq;

namespace RemoteAgents.Launcher
{
    // Доска готовности (шаг H1): чистая логика без шины, окна и времени; события подаются снаружи.
    // Набор ожидаемых блоков = блоки, работавшие до обновления. Последний отчитавшийся блок даёт приёмку сразу.
    internal sealed class HealthBoard
    {
        // Предохранитель (конституция 4а): событие «последний ожидаемый блок отчитался» недоступно, если от последнего события готовности прошло 5 минут;
        // при срабатывании — откат, успех не объявляет. Повторы и деградация не продлевают предохранитель.
        internal const int UpdateNoProgressFuseMs = 300000;

        // В плане блок «bridge» — это компонент control бандла; имена приводятся к одному виду.
        internal static string Normalize(string block) { return string.Equals(block, "bridge", StringComparison.OrdinalIgnoreCase) ? "control" : (block ?? "").Trim(); }

        // Блоки, работавшие до обновления: tray и transport всегда, остальные (disk, control=bridge, vpn) — из update-state.json.
        internal static string[] ExpectedBlocks(Dictionary<string, object> state)
        {
            var set = new List<string> { "tray", "transport" };
            set.AddRange(Json.Strings(Json.Get(state, "runningComponents")));
            if (Json.Bool(state, "vpnOn")) set.Add("vpn");
            return set.Select(Normalize).Where(x => x.Length > 0).Distinct(StringComparer.Ordinal).ToArray();
        }

        readonly object gate = new object();
        readonly HashSet<string> expected = new HashSet<string>(StringComparer.Ordinal);
        readonly HashSet<string> reported = new HashSet<string>(StringComparer.Ordinal);
        readonly HashSet<string> critical;
        readonly Dictionary<string, int> exits = new Dictionary<string, int>(StringComparer.Ordinal);
        bool accepted; string failure = ""; DateTime lastEventUtc;

        internal HealthBoard(IEnumerable<string> expectedBlocks, DateTime nowUtc, IEnumerable<string> criticalBlocks = null)
        {
            foreach (var b in expectedBlocks ?? new string[0]) { string n = Normalize(b); if (n.Length > 0) expected.Add(n); }
            critical = new HashSet<string>((criticalBlocks ?? new string[0]).Select(Normalize), StringComparer.Ordinal);
            lastEventUtc = nowUtc;
        }

        internal bool Accepted { get { lock (gate) return accepted; } }
        internal string Failure { get { lock (gate) return failure; } }
        internal DateTime LastEventUtc { get { lock (gate) return lastEventUtc; } }
        internal string[] Expected { get { lock (gate) return expected.OrderBy(x => x, StringComparer.Ordinal).ToArray(); } }
        internal string[] Missing { get { lock (gate) return expected.Where(x => !reported.Contains(x)).OrderBy(x => x, StringComparer.Ordinal).ToArray(); } }

        // Результат отчёта: Counted — блок ожидаемый и теперь отмечен; Completed — этим событием набор стал полным (true ровно один раз).
        internal struct Result { internal bool Counted, Completed; }

        // block.ready: блок отмечен. Блок вне набора не влияет. После приёмки события игнорируются (повтор не даёт второго accepted).
        internal Result Ready(string block, DateTime nowUtc)
        { return Report(block, nowUtc, true); }
        Result Report(string block, DateTime nowUtc, bool ready)
        {
            lock (gate) {
                var r = new Result(); string n = Normalize(block);
                if (accepted || failure.Length > 0) return r;
                if (ready) exits.Remove(n);
                if (!expected.Contains(n)) return r;
                if (!reported.Add(n)) return r;
                lastEventUtc = nowUtc; r.Counted = true;
                if (reported.Count == expected.Count) { accepted = true; r.Completed = true; }
                return r;
            }
        }

        // block.degraded: «нет сети» (Р8) засчитывается как отчёт блока; иная деградация снимает отметку блока.
        internal Result Degraded(string block, string reason, DateTime nowUtc)
        {
            if (string.Equals((reason ?? "").Trim(), "no-network", StringComparison.OrdinalIgnoreCase)) return Report(block, nowUtc, false);
            lock (gate) {
                var r = new Result(); string n = Normalize(block);
                if (accepted || failure.Length > 0 || !expected.Contains(n)) return r;
                reported.Remove(n);
                return r;
            }
        }

        // Три выхода одного критичного блока без block.ready между ними — терминальный отказ.
        internal bool ComponentExit(string block)
        {
            lock (gate) {
                string n = Normalize(block); if (accepted || failure.Length > 0 || !critical.Contains(n)) return false;
                reported.Remove(n); int count; exits.TryGetValue(n, out count); exits[n] = ++count;
                if (count < 3) return false;
                failure = "crash-loop:" + n; return true;
            }
        }
        internal bool Fail(string reason)
        { lock (gate) { if (accepted || failure.Length > 0) return false; failure = reason; return true; } }

        // Чистая проверка срока предохранителя: часы подаёт вызывающий; никаких таймеров здесь нет.
        internal bool FuseExpired(DateTime nowUtc)
        { lock (gate) return !accepted && failure.Length == 0 && (nowUtc - lastEventUtc).TotalMilliseconds >= UpdateNoProgressFuseMs; }
    }
}
