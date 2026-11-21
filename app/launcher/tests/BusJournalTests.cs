using System;
using System.Collections.Generic;
using System.IO;

namespace RemoteAgents.Launcher
{
    public static class BusJournalTests
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
            Console.WriteLine("Starting BusJournalTests...");
            _assertions = 0;

            TestTopicWithMasks();
            TestSuppressionOfNoisyTopics();
            TestNoiseSummaryThreshold();
            TestCollapseConsecutiveIdentical();
            TestWriteErrorDoesNotCrashBus();
            TestDiskWriteWithRaLog();
            TestFirstEventWrittenImmediately();
            TestLineStartsWithIsoAndSession();
            TestLongValueAndLineCut();
            TestDisposeWritesNoiseRemainder();
            TestKeySanitized();
            TestTrayTickNoiseOnlySummary();
            TestHelperSinkGetsSeqAndIsReadable();
            TestCoreLineNotDuplicatedInHelperEvents();

            Console.WriteLine($"PASS: BusJournalTests ({_assertions} assertions passed)");
        }

        // 1. Топик попадает в журнал с масками (секрет в поле замаскирован)
        private static void TestTopicWithMasks()
        {
            var lines = new List<string>();
            using (var bus = new EventBus(manualDispatch: true))
            using (var journal = new BusJournal(bus, sink: lines.Add))
            {
                bus.Publish("vpn.state", "vpn-core",
                    "secret", "SuperSecretPass123",
                    "token", "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3",
                    "auth", "secret-auth-token",
                    "note", "Bearer my-secret-bearer-token",
                    "state", "connected");

                bus.DrainOnce();

                Assert(lines.Count == 1, $"Expected 1 line, got {lines.Count}");
                string line = lines[0];

                Assert(line.Contains(" vpn.state "), "Topic must be vpn.state");
                Assert(line.Contains("source=vpn-core"), "Source must be vpn-core");
                Assert(line.Contains("seq=1 "), "Seq must be 1");
                Assert(line.Contains("state=connected"), "State field must be connected");

                // Маскирование секретов
                Assert(!line.Contains("SuperSecretPass123"), "Secret password must not be in journal");
                Assert(line.Contains("secret=***"), "Secret key value must be masked with ***");
                Assert(line.Contains("auth=***"), "Auth key value must be masked with ***");
                Assert(!line.Contains("my-secret-bearer-token"), "Bearer token must not be in journal");
                Assert(line.Contains("note=\"Bearer ***\""), "Bearer token in non-secret key must be masked");
            }
        }

        // 2. tick.* и singbox.line (INFO) не пишутся, но считаются; не-INFO singbox.line пишутся
        private static void TestSuppressionOfNoisyTopics()
        {
            var lines = new List<string>();
            using (var bus = new EventBus(manualDispatch: true))
            using (var journal = new BusJournal(bus, sink: lines.Add))
            {
                // tick.* топики
                bus.Publish("tick.tray", "timer");
                bus.Publish("tick.vpn-scan", "timer");
                bus.Publish("tick.supervisor", "timer");

                // singbox.line уровня INFO
                bus.Publish("singbox.line", "vpn-core", "level", "info", "line", "connection established");
                bus.Publish("singbox.line", "transport-core", "line", "INFO [router] routing table updated");
                bus.Publish("singbox.line", "vpn-core"); // без полей — по умолчанию INFO

                // Не-INFO singbox.line (WARN, ERROR) не подавляются
                bus.Publish("singbox.line", "vpn-core", "level", "warn", "line", "WARN interface slow");
                bus.Publish("singbox.line", "vpn-core", "level", "error", "line", "ERROR socket closed");

                // Обычный топик
                bus.Publish("net.change", "windows", "id", "1");

                bus.DrainOnce();

                Assert(journal.SuppressedCount == 6, $"Suppressed count must be 6, was {journal.SuppressedCount}");
                Assert(journal.TickCount == 3, $"Tick count must be 3, was {journal.TickCount}");
                Assert(journal.SingboxCount == 3, $"Singbox count must be 3, was {journal.SingboxCount}");

                // Подавленные не записались, записались только 3 не-INFO события
                Assert(lines.Count == 3, $"Expected 3 lines, got {lines.Count}");
                Assert(lines[0].Contains(" singbox.line ") && lines[0].Contains("WARN"), "WARN singbox.line must be written");
                Assert(lines[1].Contains(" singbox.line ") && lines[1].Contains("ERROR"), "ERROR singbox.line must be written");
                Assert(lines[2].Contains(" net.change "), "net.change must be written");
            }
        }

        // 3. 2500 подавленных → ровно 2 строки bus.noise-summary (при 1000 и 2000)
        private static void TestNoiseSummaryThreshold()
        {
            var lines = new List<string>();
            using (var bus = new EventBus(manualDispatch: true))
            using (var journal = new BusJournal(bus, sink: lines.Add))
            {
                for (int i = 0; i < 2500; i++)
                {
                    if (i < 1500)
                    {
                        bus.Publish("tick.test", "timer");
                    }
                    else
                    {
                        bus.Publish("singbox.line", "vpn-core", "level", "info", "line", "test info line");
                    }
                }

                bus.DrainOnce();

                Assert(journal.SuppressedCount == 2500, $"Suppressed count must be 2500, was {journal.SuppressedCount}");
                Assert(lines.Count == 2, $"Expected exactly 2 lines of bus.noise-summary for 2500 suppressed, got {lines.Count}");

                string line1 = lines[0];
                Assert(line1.Contains(" bus.noise-summary "), "Line 1 topic must be bus.noise-summary");
                Assert(line1.Contains(" bus "), "Line 1 comp must be bus");
                Assert(line1.Contains("suppressed=1000"), "Line 1 must report 1000 suppressed");

                string line2 = lines[1];
                Assert(line2.Contains(" bus.noise-summary "), "Line 2 topic must be bus.noise-summary");
                Assert(line2.Contains(" bus "), "Line 2 comp must be bus");
                Assert(line2.Contains("suppressed=2000"), "Line 2 must report 2000 suppressed");
            }
        }

        // 4. 150 одинаковых подряд: первое сразу, repeat count=100 на 100-м повторе, остаток при Flush
        private static void TestCollapseConsecutiveIdentical()
        {
            var lines = new List<string>();
            using (var bus = new EventBus(manualDispatch: true))
            using (var journal = new BusJournal(bus, sink: lines.Add))
            {
                for (int i = 0; i < 150; i++)
                {
                    bus.Publish("vpn.state", "vpn-core", "state", "on", "reason", "auto");
                }

                bus.DrainOnce();
                Assert(lines.Count == 2, $"Before Flush expected event + repeat 100, got {lines.Count}");
                Assert(lines[0].Contains(" vpn.state ") && !lines[0].Contains("count="), "Line 1 is the first event");
                Assert(lines[1].Contains(" repeat ") && lines[1].Contains("count=100") && lines[1].Contains("topic=vpn.state"), "Line 2 repeat count=100: " + lines[1]);

                journal.Flush();
                Assert(lines.Count == 3, $"Expected 3 lines, got {lines.Count}");
                Assert(lines[2].Contains("count=49"), "Line 3 repeat count=49: " + lines[2]);
                journal.Flush();
                Assert(lines.Count == 3, "Second Flush must not duplicate");
            }
        }

        // 5. Ошибка записи журнала не роняет шину
        private static void TestWriteErrorDoesNotCrashBus()
        {
            using (var bus = new EventBus(manualDispatch: true))
            {
                int busErrors = 0;
                bus.Subscribe(BusTopics.BusHandlerError, _ => busErrors++);

                // Приёмник строк, выбрасывающий исключение
                using (var journal = new BusJournal(bus, sink: _ => throw new IOException("Simulated disk full")))
                {
                    bus.Publish("test.error", "tray", "k", "v");
                    bus.DrainOnce();
                    }

                // Шина осталась рабочей и доставляет последующие события
                bool aliveDelivered = false;
                bus.Subscribe("test.alive", _ => aliveDelivered = true);
                bus.Publish("test.alive", "tray");
                bus.DrainOnce();

                Assert(aliveDelivered, "EventBus must remain operational after journal write error");
                Assert(busErrors == 0, "Journal write error must not cause bus handler error");
            }
        }

        // 6. Запись на диск во временный каталог через RaLog
        private static void TestDiskWriteWithRaLog()
        {
            string tempDir = Path.Combine(Path.GetTempPath(), "bus-journal-disk-" + Guid.NewGuid().ToString("N").Substring(0, 8));
            try
            {
                using (var bus = new EventBus(manualDispatch: true))
                using (var journal = new BusJournal(bus, logsDir: tempDir))
                {
                    bus.Publish("disk.event", "tray", "action", "disk-val");
                    bus.DrainOnce();
    
                    string logFile = Path.Combine(tempDir, "bus.log");
                    Assert(File.Exists(logFile), "logs/bus.log must exist on disk");

                    string text = File.ReadAllText(logFile);
                    Assert(text.Contains(" disk.event "), "bus.log must contain topic disk.event");
                    Assert(text.Contains("action=disk-val"), "bus.log must contain action disk-val");
                }
            }
            finally
            {
                try
                {
                    Directory.Delete(tempDir, true);
                }
                catch
                {
                }
            }
        }

        // 7. Одно событие + DrainOnce без Flush = ровно одна строка
        private static void TestFirstEventWrittenImmediately()
        {
            var lines = new List<string>();
            using (var bus = new EventBus(manualDispatch: true))
            using (var journal = new BusJournal(bus, sink: lines.Add))
            {
                bus.Publish("vpn.state", "vpn-core", "state", "on");
                bus.DrainOnce();
                Assert(lines.Count == 1, $"Expected 1 line without Flush, got {lines.Count}");
                Assert(journal.PendingCount == 0, "No pending repeats");
            }
            Assert(lines.Count == 1, "Dispose must add nothing");
        }

        // 8. Строка начинается с ISO-времени из evt.Utc, есть s=<сессия>
        private static void TestLineStartsWithIsoAndSession()
        {
            var lines = new List<string>();
            using (var bus = new EventBus(manualDispatch: true))
            using (var journal = new BusJournal(bus, sink: lines.Add))
            {
                bus.Publish("vpn.state", "vpn-core", "state", "on");
                bus.DrainOnce();
                string l = lines[0];
                Assert(System.Text.RegularExpressions.Regex.IsMatch(l, @"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z "), "ISO prefix: " + l);
                Assert(l.Contains(" s=" + RaLog.Session + " "), "Session s= expected: " + l);
                Assert(l.Contains(" INFO  bus "), "Level and component: " + l);
            }
        }

        // 9. Длинное значение режется до 1024, строка — до MaxLine
        private static void TestLongValueAndLineCut()
        {
            var lines = new List<string>();
            using (var bus = new EventBus(manualDispatch: true))
            using (var journal = new BusJournal(bus, sink: lines.Add))
            {
                bus.Publish("big.one", "t", "v", new string('x', 5000));
                bus.DrainOnce();
                Assert(lines[0].Contains(new string('x', 1024) + "…[cut]"), "Value cut at 1024");
                Assert(!lines[0].Contains(new string('x', 1025)), "Value must not exceed 1024");

                var args = new List<string>();
                for (int i = 0; i < 20; i++) { args.Add("k" + i); args.Add(new string('y', 9) + " " + string.Concat(System.Linq.Enumerable.Repeat("word ", 190)) + i); }
                bus.Publish("big.two", "t", args.ToArray());
                bus.DrainOnce();
                Assert(lines.Count == 2, "Second line written");
                Assert(lines[1].Length <= RaLog.MaxLine + 6, "Line cut to MaxLine, was " + lines[1].Length);
                Assert(lines[1].EndsWith("…[cut]"), "Line cut marker");
            }
        }

        // 10. Dispose пишет остаток подавленных
        private static void TestDisposeWritesNoiseRemainder()
        {
            var lines = new List<string>();
            using (var bus = new EventBus(manualDispatch: true))
            {
                var journal = new BusJournal(bus, sink: lines.Add);
                for (int i = 0; i < 7; i++) bus.Publish("tick.x", "timer");
                bus.DrainOnce();
                Assert(lines.Count == 0, "No summary before threshold");
                journal.Dispose();
                Assert(lines.Count == 1 && lines[0].Contains(" bus.noise-summary ") && lines[0].Contains("suppressed=7") && lines[0].Contains("tick=7"), "Dispose summary: " + string.Join("|", lines));
                journal.Dispose();
                Assert(lines.Count == 1, "Second Dispose writes nothing");
            }

            var exact = new List<string>();
            using (var bus = new EventBus(manualDispatch: true))
            {
                var journal = new BusJournal(bus, sink: exact.Add);
                for (int i = 0; i < 1000; i++) bus.Publish("tick.x", "timer");
                bus.DrainOnce();
                journal.Dispose();
                Assert(exact.Count == 1, "No duplicate summary when remainder is zero, got " + exact.Count);
            }
        }

        // 11. Ключи полей очищаются как в RaLog.Format
        private static void TestKeySanitized()
        {
            var lines = new List<string>();
            using (var bus = new EventBus(manualDispatch: true))
            using (var journal = new BusJournal(bus, sink: lines.Add))
            {
                bus.Publish("key.test", "t", "a b=c\"d", "1", "ok-name.1", "2");
                bus.DrainOnce();
                Assert(lines[0].Contains(" a_b_c_d=1"), "Key sanitized: " + lines[0]);
                Assert(lines[0].Contains(" ok-name.1=2"), "Good key kept: " + lines[0]);
            }
        }

        // 12. tick.tray не превращается в строки: 2500 тиков дают только 2 сводки (каждые 1000), событие рядом пишется сразу
        private static void TestTrayTickNoiseOnlySummary()
        {
            var lines = new List<string>();
            using (var bus = new EventBus(manualDispatch: true))
            using (var journal = new BusJournal(bus, sink: lines.Add))
            {
                for (int i = 0; i < 2500; i++) bus.Publish(BusTopics.TickTray, "tray");
                bus.Publish("vpn.state", "vpn-core", "state", "on");
                bus.DrainOnce();
                Assert(lines.Count == 3, "2 summaries + 1 event expected, got " + lines.Count);
                Assert(lines[0].Contains(BusTopics.BusNoiseSummary) && lines[1].Contains(BusTopics.BusNoiseSummary), "summaries first");
                Assert(!lines.Exists(l => l.Contains(" " + BusTopics.TickTray)), "no tick.tray line");
            }
        }

        // 13. Журнал шины службы: строка получает seq журнала помощника, читается через Read, bus-seq остаётся в строке
        private static void TestHelperSinkGetsSeqAndIsReadable()
        {
            string dir = Path.Combine(Path.GetTempPath(), "bus-journal-helper-" + Guid.NewGuid().ToString("N").Substring(0, 8));
            try
            {
                var events = new HelperEventLog(dir);
                // Номер помощника уже > 1 до события шины (у шины свой seq=1).
                events.Write(LogLevel.Info, "helper", "a");
                events.Write(LogLevel.Info, "helper", "b");
                events.Write(LogLevel.Info, "helper", "c");
                using (var bus = new EventBus(manualDispatch: true))
                using (var journal = new BusJournal(bus, sink: l => events.WriteLine(l)))
                {
                    bus.Publish("vpn.state", "vpn-core", "state", "on");
                    bus.DrainOnce();
                    events.Write(LogLevel.Info, "helper", "d");
                }
                var page = events.Read(0, 40000);
                Assert(page.Lines.Count == 5, "five lines readable, got " + page.Lines.Count);
                string busLine = null;
                foreach (var l in page.Lines) if (l.Contains(" vpn.state ")) busLine = l;
                Assert(busLine != null, "bus line present");
                Assert(HelperEventLog.SeqOf(busLine) == 4, "helper seq (4), not bus seq (1): " + busLine);
                Assert(busLine.Contains(" bus ") && busLine.Contains("source=vpn-core"), "bus component kept: " + busLine);
                // Курсор посередине: без потерь и повторов.
                var rest = events.Read(3, 40000);
                Assert(rest.Lines.Count == 2 && HelperEventLog.SeqOf(rest.Lines[0]) == 4 && HelperEventLog.SeqOf(rest.Lines[1]) == 5, "cursor 3 gives seq 4,5");
                Assert(rest.Lost == 0 && rest.Next == 5, "no loss, next=5");
                var none = events.Read(rest.Next, 40000);
                Assert(none.Lines.Count == 0, "no repeats after cursor");
            }
            finally
            {
                try { if (Directory.Exists(dir)) Directory.Delete(dir, true); } catch { }
            }
        }

        // Строка ERROR ядра, прошедшая через Drain, попадает в helper-events ровно один раз (core.line), не дублируясь шиной.
        private static void TestCoreLineNotDuplicatedInHelperEvents()
        {
            string dir = Path.Combine(Path.GetTempPath(), "bus-journal-core-" + Guid.NewGuid().ToString("N").Substring(0, 8));
            try
            {
                var events = new HelperEventLog(dir);
                using (var bus = new EventBus(manualDispatch: true))
                using (var journal = new BusJournal(bus, sink: l => events.WriteLine(l), excludeTopics: new[] { BusTopics.SingboxLine }))
                {
                    Action<string, string[]> publish = (t, kv) => bus.Publish(t, BusTopics.Sources.VpnCore, kv);
                    var bytes = System.Text.Encoding.UTF8.GetBytes("+0300 ERROR outbound/x: dial failed\n");
                    var reader = new CoreOutputReader(new MemoryStream(bytes), null, "vpn", publish);
                    reader.Start();
                    Assert(reader.Join(5000), "reader ends at end of stream");
                    Assert(reader.Drain(events) == 1, "one line drained");
                    bus.DrainOnce();
                }
                string all = string.Join("\n", events.Read(0, 40000).Lines);
                int count = 0, idx = 0;
                while ((idx = all.IndexOf("dial failed", idx, StringComparison.Ordinal)) >= 0) { count++; idx++; }
                Assert(count == 1, "ERROR line exactly once in helper-events, got " + count + ": " + all);
                Assert(all.Contains("core.line"), "it is the core.line record");
            }
            finally
            {
                try { if (Directory.Exists(dir)) Directory.Delete(dir, true); } catch { }
            }
        }
    }
}
