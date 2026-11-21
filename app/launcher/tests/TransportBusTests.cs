using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace RemoteAgents.Launcher
{
    public static class TransportBusTests
    {
        static int assertions;
        static void Check(bool ok, string what) { if (!ok) throw new Exception("Assertion failed: " + what); assertions++; }

        public static int Main(string[] args)
        {
            Console.WriteLine("Starting TransportBusTests...");
            ValidLinePublishesToBusWithSourceTransport();
            BadLinesIncrementRejectedWithoutCrashing();
            QueueLimitEnforced();
            FormatOutgoingAndForwarding();
            Console.WriteLine("PASS: TransportBusTests (" + assertions + " assertions passed)");
            return 0;
        }

        static void ValidLinePublishesToBusWithSourceTransport()
        {
            using (var bus = new EventBus(manualDispatch: true))
            {
                var seen = new List<BusEvent>();
                bus.Subscribe("transport.", e => seen.Add(e));
                bus.Subscribe("singbox.", e => seen.Add(e));

                using (var bridge = new TransportBusBridge(null, null, bus))
                {
                    bridge.ConsumeLine("@bus {\"topic\":\"transport.status\",\"fields\":{\"ok\":\"true\",\"phase\":\"ok\"}}");
                    bridge.ConsumeLine("@bus {\"topic\":\"transport.episode\",\"fields\":{\"id\":\"ep1\",\"tag\":\"direct\"}}");
                    bridge.ConsumeLine("@bus {\"topic\":\"singbox.line\",\"fields\":{\"core\":\"transport\",\"line\":\"sing-box started\"}}");

                    bus.DrainOnce();

                    Check(bridge.Parsed == 3, "3 valid lines parsed");
                    Check(bridge.Rejected == 0, "0 rejected");
                    Check(seen.Count == 3, "3 events published to bus");

                    Check(seen[0].Topic == BusTopics.TransportStatus, "first event topic transport.status");
                    Check(seen[0].Source == BusTopics.Sources.Transport, "source is transport");
                    Check(seen[0].Get("ok") == "true" && seen[0].Get("phase") == "ok", "fields parsed correctly");

                    Check(seen[1].Topic == BusTopics.TransportEpisode, "second event topic transport.episode");
                    Check(seen[1].Source == BusTopics.Sources.Transport, "source is transport");
                    Check(seen[1].Get("id") == "ep1", "episode field parsed");

                    Check(seen[2].Topic == BusTopics.SingboxLine, "third event topic singbox.line");
                    Check(seen[2].Source == BusTopics.Sources.Transport, "source is transport");
                }
            }
        }

        static void BadLinesIncrementRejectedWithoutCrashing()
        {
            using (var bus = new EventBus(manualDispatch: true))
            {
                using (var bridge = new TransportBusBridge(null, null, bus))
                {
                    // 1. Broken JSON
                    bridge.ConsumeLine("@bus {bad-json}");
                    Check(bridge.Rejected == 1, "broken json rejected");

                    // 2. Missing fields or wrong type
                    bridge.ConsumeLine("@bus {\"topic\":\"transport.status\",\"fields\":123}");
                    Check(bridge.Rejected == 2, "non-object fields rejected");

                    // 3. Foreign topic not in whitelist
                    bridge.ConsumeLine("@bus {\"topic\":\"vpn.state\",\"fields\":{\"state\":\"on\"}}");
                    Check(bridge.Rejected == 3, "foreign topic vpn.state rejected");

                    bridge.ConsumeLine("@bus {\"topic\":\"win.route.changed\",\"fields\":{}}");
                    Check(bridge.Rejected == 4, "foreign topic win.route.changed rejected");

                    // 4. Line too long (> 8 KB)
                    string huge = "@bus {\"topic\":\"transport.status\",\"fields\":{\"x\":\"" + new string('a', 9000) + "\"}}";
                    bridge.ConsumeLine(huge);
                    Check(bridge.Rejected == 5, "line exceeding 8KB rejected");

                    // 5. Ordinary stdout line goes to log (neither parsed nor rejected)
                    bridge.ConsumeLine("Just some stdout debug info from powershell");
                    Check(bridge.Rejected == 5 && bridge.Parsed == 0, "normal stdout does not increment rejected or parsed");
                }
            }
        }

        static void QueueLimitEnforced()
        {
            using (var bus = new EventBus(manualDispatch: true))
            {
                using (var bridge = new TransportBusBridge(null, null, bus, queueLimit: 3))
                {
                    for (int i = 0; i < 5; i++)
                    {
                        bridge.ConsumeLine("@bus {\"topic\":\"transport.status\",\"fields\":{\"n\":\"" + i + "\"}}");
                    }
                    Check(bridge.Parsed == 3, "parsed strictly at queue limit");
                    Check(bridge.Dropped == 2, "overflow dropped and counted");
                }
            }
        }

        static void FormatOutgoingAndForwarding()
        {
            // Allowed outgoing topics: win.*, net.change, tick.transport-*, transport.command
            var allowedEvent = new BusEvent(1, BusTopics.WinRouteChanged, BusTopics.Sources.Windows, DateTime.UtcNow,
                new Dictionary<string, string> { { "ifIndex", "12" }, { "token", "pass=secret123" } });
            string formatted = TransportBusBridge.FormatOutgoing(allowedEvent);
            Check(formatted != null && formatted.StartsWith("@bus "), "formatted starts with @bus ");
            Check(formatted.Contains("win.route.changed"), "contains topic");
            Check(!formatted.Contains("secret123"), "secret is masked by LogMask");

            var disallowed = new BusEvent(2, BusTopics.TransportStatus, BusTopics.Sources.Transport, DateTime.UtcNow,
                new Dictionary<string, string>());
            Check(TransportBusBridge.FormatOutgoing(disallowed) == null, "disallowed topic returns null");

            var tickEvent = new BusEvent(3, BusTopics.TickTransportMem, BusTopics.Sources.Timer, DateTime.UtcNow,
                new Dictionary<string, string>());
            Check(TransportBusBridge.FormatOutgoing(tickEvent) != null, "tick.transport-* is allowed");

            // Test bus subscriber writing to stream
            using (var bus = new EventBus(manualDispatch: true))
            {
                var ms = new MemoryStream();
                var writer = new StreamWriter(ms, Encoding.UTF8);
                using (var bridge = new TransportBusBridge(null, writer, bus))
                {
                    bus.Publish(BusTopics.NetChange, BusTopics.Sources.Tray, "id", "net1");
                    bus.Publish(BusTopics.VpnState, BusTopics.Sources.Tray, "state", "on"); // should not be forwarded
                    bus.DrainOnce();

                    writer.Flush();
                    string sentText = Encoding.UTF8.GetString(ms.ToArray());
                    Check(sentText.Contains("net.change"), "net.change was forwarded to stdin");
                    Check(!sentText.Contains("vpn.state"), "vpn.state was not forwarded to stdin");
                    Check(bridge.Sent == 1, "sent counter incremented");
                }
            }
        }
    }
}
