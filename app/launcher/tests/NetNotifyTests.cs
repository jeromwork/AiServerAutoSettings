using System;
using System.Collections.Generic;

namespace RemoteAgents.Launcher
{
    /// <summary>Микро-тесты W1: без P/Invoke, без времени; колбэки подаются вручную.</summary>
    public static class NetNotifyTests
    {
        private static int _assertions;

        private static void Assert(bool condition, string message)
        {
            if (!condition) throw new Exception("Assertion failed: " + message);
            _assertions++;
        }

        private sealed class FakeSource : INetNotifySource
        {
            public Action<int, int, int> Route, Iface, Addr;
            public Action<bool> Avail;
            public Action<string, int> Err;
            public Exception ThrowOnStart;
            public int CancelCount;
            public void Start(Action<int, int, int> r, Action<int, int, int> i, Action<int, int, int> a, Action<bool> v, Action<string, int> err)
            {
                Err = err;
                if (ThrowOnStart != null) throw ThrowOnStart;
                Route = r; Iface = i; Addr = a; Avail = v;
            }
            public void Dispose() { CancelCount++; }
        }

        public static int Main(string[] args)
        {
            Run();
            return 0;
        }

        public static void Run()
        {
            Console.WriteLine("Starting NetNotifyTests...");
            _assertions = 0;
            TestFields();
            TestCoalesce();
            TestAvailabilityLast();
            TestDroppedNotSticky();
            TestErrors();
            TestDispose();
            Console.WriteLine("PASS: NetNotifyTests (" + _assertions + " assertions passed)");
        }

        private static void TestFields()
        {
            using (var bus = new EventBus(manualDispatch: true))
            {
                var src = new FakeSource();
                var got = new List<BusEvent>();
                bus.Subscribe("win.", e => got.Add(e));
                var n = new NetNotify(bus, src);
                n.Start();
                src.Route(2, 7, 1);
                src.Iface(23, 9, 2);
                src.Addr(2, 11, 0);
                src.Avail(false);
                bus.DrainOnce();
                Assert(got.Count == 4, "4 events");
                Assert(got[0].Topic == BusTopics.WinRouteChanged && got[0].Get("family") == "ipv4" && got[0].Get("ifIndex") == "7" && got[0].Get("type") == "add", "route fields");
                Assert(got[1].Topic == BusTopics.WinIfaceChanged && got[1].Get("family") == "ipv6" && got[1].Get("type") == "delete", "iface fields");
                Assert(got[2].Topic == BusTopics.WinAddrChanged && got[2].Get("ifIndex") == "11" && got[2].Get("type") == "parameter", "addr fields");
                Assert(got[3].Topic == BusTopics.WinIfaceChanged && got[3].Get("available") == "false" && got[3].Get("type") == "availability", "availability");
                Assert(got[0].Source == BusTopics.Sources.Windows, "source");
                n.Dispose();
            }
        }

        private static void TestCoalesce()
        {
            using (var bus = new EventBus(manualDispatch: true))
            {
                var src = new FakeSource();
                var got = new List<BusEvent>();
                bus.Subscribe("win.", e => got.Add(e));
                var n = new NetNotify(bus, src);
                n.Start();
                for (int i = 0; i < 50; i++) src.Route(2, 7, 1);
                src.Route(2, 8, 1); // другой адаптер — не схлопывается
                Assert(bus.QueueCount == 2, "50 same -> 1 (+1 different)");
                bus.DrainOnce();
                Assert(got.Count == 2 && n.PendingCount == 0, "delivered, pending cleared");
                src.Route(2, 7, 1);
                bus.DrainOnce();
                Assert(got.Count == 3, "after delivery a new event is published");
                n.Dispose();
            }
        }

        private static void TestAvailabilityLast()
        {
            using (var bus = new EventBus(manualDispatch: true))
            {
                var src = new FakeSource();
                var got = new List<BusEvent>();
                bus.Subscribe("win.", e => got.Add(e));
                var n = new NetNotify(bus, src);
                n.Start();
                src.Avail(false);
                src.Avail(true);
                bus.DrainOnce();
                Assert(got.Count == 2, "both availability values delivered");
                Assert(got[got.Count - 1].Get("available") == "true", "last value is true");
                n.Dispose();
            }
        }

        private static void TestDroppedNotSticky()
        {
            using (var bus = new EventBus(manualDispatch: true, queueLimit: 2))
            {
                var src = new FakeSource();
                var got = new List<BusEvent>();
                bus.Subscribe("win.", e => got.Add(e));
                var n = new NetNotify(bus, src);
                n.Start();
                src.Route(2, 1, 1);
                src.Route(2, 2, 1);
                src.Route(2, 3, 1); // очередь полна: отброшено
                Assert(n.PendingCount == 2, "dropped event does not stay pending");
                bus.DrainOnce();
                src.Route(2, 3, 1);
                bus.DrainOnce();
                int c3 = 0;
                foreach (var e in got) if (e.Get("ifIndex") == "3") c3++;
                Assert(c3 == 1, "same event published again after queue drained");
                n.Dispose();
            }
        }

        private static void TestErrors()
        {
            using (var bus = new EventBus(manualDispatch: true))
            {
                var src = new FakeSource();
                var errs = new List<BusEvent>();
                bus.Subscribe(BusTopics.WinNotifyError, e => errs.Add(e));
                var n = new NetNotify(bus, src);
                n.Start();
                src.Err("NotifyRouteChange2", 5);
                bus.DrainOnce();
                Assert(errs.Count == 1 && errs[0].Get("api") == "NotifyRouteChange2" && errs[0].Get("rc") == "5", "error event fields");
                n.Dispose();
            }
            using (var bus = new EventBus(manualDispatch: true))
            {
                var src = new FakeSource { ThrowOnStart = new DllNotFoundException("x") };
                var errs = new List<BusEvent>();
                bus.Subscribe(BusTopics.WinNotifyError, e => errs.Add(e));
                var n = new NetNotify(bus, src);
                n.Start(); // не бросает
                bus.DrainOnce();
                Assert(errs.Count == 1 && errs[0].Get("rc") == "-1", "start exception -> error event");
                Assert(src.CancelCount == 1, "failed source disposed");
                n.Dispose();
            }
        }

        private static void TestDispose()
        {
            using (var bus = new EventBus(manualDispatch: true))
            {
                var src = new FakeSource();
                var n = new NetNotify(bus, src);
                n.Start();
                n.Dispose();
                n.Dispose();
                Assert(src.CancelCount == 1, "source disposed (Cancel) exactly once");
                src.Route(2, 1, 1);
                Assert(bus.QueueCount == 0, "no publish after dispose");
            }
        }
    }
}
