using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace RemoteAgents.Launcher
{
    public static class TransportBusTests
    {
        static int assertions;
        // Предохранитель (конституция 4а): событие завершения тестовой нити недоступно, если она зависла;
        // при срабатывании — падение теста, успех не объявляет.
        const int TestHangFuseMs = 5000;
        const string Status = "@bus {\"topic\":\"transport.status\",\"fields\":{\"phase\":\"готов\"}}";
        const string StdinReady = "@bus {\"topic\":\"transport.stdin.ready\",\"fields\":{}}";
        const string Ready = "@bus {\"topic\":\"transport.ready\",\"fields\":{}}";
        static void Check(bool ok, string what) { if (!ok) throw new Exception("Assertion failed: " + what); assertions++; }
        static void Await(WaitHandle signal) { if (!signal.WaitOne(TestHangFuseMs)) throw new Exception("Test thread deadlocked"); }
        static void Join(Thread thread) { if (!thread.Join(TestHangFuseMs)) throw new Exception("Test thread deadlocked"); }

        public static int Main(string[] args)
        {
            var clock = RaLog.Clock;
            RaLog.Clock = () => new DateTimeOffset(2026, 11, 21, 12, 0, 0, TimeSpan.Zero);
            try {
                ValidLinesAndStrictFields();
                IncomingQueueRecovers();
                ReadLoopFramesAndRejectsOversizedTails();
                ReadLoopBoundariesAndEof();
                FormatAndUtf8Forwarding();
                ForwardRouteBeforePathReady(StdinReady);
                PathReadyDoesNotOpenStdin();
                AssertFinalStatus("@bus {\"topic\":\"transport.status\",\"fields\":{\"phase\":\"stopped\"}}\n", "stopped");
                AssertFinalStatus("@bus {\"topic\":\"transport.status\",\"fields\":{\"phase\":\"failed\"}}", "failed");
                ProcessExitDrainTimeoutDoesNotBlock();
                BlockedStdinDoesNotBlockBusOrDispose();
                OutgoingOverflowRecovers();
                OversizedOutgoingIsCountedAndLogged();
                BrokenStdinDoesNotCrash();
                DuplexHandleOwnership();
                LauncherWiring();
            } finally { RaLog.Clock = clock; }
            Console.WriteLine("PASS: TransportBusTests (" + assertions + " assertions passed)");
            return 0;
        }

        static void ValidLinesAndStrictFields()
        {
            using (var bus = new EventBus(manualDispatch: true))
            using (var bridge = new TransportBusBridge(null, null, bus)) {
                var seen = new List<BusEvent>();
                bus.Subscribe("*", seen.Add);
                bridge.ConsumeLine(Status);
                bridge.ConsumeLine("@bus {\"topic\":\"singbox.line\",\"fields\":{\"core\":\"transport\"}}");
                bridge.ConsumeLine("@bus {\"topic\":\"transport.mem\",\"fields\":{\"n\":12.5,\"ok\":true,\"none\":null}}");
                bus.DrainOnce();
                Check(bridge.Parsed == 3 && bridge.Rejected == 0 && seen.Count == 3, "valid lines published");
                Check(seen.All(e => e.Source == BusTopics.Sources.Transport), "source is transport");
                Check(seen[0].Get("phase") == "готов" && seen[1].Get("core") == "transport", "fields preserved");
                Check(seen[2].Get("n") == "12.5" && seen[2].Get("ok") == "True" && seen[2].Get("none") == "", "scalars converted invariantly");
                foreach (string bad in new[] {
                    "@bus {bad-json}", "@bus {\"topic\":\"transport.status\",\"fields\":123}",
                    "@bus {\"topic\":\"vpn.state\",\"fields\":{}}", "@bus {\"topic\":\"win.route.changed\",\"fields\":{}}",
                    "@bus {\"topic\":\"transport.status\",\"fields\":{\"x\":{}}}",
                    "@bus {\"topic\":\"transport.status\",\"fields\":{\"x\":[]}}",
                    "@bus {\"topic\":\"transport.status\",\"fields\":{\"\":\"value\"}}",
                    "@bus {\"topic\":\"transport.status\",\"fields\":{},\"fields\":{}}",
                    "@bus " + new string('a', TransportBusBridge.MaxLineBytes)
                }) bridge.ConsumeLine(bad);
                Check(bridge.Rejected == 9, "malformed, nested, empty-key, duplicate-key, foreign and oversized events rejected");
                bridge.ConsumeLine("ordinary stdout");
                bridge.ConsumeLine(Status);
                bus.DrainOnce();
                Check(bridge.Parsed == 4 && bridge.Rejected == 9 && seen.Count == 4, "bad lines do not stop subsequent events");
            }
        }

        static void IncomingQueueRecovers()
        {
            using (var bus = new EventBus(manualDispatch: true, queueLimit: 3))
            using (var bridge = new TransportBusBridge(null, null, bus)) {
                int seen = 0;
                bus.Subscribe(BusTopics.TransportStatus, e => seen++);
                for (int i = 0; i < 5; i++) bridge.ConsumeLine(Status);
                Check(bus.QueueCount == 3 && bridge.Dropped == 2 && bus.DroppedCount == 2, "EventBus bounds actual pending events");
                bus.DrainOnce();
                // More than the old lifetime ceiling; each drained batch accepts more input.
                for (int i = 0; i < TransportBusBridge.DefaultQueueLimit + 1; i++) {
                    bridge.ConsumeLine(Status);
                    bus.DrainOnce();
                }
                Check(seen == 3 + TransportBusBridge.DefaultQueueLimit + 1 && bridge.Dropped == 2, "input recovers after drain, beyond lifetime limit");
            }
        }

        static string TempLogs() { return Path.Combine(Path.GetTempPath(), "b4-transport-" + Guid.NewGuid().ToString("N")); }

        static void ReadLoopFramesAndRejectsOversizedTails()
        {
            string dir = TempLogs();
            try {
                string text = "stdout pass=secret123\r\n" + new string('x', 16385) + Ready + "\r\n" +
                    "@bus {bad}\n" + Status + "\r\n" +
                    "@bus {\"topic\":\"singbox.line\",\"fields\":{\"line\":\"EOF\"}}";
                using (var bus = new EventBus(manualDispatch: true))
                using (var bridge = new TransportBusBridge(new MemoryStream(Encoding.UTF8.GetBytes(text)), null, bus, dir)) {
                    var seen = new List<BusEvent>();
                    bus.Subscribe("*", seen.Add);
                    bridge.Start();
                    Check(bridge.Join(TestHangFuseMs), "reader reached EOF");
                    bus.DrainOnce();
                    Check(bridge.Lines == 5 && bridge.Rejected == 2 && bridge.Parsed == 2, "physical lines counted, oversized line rejected once");
                    Check(!bridge.Ready && seen.Count == 2, "forged ready in long-line tail cannot become an event");
                    Check(seen[0].Get("phase") == "готов" && seen[1].Get("line") == "EOF", "CRLF, UTF-8 and unterminated EOF framed");
                }
                var log = File.ReadAllLines(Path.Combine(dir, "transport.log"));
                Check(log.Count(l => l.Contains("stdout.rejected")) == 1, "single oversized-line log marker");
                Check(log.Any(l => l.Contains("stdout ")) && !string.Join("\n", log).Contains("secret123"), "ordinary stdout logged with secrets masked");
            } finally { if (Directory.Exists(dir)) Directory.Delete(dir, true); }
        }

        static void ReadLoopBoundariesAndEof()
        {
            // The first Cyrillic code point straddles the 4096-byte read-buffer boundary.
            string prefix = "@bus {\"topic\":\"transport.status\",\"fields\":{\"text\":\"";
            string value = new string('x', 4095 - Encoding.UTF8.GetByteCount(prefix)) + "я";
            string split = prefix + value + "\"}}";
            string exact = prefix + new string('x', TransportBusBridge.MaxLineBytes - Encoding.UTF8.GetByteCount(prefix + "\"}}")) + "\"}}";
            var bytes = Encoding.UTF8.GetBytes(split + "\r\n" + exact + "\r\n").Concat(new byte[] { 0xff, 10 })
                .Concat(Encoding.UTF8.GetBytes(Status)).ToArray();
            using (var bus = new EventBus(manualDispatch: true))
            using (var bridge = new TransportBusBridge(new MemoryStream(bytes), null, bus)) {
                var seen = new List<BusEvent>();
                bus.Subscribe("*", seen.Add);
                bridge.Start();
                Check(bridge.Join(TestHangFuseMs), "boundary reader reached EOF");
                bus.DrainOnce();
                Check(seen.Count == 3 && bridge.Rejected == 1, "exact 8KiB CRLF accepted, malformed UTF-8 rejected without stopping");
                Check(seen[0].Get("text") == value && Encoding.UTF8.GetByteCount(exact) == TransportBusBridge.MaxLineBytes, "multibyte boundary preserved");
            }
            using (var bridge = new TransportBusBridge(new MemoryStream(Encoding.UTF8.GetBytes(new string('x', 20000) + Ready)), null, null)) {
                bridge.Start();
                Check(bridge.Join(TestHangFuseMs), "oversized EOF reader finished");
                Check(bridge.Rejected == 1 && bridge.Parsed == 0 && bridge.Lines == 1, "oversized EOF tail discarded once");
            }
        }

        static void FormatAndUtf8Forwarding()
        {
            string formatted = TransportBusBridge.FormatOutgoing(BusTopics.NetChange,
                new Dictionary<string, string> { { "id", "сеть" }, { "token", "secret123" } });
            Check(formatted.StartsWith("@bus ") && formatted.Contains("net.change") && !formatted.Contains("secret123"), "outgoing formatting masks secret fields");
            Check(TransportBusBridge.FormatOutgoing(BusTopics.VpnState, null) == null, "foreign outgoing topic rejected");
            Check(TransportBusBridge.IsAllowedOutgoing(BusTopics.WinRouteChanged) &&
                TransportBusBridge.IsAllowedOutgoing(BusTopics.TickTransportMem) &&
                TransportBusBridge.IsAllowedOutgoing(BusTopics.TransportCommand), "outgoing whitelist");
            using (var bus = new EventBus(manualDispatch: true)) {
                var stream = new MemoryStream();
                var bridge = new TransportBusBridge(null, stream, bus);
                // Queue before Start, then synchronise by the delivery event (no time assumptions).
                var delivered = new ManualResetEvent(false);
                var sink = new SignalledStream(delivered);
                bridge.Dispose(); // Also exercises Dispose-before-Start cleanup.
                Check(bridge.JoinWriter(TestHangFuseMs), "unstarted writer cleaned up");
                using (delivered)
                using (bridge = new TransportBusBridge(null, sink, bus)) {
                    bus.Publish(BusTopics.NetChange, BusTopics.Sources.Tray, "id", "ignored-before-ready");
                    bus.DrainOnce();
                    Check(bridge.Sent == 0 && !bridge.Ready, "no forwarding until stdin reader ready");
                    bridge.ConsumeLine(StdinReady);
                    bridge.ConsumeLine("@bus {bad}");
                    bus.Publish(BusTopics.NetChange, BusTopics.Sources.Tray, "id", "сеть");
                    bus.Publish(BusTopics.VpnState, BusTopics.Sources.Tray);
                    bus.DrainOnce();
                    bridge.Start();
                    Await(delivered);
                    bridge.Dispose();
                    Check(bridge.JoinWriter(TestHangFuseMs), "writer cleaned up");
                    byte[] sent = sink.ToArray();
                    Check(sent.Length > 0 && sent[0] == (byte)'@', "UTF-8 without BOM");
                    var payload = Json.Map(Json.Parse(Encoding.UTF8.GetString(sent).Substring(5).Trim()));
                    Check(Json.Str(Json.Map(Json.Get(payload, "fields")), "id") == "сеть", "Cyrillic preserved on wire");
                    Check(bridge.Sent == 1 && !Encoding.UTF8.GetString(sent).Contains("vpn.state"), "only allowed event forwarded once");
                }
                bus.Publish(BusTopics.NetChange, BusTopics.Sources.Tray);
                bus.DrainOnce();
                Check(bridge.Sent == 1, "disposed bridge unsubscribed");
            }
        }

        // Called by the PowerShell microtest with the actual daemon reader's announcement.
        public static string ForwardRouteBeforePathReady(string handshake)
        {
            using (var bus = new EventBus(manualDispatch: true))
            using (var delivered = new ManualResetEvent(false)) {
                var sink = new SignalledStream(delivered);
                using (var bridge = new TransportBusBridge(null, sink, bus)) {
                    bridge.ConsumeLine(handshake);
                    Check(bridge.InputReady && !bridge.Ready, "reader handshake opens forwarding before path proof");
                    bus.Publish(BusTopics.WinRouteChanged, BusTopics.Sources.Windows, "family", "IPv4", "ifIndex", "7");
                    bus.DrainOnce();
                    bridge.Start();
                    Await(delivered);
                    bridge.Dispose();
                    Check(bridge.JoinWriter(TestHangFuseMs) && bridge.Sent == 1, "route reaches daemon stdin before first path success");
                    return Encoding.UTF8.GetString(sink.ToArray());
                }
            }
        }

        static void PathReadyDoesNotOpenStdin()
        {
            using (var bus = new EventBus(manualDispatch: true))
            using (var bridge = new TransportBusBridge(null, new MemoryStream(), bus, queueLimit: 1)) {
                bridge.ConsumeLine(Ready);
                bus.Publish(BusTopics.NetChange, "test");
                bus.Publish(BusTopics.NetChange, "test");
                bus.DrainOnce();
                Check(bridge.Ready && !bridge.InputReady && bridge.Dropped == 0, "path-ready alone never opens stdin forwarding");
                bridge.Dispose();
                Check(bridge.JoinWriter(TestHangFuseMs) && bridge.Sent == 0, "no outgoing event queued without reader confirmation");
            }
        }

        public static void AssertFinalStatus(string frames, string phase)
        {
            using (var bus = new EventBus(manualDispatch: true))
            using (var input = new DelayedReadStream(frames))
            using (input.Entered)
            using (input.Release)
            using (var bridge = new TransportBusBridge(input, new MemoryStream(), bus)) {
                var phases = new List<string>();
                bus.Subscribe(BusTopics.TransportStatus, e => phases.Add(e.Get("phase")));
                bridge.ConsumeLine("@bus {\"topic\":\"transport.status\",\"fields\":{\"phase\":\"ok\"}}");
                bridge.ConsumeLine(StdinReady);
                bus.DrainOnce();
                try {
                    // Final bytes are already written; hold the real ReadLoop before it can read them.
                    bridge.Start();
                    Await(input.Entered);
                    var exiting = new Thread(() => bridge.CompleteAfterProcessExit()) { IsBackground = true };
                    exiting.Start(); Join(exiting); // Same action as Supervisor.HasExited, before releasing stdout.
                    Check(phases.SequenceEqual(new[] { "ok" }), "process exit detected before final frame was read");
                    bus.Publish(BusTopics.NetChange, "test"); bus.DrainOnce();
                    Check(bridge.JoinWriter(TestHangFuseMs) && bridge.Sent == 0, "process exit stops stdin without waiting for stdout");
                    input.Release.Set();
                    Check(bridge.Join(TestHangFuseMs) && bridge.JoinCompletion(TestHangFuseMs), "exited process stdout drains to EOF");
                    bus.DrainOnce();
                    BusEvent retained;
                    Check(phases.Last() == phase && bus.TryGetLast(BusTopics.TransportStatus, out retained) && retained.Get("phase") == phase,
                        "final status reaches subscribers and replaces retained ok after process exit");
                } finally {
                    input.Release.Set();
                    bridge.Dispose();
                    Check(bridge.Join(TestHangFuseMs) && bridge.JoinCompletion(TestHangFuseMs), "delayed reader cleaned up");
                }
            }
        }

        // Gates the actual stream read, rather than bypassing ReadLoop with ConsumeLine.
        sealed class DelayedReadStream : MemoryStream
        {
            public readonly ManualResetEvent Entered = new ManualResetEvent(false), Release = new ManualResetEvent(false);
            public DelayedReadStream(string frames) : base(Encoding.UTF8.GetBytes(frames)) { }
            public override int Read(byte[] buffer, int offset, int count) {
                Entered.Set();
                // Longer than the observer's Join fuse, so a broken completion cannot pass
                // merely because this fixture timed out and accidentally unblocked ReadLoop.
                if (!Release.WaitOne(TestHangFuseMs * 2)) throw new IOException("Test reader gate timed out");
                return base.Read(buffer, offset, count);
            }
        }

        static void ProcessExitDrainTimeoutDoesNotBlock()
        {
            using (var bus = new EventBus(manualDispatch: true))
            using (var input = new DelayedReadStream(Status))
            using (input.Entered)
            using (input.Release)
            using (var bridge = new TransportBusBridge(input, new MemoryStream(), bus)) {
                try {
                    bridge.Start(); Await(input.Entered);
                    // Zero drain budget deterministically forces the bounded fallback while Read is held.
                    var exiting = new Thread(() => bridge.CompleteAfterProcessExit(0)) { IsBackground = true };
                    exiting.Start(); Join(exiting);
                    Check(bridge.JoinCompletion(TestHangFuseMs) && bridge.JoinWriter(TestHangFuseMs), "drain timeout completes without waiting for blocked I/O");
                    input.Release.Set();
                    Check(bridge.Join(TestHangFuseMs), "timed-out reader eventually released");
                    bus.DrainOnce();
                    BusEvent retained;
                    Check(!bus.TryGetLast(BusTopics.TransportStatus, out retained), "timeout aborts late frames without claiming final delivery");
                } finally {
                    input.Release.Set();
                    bridge.Dispose();
                    Check(bridge.Join(TestHangFuseMs) && bridge.JoinCompletion(TestHangFuseMs), "timed-out bridge cleaned up");
                }
            }
            using (var bus = new EventBus(manualDispatch: true))
            using (var bridge = new TransportBusBridge(null, new MemoryStream(), bus)) {
                bridge.ConsumeLine(StdinReady);
                bus.Publish(BusTopics.NetChange, "test"); bus.DrainOnce(); // queued before Start
                bridge.CompleteAfterProcessExit(0);
                bridge.CompleteAfterProcessExit(); // Repeated exit observation is harmless.
                Check(bridge.JoinCompletion(TestHangFuseMs) && bridge.JoinWriter(TestHangFuseMs) && bridge.Sent == 0,
                    "process exit discards queued stdin frames and completion is idempotent");
            }
        }

        sealed class SignalledStream : MemoryStream
        {
            readonly EventWaitHandle delivered;
            public SignalledStream(EventWaitHandle delivered) { this.delivered = delivered; }
            public override void Flush() { base.Flush(); delivered.Set(); }
        }

        sealed class BlockedStream : MemoryStream
        {
            public readonly ManualResetEvent Entered = new ManualResetEvent(false), Release = new ManualResetEvent(false);
            public bool Closed;
            public override void Write(byte[] buffer, int offset, int count) {
                Entered.Set(); Await(Release); base.Write(buffer, offset, count);
            }
            protected override void Dispose(bool disposing) { Closed = true; base.Dispose(disposing); }
        }

        static void DispatchOnThread(EventBus bus)
        {
            var dispatch = new Thread(() => bus.DrainOnce()) { IsBackground = true };
            dispatch.Start(); Join(dispatch);
        }

        static void BlockedStdinDoesNotBlockBusOrDispose()
        {
            using (var bus = new EventBus(manualDispatch: true)) {
                var stream = new BlockedStream();
                var bridge = new TransportBusBridge(null, stream, bus, queueLimit: 2);
                int overflow = 0, unrelated = 0;
                bus.Subscribe(BusTopics.BusOverflow, e => { if (e.Get("queue") == "transport.stdin") overflow++; });
                bus.Subscribe("test.event", e => unrelated++);
                try {
                    bridge.ConsumeLine(StdinReady);
                    bridge.Start();
                    bus.Publish(BusTopics.NetChange, BusTopics.Sources.Tray);
                    DispatchOnThread(bus);
                    Await(stream.Entered); // writer is now blocked, not the dispatcher.
                    for (int i = 0; i < 7; i++) bus.Publish(BusTopics.WinRouteChanged, BusTopics.Sources.Windows);
                    bus.Publish("test.event", "test");
                    DispatchOnThread(bus);
                    Check(bridge.Dropped == 5 && overflow == 1 && unrelated == 1, "stalled stdin has bounded queue and one overflow event; bus still dispatches");
                    var disposer = new Thread(bridge.Dispose) { IsBackground = true };
                    disposer.Start(); Join(disposer);
                    Check(!stream.Closed, "Dispose does not close/flush blocked writer on caller thread");
                } finally {
                    bridge.Dispose();
                    stream.Release.Set();
                    Check(bridge.JoinWriter(TestHangFuseMs), "blocked writer released and cleaned up");
                    Check(stream.Closed, "output eventually closed by writer");
                    stream.Entered.Dispose(); stream.Release.Dispose();
                }
            }
        }

        static void OutgoingOverflowRecovers()
        {
            using (var bus = new EventBus(manualDispatch: true)) {
                using (var flushed = new AutoResetEvent(false)) {
                    var stream = new SignalledStream(flushed);
                    using (var bridge = new TransportBusBridge(null, stream, bus, queueLimit: 1)) {
                        int overflow = 0;
                        bus.Subscribe(BusTopics.BusOverflow, e => overflow++);
                        bridge.ConsumeLine(StdinReady);
                        bus.Publish(BusTopics.NetChange, "test");
                        bus.Publish(BusTopics.NetChange, "test");
                        bus.DrainOnce(); // worker has not started: deterministic capacity overflow.
                        Check(bridge.Dropped == 1 && overflow == 1, "outgoing queue is bounded before writer starts");
                        bridge.Start();
                        Await(flushed);
                        bus.Publish(BusTopics.NetChange, "test", "id", "after-drain");
                        bus.DrainOnce();
                        Await(flushed);
                        bridge.Dispose();
                        Check(bridge.JoinWriter(TestHangFuseMs) && bridge.Sent == 2 && bridge.Dropped == 1,
                            "outgoing queue accepts new events after delivery");
                    }
                }
            }
        }

        static void OversizedOutgoingIsCountedAndLogged()
        {
            string dir = TempLogs();
            try {
                using (var bus = new EventBus(manualDispatch: true))
                using (var bridge = new TransportBusBridge(null, new MemoryStream(), bus, dir)) {
                    bridge.ConsumeLine(StdinReady);
                    for (int i = 0; i < 2; i++) bus.Publish(BusTopics.NetChange, "test", "id", new string('.', 9000));
                    bus.DrainOnce();
                    Check(bridge.TooLong == 2 && bridge.Sent == 0, "oversized outgoing events counted");
                    var log = File.ReadAllLines(Path.Combine(dir, "transport.log"));
                    Check(log.Count(l => l.Contains("stdin.rejected")) == 1, "one outgoing rejection log per episode");
                    bridge.Dispose();
                    Check(bridge.JoinWriter(TestHangFuseMs), "rejected-event writer cleaned up");
                }
            } finally { if (Directory.Exists(dir)) Directory.Delete(dir, true); }
        }

        sealed class BrokenStream : MemoryStream
        {
            public override void Write(byte[] buffer, int offset, int count) { throw new IOException("closed pipe"); }
        }
        static void BrokenStdinDoesNotCrash()
        {
            using (var bus = new EventBus(manualDispatch: true))
            using (var input = new DelayedReadStream(Status))
            using (input.Entered)
            using (input.Release)
            using (var bridge = new TransportBusBridge(input, new BrokenStream(), bus)) {
                try {
                    bridge.ConsumeLine(StdinReady);
                    bus.Publish(BusTopics.NetChange, "test"); bus.DrainOnce();
                    bridge.Start(); Await(input.Entered);
                    Check(bridge.JoinWriter(TestHangFuseMs) && bridge.WriteErrors == 1, "broken pipe and disposal flush exceptions contained");
                    bus.Publish(BusTopics.NetChange, "test");
                    Check(bus.DrainOnce() == 1, "bus still runs after pipe failure");
                    input.Release.Set();
                    Check(bridge.Join(TestHangFuseMs), "stdout drains even if stdin broke before exit detection");
                    bus.DrainOnce();
                    BusEvent retained;
                    Check(bus.TryGetLast(BusTopics.TransportStatus, out retained) && retained.Get("phase") == "готов", "stdin failure preserves pending stdout status");
                } finally {
                    input.Release.Set(); bridge.Dispose();
                    Check(bridge.Join(TestHangFuseMs), "broken stdin reader cleaned up");
                }
            }
        }

        static SafeFileHandle[] FakePipe(int first)
        {
            // ownsHandle=false: tests never touch real OS handles.
            return new[] { new SafeFileHandle(new IntPtr(first), false), new SafeFileHandle(new IntPtr(first + 1), false) };
        }
        static void DuplexHandleOwnership()
        {
            foreach (string failure in new[] { "none", "stdout", "stdin", "start" }) {
                var pipes = new List<SafeFileHandle[]>();
                SafeFileHandle read = null, write = null;
                bool failed = false, launched = false;
                try {
                    string result = NativeJob.StartDuplexCore(parentReads => {
                        Check(parentReads == (pipes.Count == 0), "parent reads stdout, writes stdin");
                        if (failure == (parentReads ? "stdout" : "stdin")) throw new IOException("pipe creation failed");
                        var pair = FakePipe(pipes.Count == 0 ? 100 : 200); pipes.Add(pair); return pair;
                    }, (stdin, stdout) => {
                        launched = true;
                        Check(stdin == new IntPtr(200) && stdout == new IntPtr(101), "child stdio uses opposite pipe ends");
                        if (failure == "start") throw new IOException("process creation failed");
                        return "process";
                    }, out read, out write);
                    Check(result == "process" && failure == "none", "successful process result");
                } catch (IOException) { failed = true; }
                Check(failed == (failure != "none"), "failure propagated");
                Check(launched == (failure == "none" || failure == "start"), "launch only after both pipes opened");
                if (!failed) {
                    Check(ReferenceEquals(read, pipes[0][0]) && ReferenceEquals(write, pipes[1][1]), "parent handles transferred");
                    Check(!read.IsClosed && !write.IsClosed && pipes[0][1].IsClosed && pipes[1][0].IsClosed, "child handles closed in parent immediately");
                    read.Dispose(); write.Dispose();
                } else {
                    Check(read == null && write == null && pipes.SelectMany(p => p).All(h => h.IsClosed), "all opened handles closed on failure");
                }
            }
        }

        static void LauncherWiring([CallerFilePath] string caller = "")
        {
            string root = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(caller), "../../.."));
            var components = Json.Array(Json.Get(Json.Read(Path.Combine(root, "build/components.json")), "components")).Select(Component.Read).ToArray();
            Check(components.Single(c => c.Name == "transport").Bus && components.Where(c => c.Name != "transport").All(c => !c.Bus), "only transport opts into duplex bus");
            // Windows launches are forbidden in this task. Assert the native wiring contract in source,
            // in addition to the real pipe ownership logic tested above with injected handles.
            string supervisor = File.ReadAllText(Path.Combine(root, "app/launcher/Supervisor.cs"));
            Check(supervisor.Contains("else if (Definition.Bus)") && supervisor.Contains("job.StartDuplex(") &&
                !supervisor.Contains("Process.Start("), "duplex component remains job-owned");
            string exited = supervisor.Substring(supervisor.IndexOf("if (process != null && process.HasExited)", StringComparison.Ordinal));
            exited = exited.Substring(0, exited.IndexOf("if (elevated != null", StringComparison.Ordinal));
            Check(exited.Contains("transportBridge.CompleteAfterProcessExit()") && !exited.Contains("transportBridge.Dispose()"),
                "Supervisor uses the same stdout-draining completion exercised by the delayed-reader test");
            string native = File.ReadAllText(Path.Combine(root, "app/launcher/NativeJob.cs"));
            string duplex = native.Substring(native.IndexOf("public Process StartDuplex", StringComparison.Ordinal));
            duplex = duplex.Substring(0, duplex.IndexOf("// Factory seam", StringComparison.Ordinal));
            Check(duplex.Contains("StartCore(") && duplex.Contains("stdInput = input, stdOutput = output, stdError = output }, true)"), "duplex uses explicit inherited handles through StartCore");
            Check(native.Contains("SetHandleInformation(parentReads ? read : write, 1, 0)") &&
                native.Contains("lock (inheritGate)"), "parent pipe ends non-inheritable; pipe creation serialized");
            Check(native.Contains("JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE") && native.Contains("new IntPtr(0x0002000D)") &&
                native.Contains("new IntPtr(0x00020002)"), "kill-on-close job and explicit job/handle attribute lists preserved");
            Check(NativeJob.UniqueHandles(new IntPtr(1), new IntPtr(2), new IntPtr(2)).Length == 2, "shared stdout/stderr handle deduplicated");
        }
    }
}
