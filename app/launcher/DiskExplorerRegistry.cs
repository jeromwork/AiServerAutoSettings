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
        // Stay below the shell predicate size limit; never truncate a list of exclusions.
        internal const int MaxAppliesToLength = 2000;
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
            var configured = folders.ToArray();
            var rows = configured.Where(f => SafePath(f.Path)).ToArray();
            string uploadApplies = UploadAppliesTo(root, configured);
            foreach (string action in Actions) {
                string key = Prefix + action;
                if (store.Exists(key) && store.Read(key, "RemoteAgentsOwner") != DiskExplorerService.Owner) { log("Проводник: чужой пункт меню пропущен"); continue; }
                var selected = action == "download" ? rows.Where(f => f.ServerOnly && f.Kind == DiskExplorerKind.ServerOnly) : rows.Where(f => !f.ServerOnly && f.Kind != DiskExplorerKind.Local);
                string[] matches = selected.Select(f => "System.ItemPathDisplay:=\"" + f.Path + "\"").ToArray();
                if (action != "add" && matches.Length == 0) { Remove(key); continue; }
                if (action == "add" && uploadApplies == null) {
                    Remove(key); log("Проводник: пункт загрузки скрыт, полный список исключений не помещается или содержит недопустимый путь"); continue;
                }
                string applies = action == "add" ? uploadApplies : "(" + string.Join(" OR ", matches) + ")";
                string label = action == "download" ? "Скачать на компьютер" : action == "keep-server" ? "Оставить только на сервере" : "Загрузить на сервер";
                Set(key, "RemoteAgentsOwner", DiskExplorerService.Owner); Set(key, "MUIVerb", label); Set(key, "Icon", "\"" + exePath + "\",0");
                Set(key, "MultiSelectModel", "Single"); Set(key, "AppliesTo", applies);
                Set(key + @"\command", "", "\"" + exePath + "\"" + (launcherHome == null ? "" : " --home " + Files.Quote(launcherHome)) + " --disk-shell " + action + " \"%1\"");
            }
            if (dirty) changed();
        }
        static string UploadAppliesTo(string root, IEnumerable<DiskFolderState> folders)
        {
            // Local means a Syncthing folder not yet shared with this server: it may still be connected.
            var protectedRows = folders.Where(f => f.ServerOnly || f.Kind != DiskExplorerKind.Local).ToArray();
            if (protectedRows.Any(f => !SafePath(f.Path))) return null;
            var paths = new[] { root }.Concat(protectedRows.Select(f => f.Path)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(p => p, StringComparer.OrdinalIgnoreCase);
            string applies = string.Join(" AND ", paths.Select(p => "NOT System.ItemPathDisplay:=\"" + p + "\""));
            // Removing the owned verb hides it everywhere, including placeholders outside Disk.
            // The next snapshot restores it when the complete predicate fits again.
            return applies.Length <= MaxAppliesToLength ? applies : null;
        }
        internal void Cleanup() { dirty = false; foreach (string action in Actions) Remove(Prefix + action); if (dirty) changed(); }
        void Set(string key, string name, string value) { if (store.Read(key, name) != value) { store.Write(key, name, value); dirty = true; } }
        void Remove(string key) { if (store.Exists(key) && store.Read(key, "RemoteAgentsOwner") == DiskExplorerService.Owner) { store.DeleteTree(key); dirty = true; } }
        static bool SafePath(string path) { return !string.IsNullOrWhiteSpace(path) && path.IndexOfAny(new[] { '"', '\r', '\n', '\0' }) < 0; }
    }
}
