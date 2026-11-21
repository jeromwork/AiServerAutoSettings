using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace RemoteAgents.Launcher
{
    // Шаг B3: мост шины «служба -> трей». Без pipe, потоков и реального времени: шина в ручном режиме, фальшивый «pipe» — список строк.
    internal static class HelperBusTests
    {
        static int count;
        static void Check(bool condition, string name) { if (!condition) throw new Exception("HelperBus: " + name); count++; }
        static int Main(string[] args) { Run(); Console.WriteLine("PASS: HelperBusTests (" + count + " assertions passed)"); return 0; }

        static BusEvent Make(string topic, params string[] kv)
        {
            using (var bus = new EventBus(manualDispatch: true))
            {
                BusEvent got = null; bus.Subscribe("*", e => got = e);
                bus.Publish(topic, BusTopics.Sources.Helper, kv); bus.DrainOnce();
                return got;
            }
        }

        internal static void Run()
        {
            Frame(); Policy(); Sender(); Pipeline(); Awaiter();
            Check(NetHelperProtocol.EventsPipeName == NetHelperProtocol.PipeName + ".events", "events pipe name is the main name plus .events");
        }

        static void Frame()
        {
            var e = Make(BusTopics.VpnState, "state", "on", "reason", "monitor");
            string line = HelperBusFrame.Serialize(e);
            string topic; Dictionary<string, string> fields;
            Check(line != null && HelperBusFrame.TryParse(line, out topic, out fields) && topic == "vpn.state" && fields["state"] == "on" && fields["reason"] == "monitor", "frame round-trips");
            var big = Make(BusTopics.SingboxLine, "core", "vpn", "line", new string('x', 5000));
            string bigLine = HelperBusFrame.Serialize(big);
            Check(bigLine != null && HelperBusFrame.TryParse(bigLine, out topic, out fields) && fields["line"].Length == HelperBusFrame.MaxFieldChars, "long field is clipped, frame stays valid");
            var many = new List<string>();
            for (int i = 0; i < 60; i++) { many.Add("k" + i); many.Add(new string('y', 2000)); }
            Check(HelperBusFrame.Serialize(Make(BusTopics.VpnStep, many.ToArray())) == null, "frame over 64 KiB is not sent");
            foreach (string bad in new[] { null, "", "{}", "[]", "{\"topic\":\"vpn.state\"}", "{\"topic\":1,\"f\":{}}", "{\"topic\":\"vpn.state\",\"f\":{\"a\":1}}", "{\"topic\":\"a\",\"topic\":\"b\",\"f\":{}}", "{\"topic\":\"vpn.state\",\"f\":{}}x", "{\"topic\":\"vpn.state\",\"f\":{\"a\":\"1\",\"a\":\"2\"}}", "{\"topic\":\"\",\"f\":{}}", "not json" })
                Check(!HelperBusFrame.TryParse(bad, out topic, out fields), "reject bad frame: " + (bad ?? "null"));
            string padded = "{\"topic\":\"vpn.state\",\"f\":{}}".PadRight(HelperBusFrame.MaxBytes + 1, ' ');
            Check(!HelperBusFrame.TryParse(padded, out topic, out fields), "reject frame over 64 KiB");
        }

        static void Policy()
        {
            var vpn = new Dictionary<string, string> { { "core", "vpn" } };
            var transport = new Dictionary<string, string> { { "core", "transport" } };
            var infoLine = new Dictionary<string, string> { { "core", "vpn" }, { "level", "info" } };
            var warnLine = new Dictionary<string, string> { { "core", "vpn" }, { "level", "warn" } };
            var none = new Dictionary<string, string>();
            Check(HelperBusPolicy.Allows("vpn.state", none) && HelperBusPolicy.Allows("vpn.step", none), "vpn.* goes");
            Check(HelperBusPolicy.Allows("win.route.changed", none) && HelperBusPolicy.Allows("helper.version", none), "win.* and helper.* go");
            Check(HelperBusPolicy.Allows("singbox.started", vpn) && HelperBusPolicy.Allows("singbox.fatal", vpn) && HelperBusPolicy.Allows("singbox.line", warnLine), "singbox of the vpn core goes");
            Check(!HelperBusPolicy.Allows("singbox.started", transport) && !HelperBusPolicy.Allows("singbox.started", none), "singbox of another core does not go");
            Check(!HelperBusPolicy.Allows("singbox.line", infoLine), "INFO core lines are not forwarded");
            foreach (string topic in new[] { "transport.status", "update.requested", "tick.tray", "net.change", "component.exit", "bus.overflow", "health.accepted", "" , null })
                Check(!HelperBusPolicy.Allows(topic, none), "foreign topic does not go: " + (topic ?? "null"));
        }

        static void Sender()
        {
            using (var bus = new EventBus(manualDispatch: true))
            using (var sender = new HelperBusSender(bus))
            {
                bus.Publish(BusTopics.HelperVersion, BusTopics.Sources.Helper, "version", "9");
                bus.Publish(BusTopics.VpnState, BusTopics.Sources.Helper, "state", "off");
                bus.Publish(BusTopics.TransportStatus, BusTopics.Sources.Transport, "ok", "1"); // retained, но не из белого списка
                var lines = new List<string>();
                bus.DrainOnce(); // до подключения клиента никто не слушает
                Check(lines.Count == 0, "nothing is sent without a client");
                var attach = sender.Attach(lines.Add);
                var topics = lines.Select(Topic).ToList();
                Check(topics.Contains("vpn.state") && topics.Contains("helper.version") && !topics.Contains("transport.status") && topics.Count == 2, "retained states first, foreign retained topic not sent");
                bus.Publish(BusTopics.VpnState, BusTopics.Sources.Helper, "state", "on");
                bus.Publish(BusTopics.UpdateRequested, BusTopics.Sources.Tray);
                bus.DrainOnce();
                Check(lines.Count == 3 && Topic(lines[2]) == "vpn.state" && lines[2].Contains("\"on\""), "live event follows, foreign live topic is not sent");
                attach.Dispose();
                bus.Publish(BusTopics.VpnState, BusTopics.Sources.Helper, "state", "off"); bus.DrainOnce();
                Check(lines.Count == 3, "nothing after the client is gone");
            }
            // Событие, опубликованное до подключения, но доставленное после, уходит один раз (retained, без повтора).
            using (var bus = new EventBus(manualDispatch: true))
            using (var sender = new HelperBusSender(bus))
            {
                var lines = new List<string>();
                bus.Publish(BusTopics.VpnState, BusTopics.Sources.Helper, "state", "on");
                sender.Attach(lines.Add);
                bus.DrainOnce();
                Check(lines.Count == 1, "retained is not duplicated by its own late delivery");
                sender.Attach(l => { throw new System.IO.IOException(); });
                bus.Publish(BusTopics.VpnState, BusTopics.Sources.Helper, "state", "off"); bus.DrainOnce();
                Check(sender.Dropped >= 1, "a failing sink is counted, not thrown");
            }
        }

        static string Topic(string line)
        {
            string topic; Dictionary<string, string> fields;
            return HelperBusFrame.TryParse(line, out topic, out fields) ? topic : null;
        }

        // Служба -> фальшивый pipe -> приёмник трея -> шина трея: «vpn.state on» доходит с source=helper.
        static void Pipeline()
        {
            using (var service = new EventBus(manualDispatch: true))
            using (var tray = new EventBus(manualDispatch: true))
            using (var sender = new HelperBusSender(service))
            {
                var receiver = new HelperBusReceiver(tray);
                service.Publish(BusTopics.VpnState, BusTopics.Sources.Helper, "state", "on", "reason", "monitor");
                var wire = new List<string>();
                sender.Attach(wire.Add);
                service.Publish(BusTopics.SingboxFatal, BusTopics.Sources.VpnCore, "core", "vpn", "code", "1");
                service.DrainOnce();
                foreach (string line in wire) Check(receiver.Ingest(line), "receiver accepts a service frame");
                tray.DrainOnce();
                BusEvent last;
                Check(tray.TryGetLast(BusTopics.VpnState, out last) && last.Get("state") == "on" && last.Source == BusTopics.Sources.Helper, "tray sees vpn.state on with source=helper");
                var seen = new List<string>(); tray.Subscribe("singbox.", e => seen.Add(e.Topic + ":" + e.Get("code")));
                receiver.Ingest(wire.Last()); tray.DrainOnce();
                Check(seen.SequenceEqual(new[] { "singbox.fatal:1" }), "singbox.fatal arrives with its fields");
                // Чужой топик и мусор приёмник отбрасывает сам.
                var foreign = Make(BusTopics.UpdateRequested, "x", "y");
                Check(!receiver.Ingest(HelperBusFrame.Serialize(foreign)) && !receiver.Ingest("garbage") && receiver.Rejected == 2, "receiver re-checks the whitelist and the grammar");
            }
        }

        static void Awaiter()
        {
            using (var bus = new EventBus(manualDispatch: true))
            {
                bus.Publish(BusTopics.VpnState, BusTopics.Sources.Helper, "state", "off"); bus.DrainOnce();
                using (var stale = new VpnStateAwaiter(bus, s => s != "starting", false))
                using (var fresh = new VpnStateAwaiter(bus, s => s != "starting"))
                {
                    Check(!stale.Task.IsCompleted && fresh.Task.IsCompleted, "retained counts only when asked");
                    bus.Publish(BusTopics.VpnState, BusTopics.Sources.Helper, "state", "starting"); bus.DrainOnce();
                    Check(!stale.Task.IsCompleted, "starting is not final");
                    bus.Publish(BusTopics.VpnState, BusTopics.Sources.Helper, "state", "on"); bus.DrainOnce();
                    Check(stale.Task.IsCompleted && stale.Task.Result.Get("state") == "on", "final state completes the awaiter");
                }
            }
        }
    }
}
