using System;
using System.Collections.Generic;
using System.Linq;
#if !PORTABLE_TEST
using Microsoft.Win32;
#endif

namespace RemoteAgents.Launcher
{
    internal interface IDiskExplorerRegistry
    {
        bool Exists(string key);
        string Read(string key, string name);
        void Write(string key, string name, string value);
        void DeleteTree(string key);
    }
#if !PORTABLE_TEST
    internal sealed class DiskExplorerCurrentUserRegistry : IDiskExplorerRegistry
    {
        public bool Exists(string key) { using (var k = Registry.CurrentUser.OpenSubKey(key)) return k != null; }
        public string Read(string key, string name) { using (var k = Registry.CurrentUser.OpenSubKey(key)) return k == null ? null : k.GetValue(name) as string; }
        public void Write(string key, string name, string value) { using (var k = Registry.CurrentUser.CreateSubKey(key)) k.SetValue(name, value, RegistryValueKind.String); }
        public void DeleteTree(string key) { Registry.CurrentUser.DeleteSubKeyTree(key, false); }
    }
#endif
    // Static shell verbs need no COM registration, administrator privileges or Explorer extension DLL.
    internal sealed class DiskExplorerRegistry
    {
        internal const string Prefix = @"Software\Classes\Directory\shell\RemoteAgents.Disk.";
        readonly IDiskExplorerRegistry store;
        readonly Action<string> log;
        readonly Action changed;
        bool dirty;
        static readonly string[] Actions = { "download", "keep-server", "add" };
        internal DiskExplorerRegistry(IDiskExplorerRegistry store, Action<string> log, Action changed = null)
        { this.store = store; this.log = log ?? delegate { }; this.changed = changed ?? delegate { }; }
        internal void Register(string exePath, string root, IEnumerable<DiskFolderState> folders, string launcherHome = null)
        {
            dirty = false;
            if (!SafePath(exePath) || !SafePath(root) || (launcherHome != null && !SafePath(launcherHome))) throw new ArgumentException("Недопустимый путь оформления Проводника");
            var rows = folders.Where(f => SafePath(f.Path)).ToArray();
            foreach (string action in Actions) {
                string key = Prefix + action;
                if (store.Exists(key) && store.Read(key, "RemoteAgentsOwner") != DiskExplorerService.Owner) { log("Проводник: чужой пункт меню пропущен"); continue; }
                var selected = action == "download" ? rows.Where(f => f.ServerOnly && f.Kind == DiskExplorerKind.ServerOnly) : rows.Where(f => !f.ServerOnly && f.Kind != DiskExplorerKind.Local);
                string[] matches = selected.Select(f => "System.ItemPathDisplay:=\"" + f.Path + "\"").ToArray();
                if (action != "add" && matches.Length == 0) { Remove(key); continue; }
                string applies = action == "add" ? "NOT System.ItemPathDisplay:=\"" + root + "\"" : "(" + string.Join(" OR ", matches) + ")";
                string label = action == "download" ? "Забрать с сервера" : action == "keep-server" ? "Оставить только на сервере" : "Загрузить на сервер";
                Set(key, "RemoteAgentsOwner", DiskExplorerService.Owner); Set(key, "MUIVerb", label); Set(key, "Icon", "\"" + exePath + "\",0");
                Set(key, "MultiSelectModel", "Single"); Set(key, "AppliesTo", applies);
                Set(key + @"\command", "", "\"" + exePath + "\"" + (launcherHome == null ? "" : " --home " + Files.Quote(launcherHome)) + " --disk-shell " + action + " \"%1\"");
            }
            if (dirty) changed();
        }
        internal void Cleanup() { dirty = false; foreach (string action in Actions) Remove(Prefix + action); if (dirty) changed(); }
        void Set(string key, string name, string value) { if (store.Read(key, name) != value) { store.Write(key, name, value); dirty = true; } }
        void Remove(string key) { if (store.Exists(key) && store.Read(key, "RemoteAgentsOwner") == DiskExplorerService.Owner) { store.DeleteTree(key); dirty = true; } }
        static bool SafePath(string path) { return !string.IsNullOrWhiteSpace(path) && path.IndexOfAny(new[] { '"', '\r', '\n', '\0' }) < 0; }
    }
}
