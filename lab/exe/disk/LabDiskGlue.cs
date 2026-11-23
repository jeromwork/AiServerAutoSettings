using System;
using System.IO;
using System.Reflection;
using System.Threading;

// Клей между дословными копиями Проводника из старой Программы (namespace RemoteAgents.Launcher) и EXE Лаборатории.
namespace RemoteAgents.Launcher
{
    // Заглушки того, что копии берут из Product/Program старой Программы (нужны только пути к EXE в пунктах меню, которых в V8 нет).
    internal static class Product { public const string ExeName = "RemoteAgents.exe"; }
    internal static class Program { public static string Exe { get { return Assembly.GetEntryAssembly().Location; } } }
    // V8: пункты меню Проводника (shell verbs) не регистрируются (это V9). Реестр-пустышка: Register/Cleanup ничего не пишут и не стирают.
    internal sealed class NoVerbsRegistry : IDiskExplorerRegistry
    {
        public bool Exists(string key) { return false; }
        public string Read(string key, string name) { return null; }
        public void Write(string key, string name, string value) { }
        public void DeleteTree(string key) { }
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

        public LabDisk(string home, Action<string> log, Action<string, bool> balloon) { this.home = home; this.log = log; this.balloon = balloon; }

        public void Sync(bool diskRunning)
        {
            if (stopped) return;
            enabled = diskRunning;
            if (!diskRunning || controller != null) return;
            try {
                string assets = Path.Combine(home, "disk-assets"); Unpack(assets);
                var logger = log;
                controller = new DiskExplorerController(home, Root, () => assets, () => enabled && !stopped, () => true,
                    (message, ok) => { var context = ui; if (context != null) context.Post(s => { if (!stopped) balloon(message, ok); }, null); },
                    logger, DiskExplorerNative.CreateService(Path.Combine(DiskExplorerController.DefaultDiskHome, "explorer-icons"), logger),
                    new DiskExplorerRegistry(new NoVerbsRegistry(), logger));
                log("Проводник Диска: контроллер запущен (без пунктов меню)");
            } catch (Exception e) { log("Проводник Диска: не запустился: " + e.Message); controller = null; }
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

        // wait=false: только велеть остановиться (до Выхода Python); wait=true: дождаться (до 3,5 с) очистки и значков «Недоступно».
        public void Stop(bool wait)
        {
            stopped = true; enabled = false;
            var c = controller; if (c == null) return;
            c.Dispose();
            if (wait) { c.Wait(3500); controller = null; }
        }
    }
}
