using System;
using System.Collections.Generic;
using System.IO;

namespace RemoteAgents.Launcher
{
    public static class HealthJournalTests
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
            Console.WriteLine("Starting HealthJournalTests...");
            _assertions = 0;

            TestComponentExitWrittenImmediately();
            TestSecretMasked();
            TestForeignTopicNotWritten();
            TestDisposeUnsubscribes();
            TestHealthAndBlockTopicsWritten();
            TestDiskWriteWithRaLog();

            Console.WriteLine($"PASS: HealthJournalTests ({_assertions} assertions passed)");
        }

        // 1. Событие component.exit code=1 → ровно одна строка без Flush
        private static void TestComponentExitWrittenImmediately()
        {
            var lines = new List<string>();
            using (var bus = new EventBus(manualDispatch: true))
            using (var journal = new HealthJournal(bus, sink: lines.Add))
            {
                bus.Publish(BusTopics.ComponentExit, "supervisor", "name", "sing-box", "code", "1");
                bus.DrainOnce();

                Assert(lines.Count == 1, $"Expected exactly 1 line without Flush, got {lines.Count}");
                string line = lines[0];
                Assert(line.Contains(" component.exit "), "Topic must be component.exit: " + line);
                Assert(line.Contains(" health "), "Component must be health: " + line);
                Assert(line.Contains("source=supervisor"), "Source must be supervisor: " + line);
                Assert(line.Contains("name=sing-box"), "Name must be sing-box: " + line);
                Assert(line.Contains("code=1"), "Code must be 1: " + line);
                Assert(System.Text.RegularExpressions.Regex.IsMatch(line, @"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z "), "ISO prefix: " + line);
            }
            Assert(lines.Count == 1, "Dispose must add nothing");
        }

        // 2. Секрет в поле маскируется
        private static void TestSecretMasked()
        {
            var lines = new List<string>();
            using (var bus = new EventBus(manualDispatch: true))
            using (var journal = new HealthJournal(bus, sink: lines.Add))
            {
                bus.Publish(BusTopics.ComponentExit, "supervisor",
                    "code", "1",
                    "secret", "SuperSecretPass123",
                    "token", "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3",
                    "auth", "secret-auth-token",
                    "note", "Bearer my-secret-bearer-token");
                bus.DrainOnce();

                Assert(lines.Count == 1, $"Expected 1 line, got {lines.Count}");
                string line = lines[0];

                Assert(!line.Contains("SuperSecretPass123"), "Secret password must not be in journal");
                Assert(line.Contains("secret=***"), "Secret key value must be masked with ***");
                Assert(line.Contains("auth=***"), "Auth key value must be masked with ***");
                Assert(!line.Contains("my-secret-bearer-token"), "Bearer token must not be in journal");
                Assert(line.Contains("note=\"Bearer ***\""), "Bearer token in non-secret key must be masked");
            }
        }

        // 3. Чужой топик не пишется (включая component.exit без code)
        private static void TestForeignTopicNotWritten()
        {
            var lines = new List<string>();
            using (var bus = new EventBus(manualDispatch: true))
            using (var journal = new HealthJournal(bus, sink: lines.Add))
            {
                // Чужие топики
                bus.Publish("vpn.state", "vpn-core", "state", "on");
                bus.Publish("net.change", "windows", "id", "1");
                bus.Publish("tick.tray", "timer");
                bus.Publish("singbox.line", "vpn-core", "line", "test line");
                bus.Publish("custom.foreign.topic", "test", "k", "v");

                // component.exit без code НЕ должен писаться в health
                bus.Publish(BusTopics.ComponentExit, "supervisor", "name", "vpn");

                bus.DrainOnce();

                Assert(lines.Count == 0, $"Expected 0 lines for foreign topics, got {lines.Count}");
            }
        }

        // 4. Dispose отписывает
        private static void TestDisposeUnsubscribes()
        {
            var lines = new List<string>();
            using (var bus = new EventBus(manualDispatch: true))
            {
                var journal = new HealthJournal(bus, sink: lines.Add);
                bus.Publish(BusTopics.ComponentExit, "supervisor", "name", "sing-box", "code", "1");
                bus.DrainOnce();
                Assert(lines.Count == 1, $"Expected 1 line before dispose, got {lines.Count}");

                journal.Dispose();

                // События после Dispose не должны писаться
                bus.Publish(BusTopics.ComponentExit, "supervisor", "name", "transport", "code", "2");
                bus.Publish("block.ready", "tray", "block", "transport");
                bus.Publish("health.accepted", "tray", "ver", "1.6.0");
                bus.Publish(BusTopics.Unhandled, "app", "err", "crash");
                bus.DrainOnce();

                Assert(lines.Count == 1, $"Expected still 1 line after dispose, got {lines.Count}");
            }
        }

        // 5. Проверка записи block.ready, block.degraded, health.* и unhandled
        private static void TestHealthAndBlockTopicsWritten()
        {
            var lines = new List<string>();
            using (var bus = new EventBus(manualDispatch: true))
            using (var journal = new HealthJournal(bus, sink: lines.Add))
            {
                bus.Publish(BusTopics.BlockReady, "tray", "block", "tray");
                bus.Publish(BusTopics.BlockDegraded, "tray", "block", "transport", "reason", "no-network");
                bus.Publish("health.accepted", "tray", "ver", "1.6.0");
                bus.Publish("health.rollback", "tray", "ver", "1.5.9", "why", "crash-loop");
                bus.Publish(BusTopics.Unhandled, "app", "err", "NullReferenceException");

                bus.DrainOnce();

                Assert(lines.Count == 5, $"Expected 5 lines, got {lines.Count}");
                Assert(lines[0].Contains(" block.ready ") && lines[0].Contains("block=tray"), "block.ready line: " + lines[0]);
                Assert(lines[1].Contains(" block.degraded ") && lines[1].Contains("reason=no-network"), "block.degraded line: " + lines[1]);
                Assert(lines[2].Contains(" health.accepted ") && lines[2].Contains("ver=1.6.0"), "health.accepted line: " + lines[2]);
                Assert(lines[3].Contains(" health.rollback ") && lines[3].Contains("why=crash-loop"), "health.rollback line: " + lines[3]);
                Assert(lines[4].Contains(" unhandled ") && lines[4].Contains("err=NullReferenceException"), "unhandled line: " + lines[4]);
            }
        }

        // 6. Запись на диск во временный каталог через RaLog
        private static void TestDiskWriteWithRaLog()
        {
            string tempDir = Path.Combine(Path.GetTempPath(), "health-journal-disk-" + Guid.NewGuid().ToString("N").Substring(0, 8));
            try
            {
                using (var bus = new EventBus(manualDispatch: true))
                using (var journal = new HealthJournal(bus, logsDir: tempDir))
                {
                    bus.Publish(BusTopics.ComponentExit, "supervisor", "name", "sing-box", "code", "1");
                    bus.DrainOnce();

                    string logFile = Path.Combine(tempDir, "health.log");
                    Assert(File.Exists(logFile), "logs/health.log must exist on disk");

                    string text = File.ReadAllText(logFile);
                    Assert(text.Contains(" component.exit "), "health.log must contain topic component.exit");
                    Assert(text.Contains("code=1"), "health.log must contain code=1");
                }
            }
            finally
            {
                try
                {
                    if (Directory.Exists(tempDir))
                        Directory.Delete(tempDir, true);
                }
                catch
                {
                }
            }
        }
    }
}
