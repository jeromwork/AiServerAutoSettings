using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;

namespace RemoteAgents.Launcher
{
    internal sealed class TransportBusBridge : IDisposable
    {
        public const int MaxLineBytes = 8192;
        public const int DefaultQueueLimit = 2000;
        const string BusPrefix = "@bus ";
        const int ExitDrainTimeoutMs = 1000;

        readonly Stream input;
        readonly Stream output;
        readonly EventBus bus;
        readonly string logsDir;
        readonly BlockingCollection<string> outgoing;
        IDisposable subscription;
        Thread readerThread, writerThread, completionThread;
        int disposed, sendingStopped, completing, started, ready, inputReady, inOverflow, tooLongReported;
        long lines, parsed, rejected, dropped, sent, tooLong, writeErrors;

        public long Lines => Interlocked.Read(ref lines);
        public long Parsed => Interlocked.Read(ref parsed);
        public long Rejected => Interlocked.Read(ref rejected);
        public long Dropped => Interlocked.Read(ref dropped);
        public long Sent => Interlocked.Read(ref sent);
        public long TooLong => Interlocked.Read(ref tooLong);
        public long WriteErrors => Interlocked.Read(ref writeErrors);
        public bool InputReady => Volatile.Read(ref inputReady) != 0;
        public bool Ready => Volatile.Read(ref ready) != 0;

        public TransportBusBridge(Stream stdout, Stream stdin, EventBus bus, string logsDir = null, int queueLimit = DefaultQueueLimit)
        {
            this.input = stdout;
            this.output = stdin;
            this.bus = bus;
            this.logsDir = logsDir;
            outgoing = new BlockingCollection<string>(queueLimit > 0 ? queueLimit : DefaultQueueLimit);
            if (bus != null && output != null)
                subscription = bus.Subscribe("*", OnBusEvent);
        }

        public void Start()
        {
            if (Interlocked.Exchange(ref started, 1) != 0) return;
            if (output != null) {
                writerThread = new Thread(WriteLoop) { IsBackground = true, Name = "transport-bus-writer" };
                writerThread.Start();
            }
            if (input != null) {
                readerThread = new Thread(ReadLoop) { IsBackground = true, Name = "transport-bus-reader" };
                readerThread.Start();
            }
        }

        public bool Join(int ms)
        {
            var t = readerThread;
            return t == null || t.Join(ms);
        }

        internal bool JoinWriter(int ms)
        {
            var t = writerThread;
            return t == null || t.Join(ms);
        }

        internal bool JoinCompletion(int ms)
        {
            var t = completionThread;
            return t == null || t.Join(ms);
        }

        // Process exit is not EOF: the reader may still have buffered final status frames.
        // Stop stdin immediately, but let stdout drain on its own background thread.
        public void CompleteAfterProcessExit(int drainTimeoutMs = ExitDrainTimeoutMs)
        {
            if (Interlocked.Exchange(ref completing, 1) != 0 || Volatile.Read(ref disposed) != 0) return;
            StopSending();
            Start();
            int timeout = Math.Max(0, Math.Min(ExitDrainTimeoutMs, drainTimeoutMs));
            completionThread = new Thread(() => {
                // Fuse: a descendant may keep stdout open after the daemon exits. Never wait
                // on the UI thread or forever; on timeout abort delivery, without claiming EOF.
                bool drained = Join(timeout);
                Dispose();
                if (!drained) WriteLog("stdout.drain.timeout", "process exited; stdout did not reach EOF within drain budget");
            }) { IsBackground = true, Name = "transport-bus-completion" };
            completionThread.Start();
        }

        public static bool IsAllowedIncoming(string topic)
        {
            if (string.IsNullOrEmpty(topic)) return false;
            return topic == BusTopics.TransportStdinReady ||
                   topic == BusTopics.TransportReady ||
                   topic == BusTopics.TransportStatus ||
                   topic == BusTopics.TransportEpisode ||
                   topic == BusTopics.TransportSwitch ||
                   topic == BusTopics.TransportMem ||
                   topic == BusTopics.NetQuality ||
                   topic.StartsWith("singbox.", StringComparison.Ordinal);
        }

        public static bool IsAllowedOutgoing(string topic)
        {
            if (string.IsNullOrEmpty(topic)) return false;
            return topic.StartsWith("win.", StringComparison.Ordinal) ||
                   topic == BusTopics.NetChange ||
                   topic.StartsWith(BusTopics.TickPrefix + "transport-", StringComparison.Ordinal) ||
                   topic == BusTopics.TransportCommand;
        }

        public static string FormatOutgoing(BusEvent e)
        {
            if (e == null || !IsAllowedOutgoing(e.Topic)) return null;
            return FormatOutgoing(e.Topic, e.Fields);
        }

        public static string FormatOutgoing(string topic, IReadOnlyDictionary<string, string> fields)
        {
            if (!IsAllowedOutgoing(topic)) return null;
            var safeFields = new Dictionary<string, object>(StringComparer.Ordinal);
            if (fields != null)
            {
                foreach (var pair in fields)
                    safeFields[pair.Key] = LogMask.IsSecretKey(pair.Key) ? "***" : LogMask.Clean(pair.Value ?? "");
            }
            var payload = new Dictionary<string, object>(StringComparer.Ordinal)
            {
                { "topic", topic },
                { "fields", safeFields }
            };
            string line = BusPrefix + Json.Encode(payload);
            return Encoding.UTF8.GetByteCount(line) > MaxLineBytes ? null : line;
        }

        public static bool TryParseIncoming(string line, out string topic, out Dictionary<string, string> fields)
        {
            topic = null;
            fields = null;
            if (line == null || !line.StartsWith(BusPrefix, StringComparison.Ordinal)) return false;
            if (Encoding.UTF8.GetByteCount(line) > MaxLineBytes) return false;
            string json = line.Substring(BusPrefix.Length).Trim();
            try
            {
                NetHelperProtocol.ValidateJson(json);
                var map = Json.Map(Json.Parse(json));
                string t = Json.Get(map, "topic") as string;
                if (string.IsNullOrEmpty(t) || !IsAllowedIncoming(t)) return false;
                var fObj = Json.Get(map, "fields") as Dictionary<string, object>;
                if (fObj == null) return false;
                var res = new Dictionary<string, string>(StringComparer.Ordinal);
                foreach (var p in fObj) {
                    if (string.IsNullOrEmpty(p.Key) || !IsScalar(p.Value)) return false;
                    res[p.Key] = LogMask.IsSecretKey(p.Key) ? "***" :
                        p.Value != null ? LogMask.Clean(Convert.ToString(p.Value, CultureInfo.InvariantCulture)) : "";
                }
                topic = t;
                fields = res;
                return true;
            }
            catch
            {
                return false;
            }
        }

        static bool IsScalar(object value)
        {
            return value == null || value is string || value is bool || value is byte || value is sbyte ||
                value is short || value is ushort || value is int || value is uint || value is long ||
                value is ulong || value is float || value is double || value is decimal;
        }

        void WriteLog(string action, string text)
        {
            if (string.IsNullOrEmpty(logsDir)) return;
            try { RaLog.WriteTo(logsDir, "transport", LogLevel.Info, "transport", action,
                new[] { new KeyValuePair<string, string>("line", LogMask.Clean(text)) }); } catch { }
        }

        void ReadLoop()
        {
            var buf = new byte[4096];
            var utf8 = new UTF8Encoding(false, true);
            bool skipping = false;
            using (var pending = new MemoryStream())
            try {
                while (Volatile.Read(ref disposed) == 0) {
                    int n;
                    try { n = input.Read(buf, 0, buf.Length); } catch { break; }
                    if (n <= 0) break;
                    for (int i = 0; i < n; i++) {
                        if (buf[i] == (byte)'\n') {
                            if (!skipping) ConsumeBytes(pending, utf8);
                            pending.SetLength(0);
                            skipping = false;
                        } else if (!skipping) {
                            pending.WriteByte(buf[i]);
                            // Allow one trailing CR in a maximum-size CRLF line.
                            if (pending.Length > MaxLineBytes &&
                                !(pending.Length == MaxLineBytes + 1 && buf[i] == (byte)'\r')) {
                                Interlocked.Increment(ref lines);
                                Interlocked.Increment(ref rejected);
                                WriteLog("stdout.rejected", "line exceeds 8192 bytes; discarded through newline");
                                pending.SetLength(0);
                                skipping = true;
                            }
                        }
                    }
                }
                if (!skipping && pending.Length > 0 && Volatile.Read(ref disposed) == 0)
                    ConsumeBytes(pending, utf8);
            } finally {
                try { input.Dispose(); } catch { }
            }
        }

        void ConsumeBytes(MemoryStream pending, Encoding utf8)
        {
            var bytes = pending.ToArray();
            int count = bytes.Length;
            if (count > 0 && bytes[count - 1] == (byte)'\r') count--;
            try { ConsumeLine(utf8.GetString(bytes, 0, count)); }
            catch (DecoderFallbackException) {
                Interlocked.Increment(ref lines);
                Interlocked.Increment(ref rejected);
                WriteLog("stdout.rejected", "invalid UTF-8");
            }
        }

        public void ConsumeLine(string line)
        {
            if (Volatile.Read(ref disposed) != 0 || string.IsNullOrEmpty(line)) return;
            Interlocked.Increment(ref lines);
            if (line.StartsWith(BusPrefix, StringComparison.Ordinal))
            {
                string topic;
                Dictionary<string, string> fields;
                if (!TryParseIncoming(line, out topic, out fields))
                {
                    Interlocked.Increment(ref rejected);
                    return;
                }
                Interlocked.Increment(ref parsed);
                if (topic == BusTopics.TransportReady) Volatile.Write(ref ready, 1);
                if (topic == BusTopics.TransportStdinReady) Volatile.Write(ref inputReady, 1);
                // EventBus owns the bounded incoming queue; Parsed is a lifetime statistic.
                try {
                    if (bus != null && bus.Publish(topic, BusTopics.Sources.Transport, fields) < 0)
                        Interlocked.Increment(ref dropped);
                } catch { Interlocked.Increment(ref dropped); }
            }
            else
            {
                string clean = LogMask.Clean(line);
                if (clean.Length > 2000) clean = clean.Substring(0, 2000);
                WriteLog("stdout", clean);
            }
        }

        void OnBusEvent(BusEvent e)
        {
            if (Volatile.Read(ref sendingStopped) != 0 || output == null || !InputReady || !IsAllowedOutgoing(e.Topic)) return;
            string line = FormatOutgoing(e);
            if (line == null) {
                Interlocked.Increment(ref tooLong);
                if (Interlocked.Exchange(ref tooLongReported, 1) == 0)
                    WriteLog("stdin.rejected", "outgoing event exceeds 8192 bytes");
                return;
            }
            Interlocked.Exchange(ref tooLongReported, 0);
            try {
                if (outgoing.TryAdd(line)) return;
            } catch (InvalidOperationException) { return; } // Dispose raced dispatch.
            Interlocked.Increment(ref dropped);
            if (Interlocked.Exchange(ref inOverflow, 1) == 0) {
                bus?.Publish(BusTopics.BusOverflow, BusTopics.Sources.Transport,
                    "queue", "transport.stdin", "dropped", Dropped.ToString(CultureInfo.InvariantCulture));
            }
        }

        void WriteLoop()
        {
            // Explicit UTF-8 without BOM: StandardInput uses the console code page on net48.
            StreamWriter writer = null;
            try {
                writer = new StreamWriter(output, new UTF8Encoding(false)) { NewLine = "\n" };
                foreach (var line in outgoing.GetConsumingEnumerable()) {
                    if (Volatile.Read(ref sendingStopped) != 0) break;
                    writer.WriteLine(line);
                    writer.Flush();
                    Interlocked.Increment(ref sent);
                    if (outgoing.Count <= outgoing.BoundedCapacity / 2)
                        Interlocked.Exchange(ref inOverflow, 0);
                }
            } catch {
                Interlocked.Increment(ref writeErrors);
                // Broken stdin is normal at process exit and must not abort pending stdout.
                StopSending();
                WriteLog("stdin.failed", "transport stdin closed");
            } finally {
                // StreamWriter.Dispose may flush: it belongs ONLY to this background thread.
                // Supervisor closes the job, releasing blocked pipe I/O on shutdown/restart.
                try { writer?.Dispose(); } catch { }
                try { output.Dispose(); } catch { }
            }
        }

        void StopSending()
        {
            if (Interlocked.Exchange(ref sendingStopped, 1) != 0) return;
            try { subscription?.Dispose(); } catch { }
            outgoing.CompleteAdding();
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref disposed, 1) != 0) return;
            StopSending();
            // Never close/flush a StreamWriter or wait for pipe I/O on the caller/UI thread.
            // Also starts cleanup threads if construction was followed by Dispose before Start.
            Start();
        }
    }
}
