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
            TestRetainedWhitelistAndTryGetLast();
            TestOverflowHysteresisAndFinalDropped();
            TestFireTick();
            TestConcurrentPublishDrainMonotonicSeq();
            TestPublishFireTickAfterDispose();
            TestUnsubscribeDuringDispatch();
            TestHandlerErrorThrowingDoesNotRecurse();

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

        // 3. Исключение в обработчике не мешает следующему (bus.handler-error) и обрезка err до 300 симв.
        private static void TestHandlerExceptionIsolation()
        {
            using (var bus = new EventBus(manualDispatch: true))
            {
                var errors = new List<BusEvent>();
                bool firstCalled = false;
                bool secondCalled = false;

                bus.Subscribe(BusTopics.BusHandlerError, evt => errors.Add(evt));

                string longMessage = new string('A', 500);
                bus.Subscribe("fault.topic", evt =>
                {
                    firstCalled = true;
                    throw new InvalidOperationException(longMessage);
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

                string err = errors[0]["err"];
                Assert(err.Length <= 300, $"err length must be <= 300, was {err.Length}");
                Assert(err.StartsWith("InvalidOperationException: "), "err must start with exception type");
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

        // 5. Retained-значение TryGetLast только для белого списка в BusTopics
        private static void TestRetainedWhitelistAndTryGetLast()
        {
            using (var bus = new EventBus(manualDispatch: true))
            {
                Assert(!bus.TryGetLast("vpn.state", out _), "TryGetLast should return false for nonexistent topic");

                // Белый список: vpn.state, net.quality, transport.status, helper.version
                bus.Publish("vpn.state", "vpn-core", "state", "on", "seq", "1");
                Assert(bus.TryGetLast("vpn.state", out var lastState), "TryGetLast should find retained vpn.state");
                Assert(lastState["state"] == "on", "lastState['state'] should be 'on'");

                bus.Publish("net.quality", "transport", "score", "95");
                Assert(bus.TryGetLast("net.quality", out var netLast), "TryGetLast should find retained net.quality");
                Assert(netLast["score"] == "95", "netLast['score'] should be '95'");

                bus.Publish("helper.version", "helper", "ver", "11");
                Assert(bus.TryGetLast("helper.version", out var helperLast), "TryGetLast should find retained helper.version");
                Assert(helperLast["ver"] == "11", "helperLast['ver'] should be '11'");

                // Не в белом списке: vpn.step, custom.topic не должны сохраняться в _retained
                bus.Publish("vpn.step", "vpn-core", "step", "init");
                Assert(!bus.TryGetLast("vpn.step", out _), "vpn.step is not retained, TryGetLast must return false");

                bus.Publish("custom.topic", "tray", "data", "test");
                Assert(!bus.TryGetLast("custom.topic", out _), "custom.topic is not retained, TryGetLast must return false");
            }
        }

        // 6. Переполнение с гистерезисом (Count <= limit/2) и итоговым dropped в bus.overflow
        private static void TestOverflowHysteresisAndFinalDropped()
        {
            using (var bus = new EventBus(manualDispatch: true, queueLimit: 10))
            {
                var overflows = new List<BusEvent>();
                bus.Subscribe(BusTopics.BusOverflow, evt => overflows.Add(evt));

                // Заполняем очередь до предела (10 событий)
                for (int i = 0; i < 10; i++)
                {
                    long s = bus.Publish("test.fill", "tray", "i", i.ToString());
                    Assert(s > 0, $"Event {i} should be accepted");
                }

                // 11-е событие отбрасывается
                long drop1 = bus.Publish("test.fill", "tray", "i", "10");
                Assert(drop1 == -1, "11th event must drop");

                // Откачиваем ровно 1 событие (в очереди остаётся 9 > 10/2). Порог гистерезиса не достигнут.
                int d1 = bus.DrainOnce(1);
                Assert(d1 == 1, "Drained 1 event");

                // Добавляем событие (очередь снова 10) и следующее отбрасывается
                long s1 = bus.Publish("test.fill", "tray", "i", "extra");
                Assert(s1 > 0, "Extra event fits");
                long drop2 = bus.Publish("test.fill", "tray", "i", "extra_drop");
                Assert(drop2 == -1, "Must drop");

                // Так как порог гистерезиса не был пройден, нового bus.overflow быть не должно
                Assert(overflows.Count == 0, "bus.overflow not emitted before reaching recovery threshold");

                // Откачиваем всю очередь. Порог <= limit/2 (<=5) будет пройден
                bus.DrainOnce();

                // Проверяем: ровно один bus.overflow на весь эпизод, и dropped равен суммарно 2
                Assert(overflows.Count == 1, $"Expected exactly 1 bus.overflow for first episode, got {overflows.Count}");
                Assert(overflows[0]["dropped"] == "2", $"Final dropped must be 2, was {overflows[0]["dropped"]}");

                // Очередь пуста. Новое заполнение и переполнение должно дать ровно один НОВЫЙ bus.overflow
                for (int i = 0; i < 10; i++)
                {
                    bus.Publish("test.fill2", "tray", "i", i.ToString());
                }
                long drop3 = bus.Publish("test.fill2", "tray", "i", "drop3");
                Assert(drop3 == -1, "Must drop in second episode");

                bus.DrainOnce();

                Assert(overflows.Count == 2, $"Expected exactly 2 bus.overflow events total, got {overflows.Count}");
                Assert(overflows[1]["dropped"] == "1", $"Second overflow dropped must be 1, was {overflows[1]["dropped"]}");
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

        // 8. Два потока публикуют по 10 000 — Seq монотонен в порядке FIFO, порядок i внутри потока сохранён
        private static void TestConcurrentPublishDrainMonotonicSeq()
        {
            using (var bus = new EventBus(manualDispatch: true, queueLimit: 25000))
            {
                long lastSeq = 0;
                int lastI1 = -1;
                int lastI2 = -1;
                int count = 0;

                bus.Subscribe("concurrent.item", evt =>
                {
                    count++;
                    Assert(evt.Seq > lastSeq, $"Seq must be strictly monotonic: current {evt.Seq} <= last {lastSeq}");
                    lastSeq = evt.Seq;

                    string threadId = evt["t"];
                    int i = int.Parse(evt["i"]);
                    if (threadId == "1")
                    {
                        Assert(i == lastI1 + 1, $"Thread 1 order mismatch: expected {lastI1 + 1}, got {i}");
                        lastI1 = i;
                    }
                    else if (threadId == "2")
                    {
                        Assert(i == lastI2 + 1, $"Thread 2 order mismatch: expected {lastI2 + 1}, got {i}");
                        lastI2 = i;
                    }
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
                Assert(lastI1 == 9999, "Thread 1 completed all 10000 items in order");
                Assert(lastI2 == 9999, "Thread 2 completed all 10000 items in order");
            }
        }

        // 9. Publish / FireTick после bus.Dispose() не бросает исключений и возвращает -1
        private static void TestPublishFireTickAfterDispose()
        {
            var bus = new EventBus(manualDispatch: true);
            var tick = bus.Every("tray", 5000);

            bus.Dispose();

            long res = bus.Publish("any.topic", "tray", "k", "v");
            Assert(res == -1, "Publish after Dispose must return -1");

            // FireTick не должен бросать
            bus.FireTick("tray");
            tick.Fire();
            tick.Dispose();
            Assert(true, "FireTick after Dispose did not throw");
        }

        // 10. Отписка B обработчиком A во время диспетчеризации (текущее событие B ещё получает, следующее нет)
        private static void TestUnsubscribeDuringDispatch()
        {
            using (var bus = new EventBus(manualDispatch: true))
            {
                int bCallCount = 0;
                IDisposable subB = null;

                bus.Subscribe("test.unsub_during", evt =>
                {
                    // Обработчик A отписывает обработчик B во время первого события
                    subB?.Dispose();
                });

                subB = bus.Subscribe("test.unsub_during", evt =>
                {
                    bCallCount++;
                });

                // Первое событие: B ещё должен получить в текущей волне диспетчеризации
                bus.Publish("test.unsub_during", "tray");
                bus.DrainOnce();
                Assert(bCallCount == 1, "Handler B must still receive the current event during which it was unsubscribed");

                // Второе событие: B уже отписан и не должен получить
                bus.Publish("test.unsub_during", "tray");
                bus.DrainOnce();
                Assert(bCallCount == 1, "Handler B must not receive the subsequent event after unsubscription");
            }
        }

        // 11. Обработчик bus.handler-error бросает — шина жива, рекурсии нет
        private static void TestHandlerErrorThrowingDoesNotRecurse()
        {
            using (var bus = new EventBus(manualDispatch: true))
            {
                bool normalHandlerCalled = false;

                // Подписчик на bus.handler-error сам выбрасывает исключение
                bus.Subscribe(BusTopics.BusHandlerError, evt =>
                {
                    throw new InvalidOperationException("Handler error listener threw exception");
                });

                // Подписчик на целевой топик выбрасывает исключение
                bus.Subscribe("fault.recurse", evt =>
                {
                    throw new InvalidOperationException("Original error");
                });

                bus.Subscribe("normal.topic", evt =>
                {
                    normalHandlerCalled = true;
                });

                // Публикуем ошибочный топик, затем нормальный
                bus.Publish("fault.recurse", "tray");
                bus.Publish("normal.topic", "tray");

                bus.DrainOnce();

                Assert(normalHandlerCalled, "Normal handler must be called, bus remains alive without recursion crash");
            }
        }
    }
}
