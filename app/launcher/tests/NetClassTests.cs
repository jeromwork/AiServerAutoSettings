using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Runtime.CompilerServices;
using System.Reflection;
using System.Threading;

namespace RemoteAgents.Launcher
{
    internal static class NetClassTests
    {
        static int checks;
        static void Check(bool ok, string reason) { checks++; if (!ok) throw new Exception(reason); }
        static string Canonical(object value)
        {
            var map = value as Dictionary<string, object>;
            if (map != null) return "{" + string.Join(",", map.OrderBy(x => x.Key, StringComparer.Ordinal).Select(x => Json.Encode(x.Key) + ":" + Canonical(x.Value))) + "}";
            if (!(value is string) && value is System.Collections.IEnumerable) return "[" + string.Join(",", Json.Array(value).Select(Canonical)) + "]";
            return Json.Encode(value);
        }
        static string SchemaPath([CallerFilePath] string caller = "")
        {
            return Path.GetFullPath(Path.Combine(Path.GetDirectoryName(caller), "../config.paste.schema.json"));
        }
        static void WorkerBurst()
        {
            // Предохранитель (конституция 4а): событие тестового worker недоступно при зависании;
            // при срабатывании — провал теста, успех не объявляет.
            const int WorkerFuseMs = 5000;
            using (var bus = new EventBus(manualDispatch: true))
            using (var entered = new ManualResetEventSlim())
            using (var release = new ManualResetEventSlim())
            using (var done = new ManualResetEventSlim()) {
                int reads = 0, delivered = 0, dispatchThread = Thread.CurrentThread.ManagedThreadId;
                bool offDispatcher = true; Exception failure = null;
                using (new NetClassPublisher(bus, () => {
                    offDispatcher &= Thread.CurrentThread.ManagedThreadId != dispatchThread;
                    if (Interlocked.Increment(ref reads) == 1) {
                        entered.Set();
                        if (!release.Wait(WorkerFuseMs)) throw new Exception("reader release missing");
                    }
                    return new NetClassProfile { Id = "slow", Wlan = true };
                }, work => new Thread(() => {
                    try { work(); } catch (Exception ex) { failure = ex; } finally { done.Set(); }
                }) { IsBackground = true }.Start())) {
                    bus.Subscribe(BusTopics.WinRouteChanged, e => delivered++);
                    bus.Publish(BusTopics.WinIfaceChanged, "test"); bus.DrainOnce();
                    Check(entered.Wait(WorkerFuseMs), "worker entered by explicit signal");
                    try {
                        for (int i = 0; i < 40; i++) bus.Publish(BusTopics.WinRouteChanged, "test");
                        bus.DrainOnce();
                        Check(delivered == 40 && reads == 1, "blocked reader cannot hold DrainOnce or launch concurrent reads");
                    } finally { release.Set(); }
                    Check(done.Wait(WorkerFuseMs) && failure == null, "worker completes by signal");
                    Check(offDispatcher && reads == 2, "burst coalesces into exactly one follow-up read off dispatcher");
                }
            }
        }
        public static int Main()
        {
            Check(NetClass.Classify(new NetClassProfile { Wwan = true, Wlan = true }) == "mobile", "WWAN wins");
            Check(NetClass.Classify(new NetClassProfile { AdapterType = NetworkInterfaceType.Wwanpp }) == "mobile", "WWAN adapter");
            foreach (var p in new[] { new NetClassProfile { Wlan = true, Metered = true }, new NetClassProfile { Wlan = true, CostType = "Variable" }, new NetClassProfile { Wlan = true, CostType = "Fixed" }, new NetClassProfile { Wlan = true, Roaming = true }, new NetClassProfile { Wlan = true, ApproachingDataLimit = true } })
                Check(NetClass.Classify(p) == "mobile-hotspot", "metered Wi-Fi hotspot");
            Check(NetClass.Classify(new NetClassProfile { AdapterType = NetworkInterfaceType.Wireless80211, CostType = "Unrestricted" }) == "wifi", "unrestricted Wi-Fi");
            Check(NetClass.Classify(new NetClassProfile { AdapterType = NetworkInterfaceType.Ethernet, Metered = true }) == "fixed", "Ethernet");
            Check(NetClass.Classify(null) == "unknown", "unknown does not invent a wired network");
            Check(NetClass.IsOwnTun(VpnTun.InterfaceName) && NetClass.IsOwnTun(LanTun.InterfaceName.ToLowerInvariant()) && !NetClass.IsOwnTun("Ethernet"), "own TUN names excluded explicitly");
            WorkerBurst();
            using (var bus = new EventBus(manualDispatch: true)) {
                int reads = 0;
                var profile = new NetClassProfile { Id = "physical", AdapterType = NetworkInterfaceType.Wireless80211 };
                var jobs = new Queue<Action>();
                using (new NetClassPublisher(bus, () => { reads++; return profile; }, jobs.Enqueue)) {
                    var seen = new List<BusEvent>();
                    bus.Subscribe(BusTopics.NetChange, e => { if (e.Get("classifier") == "q") seen.Add(e); });
                    bus.Publish(BusTopics.WinIfaceChanged, "test"); bus.DrainOnce(); if (jobs.Count > 0) jobs.Dequeue()(); bus.DrainOnce();
                    Check(seen.Count == 1 && seen[0].Get("class") == "wifi", "network event publishes classification");
                    Check(reads == 1, "self-publication cannot loop");
                    bus.Publish(BusTopics.WinIfaceChanged, "test"); bus.DrainOnce(); if (jobs.Count > 0) jobs.Dequeue()(); bus.DrainOnce();
                    Check(seen.Count == 1, "duplicate snapshot suppressed");
                    profile.Metered = true;
                    bus.Publish(BusTopics.WinRouteChanged, "test"); bus.DrainOnce(); if (jobs.Count > 0) jobs.Dequeue()(); bus.DrainOnce();
                    Check(seen.Count == 2 && seen[1].Get("class") == "mobile-hotspot", "cost change reclassifies");
                    bus.Publish(BusTopics.NetChange, "test", "id", "canonical"); bus.DrainOnce(); if (jobs.Count > 0) jobs.Dequeue()(); bus.DrainOnce();
                    Check(seen.Last().Get("id") == "canonical", "external network id preserved");
                    int before = seen.Count;
                    bus.Publish(BusTopics.TransportReady, "test"); bus.DrainOnce(); if (jobs.Count > 0) jobs.Dequeue()(); bus.DrainOnce();
                    Check(seen.Count == before + 1 && seen.Last().Get("id") == "canonical", "daemon ready replays canonical classification");
                }
            }
            var root = ConfigBundle.D("kind", "remoteagents-config", "schema", 1);
            Check(ConfigBundle.Parse(Json.Encode(root)).Profile.Count > 0, "old config accepted");
            root["transport"] = ConfigBundle.D("switch", ConfigBundle.D("classK", ConfigBundle.D("fixed", 0.5, "mobile-hotspot", 1.3), "stageMs", new[] { 1000, 3000 }));
            Check(ConfigBundle.Parse(Json.Encode(root)).Profile.ContainsKey("transport") && ConfigSections.Known("transport"), "switch survives profile import");
            foreach (var bad in new[] { ConfigBundle.D("classK", ConfigBundle.D("wifi", "0.8")), ConfigBundle.D("classK", ConfigBundle.D("wifi", 0)), ConfigBundle.D("stageMs", new[] { 3000, 1000 }), ConfigBundle.D("stageMs", new[] { 1000 }), ConfigBundle.D("blipMs", ConfigBundle.D("min", 20000)), ConfigBundle.D("unknown", true), ConfigBundle.D("flapWindowMs", 1800001) }) {
                root["transport"] = ConfigBundle.D("switch", bad);
                bool rejected = false; try { ConfigBundle.Parse(Json.Encode(root)); } catch (InvalidDataException) { rejected = true; }
                Check(rejected, "invalid switch rejected");
            }
            Check(Canonical(Json.Read(SchemaPath())) == Canonical(ConfigBundle.SchemaDocument()), "published and compiled schemas agree");
            var validate = typeof(ConfigBundle).GetMethod("Validate", BindingFlags.Static | BindingFlags.NonPublic);
            validate.Invoke(null, new object[] { 0.8, ConfigBundle.D("type", "number"), "number without bounds" });
            validate.Invoke(null, new object[] { 0.8, ConfigBundle.D("type", "number", "maximum", 1), "number without minimum" });
            Check(true, "number schema permits omitted bounds");
            Console.WriteLine("PASS: Q NetClass/config (" + checks + " checks, fake profiles and manually dispatched events)");
            return 0;
        }
    }
}
