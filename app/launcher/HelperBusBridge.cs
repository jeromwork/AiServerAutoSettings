using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Threading.Tasks;

namespace RemoteAgents.Launcher
{
    // Шаг B3: мост шины «служба-помощник -> трей». Чистый код (без pipe и времени): кадр, белый список,
    // отправитель (служба) и приёмник (трей). Сам pipe `<PipeName>.events` открывают NetHelper и HelperClient.
    internal static class HelperBusFrame
    {
        internal const int MaxBytes = NetHelperProtocol.MaxMessageBytes;
        internal const int MaxFieldChars = 2000;

        // Кадр: {"seq":N,"topic":"...","source":"...","f":{"k":"v"}}. Больше 64 КБ — null (событие не уходит).
        internal static string Serialize(BusEvent e)
        {
            var fields = new Dictionary<string, object>(StringComparer.Ordinal);
            foreach (var pair in e.Fields)
                fields[pair.Key] = Clip(LogMask.Clean(pair.Value ?? ""));
            var frame = new Dictionary<string, object>(StringComparer.Ordinal) {
                { "seq", e.Seq.ToString(CultureInfo.InvariantCulture) }, { "topic", e.Topic }, { "source", e.Source ?? "" }, { "f", fields } };
            string line = Json.Encode(frame);
            return Encoding.UTF8.GetByteCount(line) > MaxBytes ? null : line;
        }
        static string Clip(string value) { return value.Length > MaxFieldChars ? value.Substring(0, MaxFieldChars) : value; }

        // Строгий разбор: тот же грамматический контроль, что у команд pipe (дубли ключей, мусор, глубина).
        internal static bool TryParse(string line, out string topic, out Dictionary<string, string> fields)
        {
            topic = null; fields = null;
            try {
                if (line == null || Encoding.UTF8.GetByteCount(line) > MaxBytes) return false;
                NetHelperProtocol.ValidateJson(line);
                var map = Json.Map(Json.Parse(line));
                if (!(Json.Get(map, "topic") is string) || !(Json.Get(map, "f") is Dictionary<string, object>)) return false;
                string t = Json.Str(map, "topic");
                if (t.Length == 0 || t.Length > 128) return false;
                var result = new Dictionary<string, string>(StringComparer.Ordinal);
                foreach (var pair in (Dictionary<string, object>)Json.Get(map, "f")) {
                    if (!(pair.Value is string)) return false;
                    result[pair.Key] = (string)pair.Value;
                }
                topic = t; fields = result; return true;
            } catch { topic = null; fields = null; return false; }
        }
    }

    internal static class HelperBusPolicy
    {
        // Только вперёд (служба -> трей): vpn.*, singbox.* ядра vpn, win.*, helper.*. singbox.line уровня INFO
        // не пересылается (шумно, в журнале службы он уже есть); остальное — да.
        internal static bool Allows(string topic, IReadOnlyDictionary<string, string> fields)
        {
            if (string.IsNullOrEmpty(topic)) return false;
            if (topic.StartsWith("vpn.", StringComparison.Ordinal) || topic.StartsWith("win.", StringComparison.Ordinal) || topic.StartsWith("helper.", StringComparison.Ordinal)) return true;
            if (topic.StartsWith("singbox.", StringComparison.Ordinal)) {
                string core; if (fields == null || !fields.TryGetValue("core", out core) || core != "vpn") return false;
                string level;
                if (topic == BusTopics.SingboxLine && fields.TryGetValue("level", out level) && level == "info") return false;
                return true;
            }
            return false;
        }
        internal static bool Allows(BusEvent e) { return e != null && Allows(e.Topic, e.Fields); }
    }

    // Служба: подписка на свою шину, при подключении клиента — сначала retained-состояния, затем живой поток.
    internal sealed class HelperBusSender : IDisposable
    {
        readonly EventBus bus;
        readonly object gate = new object();
        readonly IDisposable subscription;
        readonly Dictionary<string, long> sentSeq = new Dictionary<string, long>(StringComparer.Ordinal);
        Action<string> sink;
        long dropped;
        internal HelperBusSender(EventBus bus)
        {
            this.bus = bus;
            subscription = bus.Subscribe("*", OnEvent);
        }
        internal long Dropped { get { lock (gate) return dropped; } }
        // sink не блокирует (кладёт в ограниченную очередь нити записи). Возвращает отключение клиента.
        internal IDisposable Attach(Action<string> newSink)
        {
            lock (gate) {
                sink = newSink; sentSeq.Clear();
                foreach (string topic in BusTopics.RetainedTopics) {
                    BusEvent last;
                    if (!bus.TryGetLast(topic, out last) || !HelperBusPolicy.Allows(last)) continue;
                    Send(last);
                }
            }
            return new Detach(this, newSink);
        }
        void OnEvent(BusEvent e)
        {
            if (!HelperBusPolicy.Allows(e)) return;
            lock (gate) {
                if (sink == null) return;
                long seen; if (sentSeq.TryGetValue(e.Topic, out seen) && e.Seq <= seen) return; // уже ушло как retained
                Send(e);
            }
        }
        void Send(BusEvent e)
        {
            string line = HelperBusFrame.Serialize(e);
            if (line == null) { dropped++; return; }
            sentSeq[e.Topic] = e.Seq;
            try { sink(line); } catch { dropped++; }
        }
        sealed class Detach : IDisposable
        {
            readonly HelperBusSender owner; readonly Action<string> mine;
            internal Detach(HelperBusSender owner, Action<string> mine) { this.owner = owner; this.mine = mine; }
            public void Dispose() { lock (owner.gate) { if (owner.sink == mine) owner.sink = null; } }
        }
        public void Dispose() { subscription.Dispose(); lock (gate) sink = null; }
    }

    // Трей: кадр из pipe -> шина трея с source=helper. Повторная проверка белого списка (служба не доверена безусловно).
    internal sealed class HelperBusReceiver
    {
        readonly EventBus bus;
        internal HelperBusReceiver(EventBus bus) { this.bus = bus; }
        internal long Rejected;
        internal bool Ingest(string line)
        {
            string topic; Dictionary<string, string> fields;
            if (!HelperBusFrame.TryParse(line, out topic, out fields) || !HelperBusPolicy.Allows(topic, fields)) { Rejected++; return false; }
            return bus.Publish(topic, BusTopics.Sources.Helper, fields) >= 0;
        }
    }

    // Ожидание конечного vpn.state на шине вместо опроса status каждые 200 мс.
    internal sealed class VpnStateAwaiter : IDisposable
    {
        readonly TaskCompletionSource<BusEvent> done = new TaskCompletionSource<BusEvent>();
        readonly Func<string, bool> isFinal;
        readonly IDisposable subscription;
        // useRetained=false: прежнее retained-значение не считается ответом на новую команду.
        internal VpnStateAwaiter(EventBus bus, Func<string, bool> isFinal, bool useRetained = true)
        {
            this.isFinal = isFinal;
            subscription = bus.Subscribe(BusTopics.VpnState, Check);
            BusEvent last; if (useRetained && bus.TryGetLast(BusTopics.VpnState, out last)) Check(last);
        }
        void Check(BusEvent e) { if (isFinal(e.Get("state"))) done.TrySetResult(e); }
        internal Task<BusEvent> Task { get { return done.Task; } }
        public void Dispose() { subscription.Dispose(); }
    }
}
