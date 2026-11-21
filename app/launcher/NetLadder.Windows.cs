using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace RemoteAgents.Launcher
{
    // Ступени проверки на реальной сети (всё в фоне; UI не блокируется).
    internal sealed class WindowsNetProbe : INetProbe
    {
        readonly string home;
        readonly Func<Dictionary<string, object>> transport, vpn;
        internal WindowsNetProbe(string home, Func<Dictionary<string, object>> transport, Func<Dictionary<string, object>> vpn)
        { this.home = home; this.transport = transport; this.vpn = vpn; }
        bool ChannelFirst()
        { try { return Json.Bool(Json.Map(Json.Get(Json.Read(Path.Combine(home, "config.json")), "transport")), "channelFirst"); } catch { return false; } }

        static StageResult Timed(int stage, Func<string> body, string code)
        {
            var watch = Stopwatch.StartNew();
            try { string error = body(); return error == null ? StageResult.Pass(stage, watch.ElapsedMilliseconds) : StageResult.Fail(stage, watch.ElapsedMilliseconds, code, error); }
            catch (Exception e) { return StageResult.Fail(stage, watch.ElapsedMilliseconds, code, e.GetType().Name); }
        }
        public StageResult LocalNet()
        {
            return Timed(1, () => {
                bool found = NetworkInterface.GetAllNetworkInterfaces().Any(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback
                    && !n.Name.StartsWith("RemoteAgents-", StringComparison.OrdinalIgnoreCase)
                    && n.GetIPProperties().GatewayAddresses.Any(g => !g.Address.Equals(IPAddress.Any) && !g.Address.Equals(IPAddress.IPv6Any)));
                return found ? null : "no-gateway-adapter";
            }, "no-local-net");
        }
        public StageResult Conflict()
        {
            var watch = Stopwatch.StartNew();
            var status = vpn();
            string name = Json.Str(status, "conflictName");
            if (Json.Str(status, "state") == "conflict" || name.Length > 0) return StageResult.Fail(2, watch.ElapsedMilliseconds, "conflict", "name=" + name);
            return StageResult.Pass(2, watch.ElapsedMilliseconds, Json.Str(status, "suspects"));
        }
        public StageResult Transport()
        {
            var watch = Stopwatch.StartNew();
            var t = transport();
            if (t.Count == 0) return StageResult.Fail(3, watch.ElapsedMilliseconds, "transport-down", "status-missing-or-stale");
            string reason = Json.Str(Json.Map(Json.Get(t, "reason")), "code");
            if (!Json.Bool(t, "ok") || Json.Str(t, "phase") == "failed")
                return StageResult.Fail(3, watch.ElapsedMilliseconds, "transport-down", "phase=" + Json.Str(t, "phase") + " active=" + Json.Str(t, "active") + " code=" + reason);
            return StageResult.Pass(3, watch.ElapsedMilliseconds, "active=" + Json.Str(t, "active"));
        }
        static bool Connect(string host, int port, int timeoutMs, out string error)
        {
            error = "";
            try {
                using (var client = new TcpClient()) {
                    var task = client.ConnectAsync(host, port);
                    if (!task.Wait(timeoutMs)) { error = "timeout"; return false; }
                    return client.Connected;
                }
            } catch (Exception e) { error = (e.InnerException ?? e).GetType().Name; return false; }
        }
        public StageResult Ports(bool vpnOn)
        {
            var watch = Stopwatch.StartNew();
            var entries = NetPorts.Entries(transport(), vpnOn, ChannelFirst());
            var tasks = entries.Select(e => Task.Run(() => { string err; return Connect(e.Host, e.Port, 300, out err) ? null : NetPorts.Describe(e) + "(" + err + ")"; })).ToArray();
            Task.WaitAll(tasks);
            var closed = tasks.Select(t => t.Result).Where(r => r != null).ToArray();
            return closed.Length == 0 ? StageResult.Pass(4, watch.ElapsedMilliseconds, entries.Length + " open") : StageResult.Fail(4, watch.ElapsedMilliseconds, "port-closed", "port=" + string.Join(",", closed));
        }
        public StageResult Banner()
        {
            var watch = Stopwatch.StartNew();
            int port = NetPorts.Entries(transport(), false)[0].Port;
            try {
                using (var client = new TcpClient()) {
                    if (!client.ConnectAsync("127.0.0.1", port).Wait(3000)) return StageResult.Fail(5, watch.ElapsedMilliseconds, "channel-no-banner", "connect-timeout");
                    var stream = client.GetStream(); stream.ReadTimeout = 3000;
                    var buffer = new byte[64]; int read = stream.Read(buffer, 0, buffer.Length);
                    string banner = Encoding.ASCII.GetString(buffer, 0, Math.Max(0, read));
                    return banner.StartsWith("SSH-2.0") ? StageResult.Pass(5, watch.ElapsedMilliseconds) : StageResult.Fail(5, watch.ElapsedMilliseconds, "channel-no-banner", read == 0 ? "closed" : "not-ssh");
                }
            } catch (Exception e) { return StageResult.Fail(5, watch.ElapsedMilliseconds, "channel-no-banner", (e.InnerException ?? e).GetType().Name); }
        }
        public StageResult Route()
        {
            var watch = Stopwatch.StartNew();
            int index = NetRoute.BestInterface(IPAddress.Parse("1.1.1.1"));
            if (index < 0) return StageResult.Fail(6, watch.ElapsedMilliseconds, "route-not-ours", "GetBestInterface=failed");
            string name = NetworkInterface.GetAllNetworkInterfaces().Where(n => { try { return n.GetIPProperties().GetIPv4Properties().Index == (int)index; } catch { return false; } })
                .Select(n => n.Name).FirstOrDefault() ?? ("ifIndex" + index);
            return name.StartsWith("RemoteAgents-", StringComparison.OrdinalIgnoreCase) ? StageResult.Pass(6, watch.ElapsedMilliseconds, name)
                : StageResult.Fail(6, watch.ElapsedMilliseconds, "route-not-ours", "iface=" + name);
        }
        public StageResult Dns()
        {
            var watch = Stopwatch.StartNew();
            try {
                var task = Dns_.GetHostAddressesAsync("www.gstatic.com");
                if (!task.Wait(3000)) return StageResult.Fail(7, watch.ElapsedMilliseconds, "dns-fail", "timeout");
                return task.Result.Length > 0 ? StageResult.Pass(7, watch.ElapsedMilliseconds, task.Result[0].ToString()) : StageResult.Fail(7, watch.ElapsedMilliseconds, "dns-fail", "empty");
            } catch (Exception e) { return StageResult.Fail(7, watch.ElapsedMilliseconds, "dns-fail", (e.InnerException ?? e).GetType().Name); }
        }
        public StageResult Http()
        {
            var watch = Stopwatch.StartNew();
            try {
                var request = (HttpWebRequest)WebRequest.Create("http://www.gstatic.com/generate_204");
                request.Proxy = null; request.Timeout = 5000; request.ReadWriteTimeout = 5000; request.AllowAutoRedirect = false;
                using (var response = (HttpWebResponse)request.GetResponse())
                    return (int)response.StatusCode == 204 ? StageResult.Pass(8, watch.ElapsedMilliseconds) : StageResult.Fail(8, watch.ElapsedMilliseconds, "http-fail", "status=" + (int)response.StatusCode);
            } catch (WebException e) {
                var http = e.Response as HttpWebResponse;
                return StageResult.Fail(8, watch.ElapsedMilliseconds, "http-fail", http != null ? "status=" + (int)http.StatusCode : "err=" + e.Status);
            } catch (Exception e) { return StageResult.Fail(8, watch.ElapsedMilliseconds, "http-fail", "err=" + e.GetType().Name); }
        }
        public StageResult Egress()
        {
            var watch = Stopwatch.StartNew();
            try {
                ServicePointManager.SecurityProtocol |= (SecurityProtocolType)3072;
                var request = (HttpWebRequest)WebRequest.Create("https://api.ipify.org");
                request.Proxy = null; request.Timeout = 5000; request.ReadWriteTimeout = 5000;
                using (var response = request.GetResponse())
                using (var reader = new StreamReader(response.GetResponseStream())) {
                    string ip = reader.ReadToEnd().Trim();
                    if (ip.Length > 64) ip = ip.Substring(0, 64);
                    return StageResult.Pass(9, watch.ElapsedMilliseconds, ip);
                }
            } catch (Exception e) { return new StageResult { Stage = 9, Ok = true, Ms = watch.ElapsedMilliseconds, Info = "unavailable:" + e.GetType().Name }; }
        }
        static class Dns_ { internal static Task<IPAddress[]> GetHostAddressesAsync(string host) { return System.Net.Dns.GetHostAddressesAsync(host); } }
    }

    // Сторож и сквозная проверка после «Включить». Один прогон за раз (общий флаг для сторожа и RunE2E), всё в фоне.
    internal sealed class NetLadderService
    {
        const long BannerEveryMs = 5 * 60000;
        readonly Journal log;
        readonly INetProbe probe;
        readonly Stopwatch clock = Stopwatch.StartNew();
        readonly NetSchedule schedule;
        readonly NetWatch watch = new NetWatch();
        int running;
        string lastNetwork, lastActive, lastPortsState = "";
        long lastBannerMs = -BannerEveryMs;
        // Заметка для трея: текст при отказе ступеней 6–8 при включённом VPN, пустая строка — всё хорошо.
        internal Action<string> Note;
        internal event Action<LadderResult> Changed; // ok -> fail / fail -> ok (для LogShipper.Kick)
        internal NetLadderService(string home, Journal log, Func<Dictionary<string, object>> transport, Func<Dictionary<string, object>> vpn)
        {
            this.log = log;
            probe = new WindowsNetProbe(home, transport, vpn);
            schedule = new NetSchedule(clock.ElapsedMilliseconds);
        }
        bool TryEnter() { return Interlocked.CompareExchange(ref running, 1, 0) == 0; }
        void Leave() { Interlocked.Exchange(ref running, 0); }
        // Раз в секунду из Tick: дешёвое решение, нужен ли прогон.
        internal void Tick(Dictionary<string, object> transportNow, bool vpnOn)
        {
            string network = Json.Str(transportNow, "network"), active = Json.Str(transportNow, "active");
            if (lastNetwork != null && (network != lastNetwork || active != lastActive) && (network.Length > 0 || active.Length > 0)) schedule.Kick();
            lastNetwork = network; lastActive = active;
            long now = clock.ElapsedMilliseconds;
            int level = schedule.Due(now, vpnOn);
            if (level == 0 || !TryEnter()) return;
            schedule.Started(now, vpnOn, level);
            Task.Run(() => {
                try { Watch(vpnOn, level); }
                catch (Exception e) { log.Write(LogLevel.Warn, "net", "net.watch-error", "err", e.GetType().Name); }
                finally { Leave(); }
            });
        }
        void Watch(bool vpnOn, int level)
        {
            // Ступени 1–4 — только локальные проверки. Баннер SSH (ступень 5, обращение к серверу) —
            // не чаще раза в 5 мин или при смене результата ступени 4.
            var result = NetLadder.Run(probe, vpnOn, level, null, false);
            var ports = result.Stages.FirstOrDefault(s => s.Stage == 4);
            string portsState = ports == null ? "" : ports.Ok ? "ok" : "fail";
            long now = clock.ElapsedMilliseconds;
            if (result.Ok && (portsState != lastPortsState || now - lastBannerMs >= BannerEveryMs)) {
                lastBannerMs = now;
                var banner = Guarded(probe.Banner);
                var all = result.Stages.Where(s => s.Stage != 5).Concat(new[] { banner }).ToArray();
                result = NetLadder.Evaluate(all);
            }
            lastPortsState = portsState;
            var change = watch.Track(result, DateTime.UtcNow);
            if (change != null) {
                var fields = new List<string> { "from", change.From, "to", change.To, "vpn", vpnOn ? "on" : "off" };
                if (change.To == "fail") fields.AddRange(new[] { "stage", change.Stage.ToString(CultureInfo.InvariantCulture), "reason", change.Reason, "detail", change.Detail });
                else if (change.DownMs > 0) fields.AddRange(new[] { "down_ms", change.DownMs.ToString(CultureInfo.InvariantCulture) });
                fields.AddRange(new[] { "since", change.Since.ToString("o", CultureInfo.InvariantCulture) });
                log.Write(change.To == "fail" ? LogLevel.Warn : LogLevel.Info, "net", "net.state", fields.ToArray());
                var changed = Changed; if (changed != null) try { changed(result); } catch { }
            }
            Publish(result, vpnOn);
            if (schedule.HeartbeatDue(clock.ElapsedMilliseconds))
                log.Write(LogLevel.Info, "net", "net.heartbeat", "state", watch.State, "vpn", vpnOn ? "on" : "off", "stages", Stages(result));
        }
        static StageResult Guarded(Func<StageResult> f) { try { return f(); } catch (Exception e) { return StageResult.Fail(5, 0, "probe-error", e.GetType().Name); } }
        // «Интернет через VPN не идёт» — только при отказе ступеней 6–8.
        void Publish(LadderResult result, bool vpnOn)
        {
            var note = Note; if (note == null) return;
            bool internetDown = vpnOn && !result.Ok && result.FailStage >= 6 && result.FailStage <= 8;
            try { note(internetDown ? "VPN включён, но интернет через него не идёт: " + result.Reason + (result.Detail.Length > 0 ? " (" + result.Detail + ")" : "") : ""); } catch { }
        }
        static string Stages(LadderResult r)
        { return string.Join(",", r.Stages.Where(s => !s.Skipped).Select(s => s.Stage + ":" + (s.Ok ? "ok" : s.Code) + "/" + s.Ms)); }
        internal void Kick() { schedule.Kick(); }
        // block.ready transport: первый прогон сторожа (вызывать из потока трея, как и Tick).
        internal void TransportReady() { schedule.TransportReady(clock.ElapsedMilliseconds); }

        // После vpn.on.ok: полная лестница в фоне; ждёт свободного места среди прогонов сторожа (до 30 с).
        internal void RunE2E(string att)
        {
            Task.Run(() => {
                bool entered = false;
                try {
                    for (int i = 0; i < 60 && !(entered = TryEnter()); i++) Thread.Sleep(500);
                    if (!entered) { log.Write(LogLevel.Warn, "net", "net.e2e", "att", att, "result", "skipped", "reason", "busy"); return; }
                    var result = NetLadder.Run(probe, true, NetLadder.Full);
                    var fields = new List<string> { "att", att, "result", result.Ok ? "ok" : "fail", "stage", result.FailStage.ToString(CultureInfo.InvariantCulture), "reason", result.Reason, "detail", result.Detail, "ms_total", result.TotalMs.ToString(CultureInfo.InvariantCulture) };
                    foreach (var s in result.Stages.Where(s => !s.Skipped)) fields.AddRange(new[] { "s" + s.Stage + "ms", s.Ms.ToString(CultureInfo.InvariantCulture) });
                    fields.AddRange(new[] { "egress", result.Egress });
                    log.Write(result.Ok ? LogLevel.Info : LogLevel.Warn, "net", "net.e2e", fields.ToArray());
                    lastBannerMs = clock.ElapsedMilliseconds;
                    Publish(result, true);
                } catch (Exception e) { log.Write(LogLevel.Warn, "net", "net.e2e", "att", att, "result", "error", "err", e.GetType().Name); }
                finally { if (entered) Leave(); }
            });
        }
    }
}
