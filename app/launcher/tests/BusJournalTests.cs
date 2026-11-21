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
                journal.Flush();

                Assert(lines.Count == 1, $"Expected 1 line, got {lines.Count}");
                string line = lines[0];

                Assert(line.Contains("\"topic\":\"vpn.state\""), "Topic must be vpn.state");
                Assert(line.Contains("\"source\":\"vpn-core\""), "Source must be vpn-core");
                Assert(line.Contains("\"seq\":1"), "Seq must be 1");
                Assert(line.Contains("\"state\":\"connected\""), "State field must be connected");

                // Маскирование секретов
                Assert(!line.Contains("SuperSecretPass123"), "Secret password must not be in journal");
                Assert(line.Contains("\"secret\":\"***\""), "Secret key value must be masked with ***");
                Assert(line.Contains("\"auth\":\"***\""), "Auth key value must be masked with ***");
                Assert(!line.Contains("my-secret-bearer-token"), "Bearer token must not be in journal");
                Assert(line.Contains("\"note\":\"Bearer ***\""), "Bearer token in non-secret key must be masked");
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
                journal.Flush();

                Assert(journal.SuppressedCount == 6, $"Suppressed count must be 6, was {journal.SuppressedCount}");
                Assert(journal.TickCount == 3, $"Tick count must be 3, was {journal.TickCount}");
                Assert(journal.SingboxCount == 3, $"Singbox count must be 3, was {journal.SingboxCount}");

                // Подавленные не записались, записались только 3 не-INFO события
                Assert(lines.Count == 3, $"Expected 3 lines, got {lines.Count}");
                Assert(lines[0].Contains("\"singbox.line\"") && lines[0].Contains("WARN"), "WARN singbox.line must be written");
                Assert(lines[1].Contains("\"singbox.line\"") && lines[1].Contains("ERROR"), "ERROR singbox.line must be written");
                Assert(lines[2].Contains("\"net.change\""), "net.change must be written");
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
                journal.Flush();

                Assert(journal.SuppressedCount == 2500, $"Suppressed count must be 2500, was {journal.SuppressedCount}");
                Assert(lines.Count == 2, $"Expected exactly 2 lines of bus.noise-summary for 2500 suppressed, got {lines.Count}");

                string line1 = lines[0];
                Assert(line1.Contains("\"topic\":\"bus.noise-summary\""), "Line 1 topic must be bus.noise-summary");
                Assert(line1.Contains("\"source\":\"bus\""), "Line 1 source must be bus");
                Assert(line1.Contains("\"suppressed\":1000") || line1.Contains("\"count\":1000"), "Line 1 must report 1000 suppressed");

                string line2 = lines[1];
                Assert(line2.Contains("\"topic\":\"bus.noise-summary\""), "Line 2 topic must be bus.noise-summary");
                Assert(line2.Contains("\"source\":\"bus\""), "Line 2 source must be bus");
                Assert(line2.Contains("\"suppressed\":2000") || line2.Contains("\"count\":2000"), "Line 2 must report 2000 suppressed");
            }
        }

        // 4. 150 одинаковых подряд → 2 строки со count (первая на 100, вторая на 50)
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
                journal.Flush();

                Assert(lines.Count == 2, $"Expected exactly 2 lines for 150 identical events, got {lines.Count}");

                string line1 = lines[0];
                Assert(line1.Contains("\"topic\":\"vpn.state\""), "Line 1 topic must be vpn.state");
                Assert(line1.Contains("\"count\":100"), $"Line 1 must have count 100, got: {line1}");

                string line2 = lines[1];
                Assert(line2.Contains("\"topic\":\"vpn.state\""), "Line 2 topic must be vpn.state");
                Assert(line2.Contains("\"count\":50"), $"Line 2 must have count 50, got: {line2}");
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
                    journal.Flush();
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
                    journal.Flush();

                    string logFile = Path.Combine(tempDir, "bus.log");
                    Assert(File.Exists(logFile), "logs/bus.log must exist on disk");

                    string text = File.ReadAllText(logFile);
                    Assert(text.Contains("\"topic\":\"disk.event\""), "bus.log must contain topic disk.event");
                    Assert(text.Contains("\"action\":\"disk-val\""), "bus.log must contain action disk-val");
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
    }
}
