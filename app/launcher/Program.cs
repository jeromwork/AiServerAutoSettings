using System;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

namespace RemoteAgents.Launcher
{
    internal static partial class Program
    {
        public static string Version { get { return Assembly.GetExecutingAssembly().GetName().Version.ToString(); } }
        public static string Exe { get { return Assembly.GetExecutingAssembly().Location; } }
        public static string DefaultHome { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RemoteAgents"); } }
        // Первая строка каждого запуска: версия, помощник, ОС, пользователь, имя устройства (из профиля), компьютер, каталог.
        static void LogStart(Journal log, string home)
        {
            string device = "";
            try { device = ConfigProfile.DeviceName(ConfigProfile.Load(home)); } catch { }
            string user = ""; try { user = Environment.UserName; } catch { }
            log.Write(LogLevel.Info, "launcher", "launcher.start", "ver", Version, "helper", NetHelperInstall.InstalledVersion, "os", Environment.OSVersion.VersionString,
                "user", user, "device", device, "host", Environment.MachineName, "home", home);
        }
        public static string Option(string[] args, string key)
        { int at = Array.IndexOf(args, key); if (at < 0) return null; if (at + 1 >= args.Length || args[at + 1].StartsWith("--")) throw new ArgumentException("Нет значения параметра"); return args[at + 1]; }
        public static string InstanceName(string home, SecurityIdentifier sid)
        {
            string suffix = "";
            if (!Path.GetFullPath(home).TrimEnd('\\').Equals(Path.GetFullPath(DefaultHome).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) {
                using (var sha = System.Security.Cryptography.SHA256.Create()) suffix = "." + BitConverter.ToString(sha.ComputeHash(Files.Utf8.GetBytes(Path.GetFullPath(home).TrimEnd('\\').ToUpperInvariant()))).Replace("-", "").Substring(0, 24);
            }
            return Product.Name + ".Launcher." + sid.Value + suffix;
        }
        [STAThread] internal static int Run(string[] args)
        {
            if (TransportFaultCommand.IsRequested(args)) {
                AttachConsole(0xFFFFFFFF);
                try {
                    TransportFaultCommand.Parse(args, UpdateChannel.IsTest);
                    string faultHome = Path.GetFullPath(Option(args, "--home") ?? DefaultHome);
                    var reply = Forward(InstanceName(faultHome, WindowsIdentity.GetCurrent().User), args);
                    if (!Json.Bool(reply, "ok")) throw new InvalidOperationException(Json.Text(reply, "error", "Команда не принята"));
                    Console.WriteLine("Команда передана тестовой программе"); return 0;
                } catch (Exception ex) { Console.Error.WriteLine(ex is ArgumentException || ex is InvalidOperationException ? ex.Message : "Тестовая программа не отвечает"); return 21; }
            }
            string watchUpdate = Option(args, "--watch-update");
            if (watchUpdate != null) return UpdateWatchdog.Run(Path.GetFullPath(watchUpdate));
            string checkConfig = Option(args, "--check-update-config");
            if (checkConfig != null) { try { UpdatePolicy.Compatible(checkConfig); return 0; } catch { return 20; } }
            // Before askpass: ssh may carry a password pipe in its environment while running this relay as ProxyCommand.
            if(args.Length>0 && args[0]=="--proxy-connect")return ProxyRelay.Run(args);
            string passwordPipe=Environment.GetEnvironmentVariable("REMOTEAGENTS_PASSWORD_PIPE");
            if(!string.IsNullOrEmpty(passwordPipe))return PasswordRelay.Answer(passwordPipe);
            Journal log = null;
            EventWaitHandle updateFailed = null;
            UnhandledExceptionEventHandler unhandled = null;
            ThreadExceptionEventHandler threadException = null;
            SessionEndingEventHandler sessionEnding = null;
            try {
                if (args.Contains("--net-helper-service")) return NetHelper.Run(args);
                if (args.Contains("--net-helper-install")) return NetHelperInstall.Install(args);
                if (args.Contains("--net-helper-uninstall")) return NetHelperInstall.Uninstall();
                // Test modes never create or lock the real user's home.
                string elevated = Option(args, "--elevated-component");
                if (elevated != null) return ElevatedTask.RunComponent(Path.GetFullPath(Option(args, "--home") ?? DefaultHome), elevated);
                string test = Option(args, "--selftest-upgrade");
                if (test != null) { AttachConsole(0xFFFFFFFF); return UpgradeSelfTests.Run(Path.GetFullPath(test)); }
                test = Option(args, "--selftest-update");
                if (test != null) { AttachConsole(0xFFFFFFFF); return UpdateSelfTests.Run(Path.GetFullPath(test)); }
                string home = Path.GetFullPath(Option(args, "--home") ?? DefaultHome);
                var diskShell = DiskShellRequest.Parse(args);
                // Agent commands (docs/CONFIG.md «Ввод без раскрытия агенту»): before single-instance, the tray may run.
                // Output is only «сохранено»/«отменено»/names, never a value.
                if (args.Length > 0 && args[0] == "secret") {
                    AttachConsole(0xFFFFFFFF); Directory.CreateDirectory(home);
                    var rest = new System.Collections.Generic.List<string>(args); int at = rest.IndexOf("--home"); if (at > 0 && at + 1 < rest.Count) rest.RemoveRange(at, 2);
                    return SecretCommand.Run(home, rest.ToArray());
                }
                Directory.CreateDirectory(home); log = new Journal(home); RaLog.Configure(log.LogsDir); RaLog.Secrets = () => DiagnosticReport.KnownSecrets(home); LogStart(log, home);
                try { LegacyPacCleanup.Recover(home, new LegacyPacBrowser()); } catch { log.Write("legacy.pac.cleanup.failed"); }
                try { FirstInstall.CleanupLegacyRun(home); } catch { log.Write("legacy.run.cleanup.failed"); }
                if (args.Contains("--uninstall")) { Uninstall.Run(home); log.Write("uninstall.ok"); return 0; }
                var sid = WindowsIdentity.GetCurrent().User; string name = InstanceName(home, sid);
                var security = new MutexSecurity(); security.AddAccessRule(new MutexAccessRule(sid, MutexRights.FullControl, AccessControlType.Allow));
                bool created, owned = false, restart = false;string firstInstallSource=null;
                // A person started the EXE (not autostart/IPC/service commands): show that it runs.
                bool interactive = WindowModel.ShouldShow(args);
                using (var mutex = new Mutex(false, "Global\\" + name, out created, security)) {
                    // Serialize downloaded installers independently of the running tray's mutex.
                    using (var installer = new Mutex(false, "Global\\" + name + ".Install", out created, security)) {
                        bool installOwned;
                        if (!LauncherInstallerGate.TryEnter(installer, args, out installOwned)) throw new InvalidOperationException("Установка уже выполняется");
                        Action<string, bool> launch = (path, after) => {
                            if (owned) { mutex.ReleaseMutex(); owned = false; }
                            installer.ReleaseMutex(); installOwned = false;
                            StartLauncher(path, home, after, interactive);
                        };
                        Action firstRun = () => {
                            if (owned) { mutex.ReleaseMutex(); owned = false; }
                            installer.ReleaseMutex(); installOwned = false; FirstInstall.Start(home);
                        };
                        try {
                            owned = WaitMutex(mutex, 0);
                            string target = Path.Combine(home, Product.ExeName);
                            bool external = !Path.GetFullPath(Exe).Equals(target, StringComparison.OrdinalIgnoreCase);
                            bool command = args.Any(a => new[] { "--exit", "--uninstall", "--logs", "--rollback", "--rollback-previous", "--restart-components", "--check-updates", "--settings", "--disk-shell" }.Contains(a));
                            // --tray with --home is also the isolated development/smoke entry point.
                            bool install = external && !command && !(args.Contains("--tray") && args.Contains("--home"));
                            if (ResumePreviousRollbackAtStartup(home, owned, launch)) return 0;
                            if (owned && args.Contains("--rollback-previous")) {
                                var engine = new UpdateEngine(home, Version);
                                string previous = UpgradeInstaller.PreviousVersion(home, engine); bool blockCurrent;
                                if (!TrayContext.ConfirmPreviousRollback(previous, out blockCurrent)) return 0;
                                UpgradeInstaller.RollbackPrevious(home, engine, blockCurrent, previous, "Global\\" + name + ".Install");
                                launch(target, false); return 0;
                            }
                            // First setup owns a visible wizard before extraction, selftest or binary downloads.
                            if (install && home.Equals(DefaultHome,StringComparison.OrdinalIgnoreCase) && FirstInstall.Required(home)) {
                                if(!owned){if(TryForward(name,new[]{"--setup-check"},log)){return 0;}StopInstalled(name,target,home,mutex,log);owned=true;}
                                firstInstallSource=Exe;
                            }
                            else if (install) {
                                string zip = Path.Combine(home, "embedded-install-" + Guid.NewGuid().ToString("N") + ".zip");
                                try {
                                    string bundle = UpgradeInstaller.ExtractEmbedded(zip);
                                    var engine = new UpdateEngine(home, Version);
                                    int comparison = File.Exists(target) ? UpgradeInstaller.Compare(Version, bundle, FileVersionInfo.GetVersionInfo(target).FileVersion, engine.Current) : 1;
                                    if (comparison == 0) {
                                        if (args.Contains("--install") || (!args.Contains("--home") && FirstInstall.Required(home))) { firstRun(); return 0; }
                                        if (!owned && TryForward(name, Started(new[] { "--setup-check" }, interactive), log)) return 0;
                                        if (!owned) { StopInstalled(name, target, home, mutex, log); owned = true; }
                                        launch(target, false);
                                        return 0;
                                    }
                                    if (comparison < 0 && MessageBox.Show("Запущена более старая версия RemoteAgents. Выполнить откат лаунчера и бандла?", "RemoteAgents — откат", MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return 0;
                                    if (!owned) { StopInstalled(name, target, home, mutex, log); owned = true; }
                                    try {
                                        UpgradeInstaller.Apply(home, Exe, zip, Version, comparison < 0, f => External.SelfTest(f, home, CancellationToken.None));
                                    } catch { if (File.Exists(target)) launch(target, false); throw; }
                                    if (args.Contains("--install") || (!args.Contains("--home") && FirstInstall.Required(home))) { firstRun(); return 0; }
                                    launch(target, true); log.Write("install.upgrade.ok"); return 0;
                                } finally { if (File.Exists(zip)) File.Delete(zip); }
                            }
                            if (firstInstallSource==null && (args.Contains("--install") || (!external && args.Length == 0 && FirstInstall.Required(home)))) { firstRun(); return 0; }
                            if (!owned) {
                                if (TryForward(name, args.Contains("--uninstall") ? new[] { "--exit" } : WindowModel.ForwardArguments(args), log)) { log.Write("ipc.forward.ok"); return 0; }
                                if (command) throw new IOException("Запущенная копия RemoteAgents не отвечает");
                                StopInstalled(name, Path.Combine(home, Product.ExeName), home, mutex, log); owned = true;
                            }
                        } finally { if (installOwned) installer.ReleaseMutex(); }
                    }
                    try {
                        if (args.Contains("--uninstall") || args.Contains("--exit")) return 0;
                        // Наблюдатель вооружён до конструктора трея и любых источников block.ready.
                        sessionEnding = (s, e) => { try { UpgradeInstaller.NoteCurrentImageCleanExit(home); } catch { log.Write("update.clean-exit.write.failed"); } };
                        SystemEvents.SessionEnding += sessionEnding;
                        UpgradeInstaller.NoteImageProcess(home);
                        UpdateWatchdog.Start(home, Exe);
                        updateFailed = UpdateWatchdog.FailureEvent(home);
                        Action failUpdate = () => {
                            if (File.Exists(Path.Combine(home, Product.BundleDirectory, "exe-upgrade.json")) || File.Exists(Path.Combine(home, Product.BundleDirectory, "pending.json"))) { updateFailed.Set(); UpdateWatchdog.SignalFailure(home); }
                        };
                        unhandled = (s, e) => { log.Write("unhandled kind=app-domain"); failUpdate(); };
                        threadException = (s, e) => {
                            log.Write("unhandled kind=ui-thread"); failUpdate();
                            // Вне транзакции сохраняем прежнее завершение при необработанной ошибке UI.
                            if (!File.Exists(Path.Combine(home, Product.BundleDirectory, "exe-upgrade.json")) && !File.Exists(Path.Combine(home, Product.BundleDirectory, "pending.json"))) Environment.Exit(1);
                        };
                        AppDomain.CurrentDomain.UnhandledException += unhandled;
                        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
                        Application.ThreadException += threadException;
                        Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
                        using (var context = new TrayContext(home, log, name, sid, args, firstInstallSource)) {
                            Application.Run(context); restart = context.RestartRequested;
                            try { UpgradeInstaller.NoteCurrentImageCleanExit(home); } catch { log.Write("update.clean-exit.write.failed"); }
                        }
                    } finally { if (owned) { mutex.ReleaseMutex(); owned = false; } }
                }
                if (restart) StartLauncher(Path.Combine(home, Product.ExeName), home, true);
                return 0;
            } catch (Exception ex) {
                if (updateFailed != null) { try { updateFailed.Set(); } catch { } }
                string reason = ex.GetType().Name + ": " + (ex.Message ?? "").Replace("\r", " ").Replace("\n", " ");
                if (reason.Length > 300) reason = reason.Substring(0, 300);
                if (log != null) log.Write("launcher.fatal " + reason);
                MessageBox.Show("Действие не выполнено: " + (ex.Message ?? ex.GetType().Name) + "\n\nПодробности — logs\\launcher.log в папке RemoteAgents.", "RemoteAgents"); return 1;
            } finally {
                if (sessionEnding != null) SystemEvents.SessionEnding -= sessionEnding;
                if (unhandled != null) AppDomain.CurrentDomain.UnhandledException -= unhandled;
                if (threadException != null) Application.ThreadException -= threadException;
                if (updateFailed != null) updateFailed.Dispose();
            }
        }
        static bool WaitMutex(Mutex mutex, int timeout) { try { return mutex.WaitOne(timeout); } catch (AbandonedMutexException) { return true; } }
        internal static void StopInstalled(string name, string target, string home, Mutex mutex, Journal log)
        {
            int pid = 0;
            try { var identity = Forward(name, new[] { "--identify" }); if (Path.GetFullPath(Json.Str(identity, "home")).Equals(home, StringComparison.OrdinalIgnoreCase)) pid = Json.Int(identity, "pid", 0); } catch { }
            // Compatibility with the original one-way pipe: identify the installed image, never an arbitrary PID.
            if (pid == 0) foreach (var p in Process.GetProcessesByName(Product.Name)) using (p) { try { if (p.Id != Process.GetCurrentProcess().Id && p.MainModule.FileName.Equals(target, StringComparison.OrdinalIgnoreCase)) { pid = p.Id; break; } } catch { } }
            // A hung first-install copy (e.g. the EXE in Downloads) holds the same mutex from another path (16.11.2026):
            // only our product name, our Windows session; the mutex itself proves it is this home's instance.
            string image = pid == 0 ? null : target;
            if (pid == 0) foreach (var p in Process.GetProcessesByName(Product.Name)) using (p) { try { if (p.Id != Process.GetCurrentProcess().Id && p.SessionId == Process.GetCurrentProcess().SessionId) { pid = p.Id; image = p.MainModule.FileName; break; } } catch { } }
            bool asked = true;
            try { Forward(name, new[] { "--exit", "--install-stop" }); } catch { asked = false; log.Write("install.shutdown.ipc.failed"); }
            // Allow the owned bridge/Disk shutdown budget before last-resort termination; a silent instance gets 5 s.
            if (WaitMutex(mutex, asked ? 60000 : 5000)) return;
            if (pid == 0) throw new IOException("Не удалось определить зависший экземпляр RemoteAgents");
            using (var process = Process.GetProcessById(pid)) {
                // Recheck identity immediately before last-resort tree termination (PID reuse).
                if (!process.MainModule.FileName.Equals(image, StringComparison.OrdinalIgnoreCase)) throw new IOException("Экземпляр изменился");
                using (var kill = Process.Start(new ProcessStartInfo("taskkill.exe", "/PID " + pid + " /T /F") { UseShellExecute = false, CreateNoWindow = true })) {
                    if (!kill.WaitForExit(10000) || kill.ExitCode != 0) throw new IOException("Не удалось завершить дерево");
                }
            }
            log.Write("install.shutdown.forced"); if (!WaitMutex(mutex, 10000)) throw new IOException("Экземпляр не завершился");
        }
        public static void StartLauncher(string exe, string home, bool afterUpdate, bool started = false, bool preserveUpdateFailure = false)
        { UpgradeInstaller.PrepareImageLaunch(home, DateTime.UtcNow); UpdateWatchdog.Start(home, Exe, preserveUpdateFailure); Process.Start(new ProcessStartInfo(exe, "--tray --home " + Files.Quote(home) + (afterUpdate ? " --after-update" : "") + (started ? " --started" : "")) { UseShellExecute = false, CreateNoWindow = true }); }
        // Preserve a human launch across installation/relaunch; ordinary --tray/--after-update stay quiet.
        static string[] Started(string[] args, bool interactive) { return interactive && !args.Contains("--started") ? args.Concat(new[] { "--started" }).ToArray() : args; }
        [DllImport("kernel32.dll")] static extern bool AttachConsole(uint processId);
        [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(uint processId);
        // A running copy that does not answer within the pipe timeout is treated as hung (16.11.2026).
        static bool TryForward(string name, string[] args, Journal log)
        { try { Forward(name, args); return true; } catch (Exception) { log.Write("ipc.forward.failed"); return false; } }
        internal static System.Collections.Generic.Dictionary<string, object> Forward(string name, string[] args)
        {
            // Windows grants foreground activation to the newly launched process. Transfer it to the existing instance.
            if (WindowModel.ShouldShow(args)) {
                try { var identity = Forward(name, new[] { "--identify" }); int pid = Json.Int(identity, "pid", 0); if (pid > 0) AllowSetForegroundWindow((uint)pid); } catch { }
            }
            using (var pipe = new NamedPipeClientStream(".", name, (args.Contains("--identify") || TransportFaultCommand.IsRequested(args)) ? PipeDirection.InOut : PipeDirection.Out, PipeOptions.Asynchronous)) {
                pipe.Connect(args.Contains("--disk-shell") ? 750 : 10000);
                using (var writer = new StreamWriter(pipe, Files.Utf8, 4096, true)) { writer.WriteLine(Json.Encode(args)); writer.Flush(); }
                // Fault commands require acknowledgement of the receiving build channel too.
                if (!args.Contains("--identify") && !TransportFaultCommand.IsRequested(args)) return Json.Map(null);
                using (var reader = new StreamReader(pipe, Files.Utf8, true, 4096, true)) {
                    var read = reader.ReadLineAsync(); if (!read.Wait(5000)) throw new IOException("Канал не ответил");
                    return Json.Map(Json.Parse(read.Result));
                }
            }
        }
    }
}
