using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;

namespace RemoteAgents.Launcher
{
    /// <summary>
    /// Журнал шины событий (BusJournal, шаг B1).
    /// Подписчик на "*" шины, пишет события в logs\bus.log через RaLog (формат jsonl).
    /// Конституция 4б: шумные топики (tick.*, singbox.line INFO) подавляются и считаются,
    /// сводка bus.noise-summary пишется каждые 1000 подавленных; одинаковые события сворачиваются (до 100 повторов).
    /// </summary>
    public sealed class BusJournal : IDisposable
    {
        public const int NoiseSummaryThreshold = 1000;
        public const int CollapseThreshold = 100;

        private readonly EventBus _bus;
        private readonly string _logsDir;
        private readonly Action<string> _sink;
        private readonly IDisposable _subscription;
        private readonly object _lock = new object();

        private long _suppressedCount;
        private long _tickCount;
        private long _singboxCount;

        private BusEvent _pendingEvent;
        private int _pendingCount;
        private int _disposed;

        public long SuppressedCount
        {
            get { lock (_lock) return _suppressedCount; }
        }

        public long TickCount
        {
            get { lock (_lock) return _tickCount; }
        }

        public long SingboxCount
        {
            get { lock (_lock) return _singboxCount; }
        }

        public int PendingCount
        {
            get { lock (_lock) return _pendingCount; }
        }

        public BusJournal(EventBus bus, string logsDir = null, Action<string> sink = null)
        {
            _bus = bus ?? throw new ArgumentNullException(nameof(bus));
            _logsDir = logsDir;
            _sink = sink;
            _subscription = _bus.Subscribe("*", OnEvent);
        }

        public void Flush()
        {
            lock (_lock)
            {
                FlushPendingLocked();
            }
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0)
                return;

            try
            {
                _subscription?.Dispose();
            }
            catch
            {
            }

            lock (_lock)
            {
                FlushPendingLocked();
            }
        }

        private void OnEvent(BusEvent evt)
        {
            if (evt == null) return;
            try
            {
                lock (_lock)
                {
                    if (Volatile.Read(ref _disposed) != 0) return;

                    if (IsNoisy(evt))
                    {
                        _suppressedCount++;
                        if (evt.Topic.StartsWith("tick", StringComparison.Ordinal))
                        {
                            _tickCount++;
                        }
                        else if (string.Equals(evt.Topic, BusTopics.SingboxLine, StringComparison.Ordinal))
                        {
                            _singboxCount++;
                        }

                        if (_suppressedCount % NoiseSummaryThreshold == 0)
                        {
                            FlushPendingLocked();
                            string summaryLine = FormatNoiseSummary(evt);
                            WriteLineLocked(summaryLine);
                        }
                        return;
                    }

                    if (_pendingEvent == null)
                    {
                        _pendingEvent = evt;
                        _pendingCount = 1;
                    }
                    else if (AreIdentical(_pendingEvent, evt))
                    {
                        _pendingCount++;
                        if (_pendingCount >= CollapseThreshold)
                        {
                            FlushPendingLocked();
                        }
                    }
                    else
                    {
                        // При смене события — сбросить накопленное
                        FlushPendingLocked();
                        _pendingEvent = evt;
                        _pendingCount = 1;
                    }
                }
            }
            catch
            {
                // Ошибка записи журнала не должна ронять шину
            }
        }

        private void FlushPendingLocked()
        {
            if (_pendingEvent == null) return;

            var evt = _pendingEvent;
            int count = _pendingCount;
            _pendingEvent = null;
            _pendingCount = 0;

            string line = FormatEvent(evt, count);
            WriteLineLocked(line);
        }

        private void WriteLineLocked(string line)
        {
            if (string.IsNullOrEmpty(line)) return;
            try
            {
                if (_sink != null)
                {
                    _sink(line);
                    return;
                }

                string dir = !string.IsNullOrEmpty(_logsDir) ? _logsDir : RaLog.DefaultDir;
                if (!string.IsNullOrEmpty(dir))
                {
                    RaLog.AppendLine(dir, "bus", line);
                }
            }
            catch
            {
                // Ошибка записи журнала не роняет шину
            }
        }

        private static bool IsNoisy(BusEvent evt)
        {
            if (evt == null || string.IsNullOrEmpty(evt.Topic)) return false;
            if (evt.Topic == "tick" || evt.Topic.StartsWith(BusTopics.TickPrefix, StringComparison.Ordinal))
                return true;

            if (string.Equals(evt.Topic, BusTopics.SingboxLine, StringComparison.Ordinal))
            {
                string level = evt["level"];
                if (!string.IsNullOrEmpty(level))
                {
                    return string.Equals(level, "info", StringComparison.OrdinalIgnoreCase) ||
                           string.Equals(level, "debug", StringComparison.OrdinalIgnoreCase);
                }

                string line = evt["line"];
                if (string.IsNullOrEmpty(line)) line = evt["msg"];
                if (string.IsNullOrEmpty(line)) line = evt["text"];
                if (string.IsNullOrEmpty(line)) return true; // По умолчанию уровень INFO

                if (Regex.IsMatch(line, @"\b(FATAL|PANIC|ERROR|WARN|WARNING)\b", RegexOptions.IgnoreCase))
                    return false;

                return true;
            }

            return false;
        }

        private static bool AreIdentical(BusEvent a, BusEvent b)
        {
            if (ReferenceEquals(a, b)) return true;
            if (a == null || b == null) return false;
            if (!string.Equals(a.Topic, b.Topic, StringComparison.Ordinal)) return false;
            if (!string.Equals(a.Source, b.Source, StringComparison.Ordinal)) return false;

            var fa = a.Fields;
            var fb = b.Fields;
            int ca = fa != null ? fa.Count : 0;
            int cb = fb != null ? fb.Count : 0;
            if (ca != cb) return false;
            if (ca == 0) return true;

            foreach (var pair in fa)
            {
                if (!fb.TryGetValue(pair.Key, out var bVal)) return false;
                if (!string.Equals(pair.Value, bVal, StringComparison.Ordinal)) return false;
            }

            return true;
        }

        private static string FormatEvent(BusEvent evt, int count)
        {
            var doc = new Dictionary<string, object>(StringComparer.Ordinal);
            doc["seq"] = evt.Seq;
            doc["topic"] = evt.Topic;
            doc["source"] = evt.Source;
            if (count > 1)
            {
                doc["count"] = count;
            }

            if (evt.Fields != null)
            {
                foreach (var kvp in evt.Fields)
                {
                    string key = kvp.Key ?? string.Empty;
                    if (string.IsNullOrEmpty(key)) continue;

                    string val = kvp.Value ?? string.Empty;
                    string cleanVal = LogMask.IsSecretKey(key) ? "***" : LogMask.Clean(val);

                    if (!doc.ContainsKey(key))
                    {
                        doc[key] = cleanVal;
                    }
                    else
                    {
                        doc["field_" + key] = cleanVal;
                    }
                }
            }

            return Json.Encode(doc);
        }

        private string FormatNoiseSummary(BusEvent evt)
        {
            var doc = new Dictionary<string, object>(StringComparer.Ordinal)
            {
                { "seq", evt.Seq },
                { "topic", BusTopics.BusNoiseSummary },
                { "source", "bus" },
                { "suppressed", _suppressedCount },
                { "count", _suppressedCount },
                { "tick", _tickCount },
                { "singbox", _singboxCount }
            };

            return Json.Encode(doc);
        }
    }
}
