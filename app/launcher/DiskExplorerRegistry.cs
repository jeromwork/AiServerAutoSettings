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
    // The item offered depends on the folder itself, so the menu says what to do with it:
    //   placeholder (only on the server)  -> «Скачать на компьютер»
    //   existing unregistered copy        -> «Синхронизировать с сервером»
    //   folder that syncs with the server -> «Оставить только на сервере»
    //   any other ordinary folder         -> «Загрузить на сервер»   (never on the Disk root)
    // A folder shared with the server but receive-only gets both of the last two: upload turns it into send and receive.
    // All items carry the same icon: the program's tray icon, so they stand out from other programs' items.
    internal sealed class DiskExplorerRegistry
    {
        internal const string Prefix = @"Software\Classes\Directory\shell\RemoteAgents.Disk.";
        // Windows publishes no length limit for AppliesTo (an AQS query in one registry value). The registry rules advise
        // keeping a value under 2048 bytes, so the upload condition is kept within 1024 characters; see UploadScope.
        internal const int MaxAppliesTo = 1024;
        readonly IDiskExplorerRegistry store;
        readonly Action<string> log;
        readonly Action changed;
        bool dirty;
        static readonly string[] Actions = { "download", "sync", "keep-server", "add" };
        internal DiskExplorerRegistry(IDiskExplorerRegistry store, Action<string> log, Action changed = null)
        { this.store = store; this.log = log ?? delegate { }; this.changed = changed ?? delegate { }; }
        // iconPath is the program's icon exported as a .ico file. Without it the items fall back to the program file's own icon.
        internal void Register(string exePath, string root, IEnumerable<DiskFolderState> folders, string launcherHome = null, string iconPath = null)
        {
            dirty = false;
            if (!SafePath(exePath) || !SafePath(root) || (launcherHome != null && !SafePath(launcherHome)) || (iconPath != null && !SafePath(iconPath))) throw new ArgumentException("Недопустимый путь оформления Проводника");
            var rows = folders.Where(f => SafePath(f.Path)).ToArray();
            string[] placeholders = rows.Where(f => f.ServerOnly && f.Kind == DiskExplorerKind.ServerOnly).Select(f => f.Path).ToArray();
            string[] copies = rows.Where(f => f.ServerOnly && f.Kind == DiskExplorerKind.LocalCopy).Select(f => f.Path).ToArray();
            string[] syncing = rows.Where(f => !f.ServerOnly && f.Kind != DiskExplorerKind.Local && f.Kind != DiskExplorerKind.ServerRemoved).Select(f => f.Path).ToArray();
            string[] uploading = rows.Where(f => f.Uploads).Select(f => f.Path).ToArray();
            string icon = "\"" + (iconPath ?? exePath) + "\",0";
            foreach (string action in Actions) {
                string key = Prefix + action;
                if (store.Exists(key) && store.Read(key, "RemoteAgentsOwner") != DiskExplorerService.Owner) { log("Проводник: чужой пункт меню пропущен"); continue; }
                string[] matches = action == "download" ? placeholders : action == "sync" ? copies : action == "keep-server" ? syncing : null;
                if (matches != null && matches.Length == 0) { Remove(key); continue; }
                string applies = matches == null ? UploadScope(root, placeholders.Concat(copies).Concat(uploading)) : "(" + string.Join(" OR ", matches.Select(Term)) + ")";
                if (matches == null && applies.Contains("ItemFolderPathDisplay") && store.Read(key, "AppliesTo") != applies) log("Проводник: папок слишком много для условия меню; «Загрузить на сервер» скрыт на всех папках верхнего уровня Диска");
                string label = action == "download" ? DiskMenu.Download : action == "sync" ? DiskMenu.Sync : action == "keep-server" ? DiskMenu.KeepServer : DiskMenu.Upload;
                Set(key, "RemoteAgentsOwner", DiskExplorerService.Owner); Set(key, "MUIVerb", label); Set(key, "Icon", icon);
                Set(key, "MultiSelectModel", "Single"); Set(key, "AppliesTo", applies);
                Set(key + @"\command", "", "\"" + exePath + "\"" + (launcherHome == null ? "" : " --home " + Files.Quote(launcherHome)) + " --disk-shell " + action + " \"%1\"");
            }
            if (dirty) changed();
        }
        // Where «Загрузить на сервер» applies: an ordinary folder that does not upload yet, in Disk or anywhere else. It is hidden on the
        // Disk root and on the folders in «hidden»: placeholders and folders that already upload to the server. A folder that Syncthing
        // has registered but not shared with the server (or shares receive-only) is not hidden: for it the command has work to do.
        // The condition spells out every hidden folder, but one registry value must stay short. When the list does not fit in
        // MaxAppliesTo, the safe variant is used: every direct child of Disk is hidden as a whole (placeholders and synced folders live
        // there) and only the hidden folders outside Disk are listed; if even those do not fit they are left out (the command itself
        // answers «уже синхронизируется»). The price of the safe variant: a brand-new plain folder placed directly in Disk is not
        // offered the upload item.
        internal static string UploadScope(string root, IEnumerable<string> hidden)
        {
            root = Plain(root);
            string scope = "NOT " + Term(root);
            string[] paths = hidden.Select(Plain).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(p => p, StringComparer.OrdinalIgnoreCase).ToArray();
            if (paths.Length == 0) return scope;
            string exact = scope + string.Concat(paths.Select(Exclude));
            if (exact.Length <= MaxAppliesTo) return exact;
            scope += " AND NOT System.ItemFolderPathDisplay:=\"" + root + "\"";
            string listed = scope + string.Concat(paths.Where(p => !IsChild(p, root)).Select(Exclude));
            return listed.Length <= MaxAppliesTo ? listed : scope;
        }
        static string Term(string path) { return "System.ItemPathDisplay:=\"" + path + "\""; }
        static string Exclude(string path) { return " AND NOT " + Term(path); }
        // Explorer shows a folder path without the closing backslash, except for a drive root.
        static string Plain(string path)
        { string trimmed = path.TrimEnd('\\', '/'); return trimmed.Length == 0 ? path : trimmed.Length == 2 && trimmed[1] == ':' ? trimmed + "\\" : trimmed; }
        static bool IsChild(string path, string root)
        { int cut = path.LastIndexOfAny(new[] { '\\', '/' }); return cut > 0 && string.Equals(Plain(path.Substring(0, cut + 1)), root, StringComparison.OrdinalIgnoreCase); }
        internal void Cleanup() { dirty = false; foreach (string action in Actions) Remove(Prefix + action); if (dirty) changed(); }
        void Set(string key, string name, string value) { if (store.Read(key, name) != value) { store.Write(key, name, value); dirty = true; } }
        void Remove(string key) { if (store.Exists(key) && store.Read(key, "RemoteAgentsOwner") == DiskExplorerService.Owner) { store.DeleteTree(key); dirty = true; } }
        static bool SafePath(string path) { return !string.IsNullOrWhiteSpace(path) && path.IndexOfAny(new[] { '"', '\r', '\n', '\0' }) < 0; }
    }
}
