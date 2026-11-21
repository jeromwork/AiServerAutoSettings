using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Threading;

namespace RemoteAgents.Launcher
{
    /// <summary>
    /// Неизменяемое событие шины (BusEvent).
    /// </summary>
    public sealed class BusEvent
    {
        public static readonly IReadOnlyDictionary<string, string> EmptyFields =
            new Dictionary<string, string>(StringComparer.Ordinal);

        public long Seq { get; }
        public string Topic { get; }
        public string Source { get; }
        public DateTime Utc { get; }
        public IReadOnlyDictionary<string, string> Fields { get; }

        public BusEvent(long seq, string topic, string source, DateTime utc, IReadOnlyDictionary<string, string> fields)
        {
            Seq = seq;
            Topic = topic ?? string.Empty;
            Source = source ?? string.Empty;
            Utc = utc;
            Fields = fields ?? EmptyFields;
        }

        public string this[string key]
        {
            get
            {
                if (key != null && Fields != null && Fields.TryGetValue(key, out var val))
                    return val ?? string.Empty;
                return string.Empty;
            }
        }

        public string Get(string key, string fallback = "")
        {
            if (key != null && Fields != null && Fields.TryGetValue(key, out var val))
                return val ?? fallback;
            return fallback;
        }

        public override string ToString()
        {
            return $"#{Seq} [{Utc:HH:mm:ss.fff}] {Topic} from {Source}";
        }
    }

    /// <summary>
    /// Источник периодического тика шины (tick.name). Единственное разрешённое место периодики (Конституция 4а).
    /// </summary>
    public sealed class BusTick : IDisposable
    {
        private readonly EventBus _bus;
        private readonly string _name;
        private readonly int _periodMs;
        private Timer _timer;
        private int _disposed;

        public string Name => _name;
        public int PeriodMs => _periodMs;

        internal BusTick(EventBus bus, string name, int periodMs, bool startTimer)
        {
            _bus = bus ?? throw new ArgumentNullException(nameof(bus));
            _name = name ?? string.Empty;
            _periodMs = periodMs;

            if (startTimer && periodMs > 0)
            {
                // Таймер только публикует tick.<имя> в шину, логику вызывает подписчик.
                _timer = new Timer(_ =>
                {
                    if (Volatile.Read(ref _disposed) == 0)
                    {
                        _bus.Publish(BusTopics.TickPrefix + _name, BusTopics.Sources.Timer);
                    }
                }, null, periodMs, periodMs);
            }
        }

        public void Fire()
        {
            _bus.FireTick(_name);
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) == 0)
            {
                _timer?.Dispose();
                _timer = null;
            }
        }
    }

    /// <summary>
    /// Ядро шины событий (EventBus). Потокобезопасная очередь FIFO, retained-состояния,
    /// префиксная подписка, защита от переполнения и изоляция ошибок подписчиков.
    /// </summary>
    public sealed class EventBus : IDisposable
    {
        public const int DefaultQueueLimit = 10000;

        private sealed class Subscription
        {
            public readonly long Id;
            public readonly string Filter;
            public readonly Action<BusEvent> Handler;

            public Subscription(long id, string filter, Action<BusEvent> handler)
            {
                Id = id;
                Filter = filter;
                Handler = handler;
            }
        }

        private sealed class SubscriptionToken : IDisposable
        {
            private EventBus _bus;
            private readonly long _subId;

            public SubscriptionToken(EventBus bus, long subId)
            {
                _bus = bus;
                _subId = subId;
            }

            public void Dispose()
            {
                var bus = Interlocked.Exchange(ref _bus, null);
                bus?.Unsubscribe(_subId);
            }
        }

        private readonly BlockingCollection<BusEvent> _queue;
        private readonly int _queueLimit;
        private readonly bool _manualDispatch;
        private readonly string _defaultSource;
        private readonly ConcurrentDictionary<string, BusEvent> _retained;

        private readonly Thread _dispatchThread;
        private readonly CancellationTokenSource _cts;

        private Subscription[] _subscriptions = new Subscription[0];
        private long _subIdCounter;
        private long _seqCounter;
        private long _droppedCount;
        private int _inOverflow;
        private int _disposed;

        public long DroppedCount => Volatile.Read(ref _droppedCount);
        public long LastSeq => Volatile.Read(ref _seqCounter);
        public int QueueCount => _queue.Count;

        public EventBus(bool manualDispatch = false, int queueLimit = DefaultQueueLimit, string defaultSource = BusTopics.Sources.Tray)
        {
            _manualDispatch = manualDispatch;
            _queueLimit = queueLimit;
            _defaultSource = string.IsNullOrEmpty(defaultSource) ? BusTopics.Sources.Tray : defaultSource;
            _retained = new ConcurrentDictionary<string, BusEvent>(StringComparer.Ordinal);

            // Резервируем небольшой буфер сверх лимита для размещения служебного bus.overflow
            int boundedCapacity = _queueLimit > 0 ? _queueLimit + 100 : int.MaxValue;
            _queue = new BlockingCollection<BusEvent>(boundedCapacity);

            if (!_manualDispatch)
            {
                _cts = new CancellationTokenSource();
                _dispatchThread = new Thread(DispatchLoop)
                {
                    Name = "EventBusDispatcher",
                    IsBackground = true
                };
                _dispatchThread.Start();
            }
        }

        public IDisposable Subscribe(string topicOrPrefix, Action<BusEvent> handler)
        {
            if (handler == null) throw new ArgumentNullException(nameof(handler));
            long subId = Interlocked.Increment(ref _subIdCounter);
            var sub = new Subscription(subId, topicOrPrefix, handler);

            Subscription[] current, updated;
            do
            {
                current = _subscriptions;
                updated = new Subscription[current.Length + 1];
                Array.Copy(current, updated, current.Length);
                updated[current.Length] = sub;
            } while (Interlocked.CompareExchange(ref _subscriptions, updated, current) != current);

            return new SubscriptionToken(this, subId);
        }

        private void Unsubscribe(long subId)
        {
            Subscription[] current, updated;
            do
            {
                current = _subscriptions;
                int index = -1;
                for (int i = 0; i < current.Length; i++)
                {
                    if (current[i].Id == subId)
                    {
                        index = i;
                        break;
                    }
                }
                if (index < 0) return;

                updated = new Subscription[current.Length - 1];
                if (index > 0)
                    Array.Copy(current, 0, updated, 0, index);
                if (index < current.Length - 1)
                    Array.Copy(current, index + 1, updated, index, current.Length - index - 1);
            } while (Interlocked.CompareExchange(ref _subscriptions, updated, current) != current);
        }

        public long Publish(string topic, string source, params string[] kv)
        {
            return Publish(topic, source, ParseFields(kv));
        }

        public long Publish(string topic, string source, IReadOnlyDictionary<string, string> fields)
        {
            if (topic == null) throw new ArgumentNullException(nameof(topic));
            string actualSource = !string.IsNullOrEmpty(source) ? source : _defaultSource;

            // Проверка переполнения очереди
            if (_queueLimit > 0 && _queue.Count >= _queueLimit)
            {
                long dropped = Interlocked.Increment(ref _droppedCount);
                if (Interlocked.CompareExchange(ref _inOverflow, 1, 0) == 0)
                {
                    long overflowSeq = Interlocked.Increment(ref _seqCounter);
                    var overflowFields = new Dictionary<string, string>(StringComparer.Ordinal)
                    {
                        { "dropped", dropped.ToString() },
                        { "topic", topic }
                    };
                    var overflowEvt = new BusEvent(overflowSeq, BusTopics.BusOverflow, _defaultSource, DateTime.UtcNow, overflowFields);
                    _queue.TryAdd(overflowEvt);
                }
                return -1;
            }

            long seq = Interlocked.Increment(ref _seqCounter);
            var evt = new BusEvent(seq, topic, actualSource, DateTime.UtcNow, fields);

            if (!_queue.TryAdd(evt))
            {
                long dropped = Interlocked.Increment(ref _droppedCount);
                if (Interlocked.CompareExchange(ref _inOverflow, 1, 0) == 0)
                {
                    long overflowSeq = Interlocked.Increment(ref _seqCounter);
                    var overflowFields = new Dictionary<string, string>(StringComparer.Ordinal)
                    {
                        { "dropped", dropped.ToString() },
                        { "topic", topic }
                    };
                    var overflowEvt = new BusEvent(overflowSeq, BusTopics.BusOverflow, _defaultSource, DateTime.UtcNow, overflowFields);
                    _queue.TryAdd(overflowEvt);
                }
                return -1;
            }

            _retained.AddOrUpdate(topic, evt, (k, old) => evt.Seq > old.Seq ? evt : old);
            return seq;
        }

        public bool TryGetLast(string topic, out BusEvent evt)
        {
            if (topic != null && _retained.TryGetValue(topic, out evt))
            {
                return true;
            }
            evt = null;
            return false;
        }

        public BusTick Every(string name, int periodMs)
        {
            return new BusTick(this, name, periodMs, startTimer: !_manualDispatch);
        }

        public void FireTick(string name)
        {
            Publish(BusTopics.TickPrefix + (name ?? string.Empty), BusTopics.Sources.Timer);
        }

        public int DrainOnce(int maxCount = -1)
        {
            int count = 0;
            while (maxCount <= 0 || count < maxCount)
            {
                if (!_queue.TryTake(out var evt))
                    break;

                Dispatch(evt);
                count++;
            }
            return count;
        }

        private void DispatchLoop()
        {
            try
            {
                while (!_cts.IsCancellationRequested && !_queue.IsCompleted)
                {
                    if (_queue.TryTake(out var evt, Timeout.Infinite, _cts.Token))
                    {
                        Dispatch(evt);
                    }
                }
            }
            catch (OperationCanceledException)
            {
                // Штатная остановка при Dispose
            }
            catch
            {
                // Защита фонового потока от падения
            }
        }

        private void Dispatch(BusEvent evt)
        {
            if (evt == null) return;

            // Завершение эпизода переполнения, когда очередь опустилась ниже предела
            if (_inOverflow != 0 && _queueLimit > 0 && _queue.Count < _queueLimit)
            {
                Interlocked.Exchange(ref _inOverflow, 0);
            }

            var subs = _subscriptions;
            for (int i = 0; i < subs.Length; i++)
            {
                var sub = subs[i];
                if (Matches(sub.Filter, evt.Topic))
                {
                    try
                    {
                        sub.Handler(evt);
                    }
                    catch (Exception ex)
                    {
                        OnHandlerError(evt.Topic, ex);
                    }
                }
            }
        }

        private void OnHandlerError(string failingTopic, Exception ex)
        {
            if (string.Equals(failingTopic, BusTopics.BusHandlerError, StringComparison.Ordinal))
            {
                // Предотвращение рекурсии при ошибке в обработчике bus.handler-error
                return;
            }
            try
            {
                Publish(BusTopics.BusHandlerError, _defaultSource,
                    "topic", failingTopic ?? string.Empty,
                    "err", ex != null ? ex.ToString() : "unknown error");
            }
            catch
            {
                // Подавление ошибок во время сообщения об ошибке
            }
        }

        private static bool Matches(string filter, string topic)
        {
            if (string.IsNullOrEmpty(filter) || filter == "*")
                return true;
            if (string.IsNullOrEmpty(topic))
                return false;
            if (filter.EndsWith("*", StringComparison.Ordinal))
            {
                string prefix = filter.Substring(0, filter.Length - 1);
                return topic.StartsWith(prefix, StringComparison.Ordinal);
            }
            if (filter.EndsWith(".", StringComparison.Ordinal))
            {
                return topic.StartsWith(filter, StringComparison.Ordinal);
            }
            return string.Equals(topic, filter, StringComparison.Ordinal);
        }

        private static IReadOnlyDictionary<string, string> ParseFields(string[] kv)
        {
            if (kv == null || kv.Length == 0)
                return BusEvent.EmptyFields;

            var dict = new Dictionary<string, string>(StringComparer.Ordinal);
            for (int i = 0; i < kv.Length; i += 2)
            {
                string key = kv[i];
                if (!string.IsNullOrEmpty(key))
                {
                    string val = (i + 1 < kv.Length) ? kv[i + 1] : string.Empty;
                    dict[key] = val ?? string.Empty;
                }
            }
            return dict;
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0)
                return;

            try
            {
                _cts?.Cancel();
            }
            catch { }

            try
            {
                _queue.CompleteAdding();
            }
            catch { }

            if (_dispatchThread != null && _dispatchThread.IsAlive)
            {
                try
                {
                    _dispatchThread.Join(500);
                }
                catch { }
            }

            _queue.Dispose();
            _cts?.Dispose();
        }
    }
}
