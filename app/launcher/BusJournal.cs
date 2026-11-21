using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace RemoteAgents.Launcher
{
    /// <summary>
    /// Журнал шины событий (BusJournal, шаг B1).
    /// Подписчик на "*" шины, пишет события в logs\bus.log через RaLog (формат docs/LOGS.md).
    /// Конституция 4б: шумные топики (tick.*, singbox.line INFO) подавляются и считаются,
    /// сводка bus.noise-summary пишется каждые 1000 подавленных; одинаковые события сворачиваются (до 100 повторов).
    /// </summary>
    public sealed class BusJournal : IDisposable
    {
        public const int NoiseSummaryThreshold = 1000;
        public const int CollapseThreshold = 100;
        public const int MaxValue = 1024;

        private readonly EventBus _bus;
        private readonly string _logsDir;
        private readonly Action<string> _sink;
        private readonly HashSet<string> _exclude;
        private readonly IDisposable _subscription;
        private readonly object _lock = new object();

        private long _suppressedCount;
        private long _tickCount;
        private long _singboxCount;

        // Последнее записанное событие: только для сравнения с повторами; само оно уже на диске (4б).
        private BusEvent _last;
        private string _lastKey;
        private DateTime _repeatUtc;
        private int _repeatCount;
        private long _summarizedAt;
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
            get { lock (_lock) return _repeatCount; }
        }

        public BusJournal(EventBus bus, string logsDir = null, Action<string> sink = null, IEnumerable<string> excludeTopics = null)
        {
            _bus = bus ?? throw new ArgumentNullException(nameof(bus));
            _logsDir = logsDir;
            _sink = sink;
            // Исключённые топики не пишутся и не считаются (служба: singbox.line уже есть как core.line).
            if (excludeTopics != null) _exclude = new HashSet<string>(excludeTopics, StringComparer.Ordinal);
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
                if (_suppressedCount > _summarizedAt)
                {
                    if (WriteLineLocked(FormatNoiseSummary(DateTime.UtcNow)))
                        _summarizedAt = _suppressedCount;
                }
            }
        }

        private void OnEvent(BusEvent evt)
        {
            if (evt == null) return;
            if (_exclude != null && evt.Topic != null && _exclude.Contains(evt.Topic)) return;
            try
            {
                lock (_lock)
                {
                    if (Volatile.Read(ref _disposed) != 0) return;

                    if (IsNoisy(evt))
                    {
                        _suppressedCount++;
                        if (evt.Topic == "tick" || evt.Topic.StartsWith(BusTopics.TickPrefix, StringComparison.Ordinal))
                        {
                            _tickCount++;
                        }
                        else if (string.Equals(evt.Topic, BusTopics.SingboxLine, StringComparison.Ordinal))
                        {
                            _singboxCount++;
                        }

                        if (_suppressedCount % NoiseSummaryThreshold == 0)
                        {
                            if (WriteLineLocked(FormatNoiseSummary(evt.Utc)))
                                _summarizedAt = _suppressedCount;
                        }
                        return;
                    }

                    string key = Identity(evt);
                    if (_last != null && _lastKey == key)
                    {
                        if (_repeatCount < int.MaxValue) _repeatCount++;
                        _repeatUtc = evt.Utc;
                        if (_repeatCount >= CollapseThreshold)
                        {
                            FlushPendingLocked();
                        }
                        return;
                    }

                    // Смена события: итог повторов предыдущего, затем новое пишется сразу.
                    if (!FlushPendingLocked()) return;
                    _last = null; _lastKey = null;
                    if (!WriteLineLocked(FormatEvent(evt))) return;
                    // Не удерживаем исходные поля/длинные значения между событиями: только SHA-256 и метаданные.
                    _lastKey = key;
                    _last = new BusEvent(evt.Seq, Cut(evt.Topic), Cut(evt.Source), evt.Utc, null);
                    _repeatUtc = evt.Utc;
                }
            }
            catch
            {
                // Ошибка записи журнала не должна ронять шину
            }
        }

        private bool FlushPendingLocked()
        {
            if (_last == null || _repeatCount == 0) return true;

            int count = _repeatCount;
            if (!WriteLineLocked(FormatRepeat(_last, count, _repeatUtc))) return false;
            _repeatCount = 0;
            return true;
        }

        private bool WriteLineLocked(string line)
        {
            if (string.IsNullOrEmpty(line)) return true;
            try
            {
                if (_sink != null)
                {
                    _sink(line);
                    return true;
                }

                string dir = !string.IsNullOrEmpty(_logsDir) ? _logsDir : RaLog.DefaultDir;
                if (!string.IsNullOrEmpty(dir))
                {
                    return RaLog.AppendLine(dir, "bus", line);
                }
            }
            catch
            {
                // Ошибка записи журнала не роняет шину
            }
            return false;
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

        // Хеш исходных значений до маскирования/обрезки: разные длинные строки не становятся повторами.
        private static string Identity(BusEvent evt)
        {
            using (var sha = SHA256.Create())
            using (var stream = new CryptoStream(Stream.Null, sha, CryptoStreamMode.Write))
            using (var writer = new BinaryWriter(stream, Encoding.UTF8)) {
                writer.Write(evt.Topic); writer.Write(evt.Source); writer.Write(evt.Fields.Count);
                foreach (var pair in evt.Fields.OrderBy(p => p.Key, StringComparer.Ordinal)) {
                    writer.Write(pair.Key); writer.Write(pair.Value != null);
                    if (pair.Value != null) writer.Write(pair.Value);
                }
                writer.Flush(); stream.FlushFinalBlock();
                return Convert.ToBase64String(sha.Hash);
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
                    // Совпадение с служебными ключами не теряем, а переименовываем.
                    if (key == "seq" || key == "source" || key == "count") key = "field_" + key;
                    fields.Add(new KeyValuePair<string, string>(key, Cut(kvp.Value)));
                }
            }

            return RaLog.Format(ToOffset(evt.Utc), LogLevel.Info, "bus", evt.Topic, fields, RaLog.Session);
        }

        private static string FormatRepeat(BusEvent evt, int count, DateTime utc)
        {
            var fields = new List<KeyValuePair<string, string>>
            {
                new KeyValuePair<string, string>("topic", Cut(evt.Topic)),
                new KeyValuePair<string, string>("source", evt.Source),
                new KeyValuePair<string, string>("first_seq", evt.Seq.ToString(CultureInfo.InvariantCulture)),
                new KeyValuePair<string, string>("count", count.ToString(CultureInfo.InvariantCulture))
            };
            return RaLog.Format(ToOffset(utc), LogLevel.Info, "bus", "repeat", fields, RaLog.Session);
        }

        private string FormatNoiseSummary(DateTime utc)
        {
            var fields = new List<KeyValuePair<string, string>>
            {
                new KeyValuePair<string, string>("suppressed", _suppressedCount.ToString(CultureInfo.InvariantCulture)),
                new KeyValuePair<string, string>("tick", _tickCount.ToString(CultureInfo.InvariantCulture)),
                new KeyValuePair<string, string>("singbox", _singboxCount.ToString(CultureInfo.InvariantCulture))
            };
            return RaLog.Format(ToOffset(utc), LogLevel.Info, "bus", BusTopics.BusNoiseSummary, fields, RaLog.Session);
        }
    }
}
