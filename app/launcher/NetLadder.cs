using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace RemoteAgents.Launcher
{
    // Сквозная проверка «ступенями»: диагноз — первая упавшая ступень (docs/LOGS.md).
    //  1 local-net  2 conflict  3 transport  4 ports  5 banner  6 route  7 dns  8 http  9 egress (только сведения)
    internal sealed class StageResult
    {
        internal int Stage;
        internal bool Ok, Skipped;
        internal string Code = "", Detail = "", Info = "";
        internal long Ms;
        internal static StageResult Pass(int stage, long ms, string info = "") { return new StageResult { Stage = stage, Ok = true, Ms = ms, Info = info }; }
        internal static StageResult Fail(int stage, long ms, string code, string detail = "") { return new StageResult { Stage = stage, Ok = false, Ms = ms, Code = code, Detail = detail }; }
        internal static StageResult Skip(int stage) { return new StageResult { Stage = stage, Ok = true, Skipped = true }; }
    }
    internal sealed class LadderResult
    {
        internal bool Ok = true;
        internal int FailStage;
        internal string Reason = "", Detail = "", Egress = "";
        internal long TotalMs;
        internal StageResult[] Stages = new StageResult[0];
        internal string Key { get { return Ok ? "ok" : "fail:" + FailStage + ":" + Reason; } }
    }
    internal interface INetProbe
    {
        StageResult LocalNet();
        StageResult Conflict();
        StageResult Transport();
        StageResult Ports(bool vpnOn);
        StageResult Banner();
        StageResult Route();
        StageResult Dns();
        StageResult Http();
        StageResult Egress();
    }

    internal static class NetLadder
    {
        internal const int Quick = 1, Slow = 2, Full = 3;

        internal static LadderResult Evaluate(IEnumerable<StageResult> stages)
        {
            var list = stages.OrderBy(s => s.Stage).ToArray();
            var result = new LadderResult { Stages = list, TotalMs = list.Sum(s => s.Ms) };
            var bad = list.FirstOrDefault(s => !s.Ok && !s.Skipped && s.Stage < 9);
            if (bad != null) { result.Ok = false; result.FailStage = bad.Stage; result.Reason = bad.Code; result.Detail = bad.Detail; }
            var egress = list.FirstOrDefault(s => s.Stage == 9 && s.Ok && !s.Skipped);
            if (egress != null) result.Egress = egress.Info;
            return result;
        }

        // level: Quick = ступени 1–5 (+6 при включённом VPN), Slow = +7,8, Full = +9 (после включения).
        internal static LadderResult Run(INetProbe probe, bool vpnOn, int level, Action<int> sleep = null)
        {
            sleep = sleep ?? (ms => System.Threading.Thread.Sleep(ms));
            var stages = new List<StageResult>();
            Func<int, Func<StageResult>, StageResult> once = (n, f) => { try { return f(); } catch (Exception e) { return StageResult.Fail(n, 0, "probe-error", e.GetType().Name); } };
            // Сетевые ступени повторяются один раз: единичная задержка не должна давать «упало».
            Func<int, Func<StageResult>, StageResult> twice = (n, f) => { var r = once(n, f); if (!r.Ok) { sleep(500); var again = once(n, f); if (again.Ok) { again.Detail = "retry"; return again; } } return r; };
            stages.Add(once(1, probe.LocalNet));
            stages.Add(once(2, probe.Conflict));
            stages.Add(once(3, probe.Transport));
            stages.Add(twice(4, () => probe.Ports(vpnOn)));
            stages.Add(twice(5, probe.Banner));
            stages.Add(vpnOn ? once(6, probe.Route) : StageResult.Skip(6));
            stages.Add(vpnOn && level >= Slow ? twice(7, probe.Dns) : StageResult.Skip(7));
            stages.Add(vpnOn && level >= Slow ? twice(8, probe.Http) : StageResult.Skip(8));
            stages.Add(vpnOn && level >= Full ? once(9, probe.Egress) : StageResult.Skip(9));
            return Evaluate(stages);
        }
    }

    // Переход состояния для журнала: только изменения (ok -> fail -> ok = ровно два события).
    internal sealed class NetTransition
    {
        internal string From, To, Reason = "", Detail = "";
        internal int Stage;
        internal DateTime Since;
        internal long DownMs;
    }
    internal sealed class NetWatch
    {
        string state = "unknown", key = "";
        DateTime since = DateTime.MinValue, failedAt = DateTime.MinValue;
        internal string State { get { return state; } }
        internal DateTime Since { get { return since; } }
        internal NetTransition Track(LadderResult now, DateTime utcNow)
        {
            string target = now.Ok ? "ok" : "fail";
            if (target == state && (now.Ok || now.Key == key)) return null;
            var transition = new NetTransition { From = state, To = target, Stage = now.FailStage, Reason = now.Reason, Detail = now.Detail, Since = since == DateTime.MinValue ? utcNow : since };
            if (target == "ok" && state == "fail" && failedAt != DateTime.MinValue) transition.DownMs = (long)(utcNow - failedAt).TotalMilliseconds;
            if (target == "fail" && state != "fail") failedAt = utcNow;
            // Смена причины при продолжающемся отказе — тоже переход (fail -> fail), но простой считается от первого отказа.
            state = target; key = now.Key; since = utcNow;
            return transition;
        }
    }

    // Расписание сторожа. При VPN: ступени 1–6 раз в 30 с, 7–8 раз в 120 с. Без VPN: 1–5 раз в 60 с.
    internal sealed class NetSchedule
    {
        internal const long QuickOnMs = 30000, QuickOffMs = 60000, SlowMs = 120000, HeartbeatMs = 15 * 60000L, StartDelayMs = 10000;
        long nextQuick, nextSlow, nextHeartbeat;
        bool kicked;
        internal NetSchedule(long nowMs) { nextQuick = nowMs + StartDelayMs; nextSlow = nowMs + StartDelayMs; nextHeartbeat = nowMs + HeartbeatMs; }
        internal void Kick() { kicked = true; }
        // 0 — ничего, иначе уровень NetLadder.Quick/Slow. Вызывающий отмечает запуск через Started.
        internal int Due(long nowMs, bool vpnOn)
        {
            if (kicked) return vpnOn ? NetLadder.Slow : NetLadder.Quick;
            if (vpnOn && nowMs >= nextSlow) return NetLadder.Slow;
            return nowMs >= nextQuick ? NetLadder.Quick : 0;
        }
        internal void Started(long nowMs, bool vpnOn, int level)
        {
            kicked = false;
            nextQuick = nowMs + (vpnOn ? QuickOnMs : QuickOffMs);
            if (level >= NetLadder.Slow) nextSlow = nowMs + SlowMs;
        }
        internal bool HeartbeatDue(long nowMs) { if (nowMs < nextHeartbeat) return false; nextHeartbeat = nowMs + HeartbeatMs; return true; }
    }

    // Локальные входы из status/transport.json -> ports; без файла — значения по умолчанию.
    internal static class NetPorts
    {
        internal sealed class Entry { internal string Name, Host; internal int Port; }
        internal static int Port(System.Collections.Generic.Dictionary<string, object> ports, string key, int fallback)
        { int n = Json.Int(ports, key, 0); return n > 0 && n <= 65535 ? n : fallback; }
        internal static string Host(System.Collections.Generic.Dictionary<string, object> ports, string key, string fallback)
        { string v = Json.Str(ports, key); return v.Length > 0 ? v : fallback; }
        internal static Entry[] Entries(System.Collections.Generic.Dictionary<string, object> transport, bool vpnOn)
        {
            var ports = Json.Map(Json.Get(transport, "ports"));
            int ssh = Port(ports, "sshPort", 2222);
            var list = new List<Entry> {
                new Entry { Name = "ssh", Host = "127.0.0.1", Port = ssh },
                new Entry { Name = "ssh-channel", Host = Host(ports, "channelSshAddress", "127.0.0.2"), Port = ssh },
                new Entry { Name = "socks-channel", Host = "127.0.0.1", Port = Port(ports, "channelSocksPort", 2223) }
            };
            if (vpnOn) list.Add(new Entry { Name = "vpn-in", Host = "127.0.0.1", Port = Port(ports, "vpnInPort", 17881) });
            foreach (var key in ports.Keys.Where(k => k.IndexOf("happier", StringComparison.OrdinalIgnoreCase) >= 0 && k.EndsWith("Port", StringComparison.OrdinalIgnoreCase)))
                if (Port(ports, key, 0) > 0) list.Add(new Entry { Name = key, Host = "127.0.0.1", Port = Port(ports, key, 0) });
            return list.ToArray();
        }
        internal static string Describe(Entry e) { return e.Name + ":" + e.Port.ToString(CultureInfo.InvariantCulture); }
    }
}
