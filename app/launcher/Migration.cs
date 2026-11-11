using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Windows.Forms;

namespace RemoteAgents.Launcher
{
    internal sealed class MigrationFailureException : IOException
    {
        internal MigrationFailureException(string message) : base(message) { }
    }
    internal static class Migration
    {
        internal static string FailureMessage(string home)
        {
            try {
                string path = Path.Combine(home, "state", "migration-error.json");
                if (File.Exists(path)) {
                    string message = Json.Str(Json.Read(path), "message");
                    if (message.Length > 0 && message.Length <= 12000) return message;
                }
            } catch { }
            return "Переход не выполнен. Причина записана в logs\\migration.log; подробности транспорта — в state\\migration-probe\\logs\\transport.log.";
        }
        static string Script(string home, string name)
        {
            if (name == "Rollback.ps1") {
                string state = Path.Combine(home, "state", "migration.json");
                if (File.Exists(state)) {
                    string session = Json.Str(Json.Read(state), "session"); Guid parsed;
                    if (Guid.TryParseExact(session, "N", out parsed)) {
                        string recovery = Path.Combine(home, "state", "migration-recovery", session, "build", name);
                        if (File.Exists(recovery)) return recovery;
                    }
                }
            }
            var engine = new UpdateEngine(home, Program.Version);
            if (engine.Current.Length == 0) throw new IOException("Нет бандла для перехода");
            return Path.Combine(engine.Folder(engine.Current), "build", name);
        }
        public static int RunRecoveryHost(string home)
        {
            // This immutable copy lives outside the replaceable EXE and prunable bundles.
            if (!LauncherRecovery.Accepted(home)) return 0;
            string name = Program.InstanceName(home, System.Security.Principal.WindowsIdentity.GetCurrent().User);
            using (var installer = new Mutex(false, "Global\\" + name + ".Install")) {
                bool owned; try { owned = installer.WaitOne(0); } catch (AbandonedMutexException) { owned = true; }
                if (!owned) return 0;
                try {
                    using (var main = new Mutex(false, "Global\\" + name)) {
                        bool mainOwned; try { mainOwned = main.WaitOne(0); } catch (AbandonedMutexException) { mainOwned = true; }
                        if (!mainOwned) return 0;
                        try { UpgradeInstaller.RecoverImage(home); }
                        finally { main.ReleaseMutex(); }
                    }
                } finally { installer.ReleaseMutex(); }
            }
            if (!LauncherRecovery.Requested(home)) return 0;
            using (var process = Process.Start(new ProcessStartInfo(Path.Combine(home, "RemoteAgents.exe"), "--recover-launcher --home " + Files.Quote(home)) { UseShellExecute = false, CreateNoWindow = true })) {
                process.WaitForExit(); return process.ExitCode;
            }
        }
        public static void Start(string home)
        {
            // Independent of tray Job Object: stopping the tray cannot cancel migration/rollback.
            var process = Process.Start(new ProcessStartInfo(Files.Executable("powershell.exe"), Files.Arguments(new[] {
                "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", Script(home, "Migrate.ps1"), "-Home", home
            })) { UseShellExecute = false, CreateNoWindow = true });
            Application.EnableVisualStyles();
            using (process) using (var form = new Form { Text = "RemoteAgents — переход", Width = 560, Height = 160, StartPosition = FormStartPosition.CenterScreen })
            using (var timer = new System.Windows.Forms.Timer { Interval = 500 }) {
                var text = new Label { Text = "Проверяем новый транспорт на временных портах.\r\nПрежняя связь продолжает работать.", Dock = DockStyle.Fill, Padding = new Padding(16) };
                form.Controls.Add(text); bool done = false;
                form.FormClosing += (s, e) => { if (!done) e.Cancel = true; };
                timer.Tick += (s, e) => {
                    try {
                        string state = Path.Combine(home, "state", "migration.json");
                        if (File.Exists(state) && Json.Str(Json.Read(state), "phase") == "activating") text.Text = "Переключаем диск и управление на новый транспорт.\r\nНезависимый автоматический откат включён.";
                        if (process.HasExited) { done = true; timer.Stop(); form.Close(); }
                    } catch { }
                };
                timer.Start(); form.ShowDialog();
                if (process.ExitCode != 0) throw new MigrationFailureException(FailureMessage(home));
            }
        }
        public static void Rollback(string home)
        {
            if (!File.Exists(Path.Combine(home, "state", "migration.json"))) {
                using (var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey("Software\\Microsoft\\Windows\\CurrentVersion\\Run")) {
                    var value = Convert.ToString(key.GetValue("RemoteAgents", ""));
                    if (value.IndexOf(Path.Combine(home, "RemoteAgents.exe"), StringComparison.OrdinalIgnoreCase) >= 0) key.DeleteValue("RemoteAgents", false);
                }
                try { Program.Forward(Program.InstanceName(home, System.Security.Principal.WindowsIdentity.GetCurrent().User), new[] { "--exit" }); } catch { }
                // Clean install has no migration to undo, but Rollback.ps1 -Uninstall still removes the Explorer Disk entry.
                if (new UpdateEngine(home, Program.Version).Current.Length == 0) return;
            }
            string output = Path.Combine(home, "state", "uninstall-output.tmp"); Directory.CreateDirectory(Path.GetDirectoryName(output));
            try {
                if (External.Run("powershell.exe", new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Script(home, "Rollback.ps1"), "-Home", home, "-Uninstall" }, home, output, 180000, 1024 * 1024, CancellationToken.None) != 0) throw new IOException("Откат не завершён");
            } finally { if (File.Exists(output)) File.Delete(output); }
        }
        public static void Check(string home, bool confirm, string observer, CancellationToken cancel)
        {
            string output = Path.Combine(home, "state", "migration-check.tmp");
            try {
                if (External.Run("powershell.exe", new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Script(home, "Migrate.ps1"), "-Home", home, confirm ? "-Confirm" : "-Check", "-Observer", observer }, home, output, 60000, 1024 * 1024, cancel) != 0) throw new IOException("Проверка перехода не прошла");
            } finally { if (File.Exists(output)) File.Delete(output); }
        }
    }
}
