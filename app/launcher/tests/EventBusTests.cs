using System;
using System.Collections.Generic;
using System.Threading;

namespace RemoteAgents.Launcher
{
    public static class EventBusTests
    {
        private static int _assertions;

        private static void Assert(bool condition, string message)
        {
            if (!condition)
            {
                throw new Exception("Assertion failed: " + message);
            }
            _assertions++;
        }

        public static int Main(string[] args)
        {
            Run();
            return 0;
        }

        public static void Run()
        {
            Console.WriteLine("Starting EventBusTests...");
            _assertions = 0;

            TestFifoOrder();
            TestPrefixSubscription();
            TestHandlerExceptionIsolation();
            TestUnsubscribe();
            TestRetainedTryGetLast();
            TestOverflowSingleEventPerEpisode();
            TestFireTick();
            TestConcurrentPublishDrain();

            Console.WriteLine($"PASS: EventBusTests ({_assertions} assertions passed)");
        }

        // 1. Порядок FIFO
        private static void TestFifoOrder()
        {
            using (var bus = new EventBus(manualDispatch: true))
            {
                var received = new List<int>();
                bus.Subscribe("test.fifo", evt =>
                {
                    if (int.TryParse(evt["val"], out var val))
                    {
                        received.Add(val);
                    }
                });

                for (int i = 0; i < 100; i++)
                {
                    bus.Publish("test.fifo", "tray", "val", i.ToString());
                }

                int drained = bus.DrainOnce();
                Assert(drained == 100, "DrainOnce count should match published");
                Assert(received.Count == 100, "Received count should be 100");

                for (int i = 0; i < 100; i++)
                {
                    Assert(received[i] == i, $"FIFO order mismatch at index {i}: expected {i}, got {received[i]}");
                }
            }
        }

        // 2. Префиксная подписка
        private static void TestPrefixSubscription()
        {
            using (var bus = new EventBus(manualDispatch: true))
            {
                var vpnEvents = new List<string>();
                var stateEvents = new List<string>();
                var allEvents = new List<string>();

                using (bus.Subscribe("vpn.", evt => vpnEvents.Add(evt.Topic)))
                using (bus.Subscribe("vpn.state", evt => stateEvents.Add(evt.Topic)))
                using (bus.Subscribe("*", evt => allEvents.Add(evt.Topic)))
                {
                    bus.Publish("vpn.state", "vpn-core", "state", "on");
                    bus.Publish("vpn.step", "vpn-core", "step", "tun");
                    bus.Publish("net.change", "windows", "id", "1");

                    bus.DrainOnce();

                    Assert(vpnEvents.Count == 2, "vpn. should match vpn.state and vpn.step");
                    Assert(vpnEvents.Contains("vpn.state"), "vpn. should contain vpn.state");
                    Assert(vpnEvents.Contains("vpn.step"), "vpn. should contain vpn.step");

                    Assert(stateEvents.Count == 1, "vpn.state should match only vpn.state");
                    Assert(stateEvents[0] == "vpn.state", "stateEvents[0] should be vpn.state");

                    Assert(allEvents.Count == 3, "* should match all 3 events");
                }
            }
        }

        // 3. Исключение в обработчике не мешает следующему (bus.handler-error)
        private static void TestHandlerExceptionIsolation()
        {
            using (var bus = new EventBus(manualDispatch: true))
            {
                var errors = new List<BusEvent>();
                bool firstCalled = false;
                bool secondCalled = false;

                bus.Subscribe(BusTopics.BusHandlerError, evt => errors.Add(evt));

                bus.Subscribe("fault.topic", evt =>
                {
                    firstCalled = true;
                    throw new InvalidOperationException("Test handler exception");
                });

                bus.Subscribe("fault.topic", evt =>
                {
                    secondCalled = true;
                });

                bus.Publish("fault.topic", "tray", "k", "v");
                bus.DrainOnce();

                Assert(firstCalled, "First handler must have been called");
                Assert(secondCalled, "Second handler must have been called despite first handler throwing");
                Assert(errors.Count == 1, "Exactly one bus.handler-error must be published");
                Assert(errors[0].Topic == BusTopics.BusHandlerError, "Topic must be bus.handler-error");
                Assert(errors[0]["topic"] == "fault.topic", "Error event must specify failing topic");
                Assert(errors[0]["err"].Contains("Test handler exception"), "Error event must contain exception message");
            }
        }

        // 4. Отписка
        private static void TestUnsubscribe()
        {
            using (var bus = new EventBus(manualDispatch: true))
            {
                int count = 0;
                var sub = bus.Subscribe("test.unsub", evt => count++);

                bus.Publish("test.unsub", "tray");
                bus.DrainOnce();
                Assert(count == 1, "Handler should be called once before unregistering");

                sub.Dispose();

                bus.Publish("test.unsub", "tray");
                bus.DrainOnce();
                Assert(count == 1, "Handler should not be called after Dispose()");
            }
        }

        // 5. Retained-значение TryGetLast
        private static void TestRetainedTryGetLast()
        {
            using (var bus = new EventBus(manualDispatch: true))
            {
                Assert(!bus.TryGetLast("vpn.state", out _), "TryGetLast should return false for nonexistent topic");

                bus.Publish("vpn.state", "vpn-core", "state", "on", "seq", "1");
                Assert(bus.TryGetLast("vpn.state", out var last1), "TryGetLast should find retained vpn.state");
                Assert(last1["state"] == "on", "last1['state'] should be 'on'");
                Assert(last1["seq"] == "1", "last1['seq'] should be '1'");

                bus.Publish("vpn.state", "vpn-core", "state", "off", "seq", "2");
                Assert(bus.TryGetLast("vpn.state", out var last2), "TryGetLast should find updated retained vpn.state");
                Assert(last2["state"] == "off", "last2['state'] should be 'off'");
                Assert(last2["seq"] == "2", "last2['seq'] should be '2'");

                bus.Publish("net.quality", "transport", "score", "95");
                Assert(bus.TryGetLast("net.quality", out var netLast), "TryGetLast should find net.quality");
                Assert(netLast["score"] == "95", "netLast['score'] should be '95'");
                Assert(bus.TryGetLast("vpn.state", out var vpnLast) && vpnLast["state"] == "off", "vpn.state still retained");
            }
        }

        // 6. Переполнение даёт ровно одно bus.overflow на эпизод
        private static void TestOverflowSingleEventPerEpisode()
        {
            // Очередь с лимитом 5: первые 5 событий принимаются, 6-е, 7-е, 8-е отбрасываются
            using (var bus = new EventBus(manualDispatch: true, queueLimit: 5))
            {
                var overflows = new List<BusEvent>();
                var regulars = new List<BusEvent>();

                bus.Subscribe(BusTopics.BusOverflow, evt => overflows.Add(evt));
                bus.Subscribe("test.fill", evt => regulars.Add(evt));

                for (int i = 0; i < 5; i++)
                {
                    long seq = bus.Publish("test.fill", "tray", "i", i.ToString());
                    Assert(seq > 0, $"Event {i} should be accepted");
                }

                // Очередь заполнена. Следующие публикации приводят к отбрасыванию и ровно одному bus.overflow
                long drop1 = bus.Publish("test.fill", "tray", "i", "5");
                long drop2 = bus.Publish("test.fill", "tray", "i", "6");
                long drop3 = bus.Publish("test.fill", "tray", "i", "7");

                Assert(drop1 == -1, "Drop 1 should return -1");
                Assert(drop2 == -1, "Drop 2 should return -1");
                Assert(drop3 == -1, "Drop 3 should return -1");
                Assert(bus.DroppedCount == 3, $"DroppedCount should be 3, was {bus.DroppedCount}");

                bus.DrainOnce();

                Assert(regulars.Count == 5, $"Regular events delivered should be 5, was {regulars.Count}");
                Assert(overflows.Count == 1, $"Overflow events should be exactly 1 per episode, was {overflows.Count}");
                Assert(overflows[0].Topic == BusTopics.BusOverflow, "Overflow event topic must be bus.overflow");

                // После откачки очередь свободна. Новые события принимаются
                long nextSeq = bus.Publish("test.fill", "tray", "i", "8");
                Assert(nextSeq > 0, "Event after drain should be accepted");
                bus.DrainOnce();

                Assert(regulars.Count == 6, "Regular count should now be 6");
                Assert(overflows.Count == 1, "No new overflow event should be emitted without new overflow");
            }
        }

        // 7. FireTick даёт tick.x
        private static void TestFireTick()
        {
            using (var bus = new EventBus(manualDispatch: true))
            {
                var ticks = new List<BusEvent>();
                bus.Subscribe("tick.update", evt => ticks.Add(evt));

                using (var tick = bus.Every("update", 60000))
                {
                    bus.FireTick("update");
                    tick.Fire();

                    bus.DrainOnce();

                    Assert(ticks.Count == 2, $"Expected 2 ticks, got {ticks.Count}");
                    Assert(ticks[0].Topic == "tick.update", "Topic must be tick.update");
                    Assert(ticks[0].Source == BusTopics.Sources.Timer, "Source must be timer");
                    Assert(ticks[1].Topic == "tick.update", "Topic must be tick.update");
                    Assert(ticks[1].Source == BusTopics.Sources.Timer, "Source must be timer");
                }
            }
        }

        // 8. Два потока публикуют по 10 000 — все доставлены через DrainOnce (детерминированно)
        private static void TestConcurrentPublishDrain()
        {
            using (var bus = new EventBus(manualDispatch: true, queueLimit: 25000))
            {
                int count = 0;
                bus.Subscribe("concurrent.item", evt =>
                {
                    Interlocked.Increment(ref count);
                });

                var t1 = new Thread(() =>
                {
                    for (int i = 0; i < 10000; i++)
                    {
                        bus.Publish("concurrent.item", "tray", "t", "1", "i", i.ToString());
                    }
                });

                var t2 = new Thread(() =>
                {
                    for (int i = 0; i < 10000; i++)
                    {
                        bus.Publish("concurrent.item", "tray", "t", "2", "i", i.ToString());
                    }
                });

                t1.Start();
                t2.Start();

                t1.Join();
                t2.Join();

                int drained = bus.DrainOnce();

                Assert(bus.DroppedCount == 0, $"Dropped count should be 0, was {bus.DroppedCount}");
                Assert(drained == 20000, $"Drained count should be 20000, was {drained}");
                Assert(count == 20000, $"Subscribed handler count should be 20000, was {count}");
            }
        }
    }
}
