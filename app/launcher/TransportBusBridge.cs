using System;
using System.Collections.Generic;
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

        readonly Stream input;
        readonly StreamWriter output;
        readonly EventBus bus;
        readonly string logsDir;
        readonly int queueLimit;
        readonly object writeLock = new object();
        IDisposable subscription;
        Thread readerThread;
        int disposed;
        long lines, parsed, rejected, dropped, sent;

        public long Lines => Interlocked.Read(ref lines);
        public long Parsed => Interlocked.Read(ref parsed);
        public long Rejected => Interlocked.Read(ref rejected);
        public long Dropped => Interlocked.Read(ref dropped);
        public long Sent => Interlocked.Read(ref sent);

        public TransportBusBridge(Stream stdout, StreamWriter stdin, EventBus bus, string logsDir = null, int queueLimit = DefaultQueueLimit)
        {
            this.input = stdout;
            this.output = stdin;
            this.bus = bus;
            this.logsDir = logsDir;
            this.queueLimit = queueLimit > 0 ? queueLimit : DefaultQueueLimit;
            if (bus != null && output != null)
                subscription = bus.Subscribe("*", OnBusEvent);
        }

        public void Start()
        {
            if (input == null) return;
            readerThread = new Thread(ReadLoop) { IsBackground = true, Name = "transport-bus-reader" };
            readerThread.Start();
        }

        public bool Join(int ms)
        {
            var t = readerThread;
            return t == null || t.Join(ms);
        }

        public static bool IsAllowedIncoming(string topic)
        {
            if (string.IsNullOrEmpty(topic)) return false;
            return topic == BusTopics.TransportStatus ||
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
                    safeFields[pair.Key] = LogMask.Clean(pair.Value ?? "");
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
                string t = Json.Str(map, "topic");
                if (string.IsNullOrEmpty(t) || !IsAllowedIncoming(t)) return false;
                var fObj = Json.Get(map, "fields") as Dictionary<string, object>;
                if (fObj == null) return false;
                var res = new Dictionary<string, string>(StringComparer.Ordinal);
                foreach (var p in fObj)
                    res[p.Key] = p.Value != null ? LogMask.Clean(Convert.ToString(p.Value, CultureInfo.InvariantCulture)) : "";
                topic = t;
                fields = res;
                return true;
            }
            catch
            {
                return false;
            }
        }

        void ReadLoop()
        {
            var buf = new byte[4096];
            var pending = new MemoryStream();
            try
            {
                while (Volatile.Read(ref disposed) == 0)
                {
                    int n;
                    try { n = input.Read(buf, 0, buf.Length); } catch { break; }
                    if (n <= 0) break;
                    for (int i = 0; i < n; i++)
                    {
                        if (buf[i] == (byte)'\n')
                        {
                            ConsumeLine(Encoding.UTF8.GetString(pending.ToArray()).TrimEnd('\r'));
                            pending.SetLength(0);
                        }
                        else
                        {
                            pending.WriteByte(buf[i]);
                            if (pending.Length > MaxLineBytes * 2)
                            {
                                ConsumeLine(Encoding.UTF8.GetString(pending.ToArray()).TrimEnd('\r'));
                                pending.SetLength(0);
                            }
                        }
                    }
                }
                if (pending.Length > 0)
                    ConsumeLine(Encoding.UTF8.GetString(pending.ToArray()).TrimEnd('\r'));
            }
            finally
            {
                try { input.Dispose(); } catch { }
            }
        }

        public void ConsumeLine(string line)
        {
            if (string.IsNullOrEmpty(line)) return;
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
                if (Parsed >= queueLimit)
                {
                    Interlocked.Increment(ref dropped);
                    return;
                }
                Interlocked.Increment(ref parsed);
                try { bus?.Publish(topic, BusTopics.Sources.Transport, fields); } catch { }
            }
            else
            {
                string clean = LogMask.Clean(line);
                if (clean.Length > 2000) clean = clean.Substring(0, 2000);
                if (!string.IsNullOrEmpty(logsDir))
                {
                    try { RaLog.WriteTo(logsDir, "transport", LogLevel.Info, "transport", "stdout", new[] { new KeyValuePair<string, string>("line", clean) }); } catch { }
                }
            }
        }

        void OnBusEvent(BusEvent e)
        {
            if (Volatile.Read(ref disposed) != 0 || output == null) return;
            string line = FormatOutgoing(e);
            if (line == null) return;
            lock (writeLock)
            {
                try
                {
                    output.WriteLine(line);
                    output.Flush();
                    Interlocked.Increment(ref sent);
                }
                catch { /* запись не роняет шину */ }
            }
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref disposed, 1) != 0) return;
            try { subscription?.Dispose(); } catch { }
            try { output?.Dispose(); } catch { }
            try { input?.Dispose(); } catch { }
        }
    }
}
