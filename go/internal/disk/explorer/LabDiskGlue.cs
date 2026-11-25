using System;
using System.IO;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using System.Reflection;
using System.Threading;

// Клей между дословными копиями Проводника из старой Программы (namespace RemoteAgents.Launcher) и EXE Лаборатории.
namespace RemoteAgents.Launcher
{
    // Заглушки того, что копии берут из Product/Program старой Программы (нужны только пути к EXE в пунктах меню, которых в V8 нет).
    internal static class Product { public const string ExeName = "RemoteAgents.exe"; }
    internal static class Program { public static string Exe { get { return Assembly.GetEntryAssembly().Location; } } }
    // V9: реестр пунктов меню Проводника только под СВОИМ префиксом (RemoteAgents.LabDisk.*). Ключи старой Программы
    // (RemoteAgents.Disk.*) не читаются, не пишутся и не удаляются: любой ключ вне нашего префикса игнорируется.
    internal sealed class LabVerbsRegistry : IDiskExplorerRegistry
    {
        internal const string OwnPrefix = @"Software\Classes\Directory\shell\RemoteAgents.LabDisk.";
        readonly IDiskExplorerRegistry inner = new DiskExplorerCurrentUserRegistry();
        static string Map(string key) { return key.StartsWith(DiskExplorerRegistry.Prefix, StringComparison.Ordinal) ? OwnPrefix + key.Substring(DiskExplorerRegistry.Prefix.Length) : null; }
        public bool Exists(string key) { string k = Map(key); return k != null && inner.Exists(k); }
        const string Mark = " (Лаборатория)";
        public string Read(string key, string name)
        {
            string k = Map(key); string v = k == null ? null : inner.Read(k, name);
            if (v != null && IsCommand(key, name)) { string src; lock (sources) { if (sources.TryGetValue(k, out src)) { string exe = ShellExe, a = System.Text.RegularExpressions.Regex.Match(src, @" --disk-shell (\S+) ").Groups[1].Value; if (exe != null && v == "\"" + exe + "\" " + a + " \"%1\"") return src; } } }
            return name == "MUIVerb" && v != null && v.EndsWith(Mark, StringComparison.Ordinal) ? v.Substring(0, v.Length - Mark.Length) : v;
        }
        // Frozen: после остановки поздняя регистрация из потока контроллера не должна вернуть ключи.
        internal volatile bool Frozen;
        // V9b: команда пункта -- маленький клиент asInvoker (без UAC): "<shell.exe>" <действие> "%1". Нет клиента -- пункт не пишется.
        internal volatile string ShellExe;
        readonly System.Collections.Generic.Dictionary<string, string> sources = new System.Collections.Generic.Dictionary<string, string>();
        static bool IsCommand(string key, string name) { return name == "" && key.EndsWith(@"\command", StringComparison.Ordinal); }
        public void Write(string key, string name, string value)
        {
            string k = Map(key); string exe = ShellExe; if (k == null || Frozen || exe == null) return;
            if (IsCommand(key, name)) {
                var m = System.Text.RegularExpressions.Regex.Match(value, @" --disk-shell (\S+) ");
                if (!m.Success) return;
                lock (sources) sources[k] = value;
                value = "\"" + exe + "\" " + m.Groups[1].Value + " \"%1\"";
            }
            inner.Write(k, name, name == "MUIVerb" ? value + Mark : value);
        }
        public void DeleteTree(string key) { string k = Map(key); if (k != null) inner.DeleteTree(k); }
    }
}

namespace RemoteAgents.Lab
{
    using RemoteAgents.Launcher;
    // Контроллер значков/состояний папок Диска. Создаётся лениво, когда Python впервые сообщил «Диск: работает»;
    // без Диска не создаётся вовсе (поведение прежнее). Останавливается до завершения Job (Выход) и при выходе из трея.
    internal sealed class LabDisk
    {
        readonly string home; readonly Action<string> log; readonly Action<string, bool> balloon;
        readonly SynchronizationContext ui = SynchronizationContext.Current;
        DiskExplorerController controller; volatile bool enabled, stopped;
        DiskExplorerRegistry verbs; LabVerbsRegistry store; string triedHome;

        public LabDisk(string home, Action<string> log, Action<string, bool> balloon) { this.home = home; this.log = log; this.balloon = balloon;
            // Остатки прошлого запуска: Cleanup трогает только RemoteAgents.LabDisk.* (LabVerbsRegistry.Map), ключи Программы -- никогда.
            try { new DiskExplorerRegistry(new LabVerbsRegistry(), log, DiskExplorerNotifier.AssociationsChanged).Cleanup(); } catch (Exception) { }
            StartPipe(); }

        // diskHome: каталог Диска от Python (с учётом config.disk.home). Одна попытка создать контроллер на значение каталога.
        public void Sync(bool diskRunning, string diskHome)
        {
            if (stopped) return;
            enabled = diskRunning;
            if (!diskRunning || controller != null || string.IsNullOrEmpty(diskHome) || diskHome == triedHome) return;
            triedHome = diskHome;
            try {
                string assets = Path.Combine(home, "disk-assets"); Unpack(assets);
                var logger = log;
                store = new LabVerbsRegistry();
                // V9b: без клиента (null) пункты не регистрируем (лучше нет меню, чем UAC); контроллер значков создаётся всё равно.
                store.ShellExe = UnpackShell(assets); verbs = new DiskExplorerRegistry(store, logger, DiskExplorerNotifier.AssociationsChanged);
                controller = new DiskExplorerController(home, Root, () => assets, () => enabled && !stopped, () => true,
                    (message, ok) => { var context = ui; if (context != null) context.Post(s => { if (!stopped) balloon(message, ok); }, null); },
                    logger, DiskExplorerNative.CreateService(Path.Combine(diskHome, "explorer-icons"), logger), verbs, diskHome);
                log("Проводник Диска: контроллер запущен (каталог " + diskHome + ")");
            } catch (Exception e) { log("Проводник Диска: не запустился: " + e.Message); controller = null; }
        }

        // ---- запросы из меню Проводника (V9): RemoteAgents-Lab.exe --disk-shell <действие> "<путь>" -> pipe -> Submit ----
        static string PipeName()
        { var id = WindowsIdentity.GetCurrent(); return "RemoteAgents-Lab-disk-" + (id.User != null ? id.User.Value : id.Name); }

        // Клиент: второй экземпляр (до mutex). Не вышло за 750 мс -- сообщение и код 1.
        internal static int ForwardShell(string[] args)
        {
            try {
                if (DiskShellRequest.Parse(args) == null) return 1;
                int at = Array.IndexOf(args, "--disk-shell");
                using (var pipe = new NamedPipeClientStream(".", PipeName(), PipeDirection.Out)) {
                    pipe.Connect(750);
                    var line = new JavaScriptSerializer().Serialize(new[] { args[at + 1], args[at + 2] });
                    using (var writer = new StreamWriter(pipe, new System.Text.UTF8Encoding(false), 4096, true)) { writer.WriteLine(line); writer.Flush(); }
                }
                return 0;
            } catch (Exception) {
                MessageBox.Show("Лаборатория не запущена. Запустите RemoteAgents-Lab и повторите.", "RemoteAgents-Lab");
                return 1;
            }
        }

        void StartPipe()
        {
            var security = new PipeSecurity(); security.SetAccessRuleProtection(true, false); // только текущий пользователь, без сети
            security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.NetworkSid, null), PipeAccessRights.ReadWrite, AccessControlType.Deny));
            security.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User, PipeAccessRights.ReadWrite, AccessControlType.Allow));
            var thread = new Thread(() => {
                while (!stopped) {
                    try {
                        using (var pipe = new NamedPipeServerStream(PipeName(), PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.None, 4096, 4096, security)) {
                            pipe.WaitForConnection();
                            string line; using (var reader = new StreamReader(pipe, new System.Text.UTF8Encoding(false), false, 4096, true)) {
                                var buffer = new char[4097]; int n = 0, got;
                                while (n < buffer.Length && (got = reader.Read(buffer, n, buffer.Length - n)) > 0) n += got;
                                if (n == 0 || n > 4096) continue;
                                line = new string(buffer, 0, n).Trim();
                            }
                            var parts = new JavaScriptSerializer().Deserialize<string[]>(line);
                            if (parts == null || parts.Length != 2) continue;
                            var request = DiskShellRequest.Parse(new[] { "--disk-shell", parts[0], parts[1] });
                            var context = ui; if (context != null) context.Post(x => Submit(request), null);
                        }
                    } catch (Exception e) { if (stopped) return; log("Проводник Диска: pipe: " + e.Message); return; // Go owns the helper lifecycle; no pipe-error polling.
                    }
                }
            }) { IsBackground = true, Name = "lab-disk-pipe" };
            thread.Start();
        }

        void Submit(DiskShellRequest request)
        {
            if (stopped) return;
            var c = controller;
            if (c != null && enabled) c.Submit(request);
            else balloon("Диск сейчас ведёт Программа или не запущен", false);
        }

        // Корень Диска как у старой Программы: RemoteDisk\base.txt, затем profile.disk.base её config.json, иначе %USERPROFILE%\Disk.
        static string Root()
        {
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string installed = Files.ReadLine(Path.Combine(local, "RemoteDisk", "base.txt"));
            if (installed.Length > 0) return installed;
            try {
                var profile = Json.Map(Json.Get(Json.Read(Path.Combine(local, "RemoteAgents", "config.json")), "profile"));
                string value = Json.Str(Json.Map(Json.Get(profile, "disk")), "base");
                if (value.Length > 0) return value;
            } catch (Exception) { }
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Disk");
        }

        static void Unpack(string assets)
        {
            string target = Path.Combine(assets, "disk", "stignore.txt");
            Directory.CreateDirectory(Path.GetDirectoryName(target));
            using (var source = typeof(LabDisk).Assembly.GetManifestResourceStream("RemoteAgents.Lab.stignore.txt"))
            using (var file = new FileStream(target, FileMode.Create, FileAccess.Write)) source.CopyTo(file);
        }

        // The helper itself is the asInvoker shell client; no nested executable.
        string UnpackShell(string assets) { return Program.Exe; }
        internal void Wake() { var c = controller; if (c != null) c.Wake(); }

        // wait=false: только велеть остановиться (до Выхода Python); wait=true: дождаться (до 3,5 с) очистки и значков «Недоступно».
        public void Stop(bool wait)
        {
            stopped = true; enabled = false;
            var c = controller; if (c == null) return;
            c.Dispose();
            if (wait) { c.Wait(3500); controller = null; }
            // При выходе свои пункты меню удаляем (только RemoteAgents.LabDisk.*; ключи Программы не трогаем).
            if (store != null) store.Frozen = true;
            try { if (verbs != null) verbs.Cleanup(); } catch (Exception e) { log("Проводник Диска: очистка пунктов меню: " + e.Message); }
        }
    }
}
