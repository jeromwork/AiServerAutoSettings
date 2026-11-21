using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;

namespace RemoteAgents.Launcher
{
    // Только ручные события и подставные часы, без опроса и ожиданий.
    public static class JournalFloodTests
    {
        static int checks;
        static readonly DateTime Now = new DateTime(2026, 11, 21, 12, 0, 0, DateTimeKind.Utc);
        static void Check(bool ok, string message) { if (!ok) throw new Exception(message); checks++; }
        static Dictionary<string, object> Status(string json) { return Json.Map(Json.Parse(json)); }
        public static int Main()
        {
            string dir = Path.Combine(Path.GetTempPath(), "ra-journal-flood-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            var oldClock = RaLog.Clock; RaLog.Clock = () => new DateTimeOffset(Now);
            try {
                StatusTransitions(dir); BusRepeats(); CoreRepeats(); WriteRecovery(dir); Mirror(dir); MirrorRecovery(dir); MirrorSummaryRecovery(dir); ParallelWrites(dir); Rotation(dir);
                Console.WriteLine("PASS: JournalFloodTests (" + checks + " checks, manual events, no timers)");
                return 0;
            } finally { RaLog.Clock = oldClock; Directory.Delete(dir, true); }
        }

        static void StatusTransitions(string dir)
        {
            using (var bus = new EventBus(manualDispatch: true)) {
                var health = new List<string>(); var events = new List<BusEvent>();
                using (var journal = new HealthJournal(bus, sink: health.Add)) {
                    bus.Subscribe("block.", events.Add);
                    var tracker = new BlockStatusTracker(bus, Now, () => Now, p => Now);
                    string launcher = Path.Combine(dir, "launcher.json");
                    File.WriteAllText(launcher, "{\"ok\":true}");
                    tracker.ScanFile(launcher); bus.DrainOnce();
                    Check(events.Count == 1 && events[0].Get("block") == "launcher" && health.Count == 1, "canonical launcher ready is immediate");
                    for (int i = 0; i < 250; i++) {
                        File.WriteAllText(launcher, "{\"ok\":true,\"summary\":\"uptime " + i + "\"}");
                        tracker.ScanFile(launcher);
                        string artifact = launcher + "~RF" + i.ToString("x8") + ".TMP";
                        File.WriteAllText(artifact, "{\"ok\":false,\"summary\":\"old temporary status\"}");
                        tracker.ScanFile(artifact); File.Delete(artifact); bus.DrainOnce();
                    }
                    Check(events.Count == 1 && health.Count == 1 && tracker.TrackedBlocks == 1, "rewrites/RF suffixes neither publish nor allocate blocks");
                    string vpn = Path.Combine(dir, "vpn.json");
                    File.WriteAllText(vpn + "~RF1234.TMP", "{\"ok\":true,\"state\":\"on\"}");
                    tracker.ScanFile(vpn + "~RF1234.TMP"); bus.DrainOnce();
                    Check(events.Count == 1 && tracker.TrackedBlocks == 1, "temporary content without final file cannot make VPN ready");
                    tracker.Observe("launcher.json~RFabc", Status("{\"ok\":true}"));
                    tracker.ScanFile(Path.Combine(dir, "unexpected.json.random.tmp")); bus.DrainOnce();
                    Check(events.Count == 1, "invalid/non-status names ignored");
                    File.WriteAllText(launcher, "{\"ok\":false,\"summary\":\"down\"}");
                    tracker.ScanFile(launcher); tracker.ScanFile(launcher); bus.DrainOnce();
                    Check(events.Count == 2 && events.Last().Topic == BusTopics.BlockDegraded && health.Count == 2, "one degradation, repeats ignored");
                    tracker.Observe("launcher", Status("{\"ok\":false,\"summary\":\"other\"}")); bus.DrainOnce();
                    Check(events.Count == 3, "changed reason published");
                    tracker.Observe("launcher", Status("{\"ok\":false,\"phase\":\"failed\",\"summary\":\"other\"}"));
                    tracker.Observe("launcher", Status("{\"ok\":false,\"phase\":\"failed\",\"summary\":\"other\"}")); bus.DrainOnce();
                    Check(events.Count == 4 && events.Last().Topic == BusTopics.BlockFailed && health.Last().Contains("block.failed"), "failed differs from degraded and is journaled once");
                    File.WriteAllText(vpn, "{\"ok\":true,\"state\":\"starting\"}"); tracker.ScanFile(vpn); bus.DrainOnce();
                    Check(!tracker.IsBlockReady("vpn"), "starting VPN is not ready");
                    File.WriteAllText(vpn, "{\"ok\":true,\"state\":\"on\"}");
                    // Единственный RF-сигнал после замены; временный файл намеренно противоречит конечному.
                    File.WriteAllText(vpn + "~RF1234.TMP", "{\"ok\":false,\"phase\":\"failed\"}");
                    tracker.ScanFile(vpn + "~RF1234.TMP"); bus.DrainOnce();
                    Check(events.Count == 5 && events.Last().Get("block") == "vpn", "isolated RF hint reads final VPN, ignoring temporary failed state");
                    var board = new HealthBoard(HealthBoard.ExpectedBlocks(Status("{\"runningComponents\":[\"bridge\"],\"vpnOn\":true}")), Now);
                    bus.Subscribe(BusTopics.BlockReady, e => board.Ready(e.Get("block"), Now));
                    board.Ready("vpn", Now);
                    tracker.ScanFile(launcher); bus.DrainOnce();
                    Check(!board.Accepted && board.Missing.Contains("tray"), "launcher cannot impersonate tray acceptance");
                    tracker.Observe("bridge", Status("{\"ok\":true}"));
                    tracker.Observe("transport", Status("{\"ok\":true}"));
                    bus.Publish(BusTopics.BlockReady, "tray", "block", "tray"); bus.DrainOnce();
                    Check(board.Accepted && events.Any(e => e.Get("block") == "control"), "H1/H2 accept tray/transport/vpn/control using stable blocks");
                    var pending = new HealthBoard(new[] { "transport", "vpn" }, Now);
                    bus.Subscribe(BusTopics.BlockReady, e => pending.Ready(e.Get("block"), Now));
                    bus.Subscribe(BusTopics.BlockFailed, e => pending.Degraded(e.Get("block"), e.Get("reason"), Now));
                    pending.Ready("transport", Now);
                    tracker.Observe("transport", Status("{\"ok\":false,\"phase\":\"failed\",\"summary\":\"failed\"}")); bus.DrainOnce();
                    pending.Ready("vpn", Now);
                    Check(!pending.Accepted && pending.Missing.Contains("transport"), "failed removes earlier readiness before acceptance");
                    tracker.Observe("transport", Status("{\"ok\":true}")); bus.DrainOnce();
                    int count = events.Count;
                    tracker.Observe("transport", Status("{\"ok\":true,\"summary\":\"new uptime\"}")); bus.DrainOnce();
                    Check(events.Count == count, "ready payload content does not reset deduplication");
                    bus.Publish(BusTopics.ComponentExit, "tray", "name", "transport", "code", "1"); bus.DrainOnce();
                    tracker.Observe("transport", Status("{\"ok\":true}")); bus.DrainOnce();
                    Check(events.Count == count + 1, "new component lifetime republishes readiness");
                    tracker.Observe("transport", Status("{\"ok\":false,\"localNet\":\"down\"}")); bus.DrainOnce();
                    Check(events.Last().Get("reason") == "no-network", "offline health reason preserved");
                    for (int i = 0; i < 100; i++) tracker.Observe("extra-" + i, Status("{\"ok\":true}"));
                    bus.DrainOnce();
                    Check(tracker.TrackedBlocks == BlockStatusTracker.MaxBlocks, "status state has a hard cardinality bound");
                }
            }
        }

        static void BusRepeats()
        {
            var lines = new List<string>();
            using (var bus = new EventBus(manualDispatch: true))
            using (var journal = new BusJournal(bus, sink: lines.Add)) {
                for (int i = 0; i < 6; i++) {
                    bus.Publish("vpn.state", "helper", "state", "on"); bus.DrainOnce();
                    if (i == 0) Check(lines.Count == 1, "first bus event is on disk immediately");
                }
                Check(lines.Count == 1 && journal.PendingCount == 5, "same bus events collapse ignoring seq/time");
                bus.Publish("transport.switch", "transport", "reason", "path-changed"); bus.DrainOnce();
                Check(lines.Count == 3 && lines[1].Contains("count=5") && lines[2].Contains("transport.switch"), "bus transition flushes exact additional repeat count");
                bus.Publish("transport.switch", "transport", "reason", "path-changed"); bus.DrainOnce();
                journal.Flush(); Check(lines.Last().Contains("count=1"), "bus explicit flush preserves final repeat");
                int before = lines.Count;
                string common = new string('x', 1500);
                bus.Publish("update.probe", "tray", "msg", common + "a"); bus.DrainOnce();
                bus.Publish("update.probe", "tray", "msg", common + "b"); bus.DrainOnce();
                Check(lines.Count == before + 2, "bus compares original payload before truncating it");
                before = lines.Count;
                bus.Publish("vpn.state", "helper", "a", "1", "b", "2"); bus.DrainOnce();
                bus.Publish("vpn.state", "helper", "b", "2", "a", "1"); bus.DrainOnce(); journal.Flush();
                Check(lines.Count == before + 2 && lines.Last().Contains("count=1"), "field order does not defeat bus deduplication");
                foreach (string topic in new[] { "health.accepted", "health.failed", "component.exit", "update.done", "vpn.failed" }) {
                    bus.Publish(topic, "test", "reason", "diagnostic"); bus.DrainOnce();
                    Check(lines.Last().Contains(topic), "important bus topic retained: " + topic);
                }
                bus.Publish("tick.tray", "timer"); bus.DrainOnce();
                Check(journal.SuppressedCount == 1, "tick noise still suppressed");
                for (int i = 0; i < 205; i++) { bus.Publish("core.test", "test"); bus.DrainOnce(); }
                Check(journal.PendingCount == 4, "bus repeat counter bounded by threshold");
            }
            Check(lines.Any(l => l.Contains("count=4")), "bus dispose flushes final partial repeat batch");
        }

        static string Core(int seq, string text, string session = "abcd")
        {
            return RaLog.Format(new DateTimeOffset(Now.AddSeconds(seq)), LogLevel.Info, "core", "core.line",
                RaLog.Pairs(new[] { "seq", seq.ToString(), "text", text }), session);
        }
        static void CoreRepeats()
        {
            var lines = new List<string>(); var journal = new CoreJournal(line => { lines.Add(line); return true; });
            for (int i = 0; i < 4; i++) journal.Write(Core(i, "+0300 2026-11-21 12:00:0" + i + " \u001b[31mERROR\u001b[0m dns: connection refused"));
            Check(lines.Count == 1 && lines[0].Contains(" ERROR ") && !lines[0].Contains("[31m"), "first core error immediate, ANSI level repaired");
            journal.Write(Core(4, "+0300 2026-11-21 12:00:04 [33mWARN[0m network: slow"));
            Check(lines.Count == 3 && lines[1].Contains("count=3") && lines[1].Contains(" ERROR ") && lines[2].Contains(" WARN "), "core change retains first and x3 with severity");
            journal.Write(Core(5, "+0300 2026-11-21 12:00:05 WARN network: slow")); journal.Flush();
            Check(lines.Count == 4 && lines.Last().Contains("count=1"), "core final flush writes exact repeat count");
            int before = lines.Count;
            for (int i = 0; i < 1003; i++) journal.Write(Core(6, "+0300 2026-11-21 12:00:06 INFO router: found process path: example.exe"));
            journal.Flush();
            Check(lines.Count == before + 2 && lines[before].Contains("suppressed=1000") && lines.Last().Contains("suppressed=3"), "process discovery spam summarized with bounded counters");
            journal.Write(Core(7, "+0300 2026-11-21 12:00:07 ERROR router: found process path: failed"));
            Check(lines.Last().Contains(" ERROR "), "router errors never classified as noise");
            before = lines.Count;
            journal.Write("2026-11-21T12:00:00.000Z 12:00:00.000+00:00 INFO core core.line s=abcd seq=8 text=" + RaLog.QuoteValue("WARN " + new string('x', 5000) + "a"));
            journal.Write("2026-11-21T12:00:00.000Z 12:00:00.000+00:00 INFO core core.line s=abcd seq=9 text=" + RaLog.QuoteValue("WARN " + new string('x', 5000) + "b"));
            Check(lines.Count == before + 2, "core original payload compared before output truncation");
            journal.Write(Core(10, "INFO sing-box started (0.5s)"));
            Check(lines.Last().Contains("sing-box started"), "core lifecycle diagnostics retained");
            journal.Write(Core(11, "WARN same", "new-run")); journal.Write(Core(12, "WARN same", "other-run"));
            Check(!lines.Last().Contains(" repeat "), "different service sessions do not collapse");
            before = lines.Count;
            for (int i = 0; i < 206; i++) journal.Write(Core(i, "ERROR repeated"));
            journal.Flush();
            Check(lines.Count == before + 4 && lines.Last().Contains("count=5"), "core continuous repeats periodically summarize and final remainder survives");
            journal.Write("unrecognized diagnostic");
            Check(lines.Last() == "unrecognized diagnostic", "unrecognized core format preserved");
        }

        static void Mirror(string dir)
        {
            string logs = Path.Combine(dir, "mirror"), state = Path.Combine(dir, "state");
            int calls = 0;
            var mirror = new HelperLogMirror(logs, state, () => true, () => "15", (after, max) => {
                calls++;
                if (after > 0) return new Dictionary<string, object> { { "next", after }, { "lines", new string[0] } };
                return new Dictionary<string, object> {
                    { "next", 4 }, { "lines", new[] {
                        Core(1, "ERROR diagnostic"), Core(2, "ERROR diagnostic"),
                        Core(3, "INFO router: found process path: example.exe"),
                        RaLog.Format(new DateTimeOffset(Now), LogLevel.Info, "helper", "vpn.state", RaLog.Pairs(new[] { "seq", "4", "state", "on" }), "abcd")
                    } }
                };
            }, (level, evt, fields) => { });
            Check(mirror.Pull() == 4 && calls == 2, "mirror consumes original records without cursor stalls");
            string core = File.ReadAllText(Path.Combine(logs, "core.log"));
            Check(core.Contains("seq=1") && !core.Contains("seq=2") && core.Contains("count=1") && core.Contains("suppressed=1"), "mirror writes first, repeat/noise summaries before cursor advances");
            Check(Json.Str(Json.Read(Path.Combine(state, "helper-log-cursor.json")), "after") == "4", "filtered lines advance helper cursor exactly once");
            Check(File.ReadAllText(Path.Combine(logs, "helper.log")).Contains("vpn.state"), "helper/VPN diagnostics retained in helper stream");
            Check(mirror.Pull() == 0, "no duplicate mirror page after saved cursor");
        }

        static void WriteRecovery(string dir)
        {
            string logs = Path.Combine(dir, "core-recovery"), path = Path.Combine(logs, "core.log");
            Directory.CreateDirectory(path); // FileStream не может открыть каталог как журнал.
            var journal = new CoreJournal(line => RaLog.AppendLine(logs, "core", line));
            Check(!journal.Write(Core(1, "ERROR original diagnostic")) && journal.Flush(), "failed first core line is not accepted");
            Directory.Delete(path);
            Check(journal.Write(Core(2, "ERROR original diagnostic")) && journal.Flush(), "next batch retries identical core error as first");
            string text = File.ReadAllText(path);
            Check(text.Contains("original diagnostic") && text.Contains(" ERROR ") && text.Contains("log.write-failed") && !text.Contains("of=core.line"), "recovery contains first error text and failure count");
            journal.Write(Core(3, "ERROR original diagnostic")); Directory.CreateDirectory(path + ".blocked");
            File.Move(path, path + ".saved"); Directory.Move(path + ".blocked", path);
            Check(!journal.Flush(), "failed repeat summary stays pending");
            Check(!journal.Write(Core(4, "WARN next warning")), "failed prior summary does not consume warning");
            Directory.Delete(path);
            Check(journal.Write(Core(5, "WARN next warning")) && journal.Flush(), "warning retries after pending summary recovery");
            text = File.ReadAllText(path);
            Check(text.Contains("count=1") && text.Contains("next warning") && text.Contains(" WARN "), "repeat count and warning text survive refusal");

            logs = Path.Combine(dir, "bus-recovery"); path = Path.Combine(logs, "bus.log"); Directory.CreateDirectory(path);
            using (var bus = new EventBus(manualDispatch: true))
            using (var busJournal = new BusJournal(bus, logs)) {
                bus.Publish("vpn.failed", "helper", "reason", "original bus error"); bus.DrainOnce();
                Directory.Delete(path);
                bus.Publish("vpn.failed", "helper", "reason", "original bus error"); bus.DrainOnce(); busJournal.Flush();
                text = File.ReadAllText(path);
                Check(text.Contains("original bus error") && text.Contains("vpn.failed") && text.Contains("log.write-failed") && !text.Contains("first_seq="), "bus retries failed first event with original fields");
            }
        }

        static void MirrorRecovery(string dir)
        {
            foreach (string stream in new[] { "core", "helper" }) {
                string logs = Path.Combine(dir, "mirror-retry-" + stream), state = logs + "-state", path = Path.Combine(logs, stream + ".log");
                Directory.CreateDirectory(path);
                string[] lines = stream == "core" ? new[] { Core(1, "WARN mirror warning"), Core(2, "ERROR mirror error") } :
                    new[] { RaLog.Format(new DateTimeOffset(Now), LogLevel.Error, "helper", "vpn.failed", RaLog.Pairs(new[] { "reason", "mirror error" }), "abcd") };
                int calls = 0;
                var mirror = new HelperLogMirror(logs, state, () => true, () => "15", (after, max) => {
                    calls++;
                    return new Dictionary<string, object> { { "next", 2 }, { "lines", after == 0 ? lines : new string[0] } };
                }, (level, evt, fields) => { });
                Check(mirror.Pull() == 0 && calls == 1 && !File.Exists(Path.Combine(state, "helper-log-cursor.json")), "failed mirror line keeps cursor: " + stream);
                Directory.Delete(path);
                Check(mirror.Pull() == lines.Length, "mirror retries saved page after recovery: " + stream);
                string text = File.ReadAllText(path);
                Check(text.Contains("mirror error") && text.Contains(" ERROR ") && (stream != "core" || text.Contains("mirror warning") && text.Contains(" WARN ")), "mirror preserves WARN/ERROR text: " + stream);

                logs += "-permanent"; state += "-permanent"; path = Path.Combine(logs, stream + ".log"); Directory.CreateDirectory(path);
                calls = 0;
                mirror = new HelperLogMirror(logs, state, () => true, () => "15", (after, max) => {
                    calls++;
                    return new Dictionary<string, object> { { "next", 2 }, { "lines", after == 0 ? lines : new string[0] } };
                }, (level, evt, fields) => { });
                for (int i = 0; i < HelperLogMirror.MaxWriteAttempts * lines.Length; i++) mirror.Pull();
                Check(Json.Str(Json.Read(Path.Combine(state, "helper-log-cursor.json")), "after") == "2" && calls <= HelperLogMirror.Iterations, "permanent refusal advances after bounded retries: " + stream);
                Directory.Delete(path); mirror.Pull();
                text = File.ReadAllText(path);
                Check(text.Contains("lost") && text.Contains("n=" + lines.Length) && text.Contains("log.write-failed"), "first successful write reports lost original records: " + stream);
            }
        }

        static void MirrorSummaryRecovery(string dir)
        {
            string logs = Path.Combine(dir, "mirror-summary"), state = logs + "-state", path = Path.Combine(logs, "core.log");
            var oldOnError = RaLog.OnError;
            RaLog.OnError = () => { File.Move(path, path + ".saved"); Directory.CreateDirectory(path); };
            try {
                var mirror = new HelperLogMirror(logs, state, () => true, () => "15", (after, max) =>
                    new Dictionary<string, object> { { "next", 3 }, { "lines", after == 0 ? new[] {
                        Core(1, "ERROR summary diagnostic"), Core(2, "ERROR summary diagnostic"),
                        Core(3, "INFO router: found process path: example.exe") } : new string[0] } }, (level, evt, fields) => { });
                Check(mirror.Pull() == 3 && !File.Exists(Path.Combine(state, "helper-log-cursor.json")), "failed batch summary prevents cursor commit");
                RaLog.OnError = oldOnError; Directory.Delete(path);
                Check(mirror.Pull() == 0 && Json.Str(Json.Read(Path.Combine(state, "helper-log-cursor.json")), "after") == "3", "recovered summary commits page without replaying accepted rows");
                string text = File.ReadAllText(path);
                Check(text.Contains("count=1") && text.Contains("suppressed=1") && text.Contains("log.write-failed"), "repeat/noise counters survive failed batch flush exactly once");
            } finally { RaLog.OnError = oldOnError; }
        }

        static void ParallelWrites(string dir)
        {
            const int workers = 8, count = 100;
            string logs = Path.Combine(dir, "parallel"); Directory.CreateDirectory(logs);
            using (var barrier = new Barrier(workers)) {
                var threads = new Thread[workers]; var errors = new Exception[workers];
                for (int i = 0; i < workers; i++) {
                    int worker = i;
                    threads[i] = new Thread(() => {
                        try {
                            string stream = "parallel-" + worker, path = Path.Combine(logs, stream + ".log");
                            Directory.CreateDirectory(path);
                            for (int n = 0; n < count; n++) {
                                if (!barrier.SignalAndWait(3000)) throw new Exception("parallel barrier timeout");
                                if (RaLog.AppendLine(logs, stream, "blocked")) throw new Exception("blocked write succeeded");
                            }
                            Directory.Delete(path);
                            for (int n = 0; n < count; n++) {
                                if (!barrier.SignalAndWait(3000)) throw new Exception("recovery barrier timeout");
                                if (!RaLog.AppendLine(logs, stream, "record=" + n)) throw new Exception("recovery write failed");
                            }
                        } catch (Exception e) { errors[worker] = e; }
                    });
                    threads[i].IsBackground = true; threads[i].Start();
                }
                foreach (var thread in threads) Check(thread.Join(10000), "manual parallel thread completed within seconds");
                for (int i = 0; i < workers; i++) {
                    Check(errors[i] == null, "parallel stream has no dictionary errors: " + errors[i]);
                    string[] text = File.ReadAllLines(Path.Combine(logs, "parallel-" + i + ".log"));
                    Check(text.Count(l => l.Contains("log.write-failed") && l.Contains("n=100")) == 1 && text.Count(l => l.StartsWith("record=")) == count, "per-path failures and all recovered records retained: " + i);
                }
            }
        }

        static void Rotation(string dir)
        {
            long oldMax = RaLog.MaxBytes;
            try {
                Check(RaLog.MaxBytes == 2L * 1024 * 1024 && RaLog.MaxArchives == 5, "production rotation is 2 MiB with five archives (12 MiB/stream)");
                RaLog.MaxBytes = 512;
                foreach (string stream in new[] { "bus", "core" }) {
                    string logs = Path.Combine(dir, "rotation-" + stream);
                    for (int i = 0; i < 80; i++) RaLog.AppendLine(logs, stream, new string('я', 5000) + i);
                    var files = RaLog.StreamFiles(logs, stream);
                    Check(files.Length == 6 && !File.Exists(Path.Combine(logs, stream + ".log.6")), "at most six rotated files: " + stream);
                    Check(files.Sum(f => new FileInfo(f).Length) <= 6 * RaLog.MaxBytes, "stream total has strict upper bound: " + stream);
                    var utf8 = new UTF8Encoding(false, true);
                    foreach (string file in files) {
                        byte[] bytes = File.ReadAllBytes(file);
                        Check(bytes.Length <= RaLog.MaxBytes && bytes[0] == 0xEF, "per-file limit includes BOM: " + stream);
                        Check(utf8.GetString(bytes).Contains("[cut]"), "truncated UTF-8 remains valid: " + stream);
                    }
                    // Удаление .5 невозможно: ротация должна отказаться от записи, а не наращивать .log.
                    Directory.CreateDirectory(Path.Combine(logs, stream + ".log.5.blocker"));
                    File.Delete(Path.Combine(logs, stream + ".log.5"));
                    Directory.Move(Path.Combine(logs, stream + ".log.5.blocker"), Path.Combine(logs, stream + ".log.5"));
                    long before = new FileInfo(Path.Combine(logs, stream + ".log")).Length;
                    RaLog.AppendLine(logs, stream, new string('x', 500));
                    Check(new FileInfo(Path.Combine(logs, stream + ".log")).Length == before, "rotation failure cannot grow active log: " + stream);
                    Directory.Delete(Path.Combine(logs, stream + ".log.5"));
                    RaLog.AppendLine(logs, stream, "recovered");
                    Check(File.ReadAllText(Path.Combine(logs, stream + ".log")).Contains("log.write-failed"), "rotation failure counter reported after recovery: " + stream);
                }
            } finally { RaLog.MaxBytes = oldMax; }
        }
    }
}
