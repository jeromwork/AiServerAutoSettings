using System;
using System.IO;
using System.Linq;

namespace RemoteAgents.Launcher
{
    internal static class WindowModelTests
    {
        static int count;
        static void Check(bool condition, string name)
        { if (!condition) throw new Exception("Window: " + name); count++; }
        internal static void Run()
        {
            Check(WindowModel.Route(new string[0]) == WindowCommand.Show, "human launch opens the main window");
            Check(WindowModel.Route(new[] { "--home", "test-home" }) == WindowCommand.Show, "home option preserves human launch");
            Check(WindowModel.Route(new[] { "--tray", "--home", "test-home" }) == WindowCommand.None, "Windows sign-in stays in tray");
            Check(WindowModel.Route(new[] { "--tray", "--after-update" }) == WindowCommand.None, "internal restart after update stays quiet");
            Check(WindowModel.Route(new[] { "--tray", "--after-update", "--started" }) == WindowCommand.Show, "new downloaded EXE preserves human intent after upgrade");
            Check(WindowModel.Route(new[] { "--tray", "--show" }) == WindowCommand.Show, "explicit show command wins over tray");
            Check(WindowModel.Route(new[] { "--settings" }) == WindowCommand.Show, "legacy settings opens main");
            Check(WindowModel.Route(new[] { "--setup-check" }) == WindowCommand.SetupCheck, "setup check is not a human launch");
            Check(WindowModel.Route(new[] { "--logs" }) == WindowCommand.Logs, "logs command does not open main");
            Check(WindowModel.Route(new[] { "--check-updates" }) == WindowCommand.CheckUpdates, "update command routes to update");
            Check(WindowModel.Route(new[] { "--restart-components" }) == WindowCommand.Restart, "restart command routes to supervisor");
            Check(WindowModel.Route(new[] { "--rollback" }) == WindowCommand.Rollback, "rollback stays a command");
            Check(WindowModel.Route(new[] { "--exit", "--show" }) == WindowCommand.Exit, "exit takes precedence");
            Check(WindowModel.Route(new[] { "--uninstall" }) == WindowCommand.Exit, "uninstall exits the existing instance");
            Check(!WindowModel.ShouldShow(new[] { "--identify" }), "identity IPC does not recurse into activation");
            var forwarded = WindowModel.ForwardArguments(new string[0]);
            Check(forwarded.Contains("--show") && WindowModel.Route(forwarded) == WindowCommand.Show, "second human instance tells first to show");
            Check(WindowModel.ForwardArguments(new[] { "--home", "test-home" }).Contains("--show"), "second instance with home tells first to show");
            Check(!WindowModel.ForwardArguments(new[] { "--tray" }).Contains("--show"), "second sign-in does not open a window");
            Check(WindowModel.ForwardArguments(new[] { "--show" }).Count(x => x == "--show") == 1, "forward is idempotent");
            var window = new WindowModel(); window.Show();
            Check(window.Visible, "show makes visible");
            Check(window.CloseToTray() && !window.Visible, "cross hides to tray and shows hint once");
            window.Show(); Check(!window.CloseToTray(), "repeated cross has no hint");
            Check(!new WindowModel(true).CloseToTray(), "persisted first-close hint survives restart");
            Check(window.Exit(false) == WindowExit.Unload, "exit unloads without a question");
            Check(window.Exit(true) == WindowExit.ConfirmApplying, "applying settings requires interrupt confirmation");
            foreach (string work in new[] { "", "сверка конфига", "проверка здоровья", "применение настроек" }) {
                foreach (string page in new[] { "Папки", "Конфиг", "Подробно", "Сервис" })
                    Check(WindowModel.CanOpen(page, work), "navigation remains open: " + work + "/" + page);
                Check(WindowModel.Conflict(work) == (work.Length == 0 ? "" : "Идёт " + work + ", подождите"), "conflict identifies only the action");
            }
            var now = new DateTime(2026, 11, 12, 10, 0, 0, DateTimeKind.Utc); var schedule = new ConfigSyncSchedule();
            Check(!schedule.Due(false, now, false), "no sync while disconnected");
            Check(!schedule.Due(true, now, false), "no sync on first confirmed connection");
            Check(!schedule.Due(true, now.AddSeconds(119), false), "wait a full two minutes");
            Check(!schedule.Due(true, now.AddMinutes(2), true), "defer conflicting work without consuming attempt");
            Check(schedule.Due(true, now.AddMinutes(2), false), "sync due at two minutes");
            schedule.Started(now.AddMinutes(2));
            Check(!schedule.Due(true, now.AddMinutes(6), false), "five minutes between attempts including failures");
            Check(schedule.Due(true, now.AddMinutes(7), false), "next sync five minutes after attempt");
            Check(!schedule.Due(false, now.AddMinutes(7), false), "lost connection resets warmup");
            Check(!schedule.Due(true, now.AddMinutes(8), false), "reconnection must warm up again");
            Check(schedule.Due(true, now.AddMinutes(10), false), "two minutes after reconnection");
            var status = Json.Map(Json.Parse("{\r\n\"ok\":true,\"title\":\"Проверенный путь\",\"summary\":\"Ожидается проверка пути\",\"error\":\"нет связи\"\r\n}"));
            string line = StatusView.Line("Связь с сервером", status, true);
            Check(line.StartsWith("✅") && line.Contains("подключено") && line.Contains("Проверенный путь"), "confirmed transport has a consistent connection line");
            Check(!line.Contains("нет связи") && !line.Contains("Ожидается"), "stale process summary/error cannot override ok=true");
            Check(StatusView.Line("Связь с сервером", Json.Map(null), true).StartsWith("⏳"), "missing status is unknown");
            status["ok"] = false;
            Check(StatusView.Line("Связь с сервером", status, true).StartsWith("❌"), "failed proof is an error");
            string dir = Path.Combine(Path.GetTempPath(), "tray-status-" + Guid.NewGuid().ToString("N"));
            try {
                Directory.CreateDirectory(Path.Combine(dir, "status"));
                string file = Path.Combine(dir, "status", "transport.json");
                Files.Atomic(file, "{\r\n\"ok\":true,\"summary\":\"Ожидается проверка пути\"\r\n}");
                Check(StatusView.Line("Связь", StatusView.Read(dir, "transport", maxAgeSec: 15), true).StartsWith("✅"), "actual CRLF transport file feeds connection line");
                File.SetLastWriteTimeUtc(file, DateTime.UtcNow.AddSeconds(-30));
                Check(StatusView.Line("Связь", StatusView.Read(dir, "transport", maxAgeSec: 15), true).StartsWith("⏳"), "expired ok does not claim connectivity");
                Files.Atomic(file, "{\"ok\":true,\"updatedAt\":\"2000-01-01T00:00:00Z\"}");
                Check(StatusView.Read(dir, "transport", maxAgeSec: 15).Count == 0, "old embedded timestamp cannot look fresh after file rewrite");
            } finally { Directory.Delete(dir, true); }
            Console.WriteLine("PASS: " + count + " window/routing/sync/status checks");
        }
    }
}
