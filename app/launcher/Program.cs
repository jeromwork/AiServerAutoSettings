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
    internal static class Program
    {
        public static string Version { get { return Assembly.GetExecutingAssembly().GetName().Version.ToString(); } }
        public static string Exe { get { return Assembly.GetExecutingAssembly().Location; } }
        public static string DefaultHome { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RemoteAgents"); } }
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
            // Before askpass: ssh may carry a password pipe in its environment while running this relay as ProxyCommand.
            if(args.Length>0 && args[0]=="--invite-hop")return InviteHop.Run(args);
            if(args.Length>0 && args[0]=="--proxy-connect")return ProxyRelay.Run(args);
            string passwordPipe=Environment.GetEnvironmentVariable("REMOTEAGENTS_PASSWORD_PIPE");
            if(!string.IsNullOrEmpty(passwordPipe))return PasswordRelay.Answer(passwordPipe);
            Journal log = null;
            try {
                // Test modes never create or lock the real user's home.
                string elevated = Option(args, "--elevated-component");
                if (elevated != null) return ElevatedTask.RunComponent(Path.GetFullPath(Option(args, "--home") ?? DefaultHome), elevated);
                string test = Option(args, "--selftest-upgrade");
                if (test != null) { AttachConsole(0xFFFFFFFF); return UpgradeSelfTests.Run(Path.GetFullPath(test)); }
                test = Option(args, "--selftest-update");
                if (test != null) { AttachConsole(0xFFFFFFFF); return UpdateSelfTests.Run(Path.GetFullPath(test)); }
                string home = Path.GetFullPath(Option(args, "--home") ?? DefaultHome);
                Directory.CreateDirectory(home); log = new Journal(home); log.Write("launcher.start");
                if (args.Contains("--uninstall")) { if (Product.IsVpn) FirstInstall.UninstallVpn(home); else Uninstall.Run(home); log.Write("uninstall.ok"); return 0; }
                System.Collections.Generic.Dictionary<string,byte[]> refreshFiles=null;
                if(!Product.IsVpn && !args.Contains("--tray") && !args.Contains("--exit")){
                    var overlay=InvitationOverlay.Read(Exe);
                    if(overlay!=null && new Invitation(Json.Map(Json.Parse(System.Text.Encoding.UTF8.GetString(overlay["invite.rainvite"])))).IsRefresh)refreshFiles=overlay;
                }
                if(refreshFiles==null && !Product.IsVpn && !args.Contains("--exit") && !args.Contains("--tray")) {
                    try{bool embedded=InvitationOverlay.Stage(home,Exe);
                        string invitation=embedded?null:Invitation.Find(args,Path.GetDirectoryName(Exe));
                        if(embedded)args=args.Concat(new[]{"--setup-check"}).ToArray();
                        if(invitation!=null){Invitation.Stage(home,invitation);args=args.Concat(new[]{"--setup-check"}).ToArray();}
                    }catch(Exception e){MessageBox.Show(e.Message,"RemoteAgents — приглашение");return 1;}
                }
                var sid = WindowsIdentity.GetCurrent().User; string name = InstanceName(home, sid);
                var security = new MutexSecurity(); security.AddAccessRule(new MutexAccessRule(sid, MutexRights.FullControl, AccessControlType.Allow));
                bool created, owned = false, restart = false;string firstInstallSource=null;
                using (var mutex = new Mutex(false, "Global\\" + name, out created, security)) {
                    // Serialize downloaded installers independently of the running tray's mutex.
                    using (var installer = new Mutex(false, "Global\\" + name + ".Install", out created, security)) {
                        bool installOwned = WaitMutex(installer, 0);
                        if (!installOwned) throw new InvalidOperationException("Установка уже выполняется");
                        Action<string, bool> launch = (path, after) => {
                            if (owned) { mutex.ReleaseMutex(); owned = false; }
                            installer.ReleaseMutex(); installOwned = false;
                            StartLauncher(path, home, after);
                        };
                        Action firstRun = () => {
                            if (owned) { mutex.ReleaseMutex(); owned = false; }
                            installer.ReleaseMutex(); installOwned = false; FirstInstall.Start(home);
                        };
                        try {
                            owned = WaitMutex(mutex, 0);
                            string target = Path.Combine(home, Product.ExeName);
                            if(refreshFiles!=null){
                                if(!File.Exists(target))throw new IOException("Этот компьютер ещё не подключён. Попросите приглашение для регистрации.");
                                if(!owned){StopInstalled(name,target,home,mutex,log);owned=true;}
                                try{RefreshPackage.Apply(home,refreshFiles);}
                                catch(Exception e){launch(target,false);MessageBox.Show(e.Message,"RemoteAgents — обновление связи");return 1;}
                            }
                            bool external = !Path.GetFullPath(Exe).Equals(target, StringComparison.OrdinalIgnoreCase);
                            bool command = args.Any(a => new[] { "--exit", "--uninstall", "--logs", "--rollback", "--restart-components", "--check-updates", "--settings" }.Contains(a));
                            // --tray with --home is also the isolated development/smoke entry point.
                            bool install = external && !command && !(args.Contains("--tray") && args.Contains("--home"));
                            // First setup owns a visible wizard before extraction, selftest or binary downloads.
                            if (install && home.Equals(DefaultHome,StringComparison.OrdinalIgnoreCase) && FirstInstall.Required(home)) {
                                if(!owned){Forward(name,new[]{"--setup-check"});return 0;}
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
                                        if (!owned) Forward(name, new[] { "--setup-check" }); else launch(target, false);
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
                            if (!owned) { Forward(name, args.Contains("--uninstall") ? new[] { "--exit" } : args.Length == 0 ? new[] { "--setup-check" } : args); log.Write("ipc.forward.ok"); return 0; }
                        } finally { if (installOwned) installer.ReleaseMutex(); }
                    }
                    try {
                        if (args.Contains("--uninstall") || args.Contains("--exit")) return 0;
                        Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
                        using (var context = new TrayContext(home, log, name, sid, args, firstInstallSource)) { Application.Run(context); restart = context.RestartRequested; }
                    } finally { if (owned) { mutex.ReleaseMutex(); owned = false; } }
                }
                if (restart) StartLauncher(Path.Combine(home, Product.ExeName), home, true);
                return 0;
            } catch { if (log != null) log.Write("launcher.fatal"); MessageBox.Show("Действие не выполнено. Проверьте logs\\launcher.log в папке RemoteAgents. Обновление могло быть отклонено самопроверкой или ещё проходить проверку здоровья.", "RemoteAgents"); return 1; }
        }
        static bool WaitMutex(Mutex mutex, int timeout) { try { return mutex.WaitOne(timeout); } catch (AbandonedMutexException) { return true; } }
        internal static void StopInstalled(string name, string target, string home, Mutex mutex, Journal log)
        {
            int pid = 0;
            try { var identity = Forward(name, new[] { "--identify" }); if (Path.GetFullPath(Json.Str(identity, "home")).Equals(home, StringComparison.OrdinalIgnoreCase)) pid = Json.Int(identity, "pid", 0); } catch { }
            // Compatibility with the original one-way pipe: identify the installed image, never an arbitrary PID.
            if (pid == 0) foreach (var p in Process.GetProcessesByName(Product.Name)) using (p) { try { if (p.Id != Process.GetCurrentProcess().Id && p.MainModule.FileName.Equals(target, StringComparison.OrdinalIgnoreCase)) { pid = p.Id; break; } } catch { } }
            try { Forward(name, new[] { "--exit", "--install-stop" }); } catch { log.Write("install.shutdown.ipc.failed"); }
            if (WaitMutex(mutex, 20000)) return;
            if (pid == 0) throw new IOException("Не удалось определить экземпляр");
            using (var process = Process.GetProcessById(pid)) {
                // Recheck identity immediately before last-resort tree termination (PID reuse).
                if (!process.MainModule.FileName.Equals(target, StringComparison.OrdinalIgnoreCase)) throw new IOException("Экземпляр изменился");
                using (var kill = Process.Start(new ProcessStartInfo("taskkill.exe", "/PID " + pid + " /T /F") { UseShellExecute = false, CreateNoWindow = true })) {
                    if (!kill.WaitForExit(10000) || kill.ExitCode != 0) throw new IOException("Не удалось завершить дерево");
                }
            }
            log.Write("install.shutdown.forced"); if (!WaitMutex(mutex, 10000)) throw new IOException("Экземпляр не завершился");
        }
        public static void StartLauncher(string exe, string home, bool afterUpdate)
        { Process.Start(new ProcessStartInfo(exe, "--tray --home " + Files.Quote(home) + (afterUpdate ? " --after-update" : "")) { UseShellExecute = false, CreateNoWindow = true }); }
        [DllImport("kernel32.dll")] static extern bool AttachConsole(uint processId);
        internal static System.Collections.Generic.Dictionary<string, object> Forward(string name, string[] args)
        {
            using (var pipe = new NamedPipeClientStream(".", name, args.Contains("--identify") ? PipeDirection.InOut : PipeDirection.Out, PipeOptions.Asynchronous)) {
                pipe.Connect(10000);
                using (var writer = new StreamWriter(pipe, Files.Utf8, 4096, true)) { writer.WriteLine(Json.Encode(args)); writer.Flush(); }
                // Older launchers do not acknowledge commands; only identify needs a reply.
                if (!args.Contains("--identify")) return Json.Map(null);
                using (var reader = new StreamReader(pipe, Files.Utf8, true, 4096, true)) {
                    var read = reader.ReadLineAsync(); if (!read.Wait(5000)) throw new IOException("Канал не ответил");
                    return Json.Map(Json.Parse(read.Result));
                }
            }
        }
    }
}
