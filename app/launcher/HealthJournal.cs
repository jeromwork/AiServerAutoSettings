using System;
using System.Collections.Generic;
using System.Globalization;
using System.Threading;

namespace RemoteAgents.Launcher
{
    /// <summary>
    /// Журнал здоровья и падений (HealthJournal, шаг H3 этап 1).
    /// Подписчик шины (EventBus) на топики:
    /// - component.exit (с code)
    /// - unhandled
    /// - block.ready
    /// - block.degraded
    /// - health.*
    /// Пишет каждое событие СРАЗУ (без буфера на выходе, ПОПРАВКА v4 п.4) в поток health
    /// (logs\health.log через RaLog).
    /// </summary>
    public sealed class HealthJournal : IDisposable
    {
        public const int MaxValue = 1024;

        private readonly EventBus _bus;
        private readonly string _logsDir;
        private readonly Action<string> _sink;
        private readonly IDisposable[] _subscriptions;
        private readonly object _lock = new object();
        private int _disposed;

        public HealthJournal(EventBus bus, string logsDir = null, Action<string> sink = null)
        {
            _bus = bus ?? throw new ArgumentNullException(nameof(bus));
            _logsDir = logsDir;
            _sink = sink;

            _subscriptions = new[]
            {
                _bus.Subscribe(BusTopics.ComponentExit, OnEvent),
                _bus.Subscribe(BusTopics.Unhandled, OnEvent),
                _bus.Subscribe(BusTopics.BlockReady, OnEvent),
                _bus.Subscribe(BusTopics.BlockDegraded, OnEvent),
                _bus.Subscribe(BusTopics.BlockFailed, OnEvent),
                _bus.Subscribe("health.*", OnEvent)
            };
        }

        public void Flush()
        {
            // Без буфера на выходе: каждое событие пишется сразу при поступлении.
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0)
                return;

            if (_subscriptions != null)
            {
                for (int i = 0; i < _subscriptions.Length; i++)
                {
                    try
                    {
                        _subscriptions[i]?.Dispose();
                    }
                    catch
                    {
                    }
                }
            }
        }

        private void OnEvent(BusEvent evt)
        {
            if (evt == null) return;
            if (Volatile.Read(ref _disposed) != 0) return;
            if (!IsInterested(evt)) return;

            try
            {
                lock (_lock)
                {
                    if (Volatile.Read(ref _disposed) != 0) return;
                    WriteLineLocked(FormatEvent(evt));
                }
            }
            catch
            {
                // Ошибка записи журнала не должна ронять шину
            }
        }

        internal static bool IsInterested(BusEvent evt)
        {
            if (evt == null || string.IsNullOrEmpty(evt.Topic)) return false;
            string topic = evt.Topic;

            if (string.Equals(topic, BusTopics.ComponentExit, StringComparison.Ordinal))
            {
                return evt.Fields != null && !string.IsNullOrEmpty(evt["code"]);
            }

            if (string.Equals(topic, BusTopics.Unhandled, StringComparison.Ordinal))
                return true;

            if (string.Equals(topic, BusTopics.BlockReady, StringComparison.Ordinal) ||
                string.Equals(topic, BusTopics.BlockDegraded, StringComparison.Ordinal) ||
                string.Equals(topic, BusTopics.BlockFailed, StringComparison.Ordinal))
                return true;

            if (topic.StartsWith("health.", StringComparison.Ordinal) || string.Equals(topic, "health", StringComparison.Ordinal))
                return true;

            return false;
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
                    RaLog.AppendLine(dir, "health", line);
                }
            }
            catch
            {
                // Ошибка записи журнала не роняет шину
            }
        }

        private static DateTimeOffset ToOffset(DateTime utc)
        {
            if (utc == default(DateTime)) utc = DateTime.UtcNow;
            return new DateTimeOffset(DateTime.SpecifyKind(utc, DateTimeKind.Utc)).ToLocalTime();
        }

        private static string Cut(string value)
        {
            if (value == null) return string.Empty;
            return value.Length > MaxValue ? value.Substring(0, MaxValue) + "…[cut]" : value;
        }

        private static string FormatEvent(BusEvent evt)
        {
            var fields = new List<KeyValuePair<string, string>>();
            fields.Add(new KeyValuePair<string, string>("seq", evt.Seq.ToString(CultureInfo.InvariantCulture)));
            fields.Add(new KeyValuePair<string, string>("source", Cut(evt.Source)));
            if (evt.Fields != null)
            {
                foreach (var kvp in evt.Fields)
                {
                    string key = kvp.Key ?? string.Empty;
                    if (key.Length == 0) continue;
                    // Совпадение со служебными ключами не теряем, а переименовываем.
                    if (key == "seq" || key == "source" || key == "count") key = "field_" + key;
                    fields.Add(new KeyValuePair<string, string>(key, Cut(kvp.Value)));
                }
            }

            return RaLog.Format(ToOffset(evt.Utc), LogLevel.Info, "health", evt.Topic, fields, RaLog.Session);
        }
    }
}
