using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
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
            NetHelperVersionTests.Run();
            var oldClock = RaLog.Clock; var oldLimits = RaLog.Limits;
            RaLog.Clock = () => new DateTimeOffset(2026, 11, 21, 12, 0, 0, TimeSpan.Zero);
            RaLog.Limits = new LogLimits();
            try {
                Golden(); Mask(); Rotation(); Encoding_(); JournalMapping(); Conflicts(); Ladder(); HelperEvents(); Protocol(); CorePump(); CoreReaderEvents(); UniqueHandlesTest(); WindowLog(); Shipper(); ShipperInvalidUtf8(); ShipperRisks(); SshSender(); Mirror(); Limits();
            } finally { RaLog.Clock = oldClock; RaLog.Limits = oldLimits; }
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
            foreach (string input in new[] { new string('.', 8192), string.Concat(Enumerable.Repeat("_-", 4000)) }) {
                Check(LogMask.Clean(input) == input, "long nonsecret input is preserved");
            }
            Check(LogMask.Clean("x SECRETVALUE y", new[] { "SECRETVALUE" }) == "x *** y", "known secret values are hidden");
            RaLog.Secrets = () => new[] { "HIDDEN-VALUE" };
            try {
                string line = RaLog.Format(RaLog.Clock(), LogLevel.Info, "launcher", "t", new[] { new KeyValuePair<string, string>("msg", "a HIDDEN-VALUE b") }, "0000");
                Check(!line.Contains("HIDDEN-VALUE") && line.Contains("a *** b"), "RaLog.Format hides known secrets");
            } finally { RaLog.Secrets = null; }
        }

        // Микро-тест ограничений журнала: настройки по умолчанию, фальшивые часы, без ожиданий.
        static void Limits()
        {
            string dir = Temp("limits"), other = Temp("limits-other"), cdir = Temp("purge");
            var oldClock = RaLog.Clock; var oldLimits = RaLog.Limits; string oldDir = RaLog.DefaultDir;
            try {
                Check(LogLimits.RepeatWindow == TimeSpan.FromSeconds(60) && LogLimits.EventBurstLines == 20,
                    "default repeat and burst limits stay enabled");
                RaLog.Limits = new LogLimits();
                var t = new DateTimeOffset(2026, 11, 21, 12, 0, 0, TimeSpan.Zero);
                RaLog.Clock = () => t;
                var same = RaLog.Pairs(new[] { "path", "x" });
                for (int i = 0; i < 13; i++) { RaLog.WriteTo(dir, "launcher", LogLevel.Info, "disk", "disk.explorer.unavailable", same); t = t.AddSeconds(5); }
                string text = File.ReadAllText(Path.Combine(dir, "launcher.log"), Encoding.UTF8);
                Check(Regex.Matches(text, "unavailable s=").Count == 2 && text.Contains("count=11 of=disk.explorer.unavailable"),
                    "launcher Info repeats collapse with defaults");
                // Реальный путь: Journal.Write даёт Warn (не режется), поэтому источник пишет событие только при переходе.
                string jhome = Temp("outage"); var journal = new Journal(jhome); var outage = new ExplorerOutage();
                for (int i = 0; i < 13; i++) { string e = outage.Failed(); if (e != null) journal.Write(e); t = t.AddSeconds(5); }
                string r = outage.Recovered(); if (r != null) journal.Write(r);
                Check(outage.Recovered() == null, "recovery is reported once");
                string jtext = File.ReadAllText(Path.Combine(jhome, "logs", "launcher.log"), Encoding.UTF8);
                Check(Regex.Matches(jtext, "disk.explorer.unavailable").Count == 1 && Regex.Matches(jtext, "disk.explorer.recovered").Count == 1,
                    "explorer outage loop writes one unavailable line and one recovery line");
                t = t.AddSeconds(120);
                for (int i = 0; i < 24; i++) RaLog.WriteTo(dir, "launcher", LogLevel.Info, "disk", "disk.noise", RaLog.Pairs(new[] { "n", i.ToString() }));
                text = File.ReadAllText(Path.Combine(dir, "launcher.log"), Encoding.UTF8);
                Check(Regex.Matches(text, @"disk\.noise\s+s=").Count == 20, "default burst cap keeps 20 distinct launcher Info lines");
                t = t.AddSeconds(61);
                RaLog.WriteTo(dir, "launcher", LogLevel.Info, "disk", "disk.other", null);
                text = File.ReadAllText(Path.Combine(dir, "launcher.log"), Encoding.UTF8);
                Check(text.Contains("count=4 of=disk.noise reason=rate"), "expired rate counter flushes on next launcher write");

                // Каждый случай содержит повторы и превышает предел частоты; ни одна строка не должна исчезнуть.
                RaLog.Limits = new LogLimits();
                foreach (string stream in new[] { "launcher", "helper-events", "config-window", "transport", "bus" })
                    foreach (string comp in new[] { "disk", "vpn", "net", "helper", "core", "config" })
                        foreach (LogLevel level in new[] { LogLevel.Debug, LogLevel.Info, LogLevel.Warn, LogLevel.Error }) {
                            if (stream == "launcher" && comp == "disk" && level < LogLevel.Warn) continue;
                            string evt = "bypass." + comp + "." + level.ToString().ToLowerInvariant();
                            for (int i = 0; i < 50; i++) RaLog.WriteTo(other, stream, level, comp, evt, RaLog.Pairs(new[] { "n", (i % 25).ToString() }));
                            string[] lines = File.ReadAllLines(Path.Combine(other, stream + ".log"), Encoding.UTF8);
                            Check(lines.Count(line => line.Contains(evt + " ")) == 50, stream + "/" + comp + "/" + level + " bypasses both limits");
                        }
                Check(RaLog.Limits.Tracked == 0, "bypassed events do not enter limiter state");

                // Drain работает без Configure: сводки уходят в исходные каталоги WriteTo, один раз, до отправки.
                for (int i = 0; i < 4; i++) RaLog.WriteTo(dir, "launcher", LogLevel.Info, "disk", "drain.same", same);
                for (int i = 0; i < 23; i++) RaLog.WriteTo(other, "launcher", LogLevel.Info, "disk", "drain.rate", RaLog.Pairs(new[] { "n", i.ToString() }));
                RaLog.Configure(null);
                RaLog.FlushLimits();
                Check(RaLog.Limits.Tracked == 0, "Drain clears all limiter state");
                text = File.ReadAllText(Path.Combine(dir, "launcher.log"), Encoding.UTF8);
                string otherText = File.ReadAllText(Path.Combine(other, "launcher.log"), Encoding.UTF8);
                Check(text.Contains("count=3 of=drain.same") && !otherText.Contains("of=drain.same"), "Drain writes repeat summary to original directory");
                Check(otherText.Contains("count=3 of=drain.rate reason=rate") && !text.Contains("of=drain.rate"), "Drain writes rate summary to its own directory");
                RaLog.FlushLimits();
                Check(text == File.ReadAllText(Path.Combine(dir, "launcher.log"), Encoding.UTF8) &&
                    otherText == File.ReadAllText(Path.Combine(other, "launcher.log"), Encoding.UTF8), "second Drain writes no duplicate summaries");
                var sender = new FakeSender();
                var shipper = new LogShipper(dir, dir, sender, (lvl, evt, kv) => { }, "device", "host", "1", () => t.UtcDateTime);
                Check(shipper.Cycle(false) == 1 && sender.Texts.Single().Contains("count=3 of=drain.same"), "drained summary is included in next shipment");

                // PurgeArchives удаляет только по сроку, даже если архивов больше прежних 20 МиБ.
                string old = Path.Combine(cdir, "a.log.1"), fresh = Path.Combine(cdir, "a.log.2"), big = Path.Combine(cdir, "b.log.1"), live = Path.Combine(cdir, "a.log"), foreign = Path.Combine(cdir, "a.log.backup");
                File.WriteAllText(old, "x"); File.WriteAllText(fresh, "x"); File.WriteAllText(live, "x"); File.WriteAllText(foreign, "x");
                using (var file = File.Create(big)) file.SetLength(21L * 1024 * 1024);
                File.SetLastWriteTimeUtc(old, t.UtcDateTime.AddDays(-15)); File.SetLastWriteTimeUtc(fresh, t.UtcDateTime.AddDays(-14)); File.SetLastWriteTimeUtc(big, t.UtcDateTime.AddDays(-2));
                File.SetLastWriteTimeUtc(live, t.UtcDateTime.AddDays(-15)); File.SetLastWriteTimeUtc(foreign, t.UtcDateTime.AddDays(-15));
                Check(LogLimits.PurgeArchives(cdir, t) == 1 && !File.Exists(old) && File.Exists(fresh) && File.Exists(big) && File.Exists(live) && File.Exists(foreign),
                    "only expired numbered archives are purged; 21 MiB of recent archives survives");
                // Общий предел 60 МиБ по-прежнему применяется при ротации; второго предела архивов нет.
                Check(RaLog.TotalLimit == 60L * 1024 * 1024, "directory total limit stays 60 MiB");
                using (var file = File.OpenWrite(fresh)) file.SetLength(41L * 1024 * 1024);
                File.SetLastWriteTimeUtc(fresh, t.UtcDateTime.AddDays(-1));
                File.WriteAllText(Path.Combine(cdir, "trigger.log"), "x");
                long oldMax = RaLog.MaxBytes;
                try {
                    RaLog.MaxBytes = 1;
                    RaLog.WriteTo(cdir, "trigger", LogLevel.Warn, "launcher", "rotate", null);
                } finally { RaLog.MaxBytes = oldMax; }
                Check(!File.Exists(fresh) && File.Exists(big) && Directory.GetFiles(cdir, "*.log*").Sum(path => new FileInfo(path).Length) <= RaLog.TotalLimit,
                    "rotation enforces directory total by removing archives");
                var small = new LogLimits(); int oldKeys = LogLimits.MaxTrackedKeys; LogLimits.MaxTrackedKeys = 8;
                try { var sink = new List<LogLimits.Summary>(); for (int i = 0; i < 100; i++) small.Allow(dir, "launcher", LogLevel.Info, "disk", "e", RaLog.Pairs(new[] { "i", i.ToString() }), t, sink); Check(small.Tracked <= 8 + 1, "tracked keys are bounded"); }
                finally { LogLimits.MaxTrackedKeys = oldKeys; }
            } finally {
                RaLog.Clock = oldClock; RaLog.Limits = oldLimits; RaLog.Configure(oldDir);
                foreach (string path in new[] { dir, other, cdir }) try { Directory.Delete(path, true); } catch { }
            }
        }

        static void WindowLog()
        {
            string dir = Temp("window");
            try {
                string[] parts = Enumerable.Range(0, 50).Select(i => "Строка " + (i % 25)).ToArray();
                DiagnosticReport.WriteWindowLog(dir, string.Join("\n", parts), new string[0]);
                string[] lines = File.ReadAllLines(Path.Combine(dir, "config-window.log"), Encoding.UTF8);
                Check(lines.Length == parts.Length, "WriteWindowLog keeps all 50 lines including repeats");
                Check(lines.SequenceEqual(parts.Select(part => RaLog.Format(RaLog.Clock(), LogLevel.Info, "config", "window.text", RaLog.Pairs(new[] { "msg", part }), RaLog.Session))),
                    "WriteWindowLog preserves complete text in original order");
            } finally { try { Directory.Delete(dir, true); } catch { } }
        }

        static void Rotation()
        {
            string dir = Temp("rotate");
            long oldMax = RaLog.MaxBytes; int oldArchives = RaLog.MaxArchives;
            try {
                Check(RaLog.MaxBytes == 2L * 1024 * 1024 && RaLog.MaxArchives == 5, "defaults are 2 MiB and 5 archives");
                RaLog.MaxBytes = 4000;
                for (int i = 0; i < 400; i++) RaLog.WriteTo(dir, "launcher", LogLevel.Warn, "launcher", "tick", new[] { new KeyValuePair<string, string>("n", i.ToString()), new KeyValuePair<string, string>("pad", new string('p', 60)) });
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
            r = VpnConflict.Evaluate(Inventory("inventory-wifi-happ-installed.json"));
            Check(r.Conflicts.Count == 0 && r.Suspects.Any(x => x.Name == "Happ"), "Wi-Fi with default route + installed Happ -> suspects only");
            r = VpnConflict.Evaluate(Inventory("inventory-modem-tailscaled.json"));
            Check(r.Conflicts.Count == 0 && r.Suspects.Any(x => x.Name == "Tailscale"), "modem without gateway + tailscaled -> not a conflict");
            r = VpnConflict.Evaluate(Inventory("inventory-physical-v6only.json"));
            Check(r.Conflicts.Count == 0, "physical adapter with only ::/0 is not a conflict");
            r = VpnConflict.Evaluate(Inventory("inventory-single-half.json"));
            Check(r.Conflicts.Count == 0, "a single /1 route is not a full route");
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
            Check(schedule.Due(0, true) == 0, "no run before block.ready transport");
            schedule.TransportReady(10000); Check(schedule.Due(10000, true) == NetLadder.Slow, "first run on block.ready transport");
            schedule.Started(10000, true, NetLadder.Slow);
            Check(schedule.Due(30000, true) == 0 && schedule.Due(40000, true) == NetLadder.Quick && schedule.Due(130000, true) == NetLadder.Slow, "VPN on: quick every 30 s, slow every 120 s");
            schedule.Started(130000, false, NetLadder.Quick);
            Check(schedule.Due(150000, false) == 0 && schedule.Due(190000, false) == NetLadder.Quick, "VPN off: quick every 60 s");
            schedule.Kick(); Check(schedule.Due(131000, false) == NetLadder.Quick, "kick forces a run");
            // Образец status/transport.json: ports{...serverPort}, localWeb{enabled, available, port}; channelFirst — из config.json.
            const string sample = "{\"ports\":{\"sshPort\":2300,\"channelSocksPort\":2301,\"vpnInPort\":17999,\"channelSshAddress\":\"127.0.0.9\",\"serverPort\":2200},\"localWeb\":{\"enabled\":true,\"available\":true,\"port\":3005,\"serverPort\":3005}}";
            var transport = Json.Map(Json.Parse(sample));
            var plain = NetPorts.Entries(transport, false);
            Check(plain.Length == 2 && plain.Any(p => p.Name == "ssh" && p.Port == 2300) && plain.Any(p => p.Name == "happier-web" && p.Port == 3005), "without channelFirst only the local ssh entry and Happier web are checked");
            var channel = NetPorts.Entries(transport, true, true);
            Check(channel.Any(p => p.Name == "channel-ssh" && p.Host == "127.0.0.9" && p.Port == 2200) && channel.Any(p => p.Name == "channel-socks" && p.Port == 2301) && channel.Any(p => p.Name == "vpn-in" && p.Port == 17999), "channelFirst adds channel ssh (server port) and socks; VPN adds vpn-in");
            Check(!NetPorts.Entries(Json.Parse("{\"localWeb\":{\"enabled\":true,\"available\":false,\"port\":3005}}") as Dictionary<string, object>, false).Any(p => p.Name == "happier-web"), "unavailable local web is not checked");
            Check(NetPorts.Entries(Json.Map(null), false).Single().Port == 2222, "defaults without transport.json");
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
                var reset = log.Read(500, 1000);
                Check(reset.Reset && reset.Next == 50 && reset.Lines.Count == 0 && Json.Bool(Json.Map(Json.Parse(HelperEventLog.Reply(reset, "10"))), "reset"), "a cursor ahead of the journal resets to the last seq");
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

        static void CoreReaderEvents()
        {
            string dir = Temp("corereader");
            try {
                var events = new HelperEventLog(dir); var bus = new EventBus(true); var seen = new List<string>();
                bus.Subscribe("singbox.", e => seen.Add(e.Topic + "|" + e["core"] + "|" + e["line"]));
                Action<string, string[]> publish = (t, kv) => bus.Publish(t, BusTopics.Sources.VpnCore, kv);
                string path = Path.Combine(dir, CoreLogPump.FileName);
                string text = "+0300 INFO router: rules password=abc\r\n+0300 INFO inbound connection from x\r\n+0300 WARN dns: slow\r\n+0300 INFO sing-box started (0.5s)\r\n+0300 FATAL start service: boom\r\npart";
                var bytes = Encoding.UTF8.GetBytes(text + "ial\n");
                var reader = new CoreOutputReader(new ChunkedStream(bytes, 7), path, "vpn", publish);
                reader.Start();
                Check(reader.Join(5000) && reader.Eof.WaitOne(0), "reader ends at end of stream");
                Check(reader.Ready.WaitOne(0) && reader.ReadyLine.Contains("sing-box started ("), "ready is set by the started line");
                Check(reader.LastFatal.Contains("boom"), "fatal line is remembered");
                Check(reader.Lines == 6, "split chunks are glued into lines, got " + reader.Lines);
                Check(reader.Drain(events) == 4 && reader.Sent == 4 && reader.Dropped == 0, "only router/WARN/started/FATAL lines are queued, inbound connection is filtered");
                bus.DrainOnce();
                Check(seen.Count(x => x.StartsWith("singbox.started|vpn|")) == 1 && seen.Count(x => x.StartsWith("singbox.fatal|vpn|")) == 1 && seen.Count(x => x.StartsWith("singbox.line|vpn|")) == 4, "bus got started, fatal and filtered lines: " + string.Join(";", seen));
                string all = string.Join("\n", events.Read(0, 40000).Lines);
                Check(all.Contains("core.line") && all.Contains("password=***") && !all.Contains("inbound connection"), "helper events are masked and filtered");
                Check(File.ReadAllText(path).Contains("inbound connection") && File.ReadAllText(path).Contains("partial"), "the local file keeps every line");
                reader.WriteStats(events); reader.WriteStats(events);
                Check(string.Join("\n", events.Read(0, 40000).Lines).Split(new[] { "core.stats" }, StringSplitOptions.None).Length == 2, "stats are written once");
                CoreReaderRotation();
                Check(reader.Tail(2).Contains("partial"), "in-memory tail is available without the file");
                var many = new StringBuilder(); for (int i = 0; i < CoreOutputReader.QueueLimit + 5; i++) many.Append("WARN x\n");
                var flood = new CoreOutputReader(new ChunkedStream(Encoding.UTF8.GetBytes(many.ToString()), 4096), null, "vpn", null); flood.Start(); flood.Join(5000);
                Check(flood.Sent == CoreOutputReader.QueueLimit && flood.Dropped == 5, "the queue is bounded, overflow is counted");
            } finally { try { Directory.Delete(dir, true); } catch { } }
        }
        static void CoreReaderRotation()
        {
            string dir = Temp("corerotate");
            try {
                string path = Path.Combine(dir, CoreLogPump.FileName);
                string line = "INFO router: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n";
                var data = Encoding.UTF8.GetBytes(string.Concat(Enumerable.Repeat(line, 6)));
                var r = new CoreOutputReader(new ChunkedStream(data, line.Length), path, "vpn", null, 120);
                r.Start();
                Check(r.Join(5000) && r.Lines == 6, "rotation: every line is still read");
                Check(File.Exists(path + ".1") && new FileInfo(path).Length < new FileInfo(path + ".1").Length + line.Length && File.ReadAllText(path).StartsWith("INFO"), "rotation: .1 appears and the file starts anew");
                // Move не удаётся (.1 — каталог): одна запись в шину, файл усекается, а не растёт.
                string dir2 = Temp("corerotate2");
                try {
                    string path2 = Path.Combine(dir2, CoreLogPump.FileName); Directory.CreateDirectory(path2 + ".1");
                    var seen = new List<string>();
                    var r2 = new CoreOutputReader(new ChunkedStream(Encoding.UTF8.GetBytes(string.Concat(Enumerable.Repeat(line, 20))), line.Length), path2, "vpn", (t, kv) => seen.Add(t), 120);
                    r2.Start();
                    Check(r2.Join(5000) && r2.Lines == 20, "rotation failure: reading continues");
                    Check(seen.Count(x => x == BusTopics.SingboxLine) == 1, "rotation failure: reported once, got " + seen.Count);
                    Check(new FileInfo(path2).Length <= 120 + line.Length, "rotation failure: file is truncated, growth is bounded");
                } finally { try { Directory.Delete(dir2, true); } catch { } }
            } finally { try { Directory.Delete(dir, true); } catch { } }
        }
        static void UniqueHandlesTest()
        {
            var u = NativeJob.UniqueHandles(new IntPtr(4), new IntPtr(8), new IntPtr(8), IntPtr.Zero);
            Check(u.Length == 2 && u[0] == new IntPtr(4) && u[1] == new IntPtr(8), "inherited handle list has no duplicates");
        }
        sealed class ChunkedStream : MemoryStream
        {
            readonly int chunk;
            internal ChunkedStream(byte[] data, int chunk) : base(data) { this.chunk = chunk; }
            public override int Read(byte[] buffer, int offset, int count) { return base.Read(buffer, offset, Math.Min(count, chunk)); }
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
                string[] burst = Enumerable.Range(0, 120).Select(i => "INFO core output " + (i % 30)).ToArray();
                File.AppendAllText(Path.Combine(dir, CoreLogPump.FileName), string.Join("\n", burst) + "\n");
                Check(pump.Pump() == 120 && events.Last == 124 && pump.Pump() == 0, "CorePump keeps 120 burst lines exactly once");
                var page = events.Read(0, HelperEventLog.MaxRead);
                Check(page.Lost == 0 && page.Next == 124 && page.Lines.Select(HelperEventLog.SeqOf).SequenceEqual(Enumerable.Range(1, 124).Select(i => (ulong)i)),
                    "CorePump helper-events seq has no gaps");
                Check(page.Lines.Skip(4).Select((line, i) => line.EndsWith("text=" + RaLog.QuoteValue(burst[i]), StringComparison.Ordinal)).All(ok => ok),
                    "all core burst text, including repeats, is preserved in order");
                File.WriteAllText(Path.Combine(dir, CoreLogPump.FileName), new string('x', 100) + "\n");
                pump.RotateIfLarge(10);
                Check(File.Exists(Path.Combine(dir, CoreLogPump.FileName + ".1")) && !File.Exists(Path.Combine(dir, CoreLogPump.FileName)), "core log rotates before a restart");
            } finally { try { Directory.Delete(dir, true); } catch { } }
        }

        sealed class FakeSender : ILogSender
        {
            internal readonly List<string> Texts = new List<string>(); internal readonly List<string> PathsTried = new List<string>();
            internal bool FailChannel, FailDirect;
            internal Action DuringSend;
            internal readonly List<byte[]> Bodies = new List<byte[]>();
            public SendResult Send(byte[] gz, string batchId, string path, int timeoutMs)
            {
                PathsTried.Add(path);
                if (DuringSend != null) DuringSend();
                if ((path == "channel" && FailChannel) || (path == "direct" && FailDirect)) return new SendResult { Err = "ssh-exit", Exit = 255, Stderr = "refused" };
                using (var ms = new MemoryStream(gz)) using (var z = new GZipStream(ms, CompressionMode.Decompress)) using (var raw = new MemoryStream()) {
                    z.CopyTo(raw); var body = raw.ToArray(); Bodies.Add(body); Texts.Add(Encoding.UTF8.GetString(body));
                }
                return new SendResult { Ok = true };
            }
        }
        static void WriteLog(string path, int from, int count, bool bom)
        {
            var text = new StringBuilder();
            for (int i = from; i < from + count; i++) text.Append("2026-11-20T09:00:" + (i % 60).ToString("00") + ".000Z 12:00:00.000+03:00 INFO  vpn       tick           s=1111 n=" + i + "\n");
            using (var f = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite)) {
                if (bom && f.Length == 0) f.Write(new byte[] { 0xEF, 0xBB, 0xBF }, 0, 3);
                var bytes = new UTF8Encoding(false).GetBytes(text.ToString()); f.Write(bytes, 0, bytes.Length);
            }
        }
        static int Lines(string text) { return text.Split('\n').Count(l => l.Contains(" tick ")); }

        static void Shipper()
        {
            string dir = Temp("ship"); string logs = Path.Combine(dir, "logs"), state = Path.Combine(dir, "state"); Directory.CreateDirectory(logs); Directory.CreateDirectory(state);
            try {
                var clock = new DateTime(2026, 11, 20, 9, 0, 0, DateTimeKind.Utc);
                var events = new List<string>(); var sender = new FakeSender();
                var shipper = new LogShipper(logs, state, sender, (lvl, evt, kv) => events.Add(evt + " " + string.Join(",", kv)), "Компьютер", "WIN-1", "1.0", () => clock);
                WriteLog(Path.Combine(logs, "launcher.log"), 0, 3, true);
                File.AppendAllText(Path.Combine(logs, "launcher.log"), "partial line without end");
                sender.FailChannel = sender.FailDirect = true;
                Check(shipper.Cycle(false) == 0 && !File.Exists(Path.Combine(state, "log-ship.json")), "cursor does not move without OK");
                Check(sender.PathsTried.SequenceEqual(new[] { "channel", "direct" }) && events.Any(e => e.StartsWith("ship.failed path,channel")) && events.Any(e => e.StartsWith("ship.failed path,direct")), "channel then direct are tried and logged");
                Check(shipper.FailureCount == 1 && (shipper.NextAt - clock).TotalSeconds == 60, "backoff 60 s");
                shipper.Kick(); Check((shipper.NextAt - clock).TotalSeconds == 60, "ERROR cannot shorten failure backoff");
                shipper.Cycle(false); Check((shipper.NextAt - clock).TotalSeconds == 120, "backoff 120 s");
                shipper.Cycle(false); shipper.Cycle(false); Check((shipper.NextAt - clock).TotalSeconds == 300 && LogShipper.DelaySeconds(9) == 300, "backoff stops at 300 s");
                sender.FailChannel = true; sender.FailDirect = false; sender.Texts.Clear(); sender.PathsTried.Clear();
                Check(shipper.Cycle(false) == 1 && sender.PathsTried.SequenceEqual(new[] { "channel", "direct" }), "direct path works when the channel is down");
                string first = sender.Texts[0];
                Check(first.StartsWith("RA-LOGS 1 batch=") && first.Contains("device=" + LogShipper.Base64Url("Компьютер")) && first.Contains("host=WIN-1") && Lines(first) == 3 && !first.Contains("partial line"), "header, three whole lines, partial tail is not sent");
                Check(shipper.FailureCount == 0 && (shipper.NextAt - clock).TotalSeconds == 60, "success resets the backoff");
                sender.Texts.Clear(); sender.FailChannel = false;
                Check(shipper.Cycle(false) == 0 && sender.Texts.Count == 0, "nothing new -> nothing sent");
                File.AppendAllText(Path.Combine(logs, "launcher.log"), " finished\n");
                WriteLog(Path.Combine(logs, "launcher.log"), 3, 2, false);
                Check(shipper.Cycle(false) == 1 && Lines(sender.Texts[0]) == 2 && sender.Texts[0].Contains("partial line without end finished"), "only new lines, the completed line is sent once");
                // Ротация: хвост уходит в .1, появляется новый файл — без дублей.
                WriteLog(Path.Combine(logs, "launcher.log"), 5, 2, false);
                File.Move(Path.Combine(logs, "launcher.log"), Path.Combine(logs, "launcher.log.1"));
                WriteLog(Path.Combine(logs, "launcher.log"), 7, 2, true);
                sender.Texts.Clear();
                shipper.Cycle(false);
                string all = string.Join("\n", sender.Texts);
                Check(Lines(all) == 4 && all.Contains("n=5") && all.Contains("n=8") && !all.Contains("n=4\n") && !all.Contains("n=3\n"), "rotation: rest of the old file plus the new file, no duplicates");
                // Потеря: отпечаток неизвестен.
                File.WriteAllText(Path.Combine(state, "log-ship.json"), "{\"streams\":{\"launcher\":{\"fp\":\"deadbeef\",\"fpLen\":10,\"off\":\"5\"}}}");
                events.Clear(); sender.Texts.Clear();
                sender.FailChannel = sender.FailDirect = true;
                shipper.Cycle(false); shipper.Cycle(false);
                Check(events.Count(e => e.StartsWith("ship.gap")) == 1, "one ship.gap per missing fingerprint across retries");
                sender.FailChannel = sender.FailDirect = false;
                shipper.Cycle(false);
                Check(events.Any(e => e.StartsWith("ship.gap stream,launcher,lost,unknown")) && sender.Texts.Count == 1, "unknown fingerprint gives ship.gap and restarts from the oldest file");
                // Лимит пачки 512 КБ.
                WriteLog(Path.Combine(logs, "transport.log"), 0, 12000, true);
                sender.Texts.Clear();
                int batches = shipper.Cycle(false);
                Check(batches >= 2 && sender.Texts.Where(t => t.Contains("@@ transport")).All(t => Encoding.UTF8.GetByteCount(t) <= LogShipper.MaxRawBytes + 2048), "batches are limited to 512 KiB of text");
                Check(Lines(string.Join("\n", sender.Texts.Where(t => t.Contains("@@ transport")))) == 12000, "all lines of a large file arrive exactly once");
                // Не больше 8 пачек за цикл.
                WriteLog(Path.Combine(logs, "core.log"), 0, 80000, true);
                sender.Texts.Clear();
                Check(shipper.Cycle(false) == 8, "at most eight batches per cycle");
            } finally { try { Directory.Delete(dir, true); } catch { } }
        }

        static void SshSender()
        {
            var source = new[] { "-o", "ConnectTimeout=15", "-o", "StrictHostKeyChecking=yes", "-n", "-p", "2222", "user@server.example" };
            var args = SshLogSender.BuildArguments(source, "channel-alias", "c2NyaXB0");
            Check(args.Contains("HostKeyAlias=channel-alias") && args.Contains("user@server.example") && args.Contains("2222") && !args.Contains("-n"), "direct SSH keeps alias, server and port, accepts stdin");
            Check(Array.IndexOf(args, "ConnectTimeout=8") < Array.IndexOf(args, "ConnectTimeout=15"), "ship timeout precedes base timeout");
            string home = Temp("ssh-source");
            try {
                var update = new Dictionary<string, object> { { "args", source }, { "hostKeyAlias", "channel-alias" }, { "viaLocalPort", 2345 } };
                var channel = SshSource.Load(Configuration.ForUpdate(Json.Encode(update)), home);
                update.Remove("viaLocalPort");
                var direct = SshSource.Load(Configuration.ForUpdate(Json.Encode(update)), home);
                var directArgs = SshLogSender.BuildArguments(direct.Args, direct.HostKeyAlias, "script");
                Check(channel.HostKeyAlias == direct.HostKeyAlias && directArgs.Contains("HostKeyAlias=channel-alias") && directArgs.Contains("user@server.example") && directArgs.Contains("2222") && !directArgs.Contains("2345") && !directArgs.Contains("-n"), "direct config preserves channel alias and original remote port");
            } finally { Directory.Delete(home, true); }
            string id = Guid.NewGuid().ToString("N"), ok = "OK batch=" + id + " stored=12";
            Check(SshLogSender.ValidReply(0, ok + "\n", id) && SshLogSender.ValidReply(0, ok, id), "exact successful acknowledgement");
            foreach (string bad in new[] { "OK batch=foreign stored=1", ok + "extra", ok + "\nextra\n", "\n" + ok, ok + "\n\n", "ERR failed" })
                Check(!SshLogSender.ValidReply(0, bad, id), "reject malformed/foreign acknowledgement");
            Check(!SshLogSender.ValidReply(255, ok, id), "nonzero exit rejects OK");
        }

        static void ShipperInvalidUtf8()
        {
            string dir = Temp("ship-invalid-utf8"), logs = Path.Combine(dir, "logs"), state = Path.Combine(dir, "state");
            Directory.CreateDirectory(logs); Directory.CreateDirectory(state);
            try {
                var body = Encoding.UTF8.GetBytes("first Я\nbad ").Concat(new byte[] { 0xFF }).Concat(Encoding.UTF8.GetBytes(" middle\ntail\n")).ToArray();
                var source = new byte[] { 0xEF, 0xBB, 0xBF }.Concat(body).ToArray();
                File.WriteAllBytes(Path.Combine(logs, "launcher.log"), source);
                var sender = new FakeSender();
                var shipper = new LogShipper(logs, state, sender, (level, evt, kv) => { }, "device", "host", "1", () => RaLog.Clock().UtcDateTime);
                Check(shipper.Cycle(false) == 1 && sender.Bodies.Count == 1, "invalid UTF-8 file is shipped once");
                byte[] packed = sender.Bodies.Single();
                int bodyStart = Array.IndexOf(packed, (byte)10, Array.IndexOf(packed, (byte)10) + 1) + 1;
                Check(packed.Skip(bodyStart).SequenceEqual(body), "0xFF and original UTF-8 bytes survive gzip packing exactly");
                string metadata = Encoding.UTF8.GetString(packed, 0, bodyStart);
                Check(metadata.Contains(" from=3 to=" + source.Length + " lines=3\n"), "byte offsets and newline count match the raw body");
                var cursors = Json.Map(Json.Get(Json.Read(Path.Combine(state, "log-ship.json")), "streams"));
                Check(Json.Str(Json.Map(cursors["launcher"]), "off") == source.Length.ToString(), "invalid UTF-8 cursor advances to the file end after OK");
                Check(shipper.Cycle(false) == 0 && sender.Bodies.Count == 1, "next cycle has nothing to ship after invalid UTF-8");
            } finally { try { Directory.Delete(dir, true); } catch { } }
        }

        static void ShipperRisks()
        {
            string dir = Temp("ship-risks"), logs = Path.Combine(dir, "logs"), state = Path.Combine(dir, "state");
            Directory.CreateDirectory(logs); Directory.CreateDirectory(state);
            try {
                var sender = new FakeSender();
                var shipper = new LogShipper(logs, state, sender,
                    (level, evt, kv) => RaLog.WriteTo(logs, "launcher", level, "ship", evt, RaLog.Pairs(kv)), "device", "host", "1", () => RaLog.Clock().UtcDateTime);
                WriteLog(Path.Combine(logs, "launcher.log"), 0, 3, true);
                Check(shipper.Cycle(false) == 1, "success through actual RaLog writer");
                sender.Texts.Clear();
                Check(shipper.Cycle(false) == 0 && sender.Texts.Count == 0, "ship DEBUG never feeds the next cycle");
                RaLog.WriteTo(logs, "launcher", LogLevel.Debug, "ship", "ship.test", null);
                Check(!File.ReadAllText(Path.Combine(logs, "launcher.log")).Contains("ship.test"), "RaLog filters ship DEBUG");
                WriteLog(Path.Combine(logs, "launcher.log"), 3, 1, false);
                sender.DuringSend = () => shipper.Kick();
                shipper.Cycle(false);
                Check(shipper.NextAt == RaLog.Clock().UtcDateTime.AddSeconds(5), "Kick during successful cycle uses injected clock");
                sender.DuringSend = null;
                WriteLog(Path.Combine(logs, "launcher.log"), 4, 1, false);
                sender.FailChannel = true; sender.PathsTried.Clear();
                shipper.Cycle(true, DateTime.MaxValue);
                Check(sender.PathsTried.SequenceEqual(new[] { "channel", "direct" }), "exit cycle can fall back to direct before stopping components");
                sender.FailChannel = false;
                // Синхронный цикл выхода, без ожиданий и проверок реальных тайм-аутов.
                WriteLog(Path.Combine(logs, "core.log"), 0, 18000, true);
                sender.PathsTried.Clear(); sender.Texts.Clear();
                Check(shipper.Cycle(true, DateTime.MaxValue) == 2 && sender.Texts.Count == 2,
                    "exit cycle sends at most two batches");
                Check(shipper.Cycle(false) > 0, "remaining batches stay available for the next cycle");
            } finally { try { Directory.Delete(dir, true); } catch { } }
        }

        static void Mirror()
        {
            string dir = Temp("mirror"); string logs = Path.Combine(dir, "logs"), state = Path.Combine(dir, "state"); Directory.CreateDirectory(logs); Directory.CreateDirectory(state);
            try {
                int calls = 0; string version = "9"; bool ready = true; var events = new List<string>();
                Func<ulong, int, Dictionary<string, object>> read = (after, max) => {
                    calls++;
                    if (after >= 3) return Json.Map(Json.Parse("{\"ok\":true,\"lines\":[],\"next\":3,\"lost\":0,\"reset\":false}"));
                    return Json.Map(Json.Parse("{\"ok\":true,\"lines\":[\"2026-11-20T09:00:00.000Z 12:00:00.000+03:00 INFO  helper    stage s=1 seq=1\",\"2026-11-20T09:00:01.000Z 12:00:01.000+03:00 WARN  core      core.line s=1 seq=2 text=x\",\"2026-11-20T09:00:02.000Z 12:00:02.000+03:00 INFO  helper    cmd.done s=1 seq=3\"],\"next\":3,\"lost\":2,\"reset\":false}"));
                };
                var mirror = new HelperLogMirror(logs, state, () => ready, () => version, read, (lvl, evt, kv) => events.Add(evt));
                Check(mirror.Pull() == -1 && calls == 0, "helper v9 is never asked (a bad command would close the pipe)");
                version = "10"; ready = false; Check(mirror.Pull() == -1 && calls == 0, "disconnected helper is not asked");
                ready = true;
                Check(mirror.Pull() == 3, "three lines are mirrored");
                string helper = File.ReadAllText(Path.Combine(logs, "helper.log"), Encoding.UTF8), core = File.ReadAllText(Path.Combine(logs, "core.log"), Encoding.UTF8);
                Check(helper.Contains("seq=1") && helper.Contains("seq=3") && !helper.Contains("seq=2") && core.Contains("seq=2") && !core.Contains("seq=1"), "core lines go to core.log, the rest to helper.log");
                Check(events.Contains("helper.log-lost"), "lost lines are reported");
                int before = calls; Check(mirror.Pull() == 0 && calls == before + 1 && File.ReadAllText(Path.Combine(state, "helper-log-cursor.json")).Contains("\"3\""), "cursor is stored and nothing is duplicated");
                var failing = new HelperLogMirror(logs, state, () => true, () => "10", (a, m) => { throw new IOException("pipe closed"); }, (lvl, evt, kv) => events.Add(evt));
                Check(failing.Pull() == -1 && events.Contains("helper.unreachable"), "a read exception is caught and reported once");
                var resetMirror = new HelperLogMirror(logs, state, () => true, () => "10", (a, m) => Json.Map(Json.Parse("{\"ok\":true,\"lines\":[],\"next\":1,\"lost\":0,\"reset\":true}")), (lvl, evt, kv) => events.Add(evt));
                resetMirror.Pull(); Check(events.Contains("helper.log-reset") && File.ReadAllText(Path.Combine(state, "helper-log-cursor.json")).Contains("\"1\""), "journal reset moves the cursor back");
            } finally { try { Directory.Delete(dir, true); } catch { } }
        }
    }
}
