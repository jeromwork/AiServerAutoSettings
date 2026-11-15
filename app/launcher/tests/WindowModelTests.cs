using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Threading;
using System.Threading.Tasks;

namespace RemoteAgents.Launcher
{
    internal static class WindowModelTests
    {
        static int count;
        static void Check(bool condition, string name)
        { if (!condition) throw new Exception("Window: " + name); count++; }
        internal static void Run()
        {
            Check(!Product.VpnEnabled, "system VPN is disabled in this release");
            Check(!WindowModel.SetupSections.Contains(5) && !WindowModel.StatusNames.Contains("vpn") && !ConfigSections.Rows.Contains(ConfigSections.Vpn), "VPN is absent from wizard, details, main status and config rows");
            var vpnConfig = Configuration.ForUpdate("{}");
            vpnConfig.Data["components"] = ConfigBundle.D("vpn", ConfigBundle.D("enabled", true));
            Check(!vpnConfig.Wanted(new Component { Name = "vpn", Default = true, RequiredConfig = new string[0] }), "saved enabled intent cannot start the VPN runtime");
            Check(!TrayMenuModel.Build(ConfigBundle.D("vpn", ConfigBundle.D("enabled", true)), Json.Map(null), Json.Map(null), Json.Map(null)).Any(e => e.Id.ToLowerInvariant().Contains("vpn") || e.Text.Contains("VPN")), "tray has no VPN even when configured enabled");
            Check(Json.Bool(WizardRunner.Run("nonexistent", "nonexistent", "Vpn", new { enabled = true }, CancellationToken.None), "ok"), "Enable via wizard returns disabled without launching a process or writing files");
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
            using (var installer = new Mutex(false)) {
                installer.WaitOne();
                try {
                    bool ordinary = Task.Run(() => { bool owned; bool ok = LauncherInstallerGate.TryEnter(installer, new string[0], out owned); if (owned) installer.ReleaseMutex(); return ok; }).GetAwaiter().GetResult();
                    Check(!ordinary, "simultaneous installer still refused");
                    // No command bypasses the installer lock any more (the Explorer verbs are gone): every launch waits its turn.
                    bool other = Task.Run(() => { bool owned; bool ok = LauncherInstallerGate.TryEnter(installer, new[] { "--tray", "--home", "test-home" }, out owned); if (owned) installer.ReleaseMutex(); return ok; }).GetAwaiter().GetResult();
                    Check(!other, "a second launch with any arguments is refused while an installer runs");
                } finally { installer.ReleaseMutex(); }
            }
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
                foreach (string page in new[] { "Конфиг", "Подробно", "Сервис" })
                    Check(WindowModel.CanOpen(page, work), "navigation remains open: " + work + "/" + page);
                Check(WindowModel.Conflict(work) == (work.Length == 0 ? "" : "Идёт " + work + ", подождите"), "conflict identifies only the action");
            }
            DiskRunsApart().GetAwaiter().GetResult();
            var terminal = new Dictionary<string, SectionState> {
                { ConfigSections.Server, SectionState.Done }, { ConfigSections.Connection, SectionState.Unchanged },
                { ConfigSections.Bridge, SectionState.Failed }, { ConfigSections.Account, SectionState.Blocked },
                { ConfigSections.Disk, SectionState.Waiting } };
            Check(WindowModel.CanFinish(false, terminal), "Done allows visible errors and an unconfirmed Disk");
            terminal[ConfigSections.Disk] = SectionState.Running;
            Check(WindowModel.CanFinish(false, terminal), "Disk does not gate Done");
            foreach (var state in new[] { SectionState.Waiting, SectionState.Running }) {
                terminal[ConfigSections.Account] = state;
                Check(!WindowModel.CanFinish(false, terminal), "non-Disk work still outstanding: " + state);
            }
            // VPN «ещё не подтверждено» and a Happier install on the server are Pending: handed to the tray, never a dead end.
            terminal[ConfigSections.Account] = SectionState.Done; terminal[ConfigSections.Vpn] = SectionState.Pending;
            Check(WindowModel.CanFinish(false, terminal), "pending VPN does not block Done");
            terminal[ConfigSections.Account] = SectionState.Pending;
            Check(WindowModel.CanFinish(false, terminal), "pending server install does not block Done");
            terminal[ConfigSections.Account] = SectionState.Done;
            Check(WindowModel.DiskInBackground.Contains("в фоне") && WindowModel.DiskInBackground.Contains("Syncthing Tray"), "the window says the Disk install goes on in the background and where folders are accepted");
            BackgroundRunner().GetAwaiter().GetResult();
            Check(!WindowModel.CanFinish(true, terminal), "startup/activation guard still gates Done");
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
        static async Task BackgroundRunner()
        {
            // The Disk runner: independent of windows, one run at a time, the newest request queued, Stop cancels.
            var runner = new SerialRunner<DiskRun>(); int changes = 0; runner.Changed += () => Interlocked.Increment(ref changes);
            var gate = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            var order = new ConcurrentQueue<string>();
            Check(runner.Start(async token => { order.Enqueue("first"); await gate.Task; return new DiskRun { Ok = true, Summary = "first" }; }), "idle runner starts at once");
            Check(runner.Busy, "busy while the run is in progress");
            Check(!runner.Start(async token => { order.Enqueue("stale"); await Task.Yield(); return new DiskRun { Summary = "stale" }; }), "second request queues");
            Check(!runner.Start(async token => { order.Enqueue("newest"); await Task.Yield(); return new DiskRun { Ok = true, Summary = "newest" }; }), "newest request replaces the queued one");
            gate.SetResult(true); await runner.Current;
            Check(!runner.Busy && runner.Last.Summary == "newest", "queue drains to the newest choice");
            Check(string.Join(",", order) == "first,newest", "stale queued request is dropped, never run twice in parallel");
            Check(changes == 2, "Changed on start and when drained");
            Check(runner.Start(async token => { throw new InvalidOperationException("boom"); }), "a failing run does not wedge the runner");
            await runner.Current; Check(!runner.Busy && runner.Last.Summary == "newest", "failure leaves the last real result");
            var cancelled = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            runner.Start(async token => { try { await Task.Delay(Timeout.Infinite, token); } catch (OperationCanceledException) { cancelled.SetResult(true); throw; } return null; });
            runner.Stop(); await runner.Current;
            Check(cancelled.Task.IsCompleted && !runner.Busy, "tray exit cancels the background run");
            Check(!runner.Start(token => Task.FromResult(new DiskRun())), "nothing starts after Stop");
        }
        static async Task DiskRunsApart()
        {
            // The window takes Disk out of the plan (the Disk install can take minutes and survives closing the window):
            // every other section starts and finishes without it, and Disk later runs once on the same engine.
            var plan = ConfigSections.Order.Where(s => s != ConfigSections.Disk).ToList();
            var started = new ConcurrentDictionary<string, int>();
            var account = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            var connection = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            Func<string, CancellationToken, Task<SectionOutcome>> run = async (section, token) => {
                started.AddOrUpdate(section, 1, (s, n) => n + 1);
                if (section == ConfigSections.Account) await account.Task;
                return new SectionOutcome { Ok = true, Summary = "проверено на стенде" };
            };
            var execution = ConfigEngine.Execute(plan, run, (section, state, text) => {
                if (section == ConfigSections.Connection && state == SectionState.Done) connection.TrySetResult(true);
            }, CancellationToken.None);
            try {
                Check(await Task.WhenAny(connection.Task, Task.Delay(3000)) == connection.Task, "Connection reports ready before long Account finishes");
                Check(!execution.IsCompleted && started.ContainsKey(ConfigSections.Account), "Happier is still running while the rest goes on");
                foreach (string section in new[] { ConfigSections.Bridge, ConfigSections.Proxy, ConfigSections.Lan })
                    Check(started.ContainsKey(section), section + " executes without Disk");
                Check(!started.ContainsKey(ConfigSections.Disk), "Disk has not run inside the window's plan");
                // The background run invokes only Disk on the same engine while the other plan is alive.
                var disk = await ConfigEngine.Execute(new[] { ConfigSections.Disk }, run, (s, state, text) => { }, CancellationToken.None);
                Check(disk[ConfigSections.Disk].Ok && started[ConfigSections.Disk] == 1, "the background run executes Disk exactly once");
                Check(!execution.IsCompleted && started[ConfigSections.Account] == 1, "Disk does not wait for or restart Happier");
            } finally { account.TrySetResult(true); await execution; }
            // Executing the window's plan alone leaves Disk untouched.
            started.Clear();
            await ConfigEngine.Execute(plan, run, (s, state, text) => { }, CancellationToken.None);
            Check(!started.ContainsKey(ConfigSections.Disk) && started.ContainsKey(ConfigSections.Bridge) && started.ContainsKey(ConfigSections.Account) && !started.ContainsKey(ConfigSections.Vpn), "the plan without Disk never applies Disk or disabled VPN");
        }
    }
}
