using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;

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
        public static int Main()
        {
            Check(NetClass.Classify(new NetClassProfile { Wwan = true, Wlan = true }) == "mobile", "WWAN wins");
            Check(NetClass.Classify(new NetClassProfile { AdapterType = NetworkInterfaceType.Wwanpp }) == "mobile", "WWAN adapter");
            foreach (var p in new[] { new NetClassProfile { Wlan = true, Metered = true }, new NetClassProfile { Wlan = true, CostType = "Variable" }, new NetClassProfile { Wlan = true, CostType = "Fixed" }, new NetClassProfile { Wlan = true, Roaming = true }, new NetClassProfile { Wlan = true, ApproachingDataLimit = true } })
                Check(NetClass.Classify(p) == "mobile-hotspot", "metered Wi-Fi hotspot");
            Check(NetClass.Classify(new NetClassProfile { AdapterType = NetworkInterfaceType.Wireless80211, CostType = "Unrestricted" }) == "wifi", "unrestricted Wi-Fi");
            Check(NetClass.Classify(new NetClassProfile { AdapterType = NetworkInterfaceType.Ethernet, Metered = true }) == "fixed", "Ethernet");
            Check(NetClass.Classify(null) == "unknown", "unknown does not invent a wired network");
            using (var bus = new EventBus(manualDispatch: true)) {
                int reads = 0;
                var profile = new NetClassProfile { Id = "physical", AdapterType = NetworkInterfaceType.Wireless80211 };
                using (new NetClassPublisher(bus, () => { reads++; return profile; })) {
                    var seen = new List<BusEvent>();
                    bus.Subscribe(BusTopics.NetChange, e => { if (e.Get("classifier") == "q") seen.Add(e); });
                    bus.Publish(BusTopics.WinIfaceChanged, "test"); bus.DrainOnce(); bus.DrainOnce();
                    Check(seen.Count == 1 && seen[0].Get("class") == "wifi", "network event publishes classification");
                    Check(reads == 1, "self-publication cannot loop");
                    bus.Publish(BusTopics.WinIfaceChanged, "test"); bus.DrainOnce(); bus.DrainOnce();
                    Check(seen.Count == 1, "duplicate snapshot suppressed");
                    profile.Metered = true;
                    bus.Publish(BusTopics.WinRouteChanged, "test"); bus.DrainOnce(); bus.DrainOnce();
                    Check(seen.Count == 2 && seen[1].Get("class") == "mobile-hotspot", "cost change reclassifies");
                    bus.Publish(BusTopics.NetChange, "test", "id", "canonical"); bus.DrainOnce(); bus.DrainOnce();
                    Check(seen.Last().Get("id") == "canonical", "external network id preserved");
                    int before = seen.Count;
                    bus.Publish(BusTopics.TransportReady, "test"); bus.DrainOnce(); bus.DrainOnce();
                    Check(seen.Count == before + 1 && seen.Last().Get("id") == "canonical", "daemon ready replays canonical classification");
                }
            }
            var root = ConfigBundle.D("kind", "remoteagents-config", "schema", 1);
            Check(ConfigBundle.Parse(Json.Encode(root)).Profile.Count > 0, "old config accepted");
            root["transport"] = ConfigBundle.D("switch", ConfigBundle.D("classK", ConfigBundle.D("fixed", 0.5, "mobile-hotspot", 1.3), "stageMs", new[] { 1000, 3000 }));
            Check(ConfigBundle.Parse(Json.Encode(root)).Profile.ContainsKey("transport") && ConfigSections.Known("transport"), "switch survives profile import");
            foreach (var bad in new[] { ConfigBundle.D("classK", ConfigBundle.D("wifi", "0.8")), ConfigBundle.D("classK", ConfigBundle.D("wifi", 0)), ConfigBundle.D("stageMs", new[] { 3000, 1000 }), ConfigBundle.D("stageMs", new[] { 1000 }), ConfigBundle.D("blipMs", ConfigBundle.D("min", 20000)), ConfigBundle.D("unknown", true) }) {
                root["transport"] = ConfigBundle.D("switch", bad);
                bool rejected = false; try { ConfigBundle.Parse(Json.Encode(root)); } catch (InvalidDataException) { rejected = true; }
                Check(rejected, "invalid switch rejected");
            }
            Check(Canonical(Json.Read("app/launcher/config.paste.schema.json")) == Canonical(ConfigBundle.SchemaDocument()), "published and compiled schemas agree");
            Console.WriteLine("PASS: Q NetClass/config (" + checks + " checks, fake profiles and manually dispatched events)");
            return 0;
        }
    }
}
