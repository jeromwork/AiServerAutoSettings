using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace RemoteAgents.Launcher
{
    // Группа --logging: формат, маскирование, ротация, кодировка, конфликты, лестница, журнал помощника.
    internal static class LoggingTests
    {
        static int count;
        static void Check(bool value, string name) { if (!value) throw new Exception("Logging: FAIL " + name); count++; }

        static string Fixtures()
        {
            string dir = AppContext.BaseDirectory;
            while (dir != null && !Directory.Exists(Path.Combine(dir, "app", "launcher", "tests", "fixtures", "logging"))) dir = Path.GetDirectoryName(dir);
            if (dir == null) throw new Exception("Logging: fixtures not found");
            return Path.Combine(dir, "app", "launcher", "tests", "fixtures", "logging");
        }
        static string Temp(string name)
        {
            string dir = Path.Combine(Path.GetTempPath(), "ra-logging-" + name + "-" + Guid.NewGuid().ToString("N").Substring(0, 8));
            Directory.CreateDirectory(dir); return dir;
        }

        internal static int Run(string[] args)
        {
            Golden(); Mask(); Rotation(); Encoding_(); JournalMapping(); Conflicts(); Ladder(); HelperEvents(); Protocol(); CorePump();
            Console.WriteLine("PASS: Logging " + count + " checks");
            return 0;
        }

        static void Golden()
        {
            string fx = Fixtures();
            var now = new DateTimeOffset(2026, 11, 20, 12, 13, 5, 123, TimeSpan.FromHours(3));
            var cases = Json.Array(Json.Parse(File.ReadAllText(Path.Combine(fx, "golden-cases.json"), Encoding.UTF8))).Select(Json.Map).ToArray();
            var expected = File.ReadAllLines(Path.Combine(fx, "golden-lines.txt"), Encoding.UTF8);
            Check(cases.Length == expected.Length && cases.Length >= 10, "golden case count");
            for (int i = 0; i < cases.Length; i++) {
                var c = cases[i]; var fields = new List<KeyValuePair<string, string>>(); int index = 0;
                foreach (var pair in Json.Array(Json.Get(c, "fields"))) {
                    var kv = Json.Array(pair); string value = Convert.ToString(kv[1]);
                    var repeat = Json.Map(Json.Get(c, "repeat"));
                    if (repeat.Count > 0 && Json.Int(repeat, "index", -1) == index) value = string.Concat(Enumerable.Repeat(Json.Str(repeat, "text"), Json.Int(repeat, "count", 0)));
                    fields.Add(new KeyValuePair<string, string>(Convert.ToString(kv[0]), value)); index++;
                }
                var level = (LogLevel)Enum.Parse(typeof(LogLevel), Json.Str(c, "level"), true);
                string line = RaLog.Format(now, level, Json.Str(c, "comp"), Json.Str(c, "evt"), fields, "7f3a");
                if (expected[i] == "@long") Check(line.Length == Json.Int(c, "expectLength", -1) && line.EndsWith(Json.Str(c, "endsWith"), StringComparison.Ordinal), "long line is cut at 4096 + marker");
                else Check(line == expected[i], "golden line " + i + ": " + line);
            }
        }

        static void Mask()
        {
            var cases = Json.Array(Json.Parse(File.ReadAllText(Path.Combine(Fixtures(), "mask-cases.json"), Encoding.UTF8))).Select(Json.Map).ToArray();
            Check(cases.Length >= 15, "mask case count");
            foreach (var c in cases) { string got = LogMask.Clean(Json.Str(c, "in")); Check(got == Json.Str(c, "out"), "mask [" + Json.Str(c, "in") + "] -> [" + got + "]"); }
            Check(LogMask.Clean("x SECRETVALUE y", new[] { "SECRETVALUE" }) == "x *** y", "known secret values are hidden");
        }

        static void Rotation()
        {
            string dir = Temp("rotate");
            long oldMax = RaLog.MaxBytes; int oldArchives = RaLog.MaxArchives;
            try {
                Check(RaLog.MaxBytes == 2L * 1024 * 1024 && RaLog.MaxArchives == 5, "defaults are 2 MiB and 5 archives");
                RaLog.MaxBytes = 4000;
                for (int i = 0; i < 400; i++) RaLog.WriteTo(dir, "launcher", LogLevel.Info, "launcher", "tick", new[] { new KeyValuePair<string, string>("n", i.ToString()), new KeyValuePair<string, string>("pad", new string('p', 60)) });
                Check(File.Exists(Path.Combine(dir, "launcher.log.1")), "oversized log rotates to .1");
                Check(!File.Exists(Path.Combine(dir, "launcher.log.6")) && Directory.GetFiles(dir, "launcher.log.*").Count(f => !f.EndsWith("launcher.log")) <= 5, "at most five archives are kept: " + string.Join(",", Directory.GetFiles(dir).Select(Path.GetFileName)));
                foreach (string file in Directory.GetFiles(dir, "launcher.log*")) {
                    byte[] bytes = File.ReadAllBytes(file);
                    Check(bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF, "BOM at the start of " + Path.GetFileName(file));
                    int inner = 0; for (int i = 3; i + 2 < bytes.Length; i++) if (bytes[i] == 0xEF && bytes[i + 1] == 0xBB && bytes[i + 2] == 0xBF) inner++;
                    Check(inner == 0, "no BOM inside " + Path.GetFileName(file));
                }
                var files = RaLog.StreamFiles(dir, "launcher");
                Check(files.Last().EndsWith("launcher.log") && files.Length >= 2, "stream files are ordered oldest to newest");
            } finally { RaLog.MaxBytes = oldMax; RaLog.MaxArchives = oldArchives; try { Directory.Delete(dir, true); } catch { } }
        }

        static void Encoding_()
        {
            string dir = Temp("utf8");
            try {
                RaLog.WriteTo(dir, "launcher", LogLevel.Info, "launcher", "t", new[] { new KeyValuePair<string, string>("name", "Беспроводная сеть") });
                byte[] bytes = File.ReadAllBytes(Path.Combine(dir, "launcher.log"));
                string text = new UTF8Encoding(false, true).GetString(bytes);
                Check(text.Contains("Беспроводная сеть"), "file is valid UTF-8 Cyrillic");
                Check(IndexOf(bytes, new byte[] { 0xD0, 0x91, 0xD0, 0xB5 }) > 0, "Cyrillic bytes are D0 91 D0 B5 (no double encoding)");
            } finally { try { Directory.Delete(dir, true); } catch { } }
        }
        static int IndexOf(byte[] data, byte[] pattern)
        {
            for (int i = 0; i + pattern.Length <= data.Length; i++) { bool ok = true; for (int j = 0; j < pattern.Length && ok; j++) ok = data[i + j] == pattern[j]; if (ok) return i; }
            return -1;
        }

        static void JournalMapping()
        {
            string home = Temp("journal");
            try {
                var journal = new Journal(home);
                journal.Write("vpn.on.ok ms=5");
                journal.Write("vpn.off.failed x");
                journal.Write("something.fatal code=1");
                journal.Write("plain.event att=on-1 state=a b c");
                var lines = File.ReadAllLines(Path.Combine(home, "logs", "launcher.log"), Encoding.UTF8).Select(l => l.TrimStart('\uFEFF')).ToArray();
                Check(Regex.IsMatch(lines[0], @"^\d{4}-\d{2}-\d{2}T[\d:.]+Z \S+ INFO  vpn       vpn\.on\.ok +s=[0-9a-f]{4} ms=5$"), "vpn.on.ok -> component vpn, INFO: " + lines[0]);
                Check(lines[1].Contains(" WARN  vpn ") && lines[1].Contains("msg=x"), "failed -> WARN, free text goes to msg");
                Check(lines[2].Contains(" ERROR launcher ") , "fatal -> ERROR, unknown prefix -> launcher");
                Check(lines[3].Contains("att=on-1") && lines[3].Contains("state=a") && lines[3].Contains("msg=\"b c\""), "k=v fields kept, loose words become msg");
            } finally { try { Directory.Delete(home, true); } catch { } }
        }

        static Dictionary<string, object> Inventory(string name) { return Json.Read(Path.Combine(Fixtures(), name)); }
        static void Conflicts()
        {
            var r = VpnConflict.Evaluate(Inventory("inventory-happ-hardware.json"));
            Check(r.Conflicts.Count == 1 && r.Conflicts[0].Name == "Happ" && r.Conflicts[0].Iface == "happ-xray" && r.Conflicts[0].Route == "0.0.0.0/0", "happ-xray (hardware flag) with 0/0 metric 0 -> conflict Happ");
            r = VpnConflict.Evaluate(Inventory("inventory-happ-iponly.json"));
            Check(r.Conflicts.Count == 1 && r.Conflicts[0].Name == "Happ" && r.Conflicts[0].Why == "ip-only-tunnel", "IP-only happ-default-tun -> conflict");
            r = VpnConflict.Evaluate(Inventory("inventory-tailscale-nofull.json"));
            Check(r.Conflicts.Count == 0 && r.Suspects.Any(s => s.Name == "Tailscale"), "Tailscale without full route -> suspect only");
            r = VpnConflict.Evaluate(Inventory("inventory-tailscale-exit.json"));
            Check(r.Conflicts.Count == 1 && r.Conflicts[0].Name == "Tailscale", "Tailscale exit node (0/1 + 128/1) -> conflict");
            r = VpnConflict.Evaluate(Inventory("inventory-wifi-default.json"));
            Check(r.Conflicts.Count == 0 && r.Suspects.Count == 0, "physical Wi-Fi default route is not a conflict");
            r = VpnConflict.Evaluate(Inventory("inventory-own.json"), @"C:\ProgramData\RemoteAgents\Helper");
            Check(r.Conflicts.Count == 0 && r.Suspects.Count == 0, "RemoteAgents-* and our own sing-box are ignored");
            r = VpnConflict.Evaluate(Inventory("inventory-xray-proc.json"));
            Check(r.Conflicts.Count == 0 && r.Suspects.Any(s => s.Name == "Xray" && s.Kind == "proc"), "xray process without route -> suspect");
            Check(VpnConflict.KnownLabel("Happier") == null && VpnConflict.KnownLabel("happ-xray") == "Happ", "Happier is not Happ");
            Check(VpnTun.Conflict(Inventory("inventory-happ-hardware.json")) == "Happ", "VpnTun.Conflict returns the friendly name");
            var script = VpnTunSession.InventoryScript(false);
            Check(script.Contains("Get-NetIPInterface") && script.Contains("ActiveStore") && script.Contains("\\x00-\\x7F") && VpnTunSession.InventoryScript(true).Contains("Get-Process"), "inventory script has IP interfaces, routes, processes and ASCII escaping");
        }

        sealed class FakeProbe : INetProbe
        {
            internal int Failing; internal string Code = "x";
            StageResult R(int n) { return Failing == n ? StageResult.Fail(n, 3, Code, "d") : StageResult.Pass(n, 3); }
            public StageResult LocalNet() { return R(1); } public StageResult Conflict() { return R(2); } public StageResult Transport() { return R(3); }
            public StageResult Ports(bool vpnOn) { return R(4); } public StageResult Banner() { return R(5); } public StageResult Route() { return R(6); }
            public StageResult Dns() { return R(7); } public StageResult Http() { return R(8); } public StageResult Egress() { return StageResult.Pass(9, 1, "203.0.113.5"); }
        }
        static void Ladder()
        {
            var probe = new FakeProbe();
            var ok = NetLadder.Run(probe, true, NetLadder.Full, ms => { });
            Check(ok.Ok && ok.Egress == "203.0.113.5" && ok.Stages.Count(s => !s.Skipped) == 9, "healthy ladder runs nine stages");
            probe.Failing = 4; probe.Code = "port-closed";
            var bad = NetLadder.Run(probe, true, NetLadder.Slow, ms => { });
            Check(!bad.Ok && bad.FailStage == 4 && bad.Reason == "port-closed", "first failed stage is the diagnosis");
            probe.Failing = 7; probe.Code = "dns-fail"; probe.Failing = 4; var both = NetLadder.Evaluate(new[] { StageResult.Fail(7, 1, "dns-fail"), StageResult.Fail(4, 1, "port-closed"), StageResult.Pass(1, 1) });
            Check(both.FailStage == 4, "evaluate picks the lowest failed stage");
            probe.Failing = 7;
            Check(NetLadder.Run(probe, false, NetLadder.Slow, ms => { }).Ok, "stages 6-9 are skipped while VPN is off");
            Check(NetLadder.Run(probe, true, NetLadder.Quick, ms => { }).Ok, "slow stages are skipped on a quick run");
            var watch = new NetWatch(); var t0 = new DateTime(2026, 11, 20, 9, 0, 0, DateTimeKind.Utc);
            var events = new List<NetTransition>();
            Action<LadderResult, int> feed = (result, seconds) => { var t = watch.Track(result, t0.AddSeconds(seconds)); if (t != null) events.Add(t); };
            feed(ok, 0); feed(ok, 30); feed(bad, 60); feed(bad, 90); feed(ok, 120); feed(ok, 150);
            Check(events.Count == 3 && events[0].To == "ok" && events[1].To == "fail" && events[1].Stage == 4 && events[2].To == "ok", "ok -> fail -> ok gives exactly two transitions after the first state");
            Check(events[2].DownMs == 60000, "down time is measured from the first failure");
            var schedule = new NetSchedule(0);
            Check(schedule.Due(1000, true) == 0 && schedule.Due(NetSchedule.StartDelayMs, true) == NetLadder.Slow, "first run after the start delay");
            schedule.Started(10000, true, NetLadder.Slow);
            Check(schedule.Due(30000, true) == 0 && schedule.Due(40000, true) == NetLadder.Quick && schedule.Due(130000, true) == NetLadder.Slow, "VPN on: quick every 30 s, slow every 120 s");
            schedule.Started(130000, false, NetLadder.Quick);
            Check(schedule.Due(150000, false) == 0 && schedule.Due(190000, false) == NetLadder.Quick, "VPN off: quick every 60 s");
            schedule.Kick(); Check(schedule.Due(131000, false) == NetLadder.Quick, "kick forces a run");
            var ports = NetPorts.Entries(Json.Map(Json.Parse("{\"ports\":{\"sshPort\":2300,\"channelSshAddress\":\"127.0.0.9\",\"channelSocksPort\":2301,\"vpnInPort\":17999,\"happierWebPort\":3005}}")), true);
            Check(ports.Any(p => p.Name == "ssh" && p.Port == 2300) && ports.Any(p => p.Host == "127.0.0.9") && ports.Any(p => p.Name == "vpn-in" && p.Port == 17999) && ports.Any(p => p.Name == "happierWebPort" && p.Port == 3005), "ports come from transport.json");
            Check(NetPorts.Entries(Json.Map(null), false).Any(p => p.Port == 2222) && !NetPorts.Entries(Json.Map(null), false).Any(p => p.Name == "vpn-in"), "defaults without transport.json; vpn-in only when VPN is on");
        }

        static void HelperEvents()
        {
            string dir = Temp("events");
            try {
                var log = new HelperEventLog(dir);
                for (int i = 0; i < 50; i++) log.Write(LogLevel.Info, "helper", "tick", "n", i.ToString(), "pad", new string('z', 400));
                Check(log.Last == 50, "seq counts events");
                var page = log.Read(0, 5000);
                Check(page.Lines.Count > 0 && page.Lines.Count < 50 && page.Next == (ulong)page.Lines.Count && page.Lost == 0, "max bytes limits the page");
                var rest = log.Read(page.Next, 40000);
                Check(rest.Lines.Count == 50 - page.Lines.Count && rest.Next == 50, "next page continues without gaps");
                Check(log.Read(50, 1000).Lines.Count == 0 && log.Read(50, 1000).Next == 50, "nothing new gives an empty page");
                Check(HelperEventLog.SeqOf(page.Lines[0]) == 1, "seq is parsed from the line");
                var again = new HelperEventLog(dir);
                Check(again.Last == 50 && again.Write(LogLevel.Info, "helper", "restart") == 51, "seq continues after a service restart");
                string reply = HelperEventLog.Reply(rest, "10");
                var parsed = Json.Map(Json.Parse(reply));
                Check(Json.Bool(parsed, "ok") && Json.Str(parsed, "helperVersion") == "10" && Json.Array(Json.Get(parsed, "lines")).Length == rest.Lines.Count && Json.Str(parsed, "next") == "50", "reply carries ok, version, lines, next");
                Check(Encoding.UTF8.GetByteCount(HelperEventLog.Reply(log.Read(0, 40000), "10")) < NetHelperProtocol.MaxMessageBytes, "a full page fits one pipe frame");
                // Потеря: убираем старые файлы вручную.
                RaLog.MaxBytes = 3000;
                try { for (int i = 0; i < 400; i++) again.Write(LogLevel.Info, "helper", "bulk", "pad", new string('q', 100)); } finally { RaLog.MaxBytes = 2L * 1024 * 1024; }
                var lost = again.Read(1, 40000);
                Check(lost.Lost > 0 && lost.Lines.Count > 0, "an old cursor reports lost lines");
            } finally { RaLog.MaxBytes = 2L * 1024 * 1024; try { Directory.Delete(dir, true); } catch { } }
        }

        static void Protocol()
        {
            string command; Dictionary<string, object> map;
            Check(NetHelperProtocol.TryRequest("{\"cmd\":\"log.read\",\"after\":12,\"max\":40000}", out command, out map) && command == "log.read", "log.read request is accepted");
            Check(NetHelperProtocol.TryRequest("{\"cmd\":\"log.read\"}", out command, out map), "log.read without arguments is accepted");
            Check(!NetHelperProtocol.TryRequest("{\"cmd\":\"log.read\",\"after\":-1}", out command, out map), "negative cursor is rejected");
            Check(!NetHelperProtocol.TryRequest("{\"cmd\":\"log.read\",\"max\":99999}", out command, out map), "max above 40000 is rejected");
            Check(!NetHelperProtocol.TryRequest("{\"cmd\":\"log.read\",\"path\":\"C:\\\\x\"}", out command, out map), "extra fields are rejected");
            Check(!NetHelperProtocol.TryRequest("{\"cmd\":\"log.read\",\"after\":\"1\"}", out command, out map), "string cursor is rejected");
        }

        static void CorePump()
        {
            string dir = Temp("core");
            try {
                var events = new HelperEventLog(dir); var pump = new CoreLogPump(dir, events);
                File.WriteAllText(Path.Combine(dir, CoreLogPump.FileName), "+0300 2026-11-20 12:00:00 WARN router: x password=abc\r\n+0300 INFO ok\r\nhalf");
                Check(pump.Pump() == 2 && events.Last == 2, "complete lines are moved into helper events");
                File.AppendAllText(Path.Combine(dir, CoreLogPump.FileName), " line\nERROR boom\n");
                Check(pump.Pump() == 2 && events.Last == 4, "the partial line is completed later, nothing is duplicated");
                string all = string.Join("\n", events.Read(0, 40000).Lines);
                Check(all.Contains(" core      core.line") && all.Contains("password=***") && all.Contains(" WARN ") && all.Contains(" ERROR "), "core lines are masked, leveled and marked as core");
                Check(pump.Tail(15).Contains("boom") && !pump.Tail(15).Contains("abc"), "tail is masked");
                File.WriteAllText(Path.Combine(dir, CoreLogPump.FileName), new string('x', 100) + "\n");
                pump.RotateIfLarge(10);
                Check(File.Exists(Path.Combine(dir, CoreLogPump.FileName + ".1")) && !File.Exists(Path.Combine(dir, CoreLogPump.FileName)), "core log rotates before a restart");
            } finally { try { Directory.Delete(dir, true); } catch { } }
        }
    }
}
